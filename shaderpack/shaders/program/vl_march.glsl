// Light shafts and ground mist, marched into half-resolution targets.
// Writes colortex10 = in-scattered light (rgb) + mist transmittance (a), colortex12 = scene distance.
// A fresh dither every frame; vl_temporal (clouds_temporal.glsl with TEMPORAL_VL) accumulates it, and the
// fog pass upsamples it with a depth-aware filter. Doing this at full resolution after TAA left the dither
// visible as grain around the sun.

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

uniform vec3 sunPosition;
uniform mat4 gbufferModelViewInverse;
uniform float rainStrength;
uniform float frameTimeCounter;
#include "/lib/atmosphere.glsl"
#include "/lib/lighting.glsl"

#ifdef VERTEX
flat out vec3 sunDir;
flat out vec3 envLightDir;
flat out vec3 envDirect;
flat out vec3 envAmbient;
void main() {
    gl_Position = ftransform();
    sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    LightEnv e = makeLightEnv(sunDir);
    envLightDir = e.lightDir;
    envDirect = e.directLight;
    envAmbient = e.skyAmbient;
}
#endif

#ifdef FRAGMENT
uniform int frameCounter;
uniform float viewWidth;
uniform float viewHeight;
uniform sampler2D depthtex0;
uniform sampler2D dhDepthTex0;
uniform sampler2D shadowtex1;
uniform mat4 gbufferProjectionInverse;
uniform mat4 dhProjectionInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform vec3 cameraPosition;
uniform int isEyeInWater;
uniform ivec2 eyeBrightnessSmooth;
#define SHADOW_PASS
#include "/lib/shadows.glsl"
#include "/lib/clouds.glsl"
#include "/lib/mist.glsl"

flat in vec3 sunDir;
flat in vec3 envLightDir;
flat in vec3 envDirect;
flat in vec3 envAmbient;

/* RENDERTARGETS: 10,12 */
layout(location = 0) out vec4 outScatter;
layout(location = 1) out vec4 outDist;

float shadowVisibility(vec3 playerPos) {
    vec3 sp = (shadowProjection * (shadowModelView * vec4(playerPos, 1.0))).xyz;
    vec3 ds = distortShadow(sp) * 0.5 + 0.5;
    if (any(lessThan(ds.xy, vec2(0.0))) || any(greaterThan(ds.xy, vec2(1.0)))) return 1.0;
    return step(ds.z - 0.0002, texture(shadowtex1, ds.xy).r);
}

void main() {
    // Use the actual half-resolution target grid. Iris truncates relative buffer sizes, so this keeps
    // normalized sample positions aligned with consumers when the full-resolution viewport is odd-sized.
    vec2 targetRes = max(floor(vec2(viewWidth, viewHeight) * 0.5), vec2(1.0));
    vec2 uv = gl_FragCoord.xy / targetRes;

    float depth = texture(depthtex0, uv).r;
    vec3 viewPos;
    bool sky = false;
    if (depth < 1.0) {
        viewPos = projectAndDivide(gbufferProjectionInverse, vec3(uv, depth) * 2.0 - 1.0);
    } else {
        float dh = texture(dhDepthTex0, uv).r;
        sky = dh >= 1.0;
        viewPos = projectAndDivide(sky ? gbufferProjectionInverse : dhProjectionInverse, vec3(uv, sky ? 1.0 : dh) * 2.0 - 1.0);
    }
    vec3 playerPos = mat3(gbufferModelViewInverse) * viewPos + gbufferModelViewInverse[3].xyz;
    float dist = sky ? 1e6 : length(playerPos);
    if (depth < 0.56) dist = 0.5;
    outDist = vec4(dist, 0.0, 0.0, 0.0);
    vec3 rd = normalize(playerPos);

#if defined DIM_NETHER || defined DIM_END || !defined VOLUMETRIC_LIGHT
    outScatter = vec4(0.0, 0.0, 0.0, 1.0);
    return;
#endif
    if (isEyeInWater != 0) { outScatter = vec4(0.0, 0.0, 0.0, 1.0); return; }

    float dither = ignTemporal(gl_FragCoord.xy, frameCounter);
    float skyExposure = float(eyeBrightnessSmooth.y) / 240.0;
    bool directLightEnabled = skyExposure != 0.0 && any(notEqual(envDirect, vec3(0.0)));
    bool cloudShadowEnabled = !(envLightDir.y < 0.05);
    float mu = dot(rd, envLightDir);
    // Air: thin haze whose shafts are strongest along the long, golden light path of a low sun.
    float lowSun = 1.0 - smoothstep(0.05, 0.45, envLightDir.y);
    float airSigma = 2.6e-4 * (0.35 + 0.6 * lowSun + rainStrength);
    float airPhase = phaseMie(mu, 0.6) * 0.5 + 0.08;
    // Mist: water droplets, strongly forward scattering but with a broad isotropic share.
    float mistPhase = mix(hgPhase(mu, 0.55), 1.0 / (4.0 * PI), 0.45);
    float amount = mistAmount(sunDir);
    vec3 mistAmbient = envAmbient / PI * 0.9;

    vec3 scatter = vec3(0.0);
    float trans = 1.0;

    // Near segment: inside shadow range, terrain and cloud shadows both carve the air.
    float nearEnd = min(dist, SHADOW_DIST * 1.4);
    const int NEAR = 16;
    float stepLen = nearEnd / float(NEAR);
    for (int i = 0; i < NEAR; i++) {
        vec3 p = rd * (float(i) + dither) * stepLen;
        vec3 wp = p + cameraPosition;
        float vis = 1.0;
        if (directLightEnabled) {
            vis = shadowVisibility(p);
            if (cloudShadowEnabled) vis *= cloudShadow(wp, envLightDir);
        }
        // mistDensity returns zero before sampling cloud noise whenever falloff * amount < 0.01.
        // Since falloff is at most 1, amounts below 0.01 can skip the call exactly.
        float mist = amount < 0.01 ? 0.0 : mistDensity(wp, amount);
        vec3 sun = envDirect * vis * skyExposure;
        vec3 inscatter = sun * (airSigma * airPhase + mist * mistPhase) + mistAmbient * mist * skyExposure;
        float stepT = exp(-mist * stepLen);
        // Energy-conserving integral over the step for the mist part; the thin air term is linear.
        scatter += trans * inscatter * (mist > 1e-6 ? (1.0 - stepT) / mist : stepLen);
        trans *= stepT;
    }

    // Far segment: mist only (distant air is the analytic haze), lit through cloud shadows.
    float farEnd = min(dist, 3000.0);
    if (farEnd > nearEnd && amount > 0.01) {
        const int FAR = 10;
        float fl = (farEnd - nearEnd) / float(FAR);
        for (int i = 0; i < FAR; i++) {
            vec3 wp = rd * (nearEnd + (float(i) + dither) * fl) + cameraPosition;
            float mist = mistDensity(wp, amount);
            if (mist <= 1e-6) continue;
            float cloudVis = directLightEnabled && cloudShadowEnabled ? cloudShadow(wp, envLightDir) : 1.0;
            vec3 sun = envDirect * cloudVis * skyExposure;
            vec3 inscatter = (sun * mistPhase + mistAmbient * skyExposure) * mist;
            float stepT = exp(-mist * fl);
            scatter += trans * inscatter * (1.0 - stepT) / mist;
            trans *= stepT;
        }
    }
    outScatter = vec4(scatter, trans);
}
#endif
