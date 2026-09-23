// Atmospheric fog (aerial perspective), volumetric sun shafts, and underwater fog.

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

uniform vec3 sunPosition;
uniform mat4 gbufferModelViewInverse;
uniform float rainStrength;
uniform float frameTimeCounter;
#include "/lib/atmosphere.glsl"
#include "/lib/lighting.glsl"

#ifdef VERTEX
out vec2 texcoord;
flat out vec3 sunDir;
flat out vec3 envLightDir;
flat out vec3 envDirect;
flat out vec3 envAmbient;
void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    LightEnv e = makeLightEnv(sunDir);
    envLightDir = e.lightDir;
    envDirect = e.directLight;
    envAmbient = e.skyAmbient;
}
#endif

#ifdef FRAGMENT
uniform int frameCounter;
uniform sampler2D colortex0;
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
uniform float far;
uniform float dhFarPlane;
#define SHADOW_PASS
#include "/lib/shadows.glsl"
#include "/lib/clouds.glsl"

in vec2 texcoord;
flat in vec3 sunDir;
flat in vec3 envLightDir;
flat in vec3 envDirect;
flat in vec3 envAmbient;

/* RENDERTARGETS: 0,6 */
layout(location = 0) out vec4 outColor;
// Brightness for eye adaptation, capped so the sun's own pixels count as bright but not overwhelming.
layout(location = 1) out vec4 outAdaptLum;

float shadowVisibility(vec3 playerPos) {
    vec3 sp = (shadowProjection * (shadowModelView * vec4(playerPos, 1.0))).xyz;
    vec3 ds = distortShadow(sp) * 0.5 + 0.5;
    if (any(lessThan(ds.xy, vec2(0.0))) || any(greaterThan(ds.xy, vec2(1.0)))) return 1.0;
    return step(ds.z - 0.0002, texture(shadowtex1, ds.xy).r);
}

void main() {
    vec3 col = texture(colortex0, texcoord).rgb;
    float depth = texture(depthtex0, texcoord).r;
    vec3 viewPos;
    bool sky = false;
    if (depth < 1.0) {
        viewPos = projectAndDivide(gbufferProjectionInverse, vec3(texcoord, depth) * 2.0 - 1.0);
    } else {
        float dhDepth = texture(dhDepthTex0, texcoord).r;
        sky = dhDepth >= 1.0;
        viewPos = projectAndDivide(sky ? gbufferProjectionInverse : dhProjectionInverse,
                                   vec3(texcoord, sky ? 1.0 : dhDepth) * 2.0 - 1.0);
    }
    vec3 playerPos = mat3(gbufferModelViewInverse) * viewPos + gbufferModelViewInverse[3].xyz;
    float dist = sky ? 4096.0 : length(playerPos);
    // The hand uses its own projection; keep fog and light shafts off it.
    if (depth < 0.56) dist = 0.5;
    vec3 rd = normalize(playerPos);
    float dither = ignTemporal(gl_FragCoord.xy, frameCounter);
    float skyExposure = float(eyeBrightnessSmooth.y) / 240.0;

    if (isEyeInWater == 1) {
        // Underwater: strong absorption toward teal, lit by filtered sky/sun.
        const vec3 absorb = vec3(0.30, 0.07, 0.05);
        vec3 trans = exp(-absorb * min(dist, 96.0));
        vec3 medium = vec3(0.02, 0.10, 0.12) * (envAmbient / PI * 0.8 + envDirect * 0.06) * (0.2 + 0.8 * skyExposure);
        col = col * trans + medium * (1.0 - trans);
        outColor = vec4(col, 1.0); outAdaptLum = vec4(min(luminance(col), 10.0));
        return;
    }
    if (isEyeInWater > 1) {
        vec3 fogCol = isEyeInWater == 2 ? vec3(2.0, 0.4, 0.05) : vec3(0.6, 0.65, 0.7);
        col = mix(col, fogCol, 1.0 - exp(-dist * 0.8));
        outColor = vec4(col, 1.0); outAdaptLum = vec4(min(luminance(col), 10.0));
        return;
    }

    // Aerial perspective: blend toward the horizon sky with height-dependent density.
    if (!sky) {
        float worldY = playerPos.y + cameraPosition.y;
        float heightFalloff = exp(-max(worldY - 62.0, 0.0) / 90.0);
        float density = (0.00018 + rainStrength * 0.004) * FOG_DENSITY * mix(0.6, 1.0, heightFalloff);
#if defined DIM_NETHER
        density = 0.014;
#elif defined DIM_END
        density = 0.0025;
#endif
        // dhFarPlane is a projection plane, not the LOD extent (half of it was ~1.6 km, which flattened all
        // distant land into haze). Use the configured LOD radius when DH is active.
        float farDist = dhFarPlane > 0.0 ? LOD_DISTANCE : far;
        float fogAmt = 1.0 - exp(-dist * density);
        // Guarantee the terrain fully dissolves into the sky before the render edge.
        fogAmt = max(fogAmt, smoothstep(farDist * 0.75, farDist, dist));
#if !defined DIM_NETHER && !defined DIM_END
        // Far LODs always dissolve into the haze, so where DH has not generated yet looks the same as far land.
        // Beyond the LOD render distance there is only the sky-below-horizon haze, so terrain must be fully
        // hazed by that edge or the empty band past it shows as a lighter strip above the sea.
        // The ramp only covers the last stretch: starting it earlier flattened distant hills into grey slabs.
        fogAmt = max(fogAmt, smoothstep(LOD_DISTANCE * 0.72, LOD_DISTANCE * 0.97, dist));
#endif
        col = mix(col, hazeColor(rd, sunDir), saturate(fogAmt));

    }

#ifdef VOLUMETRIC_LIGHT
    // March toward the scene point through the shadow map for sun shafts.
    float vlDist = min(dist, SHADOW_DIST * 1.5);
    float stepLen = vlDist / float(VL_STEPS);
    float lit = 0.0;
    for (int i = 0; i < VL_STEPS; i++) {
        vec3 p = rd * (float(i) + dither) * stepLen;
        // Terrain and cloud shadows both carve the air, so beams show under cloud gaps and through trees.
        lit += shadowVisibility(p) * cloudShadow(p + cameraPosition, envLightDir);
    }
    lit /= float(VL_STEPS);
    float mu = dot(rd, envLightDir);
    float phase = phaseMie(mu, 0.72) * 0.7 + 0.08;
    // Low sun: the air is hazier along the long, golden light path, so shafts are strongest at sunrise and
    // sunset and nearly invisible at noon (as in real life and Complementary's light shafts).
    float lowSun = 1.0 - smoothstep(0.05, 0.45, envLightDir.y);
    float haze = (0.35 + 0.6 * lowSun + rainStrength) * (1.0 - exp(-vlDist * 0.004));
    col += envDirect * lit * phase * haze * 0.3 * skyExposure;
#endif

    outColor = vec4(col, 1.0); outAdaptLum = vec4(min(luminance(col), 10.0));}
#endif
