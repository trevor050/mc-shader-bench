// Deferred lighting for opaque geometry (vanilla chunks and DH LODs) plus the sky.
// Writes lit HDR to colortex0 and a copy to colortex4 for water refraction and reflections.

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
#define SHADOWS_AVAILABLE
uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D depthtex0;
uniform sampler2D dhDepthTex0;
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;
uniform mat4 gbufferProjectionInverse;
uniform mat4 dhProjectionInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform vec3 cameraPosition;
uniform float wetness;
uniform mat4 gbufferProjection;
uniform mat4 gbufferModelView;
uniform sampler2D colortex8;
uniform sampler2D colortex9;
uniform float viewWidth;
uniform float viewHeight;
#include "/lib/shadows.glsl"
#include "/lib/clouds.glsl"
#include "/lib/stars.glsl"
#include "/lib/lava.glsl"

in vec2 texcoord;
flat in vec3 sunDir;
flat in vec3 envLightDir;
flat in vec3 envDirect;
flat in vec3 envAmbient;

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
        col = rd.y < 0.0 ? hazeColor(rd, sunDir) : skyRadiance(rd, sunDir, 12) + sunAureole(rd, sunDir) + sunDisc(rd, sunDir);
#ifdef DIM_END
        float night = 1.0;
#else
        float night = smoothstep(0.05, -0.15, sunDir.y);
#endif
        float pixelAngle = 2.0 / (gbufferProjection[1][1] * viewHeight);
        // Reconstructing the direction from the far-plane depth loses precision; stars need an exact ray.
        vec3 viewDir = normalize(vec3((texcoord * 2.0 - 1.0) / vec2(gbufferProjection[0][0], gbufferProjection[1][1]), -1.0));
        vec3 starDir = normalize(mat3(gbufferModelViewInverse) * viewDir);
        col += moonSky(starDir, -sunDir);
        if (night > 0.0 && rainStrength < 1.0 && starDir.y > -0.02) {
            col += nightSky(starDir, sunDir, pixelAngle, frameTimeCounter, gl_FragCoord.xy, mat3(gbufferModelView),
                            vec2(gbufferProjection[0][0], gbufferProjection[1][1]), vec2(viewWidth, viewHeight)) * night * (1.0 - rainStrength);
        }
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
        float NdotL = dot(n, envLightDir);
        vec3 shadow = vec3(1.0);
        bool foliage = mat == MAT_FOLIAGE || mat == MAT_LEAVES || mat == MAT_TALL_UPPER;
        // The first-person hand has its own projection, so world-space effects (shadow map, SSAO, clouds) would
        // sample unrelated places. Shade it from its sky light level instead.
        bool isHand = mat == MAT_HAND;
        vec3 wp = playerPos + cameraPosition;
        if (isHand) shadow = vec3(smoothstep(0.6, 0.95, nl.w));
#if !defined DIM_NETHER && !defined DIM_END
        if (!isLod && !isHand && (NdotL > 0.0 || foliage)) {
            shadow = sampleShadow(playerPos, foliage ? envLightDir : n, abs(NdotL), ignTemporal(gl_FragCoord.xy, frameCounter));
            if (shadowWaterDepth > 0.05) {
                // Project along the light onto the water plane so the pattern slides with the sun.
                vec2 cuv = (wp.xz + envLightDir.xz / max(envLightDir.y, 0.2) * shadowWaterDepth) / 5.0;
                float c = caustics(cuv, frameTimeCounter * 0.6);
                shadow *= mix(1.0, 0.35 + c * 3.0, saturate(shadowWaterDepth * 0.7));
            }
        }
        if (!isHand) shadow *= cloudShadow(wp, envLightDir);
#endif

        // Rain: sky-exposed surfaces darken and turn glossy; flat ground pools into puddles.
        float wet = isHand ? 0.0 : wetness * smoothstep(0.82, 0.97, nl.w) * (foliage ? 0.4 : 1.0);
        float puddle = 0.0;
        if (wet > 0.0 && n.y > 0.9 && !foliage) {
            float pn = valueNoise(wp.xz * 0.12) * 0.65 + valueNoise(wp.xz * 0.5) * 0.35;
            puddle = smoothstep(0.52, 0.62, pn) * wet;
        }
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
        // The same applies under ice or glass. Sealed caves never trip this: rock blocks the shadow map there.
        vec2 lm = nl.zw;
        float reaching = saturate(luminance(shadow) * 8.0);
        if (!isLod && !isHand && (shadowWaterDepth > 0.05 || reaching > 0.0)) lm.y = max(lm.y, 0.8 * max(reaching, step(0.05, shadowWaterDepth)));
        col = shadeSurface(env, albedo, n, -rd, lm, ao, mat, shadow, m.g);
#ifdef DIM_NETHER
        if (!isHand) col += albedo * netherUplight(playerPos + cameraPosition, n, ao) / PI;
#endif
        if (mat == MAT_LAVA) col = lavaRadiance(playerPos + cameraPosition, n, frameTimeCounter);
        if (!isLod && !isHand) col += albedo * handheldLight(playerPos, n, ao);

        if (wet > 0.0 && !isLod) {
            vec3 rn = normalize(mix(n, vec3(0.0, 1.0, 0.0), puddle));
            vec3 r = reflect(rd, rn);
            float fres = 0.02 + 0.98 * pow(1.0 - saturate(dot(-rd, rn)), 5.0);
            vec3 refl = (skyRadiance(r, sunDir, 6) + sunAureole(r, sunDir)) * nl.w * nl.w;
            // A puddle is a near-perfect mirror; a floor of reflectance keeps it visible from steeper angles.
            col = mix(col, refl, mix(fres * wet * 0.35, max(fres, 0.18), puddle));
        }
    }

    // Water and glass read this copy for refraction and draw clouds in front of themselves, so it must not
    // already contain the clouds (they would show through twice, or vanish behind the water surface).
    outCopy = vec4(col, 1.0);
#if !defined DIM_NETHER && !defined DIM_END && defined CLOUDS
    // Clouds cover the sky and, when the camera is inside or above them, terrain behind them too.
    // The hand never gets clouds: they are all behind it (compositing them made the arm look cloud-shadowed
    // and see-through).
    if (depth >= 0.56) {
        float sceneDist = (depth >= 1.0 && !isLod) ? 1e6 : length(playerPos);
        vec4 clouds = upsampleClouds(texcoord, sceneDist);
        col = col * clouds.a + clouds.rgb;
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
const int colortex10Format = RGBA16F;
const int colortex11Format = RGBA16F;
const bool colortex11Clear = false;
const int colortex12Format = R32F;
const vec4 colortex0ClearColor = vec4(0.0, 0.0, 0.0, 1.0);
const bool colortex4Clear = true;
*/
const int shadowMapResolution = 3072;
const float shadowDistance = 192.0;
const float shadowDistanceRenderMul = 1.0;
const float sunPathRotation = -25.0;
const bool shadowHardwareFiltering = false;
