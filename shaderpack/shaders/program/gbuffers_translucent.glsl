// Forward-shaded translucents: water (refraction, absorption, SSR) and tinted glass/ice.
// colortex4 holds the lit opaque scene from deferred, used for refraction and reflections.
// Variants: PROG_WATER (gbuffers_water), PROG_DH (dh_water).

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

uniform vec3 sunPosition;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;
uniform float rainStrength;
uniform float frameTimeCounter;
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

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vec2 lm = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    lmcoord = saturate((lm - 1.0 / 32.0) * 16.0 / 15.0);
    glcolor = gl_Color;
    worldNormal = mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
#if defined PROG_HAND
    mat = MAT_HAND;
#elif defined PROG_DH
    mat = dhMaterialId == DH_BLOCK_WATER ? MAT_WATER : MAT_TRANSLUCENT;
#else
    mat = int(mc_Entity.x + 0.5) - 10000;
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
}
#endif

#ifdef FRAGMENT
uniform int frameCounter;
uniform sampler2D gtexture;
uniform sampler2D colortex4;
uniform sampler2D depthtex1;
uniform sampler2D dhDepthTex1;
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 dhProjectionInverse;
uniform float viewWidth;
uniform float viewHeight;
uniform float far;
uniform int isEyeInWater;
#include "/lib/shadows.glsl"
#include "/lib/water.glsl"

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 worldNormal;
in vec3 playerPos;
flat in int mat;
flat in vec3 sunDir;
flat in vec3 envLightDir;
flat in vec3 envDirect;
flat in vec3 envAmbient;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

vec3 viewFromDepth(vec2 uv, float depth) {
    return projectAndDivide(gbufferProjectionInverse, vec3(uv, depth) * 2.0 - 1.0);
}

// Screen-space reflection against the opaque depth buffer. Returns rgb and hit confidence in a.
vec4 traceSSR(vec3 viewPos, vec3 viewDir, float dither) {
#ifdef WATER_SSR
    float stepLen = 0.6 + length(viewPos) * 0.04;
    vec3 p = viewPos + viewDir * stepLen * dither;
    for (int i = 0; i < SSR_STEPS; i++) {
        p += viewDir * stepLen;
        stepLen *= 1.18;
        vec3 s = projectAndDivide(gbufferProjection, p) * 0.5 + 0.5;
        if (any(lessThan(s.xy, vec2(0.0))) || any(greaterThan(s.xy, vec2(1.0))) || p.z > -0.05) break;
        float sceneDepth = texture(depthtex1, s.xy).r;
        if (sceneDepth >= 1.0) continue;
        float sceneZ = viewFromDepth(s.xy, sceneDepth).z;
        float diff = sceneZ - p.z;
        if (diff > 0.0 && diff < stepLen * 2.5) {
            // Binary refinement between the last two samples.
            vec3 a = p - viewDir * stepLen, b = p;
            for (int j = 0; j < 5; j++) {
                vec3 m = (a + b) * 0.5;
                vec3 ms = projectAndDivide(gbufferProjection, m) * 0.5 + 0.5;
                float mz = viewFromDepth(ms.xy, texture(depthtex1, ms.xy).r).z;
                if (mz - m.z > 0.0) b = m; else a = m;
            }
            vec3 hs = projectAndDivide(gbufferProjection, b) * 0.5 + 0.5;
            vec2 edge = smoothstep(0.0, 0.08, hs.xy) * smoothstep(1.0, 0.92, hs.xy);
            return vec4(texture(colortex4, hs.xy).rgb, edge.x * edge.y);
        }
    }
#endif
    return vec4(0.0);
}

void main() {
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
    // DH depth-tests only against LOD depth, so reject fragments hidden behind real chunks.
    float chunkDepth = texture(depthtex1, uv).r;
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
            float strength = mix(1.0, 0.15, saturate(dist / 96.0));
            n = waterNormal(worldPos, frameTimeCounter, strength);
        }
        bool underwater = isEyeInWater == 1;
        if (underwater) {
            // From inside the water, side faces (against ice, glass, air pockets) should just transmit;
            // the composite pass applies the underwater medium.
            if (worldNormal.y < 0.5) {
                outColor = vec4(texture(colortex4, uv).rgb, 1.0);
                return;
            }
            n = -n;
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

        vec3 shadow = sampleShadow(playerPos, vec3(0.0, 1.0, 0.0), saturate(envLightDir.y), dither);
        float skyVis = lmcoord.y * lmcoord.y;
        const vec3 absorb = vec3(0.42, 0.075, 0.05);
        vec3 transmit = underwater ? vec3(1.0) : exp(-absorb * waterDepth);
        vec3 scatterCol = vec3(0.02, 0.09, 0.11) * (envAmbient * skyVis / PI + envDirect * shadow * 0.08);
        vec3 body = refracted * transmit + scatterCol * (1.0 - transmit);

        // Far away, a single pixel covers many small waves, so water behaves like a rough surface: it reflects
        // a spread of sky directions (skewed toward the higher, darker sky) and a smaller share overall.
        // This is what keeps a real sea darker than the sky and gives the horizon a crisp line.
        float rough = mix(0.03, 0.35, saturate(dist / 350.0));
        vec3 r = reflect(rd, n);
        r.y = abs(r.y);
        vec3 rRough = normalize(r + vec3(0.0, rough * 1.4, 0.0));
        vec3 skyRefl = skyRadiance(rRough, sunDir, 8);
        skyRefl = applyClouds(skyRefl, rRough, sunDir, envDirect, envAmbient * 0.12, cameraPosition.xz) * skyVis;
        vec3 viewPos = (gbufferModelView * vec4(playerPos, 1.0)).xyz;
        vec4 ssr = underwater ? vec4(0.0) : traceSSR(viewPos, normalize(mat3(gbufferModelView) * r), dither);
        vec3 refl = mix(skyRefl, ssr.rgb, ssr.a * (1.0 - saturate(rough * 2.5)));

        float fres = underwater ? 0.15 : fresnelSchlick(dot(-rd, n), 0.02) * mix(1.0, 0.5, saturate(rough * 2.5));
        vec3 col = mix(body, refl, fres);

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
        col += envDirect * shadow * spec * skyVis;

        outColor = vec4(col, 1.0);
        return;
    }

    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < 0.02) discard;
    vec3 n = normalize(worldNormal);
#ifdef PROG_HAND
    // The hand has its own projection; approximate its shadowing from sky light instead of the shadow map.
    vec3 shadow = vec3(smoothstep(0.6, 0.95, lmcoord.y));
#else
    vec3 shadow = sampleShadow(playerPos, n, saturate(dot(n, envLightDir)), dither);
#endif
    vec3 col = shadeSurface(env, toLinear(albedo.rgb), n, -rd, lmcoord, 1.0, mat, shadow, 0.0);
    float fres = fresnelSchlick(dot(-rd, n), 0.04);
    vec3 skyRefl = skyRadiance(reflect(rd, n), sunDir, 6) * lmcoord.y * lmcoord.y;
    col = mix(col, skyRefl, fres * 0.6);
    outColor = vec4(col, mix(albedo.a, 1.0, fres * 0.5));
}
#endif
