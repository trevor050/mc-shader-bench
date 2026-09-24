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
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D depthtex0;
uniform sampler2D dhDepthTex0;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferModelView;
uniform int frameCounter;
uniform mat4 dhProjectionInverse;
uniform vec3 cameraPosition;
uniform int isEyeInWater;
uniform ivec2 eyeBrightnessSmooth;
uniform float far;
uniform float dhFarPlane;
#include "/lib/clouds.glsl"
#include "/lib/cave.glsl"
#if defined DIM_NETHER
#include "/lib/nether_atmosphere.glsl"
#endif
#include "/lib/reflections.glsl"
#ifdef DIM_END
#include "/lib/end_atmosphere.glsl"
#endif

in vec2 texcoord;
flat in vec3 sunDir;
flat in vec3 envLightDir;
flat in vec3 envDirect;
flat in vec3 envAmbient;

// Eye adaptation input. The Overworld keeps its calibrated arithmetic mean (capped so the sun counts as bright
// but not overwhelming). The Nether and End meter a log average instead: there a lava sea is both the brightest
// thing and a large part of the frame, and an arithmetic mean let it expose every other surface to black.
#if defined DIM_NETHER || defined DIM_END
// Each pixel's reading is capped near a lit-surface level, so a lava sea counts as "bright" but cannot pull the
// exposure down to its own level: the lava stays blinding and the smoke and rock around it stay readable.
vec4 adaptMeter(vec3 c) { return vec4(log2(clamp(luminance(c), 1e-6, 0.8)) + 24.0); }
#else
vec4 adaptMeter(vec3 c) { return vec4(min(luminance(c), 4.0)); }
#endif

/* RENDERTARGETS: 0,6 */
layout(location = 0) out vec4 outColor;
// Brightness for eye adaptation, capped so the sun's own pixels count as bright but not overwhelming.
layout(location = 1) out vec4 outAdaptLum;

#if 1
uniform sampler2D colortex11;
uniform sampler2D colortex8;
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
        float sd = texelFetch(colortex8, t, 0).r;
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
    // The hand is a screen-space overlay with its own depth convention. Keep world fog, underwater
    // absorption, and half-resolution light shafts from tinting it with the scene behind.
    if (depth < 0.56) {
        outColor = vec4(col, 1.0);
        outAdaptLum = adaptMeter(col);
        return;
    }
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
    // Glossy blocks reflect the lit scene (lib/reflections.glsl). Before fog, so the reflection and the surface
    // are hazed together.
    if (!sky && depth < 1.0 && isEyeInWater == 0) {
        vec4 gm = texture(colortex2, texcoord);
        if (gm.a > 0.01) {
            vec4 gnl = texture(colortex1, texcoord);
            vec3 n = decodeNormal(gnl.xy);
            int gmat = int(gm.r * 255.0 + 0.5);
            vec3 rd = normalize(playerPos);
            float rough = sqr(1.0 - gm.a);
            float d1 = ignTemporal(gl_FragCoord.xy, frameCounter);
            float d2 = ignTemporal(gl_FragCoord.xy + vec2(37.0, 11.0), frameCounter);
            vec3 jit = vec3(d1, d2, fract(d1 + d2 * 1.618)) * 2.0 - 1.0;
            vec3 hn = normalize(n + jit * rough * 0.6);
            vec3 r = reflect(rd, hn);
            if (dot(r, n) < 0.02) r = reflect(rd, n);
            float NdotV = saturate(dot(n, -rd));
            bool metal = gmat == MAT_METAL;
            float f0 = metal ? 0.6 : 0.04;
            float F = (f0 + (1.0 - f0) * pow(1.0 - NdotV, 5.0)) * mix(0.55, 1.0, gm.a);
            // Misses: the sky where the surface sees it, otherwise what the surroundings would reflect.
#if defined DIM_NETHER
            vec3 fallback = netherSmogAmbient(netherBiomeAir()) * 2.5 + netherSeaGlow(playerPos + cameraPosition, frameTimeCounter) * 0.05;
#elif defined DIM_END
            vec3 fallback = vec3(0.012, 0.007, 0.02);
#else
            float skyVis = gnl.w * gnl.w;
            vec3 fallback = (skyRadiance(normalize(vec3(r.x, max(r.y, 0.02), r.z)), sunDir, 6) + sunAureole(r, sunDir)) * skyVis * skyVis
                          * smoothstep(-0.3, 0.1, r.y) + col * 0.15;
#endif
            vec3 viewPos = (gbufferModelView * vec4(playerPos, 1.0)).xyz;
            vec4 ssr = traceReflection(viewPos, normalize(mat3(gbufferModelView) * r), d1);
            vec3 refl = mix(fallback, ssr.rgb, ssr.a);
            if (metal) refl *= mix(vec3(1.0), col / max(max(col.r, max(col.g, col.b)), 1e-4), 0.7);
            col = mix(col, refl, F);
        }
    }
#if defined DIM_NETHER
    // Heat haze. The lava never moves: what wavers is whatever is seen *through* the hot air layer over the lava
    // seas (the far shore, pillars, walls across a lake), slowly and mostly vertically, as rising hot air bends
    // light. Strength follows how much of the ray crosses that layer, so looking across a lake shimmers and
    // looking down at the lava from a cliff does not. Lava pixels are never displaced or pulled in.
    if (!sky) {
        int matHere = int(texture(colortex2, texcoord).r * 255.0 + 0.5);
        if (matHere != MAT_LAVA) {
            const float HOT_TOP = NETHER_LAVA_LEVEL + 7.0;
            float y0 = cameraPosition.y, y1 = playerPos.y + cameraPosition.y;
            // Length of the segment camera->surface inside the slab [lava level, HOT_TOP].
            float lo = max(min(y0, y1), NETHER_LAVA_LEVEL), hi = min(max(y0, y1), HOT_TOP);
            float frac = max(hi - lo, 0.0) / max(abs(y1 - y0), 1e-3);
            float inHot = abs(y1 - y0) < 1e-3 ? float(y0 < HOT_TOP) * dist : frac * dist;
            float heat = saturate(inHot / 40.0) * smoothstep(6.0, 24.0, dist);
            if (heat > 0.01) {
                vec2 sp = texcoord * vec2(viewWidth / viewHeight, 1.0);
                float t = frameTimeCounter;
                float wave = valueNoise(vec2(sp.x * 14.0, sp.y * 26.0 - t * 1.1)) - 0.5
                           + (valueNoise(vec2(sp.x * 31.0 + 7.0, sp.y * 57.0 - t * 1.7)) - 0.5) * 0.5;
                float side = valueNoise(vec2(sp.x * 9.0 + 3.0, sp.y * 17.0 - t * 0.6)) - 0.5;
                vec2 uv2 = texcoord + vec2(side * 0.0006, wave * 0.0022) * heat;
                int matThere = int(texture(colortex2, uv2).r * 255.0 + 0.5);
                if (matThere != MAT_LAVA && texture(depthtex0, uv2).r >= 0.56) col = texture(colortex0, uv2).rgb;
            }
        }
    }
#endif
    if (isEyeInWater == 1) {
        // Underwater: strong absorption toward teal, lit by filtered sky/sun.
        const vec3 absorb = vec3(0.30, 0.07, 0.05);
        // Open sky seen from below the surface only exists inside Snell's window; past it (and wherever the
        // surface is not drawn, like LOD water seen from underneath) the view ends in the water itself.
        vec3 trans = sky ? vec3(0.0) : exp(-(absorb + WATER_TURBIDITY * 0.6) * min(dist, 96.0));
        float skyExposure = float(eyeBrightnessSmooth.y) / 240.0;
        vec3 medium = vec3(0.02, 0.10, 0.12) * (envAmbient / PI * 0.8 + envDirect * 0.06) * (0.2 + 0.8 * skyExposure);
        col = col * trans + medium * (1.0 - trans);
        outColor = vec4(col, 1.0); outAdaptLum = adaptMeter(col);
        return;
    }
    if (isEyeInWater > 1) {
        vec3 fogCol = isEyeInWater == 2 ? vec3(2.0, 0.4, 0.05) : vec3(0.6, 0.65, 0.7);
        col = mix(col, fogCol, 1.0 - exp(-dist * 0.8));
        outColor = vec4(col, 1.0); outAdaptLum = adaptMeter(col);
        return;
    }

    // Aerial perspective: blend toward the horizon sky with height-dependent density. Nether haze skips the
    // first-person hand entirely, whose depth comes from a separate projection.
#if !defined DIM_NETHER
    if (!sky) {
#else
    if (false) {
#endif
        vec3 rd = normalize(playerPos);
        float worldY = playerPos.y + cameraPosition.y;
        float heightFalloff = exp(-max(worldY - 62.0, 0.0) / 90.0);
        float density = (0.00018 + rainStrength * 0.004) * FOG_DENSITY * mix(0.6, 1.0, heightFalloff);
#if defined DIM_END
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
#if !defined DIM_NETHER && !defined DIM_END
        // Surfaces that see no sky (caves, deep interiors) fade into the cave's own air. The daylight haze, and
        // the sun's aureole in it, cannot reach them: fogging cave walls with it drew a glowing patch on the rock
        // wherever the sun stood behind it. LOD terrain is always open land.
        float open = depth < 1.0 ? smoothstep(0.03, 0.5, texture(colortex1, texcoord).w) : 1.0;
        vec3 haze = open > 0.0 ? hazeColor(rd, sunDir) : vec3(0.0);
        if (inSnowy > 0.001 && open > 0.0) {
            // Snow biome whiteout: a bright ice haze, dense enough in snowfall to swallow everything past a few
            // dozen blocks. The far fog whitens by the same share as the sky's horizon (below) so they still meet.
            vec3 white = snowWhiteout(haze);
            float wDensity = 0.0019 + 0.028 * rainStrength;
            col = mix(col, white, (1.0 - exp(-dist * wDensity)) * inSnowy * open);
            haze = mix(haze, white, inSnowy * snowHorizonShare());
        }
        if (open < 1.0) {
            float caveAmt = 1.0 - exp(-dist * caveFogDensity());
            vec3 fogCol = mix(caveAirColor(), haze, open);
            col = mix(col, fogCol, saturate(mix(caveAmt, fogAmt, open)));
        } else
            col = mix(col, haze, saturate(fogAmt));
#else
        col = mix(col, hazeColor(rd, sunDir), saturate(fogAmt));
#endif

    }
#if !defined DIM_NETHER && !defined DIM_END
    else if (inSnowy > 0.001) {
        // The whiteout also swallows the sky's lower band, matching the far fog's whitening at the horizon.
        vec3 viewDir = normalize(mat3(gbufferModelViewInverse) * projectAndDivide(gbufferProjectionInverse, vec3(texcoord, 1.0) * 2.0 - 1.0));
        float band = exp(-max(viewDir.y, 0.0) * 7.0);
        col = mix(col, snowWhiteout(col), inSnowy * snowHorizonShare() * band);
    }
#endif

#if defined DIM_NETHER
    // Smog. Past the marched range the medium continues analytically, lit like the smoke at mid height above
    // the seas; then the half-resolution march (composite/vl_march + temporal) covers the near segment.
    {
        float smogDist = sky ? 520.0 : min(dist, 520.0);
        if (smogDist > NETHER_SMOG_RANGE) {
            float ash = netherAshiness();
            vec3 mid = cameraPosition + vec3(0.0, -0.35 * max(cameraPosition.y - NETHER_LAVA_LEVEL, 0.0), 0.0);
            vec3 farLight = netherSeaGlow(mid, frameTimeCounter) + netherSmogAmbient(netherBiomeAir());
            float sigmaFar = (0.010 + 0.026 * exp(-max(mid.y - NETHER_LAVA_LEVEL, 0.0) / 30.0) + 0.02) * (1.0 + ash * 0.9);
            float farT = exp(-sigmaFar * (smogDist - NETHER_SMOG_RANGE));
            col = col * farT + farLight * 0.45 * (1.0 - farT);
        }
        vec4 smog = upsampleVL(texcoord, sky ? 1e6 : dist);
        col = col * smog.a + smog.rgb;
    }
#endif

#if defined DIM_END
    // End storm from the half-resolution march (vl_march + temporal accumulation).
    {
        vec4 storm = upsampleVL(texcoord, sky ? 1e6 : dist);
        col = col * storm.a + storm.rgb;
        // (No full-screen flare: the End's scene values are ~0.02-0.05, so even a +0.02 flare nearly doubled every
        // pixel on each strike and washed the view purple. The strike lights the clouds near the bolt instead.)
    }
#endif

#ifdef VOLUMETRIC_LIGHT
#if !defined DIM_NETHER && !defined DIM_END
    // Light shafts and ground mist from the half-resolution march (vl_march + temporal accumulation).
    vec4 vl = upsampleVL(texcoord, sky ? 1e6 : dist);
    col = col * vl.a + vl.rgb;
#endif
#endif

    outColor = vec4(col, 1.0); outAdaptLum = adaptMeter(col);}
#endif
