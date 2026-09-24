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
uniform sampler2D colortex0;
uniform sampler2D depthtex0;
uniform sampler2D dhDepthTex0;
uniform mat4 gbufferProjectionInverse;
uniform mat4 dhProjectionInverse;
uniform vec3 cameraPosition;
uniform int isEyeInWater;
uniform ivec2 eyeBrightnessSmooth;
uniform float far;
uniform float dhFarPlane;
#include "/lib/clouds.glsl"
#if defined DIM_NETHER
#include "/lib/nether_atmosphere.glsl"
#endif

in vec2 texcoord;
flat in vec3 sunDir;
flat in vec3 envLightDir;
flat in vec3 envDirect;
flat in vec3 envAmbient;

/* RENDERTARGETS: 0,6 */
layout(location = 0) out vec4 outColor;
// Brightness for eye adaptation, capped so the sun's own pixels count as bright but not overwhelming.
layout(location = 1) out vec4 outAdaptLum;

#if !defined DIM_NETHER && !defined DIM_END
uniform sampler2D colortex11;
uniform sampler2D colortex12;
uniform float viewWidth;
uniform float viewHeight;

// Joint-bilateral upsample of the half-resolution light-shaft/mist history (see deferred's upsampleClouds).
vec4 upsampleVL(vec2 uv, float sceneDist) {
    ivec2 bufferSize = textureSize(colortex11, 0);
    vec2 bufferRes = vec2(bufferSize);
    vec2 p = uv * bufferRes - 0.5;
    ivec2 i0 = ivec2(floor(p));
    vec2 f = fract(p);
    vec4 acc = vec4(0.0);
    float wsum = 0.0;
    for (int k = 0; k < 4; k++) {
        ivec2 o = ivec2(k & 1, k >> 1);
        ivec2 t = clamp(i0 + o, ivec2(0), bufferSize - 1);
        vec2 bw = mix(1.0 - f, f, vec2(o));
        float sd = texelFetch(colortex12, t, 0).r;
        float rel = abs(sd - sceneDist) / max(min(sd, sceneDist), 1.0);
        float w = bw.x * bw.y * (exp(-rel * 6.0) + 1e-3);
        acc += texelFetch(colortex11, t, 0) * w;
        wsum += w;
    }
    return acc / max(wsum, 1e-5);
}
#endif

void main() {
    vec3 col = texture(colortex0, texcoord).rgb;
    float depth = texture(depthtex0, texcoord).r;
    bool sky = false;
    float dhDepth;
    if (!(depth < 1.0)) {
        dhDepth = texture(dhDepthTex0, texcoord).r;
        sky = dhDepth >= 1.0;
    }
    // Sky pixels only use fixed distances below, so skip inverse projection and the camera transform.
    float dist = 4096.0;
    vec3 playerPos;
    if (!sky) {
        vec3 viewPos = depth < 1.0
            ? projectAndDivide(gbufferProjectionInverse, vec3(texcoord, depth) * 2.0 - 1.0)
            : projectAndDivide(dhProjectionInverse, vec3(texcoord, dhDepth) * 2.0 - 1.0);
        playerPos = mat3(gbufferModelViewInverse) * viewPos + gbufferModelViewInverse[3].xyz;
        dist = length(playerPos);
    }
    // The hand uses its own projection; keep fog and light shafts off it.
    if (depth < 0.56) dist = 0.5;
    if (isEyeInWater == 1) {
        // Underwater: strong absorption toward teal, lit by filtered sky/sun.
        const vec3 absorb = vec3(0.30, 0.07, 0.05);
        // Open sky seen from below the surface only exists inside Snell's window; past it (and wherever the
        // surface is not drawn, like LOD water seen from underneath) the view ends in the water itself.
        vec3 trans = sky ? vec3(0.0) : exp(-absorb * min(dist, 96.0));
        float skyExposure = float(eyeBrightnessSmooth.y) / 240.0;
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

    // Aerial perspective: blend toward the horizon sky with height-dependent density. Nether haze skips the
    // first-person hand entirely, whose depth comes from a separate projection.
#if defined DIM_NETHER
    if (!sky && depth >= 0.56) {
#else
    if (!sky) {
#endif
        vec3 rd = normalize(playerPos);
        float worldY = playerPos.y + cameraPosition.y;
        float heightFalloff = exp(-max(worldY - 62.0, 0.0) / 90.0);
        float density = (0.00018 + rainStrength * 0.004) * FOG_DENSITY * mix(0.6, 1.0, heightFalloff);
#if defined DIM_NETHER
        // Thick near the lava seas, thinning with height; the smoke never fully clears.
        float fogY = min(worldY, cameraPosition.y);
        density = 0.005 + 0.011 * exp(-max(fogY - 31.0, 0.0) / 40.0);
#elif defined DIM_END
        density = 0.0025;
#endif
        // dhFarPlane is a projection plane, not the LOD extent (half of it was ~1.6 km, which flattened all
        // distant land into haze). Use the configured LOD radius when DH is active.
        float farDist = dhFarPlane > 0.0 ? LOD_DISTANCE : far;
        float fogAmt = 1.0 - exp(-dist * density);
        // Guarantee the terrain fully dissolves into the sky before the render edge.
        fogAmt = max(fogAmt, smoothstep(farDist * 0.75, farDist, dist));
#ifdef DIM_END
        // The End is an island in the void: far terrain melts into the violet haze.
        fogAmt = max(fogAmt, smoothstep(150.0, 450.0, dist));
#endif
#if !defined DIM_NETHER && !defined DIM_END
        // Far LODs always dissolve into the haze, so where DH has not generated yet looks the same as far land.
        // Beyond the LOD render distance there is only the sky-below-horizon haze, so terrain must be fully
        // hazed by that edge or the empty band past it shows as a lighter strip above the sea.
        // The ramp only covers the last stretch: starting it earlier flattened distant hills into grey slabs.
        fogAmt = max(fogAmt, smoothstep(LOD_DISTANCE * 0.72, LOD_DISTANCE * 0.97, dist));
#endif
#if defined DIM_NETHER
        float hazeY = mix(worldY, cameraPosition.y, 0.5);
        col = mix(col, netherFogColor(rd, hazeY), saturate(fogAmt));
#else
        col = mix(col, hazeColor(rd, sunDir), saturate(fogAmt));
#endif

    }

#if defined DIM_NETHER
    // Integrate a single representative sample through the smoke-height segment. World-space anchoring
    // keeps the billows from sticking to the screen; skip the hand and nearby portal surfaces entirely.
    if (depth >= 0.56 && (sky || dist > 24.0)) {
        vec3 smokeRay;
        float smokeLimit;
        if (sky) {
            vec3 viewRay = projectAndDivide(gbufferProjectionInverse, vec3(texcoord, 1.0) * 2.0 - 1.0);
            smokeRay = normalize(mat3(gbufferModelViewInverse) * viewRay);
            smokeLimit = 220.0;
        } else {
            smokeRay = normalize(playerPos);
            smokeLimit = min(dist, 190.0);
        }

        vec4 smoke = sampleNetherSmoke(cameraPosition, smokeRay, smokeLimit);
        col = mix(col, smoke.rgb, smoke.a);
    }
#endif

#ifdef VOLUMETRIC_LIGHT
#if !defined DIM_NETHER && !defined DIM_END
    // Light shafts and ground mist from the half-resolution march (vl_march + temporal accumulation).
    vec4 vl = upsampleVL(texcoord, sky ? 1e6 : dist);
    col = col * vl.a + vl.rgb;
#endif
#endif

    outColor = vec4(col, 1.0); outAdaptLum = vec4(min(luminance(col), 4.0));}
#endif
