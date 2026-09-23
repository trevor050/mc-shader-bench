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

uniform sampler2D colortex11;
uniform sampler2D colortex12;
uniform float viewWidth;
uniform float viewHeight;

// Joint-bilateral upsample of the half-resolution light-shaft/mist history (see deferred's upsampleClouds).
vec4 upsampleVL(vec2 uv, float sceneDist) {
    vec2 halfRes = ceil(vec2(viewWidth, viewHeight) * 0.5);
    vec2 p = uv * halfRes - 0.5;
    ivec2 i0 = ivec2(floor(p));
    vec2 f = fract(p);
    vec4 acc = vec4(0.0);
    float wsum = 0.0;
    for (int k = 0; k < 4; k++) {
        ivec2 o = ivec2(k & 1, k >> 1);
        ivec2 t = clamp(i0 + o, ivec2(0), ivec2(halfRes) - 1);
        vec2 bw = mix(1.0 - f, f, vec2(o));
        float sd = texelFetch(colortex12, t, 0).r;
        float rel = abs(sd - sceneDist) / max(min(sd, sceneDist), 1.0);
        float w = bw.x * bw.y * (exp(-rel * 6.0) + 1e-3);
        acc += texelFetch(colortex11, t, 0) * w;
        wsum += w;
    }
    return acc / max(wsum, 1e-5);
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
        outColor = vec4(col, 1.0); outAdaptLum = vec4(min(luminance(col), 4.0));
        return;
    }
    if (isEyeInWater > 1) {
        vec3 fogCol = isEyeInWater == 2 ? vec3(2.0, 0.4, 0.05) : vec3(0.6, 0.65, 0.7);
        col = mix(col, fogCol, 1.0 - exp(-dist * 0.8));
        outColor = vec4(col, 1.0); outAdaptLum = vec4(min(luminance(col), 4.0));
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
    // Light shafts and ground mist from the half-resolution march (vl_march + temporal accumulation).
    vec4 vl = upsampleVL(texcoord, sky ? 1e6 : dist);
    col = col * vl.a + vl.rgb;
#endif

    outColor = vec4(col, 1.0); outAdaptLum = vec4(min(luminance(col), 4.0));}
#endif
