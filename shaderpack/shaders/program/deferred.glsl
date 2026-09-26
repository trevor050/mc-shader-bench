// Deferred lighting for opaque geometry (vanilla chunks and DH LODs) plus the sky.
// Writes lit HDR to colortex0 and a copy to colortex4 for water refraction and reflections.

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

uniform vec3 sunPosition;
uniform mat4 gbufferModelViewInverse;
uniform float rainStrength;
uniform float frameTimeCounter;
#include "/lib/atmosphere.glsl"
#include "/lib/end_portal.glsl"
#if !defined DIM_NETHER && !defined DIM_END
#include "/lib/cloud_weather.glsl"
#endif
#if defined FRAGMENT && defined LIGHT_FIELD
#define VOXEL_READ
#define FIELD_SHADING
uniform sampler3D lightFieldSamplerA;
uniform sampler3D lightFieldSamplerB;
uniform vec3 cameraPositionFract;
#ifdef LIGHT_FIELD_DEBUG
uniform usampler3D voxelSampler;
uniform ivec3 cameraPositionInt;
#endif
#endif
#ifdef FRAGMENT
uniform int frameCounter;
#endif
#ifdef LIGHT_FIELD
#include "/lib/voxel.glsl"
#endif
#include "/lib/lighting.glsl"
#include "/lib/ice.glsl"

#ifdef VERTEX
out vec2 texcoord;
flat out vec3 sunDir;
flat out vec3 envLightDir;
flat out vec3 envDirect;
flat out vec3 envAmbient;
#if !defined DIM_NETHER && !defined DIM_END
flat out vec4 cloudWeather0;
flat out vec3 cloudWeather1;
#endif

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    LightEnv e = makeLightEnv(sunDir);
    envLightDir = e.lightDir;
    envDirect = e.directLight;
    envAmbient = e.skyAmbient;
#if !defined DIM_NETHER && !defined DIM_END
    CloudWeather w = cloudWeather();
    cloudWeather0 = vec4(w.cov0, w.tower, w.cov1, w.cirrus);
    cloudWeather1 = vec3(w.low, w.lowCov, w.cb);
#endif
}
#endif

#ifdef FRAGMENT
uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D depthtex0;
uniform sampler2D dhDepthTex0;
#if !defined DIM_NETHER && !defined DIM_END
#define SHADOWS_AVAILABLE
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;
#endif
uniform mat4 gbufferProjectionInverse;
uniform mat4 dhProjectionInverse;
#if !defined DIM_NETHER && !defined DIM_END
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
#endif
uniform vec3 cameraPosition;
// Wetness and rain level where the player is: zero in biomes without precipitation (deserts, savannas), where
// vanilla draws no rain either (custom uniforms, shaders.properties). The sky and clouds keep the global rain level.
uniform float wetLocal;
uniform float rainLocal;
uniform mat4 gbufferProjection;
uniform mat4 gbufferModelView;
uniform sampler2D colortex8;
uniform sampler2D colortex9;
uniform float viewWidth;
uniform float viewHeight;
#if !defined DIM_NETHER && !defined DIM_END
#include "/lib/shadows.glsl"
#endif
#include "/lib/clouds.glsl"
#ifdef DIM_END
#include "/lib/end_atmosphere.glsl"
#endif
#include "/lib/stars.glsl"
#include "/lib/night.glsl"
#include "/lib/rain.glsl"

in vec2 texcoord;
flat in vec3 sunDir;
flat in vec3 envLightDir;
flat in vec3 envDirect;
flat in vec3 envAmbient;
#if !defined DIM_NETHER && !defined DIM_END
flat in vec4 cloudWeather0;
flat in vec3 cloudWeather1;
#endif

/* RENDERTARGETS: 0,4 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outCopy;

// Hemisphere SSAO in view space; the per-frame dither lets TAA converge it to a smooth result.
float ssao(vec3 viewPos, vec3 viewN, float dither) {
    const int SAMPLES = 8;
    const float RADIUS = 0.9;
    float occ = 0.0;
    vec3 t = normalize(abs(viewN.y) < 0.9 ? cross(viewN, vec3(0.0, 1.0, 0.0)) : cross(viewN, vec3(1.0, 0.0, 0.0)));
    vec3 b = cross(viewN, t);
    float cosPhi = cos(dither * TAU);
    float sinPhi = sin(dither * TAU);
    // GLSL indexes matrices as [column][row]. Keep the x/y terms for jittered or off-axis projections.
    vec4 inverseZ = vec4(gbufferProjectionInverse[0][2], gbufferProjectionInverse[1][2],
                         gbufferProjectionInverse[2][2], gbufferProjectionInverse[3][2]);
    vec4 inverseW = vec4(gbufferProjectionInverse[0][3], gbufferProjectionInverse[1][3],
                         gbufferProjectionInverse[2][3], gbufferProjectionInverse[3][3]);
    for (int i = 0; i < SAMPLES; i++) {
        float fi = (float(i) + dither) / float(SAMPLES);
        float r = sqrt(fi);
        vec3 h = vec3(r * cosPhi, r * sinPhi, sqrt(max(1.0 - fi, 0.0)));
        float nextCosPhi = cosPhi * -0.7373688781 - sinPhi * 0.6754902943;
        sinPhi = sinPhi * -0.7373688781 + cosPhi * 0.6754902943;
        cosPhi = nextCosPhi;
        vec3 dir = t * h.x + b * h.y + viewN * h.z;
        vec3 s = viewPos + dir * RADIUS * mix(0.15, 1.0, fi * fi);
        vec3 sp = projectAndDivide(gbufferProjection, s) * 0.5 + 0.5;
        if (any(lessThan(sp.xy, vec2(0.0))) || any(greaterThan(sp.xy, vec2(1.0)))) continue;
        float d = texture(depthtex0, sp.xy).r;
        if (d >= 1.0) continue;
        vec4 ndc = vec4(sp.xy * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);
        float sceneZ = dot(inverseZ, ndc) / dot(inverseW, ndc);
        float range = smoothstep(0.0, 1.0, RADIUS / abs(viewPos.z - sceneZ));
        occ += step(s.z + 0.03, sceneZ) * range;
    }
    return 1.0 - occ / float(SAMPLES);
}

// Spectral colour across a rainbow band (x = 0 violet ... 1 red).
vec3 hsv2rgbBow(float x) {
    float h = mix(0.78, 0.0, saturate(x));
    vec3 p = abs(fract(vec3(h) + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return saturate(p - 1.0);
}

// Joint-bilateral upsample of the half-resolution cloud history: taps whose scene distance differs from this
// pixel's (a tree edge in front of a cloud) are down-weighted so clouds do not bleed across silhouettes.
vec4 upsampleClouds(vec2 uv, float sceneDist) {
    ivec2 bufferSize = textureSize(colortex9, 0);
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
        float sd = texelFetch(colortex8, t, 0).g;
        float rel = abs(sd - sceneDist) / max(min(sd, sceneDist), 1.0);
        float w = bw.x * bw.y * (exp(-rel * 6.0) + 1e-3);
        acc += texelFetch(colortex9, t, 0) * w;
        wsum += w;
    }
    return acc / max(wsum, 1e-5);
}

void main() {
    LightEnv env;
    env.sunDir = sunDir;
    env.lightDir = envLightDir;
    env.directLight = envDirect;
    env.skyAmbient = envAmbient;

    float depth = texture(depthtex0, texcoord).r;
    bool isLod = false;
    vec3 viewPos;
    if (depth < 1.0) {
        viewPos = projectAndDivide(gbufferProjectionInverse, vec3(texcoord, depth) * 2.0 - 1.0);
    } else {
        float dhDepth = texture(dhDepthTex0, texcoord).r;
        isLod = dhDepth < 1.0;
        viewPos = projectAndDivide(isLod ? dhProjectionInverse : gbufferProjectionInverse,
                                   vec3(texcoord, isLod ? dhDepth : 1.0) * 2.0 - 1.0);
    }
    vec3 playerPos = mat3(gbufferModelViewInverse) * viewPos + gbufferModelViewInverse[3].xyz;
    vec3 rd = normalize(playerPos);
    vec4 gAlbedo = texture(colortex0, texcoord);

    vec3 col;
    if (depth >= 1.0 && !isLod) {
        // Sky. colortex0 holds whatever the sky programs drew (stars, moon) in linear light.
        // The sun is drawn below the eye-level horizon too: from high ground the land's edge is lower still.
        col = rd.y < 0.0 ? hazeColor(rd, sunDir) + (rd.y > -0.15 ? sunDisc(rd, sunDir) : vec3(0.0)) : skyRadiance(rd, sunDir, 12) + sunAureole(rd, sunDir) + sunDisc(rd, sunDir);
#ifdef DIM_END
        float night = 1.0;
#else
        float night = smoothstep(0.05, -0.15, sunDir.y);
#endif
        float pixelAngle = 2.0 / (gbufferProjection[1][1] * viewHeight);
        // Reconstructing the direction from the far-plane depth loses precision; stars need an exact ray.
        vec3 viewDir = normalize(vec3((texcoord * 2.0 - 1.0) / vec2(gbufferProjection[0][0], gbufferProjection[1][1]), -1.0));
        vec3 starDir = normalize(mat3(gbufferModelViewInverse) * viewDir);
#if !defined DIM_END && !defined DIM_NETHER
        col += moonSky(starDir, -sunDir);
#endif
#if !defined DIM_NETHER && !defined DIM_END
        // Rainbow: after rain, while the air is still wet and the rain itself has passed, a bow of about 42
        // degrees around the point opposite the sun, red outside and violet inside, with a faint secondary
        // bow at 51 degrees (colours reversed) and a darker band between them (Alexander's band).
        {
            float wetAir = saturate(wetLocal * 1.4 - rainLocal * 2.0);
            if (wetAir > 0.0 && sunDir.y > 0.0 && sunDir.y < 0.7) {
                float a = degrees(acos(clamp(dot(starDir, -sunDir), -1.0, 1.0)));
                float x1 = (a - 40.6) / 2.0;              // 0 = violet edge, 1 = red edge
                float x2 = (52.5 - a) / 3.2;
                vec3 bow = vec3(0.0);
                if (x1 > -0.3 && x1 < 1.3) bow += hsv2rgbBow(x1) * smoothstep(-0.3, 0.1, x1) * smoothstep(1.3, 0.9, x1);
                if (x2 > -0.3 && x2 < 1.3) bow += hsv2rgbBow(x2) * smoothstep(-0.3, 0.1, x2) * smoothstep(1.3, 0.9, x2) * 0.35;
                float band = smoothstep(42.5, 43.5, a) * smoothstep(50.5, 49.5, a);
                float strength = wetAir * smoothstep(0.0, 0.08, starDir.y + 0.02) * smoothstep(0.7, 0.3, sunDir.y);
                col = col * mix(1.0, 0.85, band * wetAir) + bow * envDirect * 0.02 * strength;
            }
        }
#endif
#ifndef DIM_NETHER
        // The Nether has no sky: no stars or Milky Way (found by Codex's perf audit).
        if (night > 0.0 && rainStrength < 1.0 && starDir.y > -0.02) {
            col += nightSky(starDir, sunDir, pixelAngle, frameTimeCounter, gl_FragCoord.xy, mat3(gbufferModelView),
                            vec2(gbufferProjection[0][0], gbufferProjection[1][1]), vec2(viewWidth, viewHeight)) * night * (1.0 - rainStrength);
        }
#if !defined DIM_END
        // Aurora over snowy lands on clear nights. It sits behind the clouds (composited below).
        float auroraAmt = AURORA * inSnowy * night * (1.0 - rainStrength) * smoothstep(-0.12, -0.3, sunDir.y);
        if (auroraAmt > 0.001) col += aurora(starDir, frameTimeCounter) * auroraAmt;
#endif
#endif
#if defined DIM_NETHER || defined DIM_END
        col += gAlbedo.rgb;
#endif
    } else {
        vec4 nl = texture(colortex1, texcoord);
        vec4 m = texture(colortex2, texcoord);
        vec3 n = decodeNormal(nl.xy);
        int mat = int(m.r * 255.0 + 0.5);
        // Very dark textures (obsidian, blackstone) crush to pure black with a plain 2.2 decode; ease the
        // curve at the bottom so their texture and hue survive.
        vec3 albedo = pow(gAlbedo.rgb, vec3(mix(1.75, 2.2, smoothstep(0.0, 0.25, luminance(gAlbedo.rgb)))));
        // Packed and blue ice: vanilla's saturated blue reads as plastic; pull it toward a paler, icier tone.
        if (mat == MAT_ICE_SOLID) albedo = mix(vec3(luminance(albedo)), albedo, 0.55) * 1.15;
        float NdotL = dot(n, envLightDir);
        vec3 shadow = vec3(1.0);
        bool foliage = mat == MAT_FOLIAGE || mat == MAT_LEAVES || mat == MAT_TALL_UPPER;
        // The first-person hand has its own projection, so world-space effects (shadow map, SSAO, clouds) would
        // sample unrelated places. Shade it from its sky light level instead.
        bool isHand = mat == MAT_HAND;
        vec3 wp = playerPos + cameraPosition;
        if (mat == MAT_LAVA && isLod) {
            // DH supplies a flat vertex colour instead of the Minecraft atlas UVs. Keep its emissive
            // G-buffer colour, then add broad, world-anchored variation as a cheap nonperiodic fallback.
            vec3 an = abs(n);
            vec2 p = an.y >= max(an.x, an.z) ? wp.xz : (an.x >= an.z ? wp.zy : wp.xy);
            float broad = valueNoise(p * 0.035 + wp.y * 0.017);
            float flicker = valueNoise(p * 0.21 + vec2(frameTimeCounter * 0.08, -frameTimeCounter * 0.05));
            albedo *= 0.78 + 0.24 * broad + 0.08 * flicker;
        }
        if (isHand) shadow = vec3(smoothstep(0.6, 0.95, nl.w));
#if !defined DIM_NETHER && !defined DIM_END
        // The hand has its own projection, so it cannot look up its own pixels in the shadow map. Use the shadow
        // next to the player instead (one value for the whole hand): standing in shade darkens it, instead of
        // the sky-light guess that kept it sunlit under trees and overhangs. The point sits a block toward the sun
        // so the player's own body, which is in the shadow map, never shades it.
        if (isHand) shadow = sampleShadow(vec3(0.0, -0.3, 0.0) + envLightDir * 1.1, envLightDir, 1.0, 0.5) * smoothstep(0.3, 0.8, nl.w);
        if (!isLod && !isHand && (NdotL > -0.4 || foliage)) {
            shadow = sampleShadow(playerPos, foliage ? envLightDir : n, abs(NdotL), ignTemporal(gl_FragCoord.xy, frameCounter));
            if (shadowWaterDepth > 0.05) {
                // Project along the light onto the water plane so the pattern slides with the sun.
                vec2 cuv = (wp.xz + envLightDir.xz / max(envLightDir.y, 0.2) * shadowWaterDepth) / 5.0;
                float c = caustics(cuv, frameTimeCounter * 0.6);
                // Strongest over shallow floors (a block or a few deep), where the focused light is still tight.
                float cAmt = saturate(shadowWaterDepth * 1.4) * mix(1.0, 0.55, smoothstep(3.0, 12.0, shadowWaterDepth));
                shadow *= mix(1.0, 0.3 + c * 3.0 * CAUSTIC_STRENGTH, cAmt);
            }
        }
        {
            CloudWeather w = CloudWeather(cloudWeather0.x, cloudWeather0.y, cloudWeather0.z,
                                          cloudWeather0.w, cloudWeather1.x, cloudWeather1.y,
                                          cloudWeather1.z);
            shadow *= cloudShadow(isHand ? cameraPosition : wp, envLightDir, w);
        }
#endif

#ifdef DIM_END
        // The islands are lit from the vortex core overhead, through the storm: its clumps cast soft shadows that
        // sweep across the ground as the vortex turns.
        if (!isHand && !isLod) {
            vec3 toCore = normalize(END_CORE_LIGHT - wp);
            env.lightDir = toCore;
            float occ = endStorm(wp + toCore * 25.0, frameTimeCounter).x * 30.0
                      + endStorm(wp + toCore * 70.0, frameTimeCounter).x * 60.0
                      + endStorm(wp + toCore * 150.0, frameTimeCounter).x * 100.0;
            // The core's heartbeat reaches the ground too.
            shadow = vec3(exp(-occ * 1.2)) * (0.92 + 0.15 * endPulse(frameTimeCounter));
        }
#endif
        // Rain: sky-exposed surfaces darken and turn glossy; flat ground pools into puddles.
        float wet = isHand ? 0.0 : wetLocal * smoothstep(0.82, 0.97, nl.w) * (foliage ? 0.4 : 1.0);
        float puddle = 0.0;
        if (wet > 0.0 && n.y > 0.9 && !foliage) {
            float pn = valueNoise(wp.xz * 0.12) * 0.65 + valueNoise(wp.xz * 0.5) * 0.35;
            puddle = smoothstep(0.52, 0.62, pn) * wet;
        }
        // While it is still raining, drops land in the puddles: rings of ripples on the mirror.
        vec2 ripple = vec2(0.0);
        if (puddle > 0.0 && rainLocal > 0.01 && length(playerPos) < 64.0)
            ripple = rainRipples(wp.xz, frameTimeCounter) * RAIN_RIPPLES * rainLocal * (1.0 - length(playerPos) / 64.0);
        // Standing water hides the surface color underneath, so puddles read as dark, glossy patches.
        albedo *= mix(1.0, 0.55, wet * 0.8) * mix(1.0, 0.25, puddle);
        float ao = m.b;
        if (!isLod && !isHand) {
            vec3 viewN = mat3(gbufferModelView) * n;
            ao *= mix(1.0, ssao(viewPos, viewN, ignTemporal(gl_FragCoord.xy + 17.0, frameCounter)), 0.85);
        }
        // Past the shadow map, canopies lose all self-shadowing and glow flat, which makes LOD trees stand
        // out against shadowed near trees. Approximate the missing inner-canopy occlusion.
        float farFoliage = foliage ? smoothstep(SHADOW_DIST * 0.8, SHADOW_DIST, length(playerPos)) : 0.0;
        if (isLod && mat == MAT_LEAVES) farFoliage = 1.0;
        shadow *= mix(1.0, 0.5, farFoliage);
        ao *= mix(1.0, 0.72, farFoliage);
        // Water lowers Minecraft's sky light by one level per block, so a seafloor looks like a sealed cave to
        // the sky-light gates in shadeSurface. When the shadow map shows light arriving through water, the
        // surface is open to the sky above that water; its absorption is already applied via the shadow term.
        // Only water triggers this. Trusting any lit shadow sample made caves glow: the shadow map is not a
        // reliable occluder underground (casters beyond its depth range or culled chunks read as open sky), and
        // lifting the sky light there also re-enabled direct sun, which lit whole cave walls blue-white next to
        // pitch-black faces. Glass does not reduce vanilla sky light, so it needs no lift.
#if !defined DIM_NETHER && !defined DIM_END
        vec2 lm = nl.zw;
        // Only surfaces really under the water: some sky light of their own and a plausible water depth. The shadow
        // map only says that water lies somewhere along the sun ray, so a cave under a lake got full sky light
        // (a lake-shaped glowing patch on the cave floor with no visible source).
        if (!isLod && !isHand && shadowWaterDepth > 0.05 && shadowWaterDepth < 20.0 && lm.y > 0.12) lm.y = max(lm.y, 0.8);
#else
        vec2 lm = nl.zw;
#endif
        float fieldWeight = 0.0;
#ifdef FIELD_SHADING
        surfaceField = FieldLight(vec3(0.0), BLOCKLIGHT_COLOR / luminance(BLOCKLIGHT_COLOR), 0.0, 0.0, vec3(0.0), 0.0, 0.0);
        if (!isHand && !isLod) surfaceField = sampleLightField(playerPos, n);
        // The hand's depth is not a world position, but the hand is at the eye: read the colour field there.
        if (isHand) surfaceField = sampleLightField(vec3(0.0, -0.4, 0.0), n);
        fieldWeight = surfaceField.weight;
#endif
        col = shadeSurface(env, albedo, n, -rd, lm, ao, mat, shadow, m.g);
#if !defined DIM_NETHER && !defined DIM_END
        // Snow: sparse point glints from individual crystals (lib/ice.glsl), plus the forward-scattering sheen
        // that makes sunlit snow glow when looking toward the sun across it.
        if (mat == MAT_SNOW && !isLod) {
            float d = length(playerPos);
            col += envDirect * shadow * snowGlint(wp, n, rd, envLightDir, d) * 60.0 * saturate(dot(n, envLightDir) * 4.0);
            float toward = saturate(dot(rd, envLightDir));
            col += envDirect * shadow * albedo * pow(toward, 6.0) * pow(1.0 - saturate(dot(n, -rd)), 3.0) * 0.12;
        }
        // Packed and blue ice: polished, with a clear sky reflection and a tight sun highlight. Light also
        // travels through ice, so its shaded faces glow a luminous blue instead of dropping to near-black.
        if (mat == MAT_ICE_SOLID && !isLod) {
            vec3 rr = reflect(rd, n);
            float F = iceFresnel(dot(-rd, n));
            vec3 hv = normalize(envLightDir - rd);
            float nh = saturate(dot(n, hv));
            const float a2 = 0.004;
            float dd = nh * nh * (a2 - 1.0) + 1.0;
            col += envDirect * shadow * a2 / (PI * dd * dd) * iceFresnel(dot(hv, -rd)) * saturate(dot(n, envLightDir)) * 0.25;
        }
#endif
        // Generic dark rock is not a mirror in the Nether. The old horizon reflection put an orange
        // Fresnel rim on every netherrack and basalt silhouette, even with no visible lava source.
#ifndef DIM_NETHER
        // Outside the Nether, very dark albedos retain a subtle sky reflection.
        float darkness = 1.0 - smoothstep(0.02, 0.07, luminance(gAlbedo.rgb));
        if (darkness > 0.0 && !isHand && mat != MAT_LAVA && mat != MAT_GLASSY && mat != MAT_POLISHED) {
            vec3 rr = reflect(rd, n);
            float fr = 0.04 + 0.96 * pow(1.0 - saturate(dot(-rd, n)), 5.0);
            vec3 env = skyRadiance(normalize(vec3(rr.x, max(rr.y, 0.05), rr.z)), sunDir, 4);
#ifndef DIM_END
            env *= lm.y * lm.y;
#endif
            col += env * fr * darkness * ao * 0.8;
        }
#endif
        if (mat == MAT_ENDPORTAL) {
            col = endPortalRadiance(wp, n, rd);
        }
        if (!isLod && !isHand) col += albedo * handheldLight(playerPos, n, ao);
        // A torch (or any light) held in either hand lights the hands themselves; vanilla's light level there does
        // not include it, so in a dark cave the hand holding a torch rendered black.
        if (isHand) {
            float held = float(max(heldBlockLightValue, heldBlockLightValue2)) / 15.0;
            if (held > 0.0) col += albedo * heldLightColor() * blockLightLevel(held * 0.92) * (0.55 + 0.45 * saturate(n.y * 0.5 + 0.5)) * 0.4;
        }
#if !defined DIM_NETHER && !defined DIM_END && defined CLOUDS
        {
            // Lightning briefly lights the landscape: cold light from the sky, strongest on open ground.
            vec4 fl = cloudFlash(cameraPosition);
            // The flash comes from one place in the sky, so faces turned toward it light up more.
            if (fl.w > 0.0) {
                float facing = 0.55 + 0.45 * saturate(dot(n, normalize(fl.xyz - wp)));
                col += albedo * vec3(0.7, 0.78, 1.0) * fl.w * 0.07 * LIGHTNING_GROUND * lm.y * lm.y * facing * ao;
            }
        }
#endif

        if (wet > 0.0 && !isLod) {
            vec3 rn = normalize(mix(n, vec3(0.0, 1.0, 0.0), puddle) + vec3(ripple.x, 0.0, ripple.y) * 0.18 * puddle);
            vec3 r = reflect(rd, rn);
            float fres = 0.02 + 0.98 * pow(1.0 - saturate(dot(-rd, rn)), 5.0);
            vec3 refl = (skyRadiance(r, sunDir, 6) + sunAureole(r, sunDir)) * nl.w * nl.w;
            // A puddle is a near-perfect mirror; a floor of reflectance keeps it visible from steeper angles.
            col = mix(col, refl, mix(fres * wet * 0.35, max(fres, 0.18), puddle));
        }
    }

#if defined LIGHT_FIELD_DEBUG && defined FIELD_SHADING
    // Diagnostics: red/green/blue = raw light field in front of the surface (log-scaled); a cyan tint marks
    // surfaces whose block is voxelized as solid, magenta marks emitters. Sky stays black.
    if (depth < 1.0) {
        vec3 dn = decodeNormal(texture(colortex1, texcoord).xy);
        vec3 f = lightFieldTap(voxelUVW(playerPos + dn * 0.55, cameraPositionFract));
        // Saturated HDR categories (grey debug values get scrambled by exposure and AgX):
        // green = field, blue = solid voxel, magenta = emitter voxel, red = outside the grid.
        col = vec3(0.0, log2(1.0 + luminance(f)) * 2.0, 0.0);
        ivec3 vb = worldBlockToVoxel(ivec3(floor(playerPos + cameraPosition - dn * 0.5)), cameraPositionInt);
        if (voxelInside(vb)) {
            uint t = voxelType(texelFetch(voxelSampler, vb, 0).r);
            if (t == VOXEL_SOLID) col.b += 4.0;
            if (t == VOXEL_EMITTER) col += vec3(4.0, 0.0, 4.0);
        } else col.r += 4.0;
    } else col = vec3(0.0);
#endif
    // Water and glass read this copy for refraction and draw clouds in front of themselves, so it must not
    // already contain the clouds (they would show through twice, or vanish behind the water surface).
    outCopy = vec4(col, 1.0);
#if !defined DIM_NETHER && !defined DIM_END && defined CLOUDS
    // Clouds cover the sky and, when the camera is inside or above them, terrain behind them too.
    // The hand never gets clouds: they are all behind it (compositing them made the arm look cloud-shadowed
    // and see-through).
    // Keep opaque entities crisp through the half-resolution cloud upsample. The cloud layer can still fill
    // the surrounding pixels, but its radiance must not wash across a player or mob silhouette.
    bool isEntity = depth < 1.0 && int(texture(colortex2, texcoord).r * 255.0 + 0.5) == MAT_ENTITY;
    if (depth >= 0.56 && !isEntity) {
        float sceneDist = (depth >= 1.0 && !isLod) ? 1e6 : length(playerPos);
        vec4 clouds = upsampleClouds(texcoord, sceneDist);
        col = col * clouds.a + clouds.rgb;
        // Lightning lights the clouds after temporal accumulation (history would average a flash away).
        vec4 flash = cloudFlash(cameraPosition);
        if (flash.w > 0.0 && clouds.a < 0.98) {
            vec2 halfRes = floor(vec2(viewWidth, viewHeight) * 0.5);
            float cd = texelFetch(colortex8, ivec2(texcoord * halfRes), 0).r;
            vec3 cp = cameraPosition + rd * min(cd, 30000.0);
            float near = exp(-length(cp - flash.xyz) / 420.0);
            col += vec3(0.7, 0.78, 1.0) * flash.w * near * (1.0 - clouds.a) * 0.11;
        }
    }
#endif
    outColor = vec4(col, 1.0);
}
#endif

/*
const int colortex0Format = RGBA16F;
const int colortex1Format = RGBA16;
const int colortex2Format = RGBA8;
const int colortex4Format = R11F_G11F_B10F;
const int colortex5Format = RGBA16F;
const bool colortex5Clear = false;
const int colortex6Format = R16F;
const int colortex7Format = RGBA16F;
const int colortex8Format = RG32F;
const int colortex9Format = RGBA16F;
const bool colortex9Clear = false;
const int colortex11Format = RGBA16F;
const bool colortex11Clear = false;
const vec4 colortex0ClearColor = vec4(0.0, 0.0, 0.0, 1.0);
const bool colortex4Clear = true;
*/
#if defined DIM_NETHER || defined DIM_END
// Voxelization only: the shadow map is never sampled here, and the distance just has to cover the light field.
const int shadowMapResolution = 256;
const float shadowDistance = 80.0;
#else
const int shadowMapResolution = 3072;
const float shadowDistance = 192.0;
#endif
const float shadowDistanceRenderMul = 1.0;
// Safe-zone radius for the light field voxelization (shadow.culling=reversed in shaders.properties).
const float voxelDistance = 64.0;
const float sunPathRotation = -25.0;
const bool shadowHardwareFiltering = false;
