// Forward-shaded translucents: water (refraction, absorption, SSR) and tinted glass/ice.
// colortex4 holds the lit opaque scene from deferred, used for refraction and reflections.
// Variants: PROG_WATER (gbuffers_water), PROG_HAND (gbuffers_hand_water), PROG_DH (dh_water).

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

uniform vec3 sunPosition;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;
uniform float rainStrength;
uniform float frameTimeCounter;
uniform ivec2 eyeBrightnessSmooth;
uniform float rainLocal;
#include "/lib/atmosphere.glsl"
#include "/lib/lighting.glsl"

#ifdef VERTEX
#include "/lib/jitter.glsl"
#if !defined PROG_DH && !defined PROG_HAND
in vec4 mc_Entity;
#endif
out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 worldNormal;
out vec3 playerPos;
flat out int mat;
flat out vec3 sunDir;
flat out vec3 envLightDir;
flat out vec3 envDirect;
flat out vec3 envAmbient;
flat out vec3 sunsetLight;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vec2 lm = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    lmcoord = saturate((lm - 1.0 / 32.0) * 16.0 / 15.0);
    glcolor = gl_Color;
    worldNormal = mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
#if defined PROG_WATER || defined PROG_DH
    // Chunk geometry: the normal is already world space; the view-matrix round trip wobbled with view bobbing.
    worldNormal = normalize(gl_Normal);
#endif
#if defined PROG_HAND
    mat = MAT_HAND;
#elif defined PROG_ENTITIES_TRANSLUCENT
    mat = MAT_ENTITY;
#elif defined PROG_DH
    mat = dhMaterialId == DH_BLOCK_WATER ? MAT_WATER : MAT_TRANSLUCENT;
#else
    mat = int(mc_Entity.x + 0.5) - 10000;
    if (mat == MAT_LAVA_FLOWING) mat = MAT_LAVA;
#endif
    vec3 viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    playerPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    gl_Position = gl_ProjectionMatrix * vec4(viewPos, 1.0);
    applyJitter(gl_Position);

    sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    LightEnv e = makeLightEnv(sunDir);
    envLightDir = e.lightDir;
    envDirect = e.directLight;
    envAmbient = e.skyAmbient;
    // Sunset palette light for the sun's path on the water and the clouds reflected in it (same as clouds_march).
    sunsetLight = sunDir.y > -0.16 ? cloudSunsetLight(sunDir) * sunsetWindow(sunDir.y) : vec3(0.0);
}
#endif

#ifdef FRAGMENT
uniform int frameCounter;
uniform sampler2D gtexture;
uniform sampler2D colortex4;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform sampler2D dhDepthTex1;
#if !defined DIM_NETHER && !defined DIM_END
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
#endif
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 dhProjectionInverse;
uniform float viewWidth;
uniform float viewHeight;
uniform float far;
uniform int isEyeInWater;
uniform sampler2D colortex9;
uniform sampler2D colortex8;
#if !defined DIM_NETHER && !defined DIM_END
#include "/lib/shadows.glsl"
#endif
#include "/lib/clouds.glsl"
#include "/lib/night.glsl"
#include "/lib/water.glsl"
#include "/lib/rain.glsl"
#include "/lib/portal.glsl"
#include "/lib/ice.glsl"
#if defined LIGHT_FIELD && !defined PROG_DH && !defined PROG_HAND
#include "/lib/voxel.glsl"
uniform usampler3D voxelSampler;
uniform ivec3 cameraPositionInt;
#endif

// 1 on the portal sheet where it meets its frame, 0 about a block inside. Uses the voxel grid (the frame is
// solid there, the sheet is an emitter); without it the rim is simply absent.
float portalFrameEdge(vec3 wp, bool alongX) {
#if defined LIGHT_FIELD && !defined PROG_DH && !defined PROG_HAND
    ivec3 v = worldBlockToVoxel(ivec3(floor(wp)), cameraPositionInt);
    if (!voxelInside(v - 1) || !voxelInside(v + 1)) return 0.0;
    vec2 f = alongX ? fract(wp.zy) : fract(wp.xy);
    ivec3 side = alongX ? ivec3(0, 0, 1) : ivec3(1, 0, 0);
    float d = 2.0;
    if (voxelType(texelFetch(voxelSampler, v - side, 0).r) == VOXEL_SOLID) d = min(d, f.x);
    if (voxelType(texelFetch(voxelSampler, v + side, 0).r) == VOXEL_SOLID) d = min(d, 1.0 - f.x);
    if (voxelType(texelFetch(voxelSampler, v - ivec3(0, 1, 0), 0).r) == VOXEL_SOLID) d = min(d, f.y);
    if (voxelType(texelFetch(voxelSampler, v + ivec3(0, 1, 0), 0).r) == VOXEL_SOLID) d = min(d, 1.0 - f.y);
    return 1.0 - smoothstep(0.0, 0.45, d);
#else
    return 0.0;
#endif
}
#if defined PROG_DH && defined DIM_END
#include "/lib/end_lod.glsl"
#endif

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 worldNormal;
in vec3 playerPos;
flat in int mat;
flat in vec3 sunDir;
flat in vec3 envLightDir;
flat in vec3 envDirect;
flat in vec3 sunsetLight;
flat in vec3 envAmbient;

#if defined PROG_WATER || defined PROG_ENTITIES_TRANSLUCENT
// Terrain translucents also tag the nether portal in the material buffer, so TAA can reproject its parallax
// interior at the depth it appears to be at. colortex2 blends with SRC_ALPHA / ONE_MINUS_SRC_ALPHA on colour and
// keeps the destination alpha (shaders.properties): alpha 0 leaves the opaque material underneath untouched.
/* RENDERTARGETS: 0,2 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outMat;
#else
/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;
#endif

vec3 viewFromDepth(vec2 uv, float depth) {
    return projectAndDivide(gbufferProjectionInverse, vec3(uv, depth) * 2.0 - 1.0);
}

// Clouds between the camera and this surface (half-resolution cloud history, see clouds_temporal.glsl).
vec3 applyCloudsInFront(vec3 col, vec2 uv, float surfaceDist) {
#if defined CLOUDS && !defined DIM_NETHER && !defined DIM_END
    if (isEyeInWater == 1 || mat == MAT_ENTITY) return col;
    vec2 bufferRes = vec2(textureSize(colortex9, 0));
    vec2 cuv = clamp(uv * bufferRes, vec2(0.5), bufferRes - 0.5) / bufferRes;
    // Cloud history was rendered against opaque depth. A cloud behind this surface must not cover it.
    if (texture(colortex8, cuv).r >= surfaceDist - 0.5) return col;
    vec4 c = texture(colortex9, cuv);
    return col * c.a + c.rgb;
#else
    return col;
#endif
}

// Screen-space reflection against the opaque depth buffer. Returns rgb and hit confidence in a.
vec4 traceSSR(vec3 viewPos, vec3 viewDir, float dither) {
#ifdef WATER_SSR
    float stepLen = 0.5 + length(viewPos) * 0.03;
    vec3 p = viewPos + viewDir * stepLen * dither;
    vec3 prev = viewPos;
    for (int i = 0; i < SSR_STEPS; i++) {
        prev = p;
        p += viewDir * stepLen;
        stepLen *= 1.15;
        vec3 s = projectAndDivide(gbufferProjection, p) * 0.5 + 0.5;
        if (any(lessThan(s.xy, vec2(0.0))) || any(greaterThan(s.xy, vec2(1.0))) || p.z > -0.05) break;
        float sceneDepth = texture(depthtex1, s.xy).r;
        if (sceneDepth >= 1.0) continue;
        // Ray went behind a surface. Only count it as a hit if the surface is plausibly what the ray struck,
        // not something far in front of it (that is what stretched shore trees into vertical streaks).
        if (s.z > sceneDepth) {
            vec3 a = prev, b = p;
            vec3 hs = s;
            for (int j = 0; j < 6; j++) {
                vec3 m = (a + b) * 0.5;
                vec3 ms = projectAndDivide(gbufferProjection, m) * 0.5 + 0.5;
                float sampleDepth = texture(depthtex1, ms.xy).r;
                if (ms.z > sampleDepth) {
                    b = m;
                    hs = ms;
                } else {
                    a = m;
                }
            }
            float hitZ = viewFromDepth(hs.xy, texture(depthtex1, hs.xy).r).z;
            float thickness = 0.35 + 0.015 * -b.z;
            if (abs(hitZ - b.z) > thickness) return vec4(0.0);
            vec2 edge = smoothstep(0.0, 0.08, hs.xy) * (1.0 - smoothstep(0.92, 1.0, hs.xy));
            // Rays heading back toward the camera have little information on screen; fade them.
            float facing = 1.0 - smoothstep(-0.2, 0.1, viewDir.z);
            vec3 hitColor = texture(colortex4, hs.xy).rgb;
            float hitDist = length(viewFromDepth(hs.xy, texture(depthtex1, hs.xy).r));
            // colortex4 excludes clouds, so restore camera-visible clouds only when they precede the SSR hit.
            hitColor = applyCloudsInFront(hitColor, hs.xy, hitDist);
            return vec4(hitColor, edge.x * edge.y * facing);
        }
    }
#endif
    return vec4(0.0);
}

void main() {
#ifdef PROG_WATER
    outMat = vec4(0.0);
#endif
    LightEnv env;
    env.sunDir = sunDir;
    env.lightDir = envLightDir;
    env.directLight = envDirect;
    env.skyAmbient = envAmbient;

    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    vec3 rd = normalize(playerPos);
    float dither = ignTemporal(gl_FragCoord.xy, frameCounter);
    float dist = length(playerPos);

#ifdef PROG_DH
    if (dist < far * 0.78) discard;
#if defined DIM_END
    if (!endLodVisible(dist, gl_FragCoord.xy, frameCounter)) discard;
#endif
    // DH has a separate depth attachment. The pre-translucent snapshot omits late player skin layers,
    // so also test the current vanilla depth before drawing distant water over them.
    float chunkDepth = min(texture(depthtex0, uv).r, texture(depthtex1, uv).r);
    if (chunkDepth < 1.0 && length(viewFromDepth(uv, chunkDepth)) < dist) discard;
#endif

    if (mat == MAT_WATER) {
#ifndef PROG_DH
        // Side faces at the render edge expose the ocean's cross-section; DH water covers beyond.
        if (length(playerPos.xz) > far * mix(0.84, 0.94, dither)) discard;
#endif
        vec3 worldPos = playerPos + cameraPosition;
        vec3 n = normalize(worldNormal);
        if (n.y > 0.5) {
            // Flatten waves with distance to avoid shimmering noise.
            float strength = mix(1.0, 0.2, saturate(dist / 96.0));
            n = waterNormal(worldPos, n, frameTimeCounter, strength);
            // Raindrops ring the surface where rain can reach it.
            if (rainLocal > 0.01 && lmcoord.y > 0.8 && dist < 64.0 && isEyeInWater != 1) {
                vec2 rp = rainRipples(worldPos.xz, frameTimeCounter) * RAIN_RIPPLES * rainLocal * (1.0 - dist / 64.0);
                n = normalize(n + vec3(rp.x, 0.0, rp.y) * 0.16);
            }
        }
        // Biome water colour (vertex tint): turquoise warm oceans, murky swamps, deep blue cold seas.
        vec3 tint = toLinear(glcolor.rgb);
        tint /= max(max(tint.r, tint.g), max(tint.b, 1e-3));
        bool underwater = isEyeInWater == 1;
        if (underwater) {
            // From inside the water, side faces (against ice, glass, air pockets) should just transmit;
            // the composite pass applies the underwater medium.
            if (abs(worldNormal.y) < 0.5) {
                outColor = vec4(texture(colortex4, uv).rgb, 1.0);
                return;
            }
            // Looking up at the surface from below: a bright circle of sky (Snell's window) surrounded by a
            // mirror of the dark water, from total internal reflection past about 48.6 degrees. The surface
            // seen from below is its own downward-facing quad, so derive the waves from the upward normal.
            if (worldNormal.y < 0.0) n = waterNormal(worldPos, vec3(0.0, 1.0, 0.0), frameTimeCounter, mix(1.0, 0.2, saturate(dist / 96.0)));
            vec3 nd = -n;
            float cosI = saturate(dot(-rd, nd));
            float F = fresnelDielectric(cosI, 1.333);
            vec3 viewNd = mat3(gbufferModelView) * nd;
            vec2 wuv = clamp(uv + viewNd.xy * 0.06, vec2(0.001), vec2(0.999));
            vec3 through = texture(colortex4, wuv).rgb;
            float skyVisU = lmcoord.y * lmcoord.y;
            vec3 deep = vec3(0.02, 0.10, 0.12) * mix(vec3(1.0), tint, 0.4)
                      * (envAmbient / PI * 0.8 + envDirect * 0.06) * (0.2 + 0.8 * skyVisU);
            vec3 vPos = (gbufferModelView * vec4(playerPos, 1.0)).xyz;
            vec3 rr = reflect(rd, nd);
            vec4 ssrU = traceSSR(vPos, normalize(mat3(gbufferModelView) * rr), dither);
            vec3 mirror = mix(deep, ssrU.rgb, ssrU.a);
            outColor = vec4(mix(through, mirror, F), 1.0);
            return;
        }

        // Water depth along the view ray, from the opaque depth behind this fragment.
#ifdef PROG_DH
        // DH keeps its own opaque depth; use it so LOD water tints by real depth like vanilla water does.
        float lodBehind = texture(dhDepthTex1, uv).r;
        float waterDepth = lodBehind >= 1.0 ? 24.0
            : max(length(projectAndDivide(dhProjectionInverse, vec3(uv, lodBehind) * 2.0 - 1.0)) - dist, 0.0);
#else
        float behind = texture(depthtex1, uv).r;
        float behindDist = behind >= 1.0 ? far * 2.0 : length(viewFromDepth(uv, behind));
        float waterDepth = max(behindDist - dist, 0.0);
#endif
        vec3 viewN = mat3(gbufferModelView) * n;
        vec2 refrUV = uv + viewN.xy * 0.04 * saturate(waterDepth / 3.0);
#ifndef PROG_DH
        float refrBehind = texture(depthtex1, refrUV).r;
        if (refrBehind < gl_FragCoord.z) refrUV = uv;  // do not refract things in front of the water
#endif
        vec3 refracted = texture(colortex4, refrUV).rgb;

        vec3 shadow = vec3(1.0);
#if !defined DIM_NETHER && !defined DIM_END
        shadow = sampleShadow(playerPos, vec3(0.0, 1.0, 0.0), saturate(envLightDir.y), dither);
#endif
        // Overhead islands can zero the water block's sky light while the surrounding sea remains open to the
        // sky. Keep a little ambient water body and reflection in that case, without lighting enclosed cave pools.
        float openView = underwater ? 0.0 : smoothstep(0.45, 0.85, float(eyeBrightnessSmooth.y) / 240.0);
        float skyVis = max(lmcoord.y * lmcoord.y, 0.25 * openView);
        // Absorption: red goes first, then green; the biome tint shifts which colour survives in depth.
        vec3 absorb = mix(vec3(0.45, 0.11, 0.075), (1.0 - tint) * 0.4 + 0.05, 0.35);
        // Suspended sediment and plankton: grey extinction on top of absorption, so the floor fades within a few
        // blocks instead of reading like a swimming pool (Trevor). Rain stirs the water up.
        float turbidity = WATER_TURBIDITY * (1.0 + 0.6 * rainStrength);
        // Cave pools are still and sediment settles: clear as glass, with cold teal-blue absorption. The body colour
        // is already dark there because it is lit by sky light.
        float caveWater = 1.0 - smoothstep(0.2, 0.6, lmcoord.y);
        turbidity *= mix(1.0, 0.3, caveWater);
        absorb = mix(absorb, vec3(0.55, 0.14, 0.08), caveWater);
        // Light scattered in the top layer veils even a shallow floor: treat every path as if it were a little deeper.
        vec3 transmit = underwater ? vec3(1.0) : exp(-(absorb + turbidity) * (waterDepth + WATER_SURFACE_VEIL * mix(1.0, 0.3, caveWater)));
        // In-scattering from suspended particles gives water a body colour even over deep or dark floors.
        vec3 albedoW = mix(vec3(0.03, 0.13, 0.15), vec3(0.05, 0.12, 0.13) * tint * 1.6, 0.5) * 1.15;
        vec3 scatterCol = albedoW * (envAmbient * skyVis / PI + envDirect * shadow * 0.12);
        vec3 body = refracted * transmit + scatterCol * (1.0 - transmit);

        // Far away, a single pixel covers many small waves, so water behaves like a rough surface: it reflects
        // a spread of sky directions (skewed toward the higher, darker sky) and a smaller share overall.
        // This is what keeps a real sea darker than the sky and gives the horizon a crisp line.
        float rough = mix(0.03, 0.35, saturate(dist / 350.0));
        vec3 r = reflect(rd, n);
        r.y = abs(r.y);
        vec3 rRough = normalize(r + vec3(0.0, rough * 1.4, 0.0));
        vec3 viewPos = (gbufferModelView * vec4(playerPos, 1.0)).xyz;
        vec4 ssr = underwater ? vec4(0.0) : traceSSR(viewPos, normalize(mat3(gbufferModelView) * r), dither);
        vec3 skyRefl = vec3(0.0);
        if (skyVis != 0.0) {
            skyRefl = skyRadiance(rRough, sunDir, 8) + sunAureole(rRough, sunDir);
#if !defined DIM_NETHER && !defined DIM_END
            // Aurora belongs to the sky fallback. The cloud reflection below occludes it with the same cloud field,
            // while an SSR hit remains a scene reflection and receives no extra aurora layer.
            float auroraAmount = auroraVisibility(sunDir.y);
            if (auroraAmount > 0.001) skyRefl += aurora(rRough, frameTimeCounter) * auroraAmount;
#endif
            bool sunsetClouds = sunsetLight.r + sunsetLight.g + sunsetLight.b > 0.0;
            skyRefl = reflectedClouds(skyRefl, rRough, cameraPosition + playerPos, sunsetClouds ? sunDir : envLightDir,
                                      sunsetClouds ? mix(envDirect, sunsetLight, sunsetWindow(sunDir.y)) : envDirect,
                                      sunsetClouds ? sunsetLight : envDirect, sunDir, envAmbient) * skyVis;
        }
        vec3 refl = mix(skyRefl, ssr.rgb, ssr.a * (1.0 - saturate(rough * 2.5)));

        float fres = underwater ? 0.15 : fresnelSchlick(dot(-rd, n), 0.02) * mix(1.0, 0.5, saturate(rough * 2.5));
        vec3 col = mix(body, refl, fres);
#ifndef PROG_DH
        // Shore foam: where the water thins out against the land, broken lacy foam that pulses as small waves lap in.
        if (SHORE_FOAM > 0.0 && !underwater && n.y > 0.5 && dist < 96.0) {
            float edge = 1.0 - smoothstep(0.05, 0.85, waterDepth);
            if (edge > 0.0) {
                vec2 fp = worldPos.xz;
                float t = frameTimeCounter;
                float lace = valueNoise(fp * 2.2 + vec2(t * 0.25, -t * 0.18)) * 0.6 + valueNoise(fp * 5.3 - vec2(t * 0.3, t * 0.21)) * 0.4;
                float lap = 0.5 + 0.5 * sin(waterDepth * 10.0 - t * 1.6 + lace * 3.0);
                float foam = smoothstep(0.5, 0.8, lace * 0.7 + lap * 0.45) * edge * (1.0 - smoothstep(48.0, 96.0, dist));
                vec3 foamCol = vec3(0.82, 0.88, 0.9) * (envAmbient * skyVis / PI + envDirect * shadow * saturate(envLightDir.y) / PI);
                col = mix(col, foamCol, foam * 0.85 * SHORE_FOAM);
            }
        }
#endif

        // Sun glitter: a microfacet highlight whose width grows with distance, so the sun's reflection
        // stretches into a shimmering path across the water toward the viewer.
        vec3 h = normalize(envLightDir - rd);
        float NdotH = saturate(dot(n, h));
        float alpha = mix(0.04, 0.3, saturate(dist / 250.0));
        float a2 = alpha * alpha;
        float dd = NdotH * NdotH * (a2 - 1.0) + 1.0;
        float D = a2 / (PI * dd * dd);
        float NdotV = max(dot(n, -rd), 0.15);
        float Fh = fresnelSchlick(dot(h, -rd), 0.02);
        float spec = D * Fh / (4.0 * NdotV) * saturate(dot(n, envLightDir));
        // Near the horizon the physical direct light fades out (its shadow-direction swap); the golden sun path on
        // water is exactly then at its best, so the glitter takes the sunset palette light while the disc is up.
        vec3 glitterLight = mix(envDirect, sunsetLight * 3.5, saturate(sunsetWindow(sunDir.y) * 1.5) * smoothstep(-0.015, 0.012, sunDir.y));
        col += glitterLight * shadow * spec * skyVis;

        outColor = vec4(applyCloudsInFront(col, uv, dist), 1.0);
        return;
    }

#ifndef PROG_DH
    if (mat == MAT_ICE) {
        // Clear ice: refracted body with cyan absorption and faint frost, under a smooth, silky reflection.
        vec3 wp = playerPos + cameraPosition;
        vec3 n0 = normalize(worldNormal);
        vec3 n = iceNormal(wp, n0);
        float behind = texture(depthtex1, uv).r;
        float behindDist = behind >= 1.0 ? dist + 4.0 : length(viewFromDepth(uv, behind));
        float thickness = clamp(behindDist - dist, 0.0, 6.0);
        vec3 viewN = mat3(gbufferModelView) * n;
        vec2 refrUV = uv + viewN.xy * 0.025 * saturate(thickness);
        if (texture(depthtex1, refrUV).r < gl_FragCoord.z) refrUV = uv;
        vec3 refracted = texture(colortex4, refrUV).rgb;

        vec3 shadow = vec3(1.0);
#if !defined DIM_NETHER && !defined DIM_END
        shadow = sampleShadow(playerPos, n0, saturate(dot(n0, envLightDir)), dither);
#endif
        // Ice is milky, not glass: the block itself (its own texture, lit like any surface, a little desaturated)
        // makes up most of what you see, with the water or ground below showing through faintly. Vanilla's white
        // streaks read as denser frost. This keeps sea ice pale and icy from afar instead of a dark mirror.
        vec4 tex = texture(gtexture, texcoord) * glcolor;
        vec3 iceAlbedo = toLinear(mix(vec3(luminance(tex.rgb)), tex.rgb, 0.7)) * 1.1;
        float frost = smoothstep(0.55, 0.9, luminance(tex.rgb));
        vec3 iceLit = shadeSurface(env, iceAlbedo, n0, -rd, lmcoord, 1.0, mat, shadow, 0.0);
        bool below = isEyeInWater == 1 || dot(n0, rd) > 0.0;
        if (below) {
            // Seen from underneath (typically from under the water of a frozen lake), the underside faces get no sky
            // light of their own and the shadow lookup sits inside the block, so ice read as a dark grey slab. Real
            // ice glows from above: light the sheet by what falls on its top face and let it through, milky.
            vec3 topShadow = vec3(1.0);
#if !defined DIM_NETHER && !defined DIM_END
            topShadow = sampleShadow(playerPos + vec3(0.0, 1.05, 0.0), vec3(0.0, 1.0, 0.0), saturate(envLightDir.y), dither);
#endif
            float skyAbove = max(lmcoord.y, float(eyeBrightnessSmooth.y) / 240.0);
            vec3 glow = iceAlbedo * (envAmbient * skyAbove * skyAbove / PI + envDirect * topShadow * saturate(envLightDir.y) / PI);
            iceLit = glow * vec3(0.8, 0.95, 1.05);
        }
        // Apply held light after the underside skylight override; this early return skips the generic translucent path.
        iceLit += iceAlbedo * handheldLight(playerPos, n0, 1.0);
        vec3 body = mix(refracted * iceTransmit(thickness), iceLit, below ? 0.6 : 0.55 + 0.35 * frost);

        float skyVis = lmcoord.y * lmcoord.y;
        vec3 r = reflect(rd, n);
        vec3 refl = skyVis > 0.0 && r.y > 0.0 ? (skyRadiance(r, sunDir, 6) + sunAureole(r, sunDir)) * skyVis : body * 0.4;
        vec3 viewPos = (gbufferModelView * vec4(playerPos, 1.0)).xyz;
        vec4 ssr = traceSSR(viewPos, normalize(mat3(gbufferModelView) * r), dither);
        refl = mix(refl, ssr.rgb, ssr.a);
        // Seen from below (or from inside water) ice is nearly index-matched: no mirror, it just lets light in.
        float F = iceFresnel(abs(dot(-rd, n))) * (below ? 0.15 : 0.75);
        vec3 col = mix(body, refl, F);

        // A tight sun highlight: polished, not glittery.
        vec3 h = normalize(envLightDir - rd);
        float nh = saturate(dot(n, h));
        const float a2 = 0.0016;
        float dd = nh * nh * (a2 - 1.0) + 1.0;
        col += envDirect * shadow * a2 / (PI * dd * dd) * iceFresnel(dot(h, -rd)) * saturate(dot(n, envLightDir)) * 0.25 * skyVis;
        outColor = vec4(applyCloudsInFront(col, uv, dist), 1.0);
        return;
    }
    if (mat == MAT_PORTAL) {
        // Keep the animated sheet continuous across the portal's blocks. A broad
        // lavender current, modest emitted light, and grazing tint supply motion/depth
        // without the busy noise field that made the previous version look marbled.
        vec3 wp = playerPos + cameraPosition;
        vec3 pn = abs(normalize(worldNormal));
        bool alongX = pn.x > pn.z;
        vec2 q = alongX ? wp.zy : wp.xy;
        float grazing = pow(1.0 - saturate(abs(dot(normalize(worldNormal), -rd))), 3.0);
        // View direction in the portal plane per block of depth, for the parallax layers behind the sheet.
        vec2 viewPlane = (alongX ? rd.zy : rd.xy) / max(abs(alongX ? rd.x : rd.z), 0.25);
        float spriteLum = luminance(texture(gtexture, texcoord).rgb);
        PortalSurface portal = shadePortal(q, viewPlane, spriteLum, portalFrameEdge(wp, alongX), grazing, frameTimeCounter);
#ifdef PROG_WATER
        outMat = vec4(float(MAT_PORTAL) / 255.0, 1.0, 1.0, 1.0);
#elif defined PROG_ENTITIES_TRANSLUCENT
        outMat = vec4(float(MAT_ENTITY) / 255.0, 0.0, 1.0, 0.0);
#endif
        // The portal stays legible when its upper blocks enter a cloud bank. Let some cloud
        // pass in front, but never erase the violet sheet into a flat patch of sky colour.
        vec3 cloudedPortal = applyCloudsInFront(portal.color, uv, dist);
        outColor = vec4(mix(cloudedPortal, portal.color, 0.7), portal.alpha);
        return;
    }
#endif
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < 0.02) discard;
    vec3 n = normalize(worldNormal);
#ifdef PROG_HAND
    // The hand has its own projection; approximate its shadowing from sky light instead of the shadow map.
    vec3 shadow = vec3(smoothstep(0.6, 0.95, lmcoord.y));
#else
    vec3 shadow = vec3(1.0);
#if !defined DIM_NETHER && !defined DIM_END
    shadow = sampleShadow(playerPos, n, saturate(dot(n, envLightDir)), dither);
#endif
#endif
    vec3 col = shadeSurface(env, toLinear(albedo.rgb), n, -rd, lmcoord, 1.0, mat, shadow, 0.0);
#ifndef PROG_HAND
    col += toLinear(albedo.rgb) * handheldLight(playerPos, n, 1.0);
#endif
#ifdef PROG_HAND
    // Arms and held items are opaque: no glass-style reflection, and never blend with the scene behind.
    outColor = vec4(col, 1.0);
    return;
#endif
    float fres = fresnelSchlick(dot(-rd, n), 0.04);
    vec3 skyRefl = vec3(0.0);
    if (lmcoord.y != 0.0) skyRefl = skyRadiance(reflect(rd, n), sunDir, 6) * lmcoord.y * lmcoord.y;
#ifndef PROG_ENTITIES_TRANSLUCENT
    // Glass-like sheen; entities are not glass.
    col = mix(col, skyRefl, fres * 0.6);
#endif
#ifdef PROG_HAND
    // The solid hand pass is cutout, not translucent. Keep transparent texels
    // discarded above, but make visible skin and held-item pixels fully opaque.
    outColor = vec4(col, 1.0);
#else
    float a = mix(albedo.a, 1.0, fres * 0.5);
#ifdef PROG_ENTITIES_TRANSLUCENT
    // Entity bodies are foreground geometry; retain their blend alpha and tag them for deferred cloud guards.
    outColor = vec4(col, a);
    outMat = vec4(float(MAT_ENTITY) / 255.0, 0.0, 1.0, 0.0);
#else
    // Preserve the material's blend alpha while compositing only cloud radiance in front of the surface.
    outColor = vec4(applyCloudsInFront(col, uv, dist), a);
#endif
#endif
}
#endif
