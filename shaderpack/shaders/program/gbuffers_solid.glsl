// Opaque geometry: writes the G-buffer that deferred.glsl lights.
//   colortex0 = albedo (sRGB) + alpha
//   colortex1 = world normal (octahedral) + lightmap (block, sky)
//   colortex2 = material id / 255, emissive, ambient occlusion
// Variants: PROG_TERRAIN, PROG_ENTITIES, PROG_TEXTURED (particles, fallbacks), PROG_BASIC, PROG_DH.

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

#ifdef VERTEX
#include "/lib/jitter.glsl"
#ifdef PROG_TERRAIN
in vec4 mc_Entity;
in vec4 at_midBlock;
in vec2 mc_midTexCoord;
uniform float frameTimeCounter;
uniform float rainStrength;
#include "/lib/waving.glsl"
#endif
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;
#ifdef PROG_BLOCK
uniform int blockEntityId;
#endif

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 worldNormal;
out vec3 relPos;
flat out int mat;
#ifdef PROG_TERRAIN
flat out vec2 lavaSpriteMid;
flat out vec2 lavaSpriteHalfExtent;
flat out float lavaFlowing;
#endif

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
#ifdef PROG_TERRAIN
    // mc_midTexCoord is Iris's raw quad UV average. Transform it just like texcoord so atlas bounds
    // remain correct when Minecraft animates or offsets the terrain texture matrix.
    lavaSpriteMid = (gl_TextureMatrix[0] * vec4(mc_midTexCoord, 0.0, 1.0)).xy;
    lavaSpriteHalfExtent = abs(texcoord - lavaSpriteMid);
#endif
    vec2 lm = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    lmcoord = saturate((lm - 1.0 / 32.0) * 16.0 / 15.0);
    glcolor = gl_Color;
    worldNormal = mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
#if defined PROG_TERRAIN || defined PROG_DH
    // Chunk geometry has no model rotation, so its normal is already in world space. Going through the view
    // matrices instead tilted every normal with view bobbing (the bob reaches the normal matrix and the
    // gbufferModelView uniform differently); at a low sun that few-degree wobble swung the ground between lit
    // and shaded with every step (Trevor: shadows bouncing while walking, fine while flying or without bobbing).
    worldNormal = normalize(gl_Normal);
#endif
    mat = MAT_NONE;

#ifdef PROG_BASIC
    // Iris rewrites line geometry around its own position attribute; touching gl_Vertex breaks linking.
    relPos = vec3(0.0);
    gl_Position = ftransform();
    applyJitter(gl_Position);
    return;
#endif
    vec3 viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    relPos = mat3(gbufferModelViewInverse) * viewPos;
#if defined PROG_TERRAIN
    mat = int(mc_Entity.x + 0.5) - 10000;
    if (mat < 0 || mat > 100) mat = MAT_NONE;
    lavaFlowing = mat == MAT_LAVA_FLOWING ? 1.0 : 0.0;
    if (mat == MAT_LAVA_FLOWING) mat = MAT_LAVA;
    vec3 playerPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    vec3 worldPos = waveVertex(playerPos + cameraPosition, mat, at_midBlock.y);
    gl_Position = gl_ProjectionMatrix * (gbufferModelView * vec4(worldPos - cameraPosition, 1.0));
#elif defined PROG_DH
    mat = MAT_LOD;
    if (dhMaterialId == DH_BLOCK_LEAVES) mat = MAT_LEAVES;
    if (dhMaterialId == DH_BLOCK_ILLUMINATED) mat = MAT_EMISSIVE;
    if (dhMaterialId == DH_BLOCK_LAVA) mat = MAT_LAVA;
    gl_Position = gl_ProjectionMatrix * vec4(viewPos, 1.0);
#else
  #ifdef PROG_ENTITIES
    mat = MAT_ENTITY;
  #endif
  #ifdef PROG_HAND
    mat = MAT_HAND;
  #endif
  #ifdef PROG_BLOCK
    mat = blockEntityId - 10000 == MAT_ENDPORTAL ? MAT_ENDPORTAL : MAT_NONE;
  #endif
    gl_Position = ftransform();
#endif
    applyJitter(gl_Position);
}
#endif

#ifdef FRAGMENT
uniform sampler2D gtexture;
#ifdef PROG_ENTITIES
uniform vec4 entityColor;
#endif
#ifdef PROG_HAND
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;
#endif
#ifdef PROG_TERRAIN
#include "/lib/cave.glsl"
#endif
#ifdef PROG_TERRAIN
uniform float far;
uniform int frameCounter;
uniform float frameTimeCounter;
uniform vec3 cameraPosition;
#endif
#ifdef PROG_DH
uniform vec3 cameraPosition;
uniform mat4 gbufferModelViewInverse;
uniform float far;
uniform float viewWidth;
uniform float viewHeight;
uniform float frameTimeCounter;
uniform mat4 dhProjectionInverse;
#if defined DIM_END
uniform int frameCounter;
#include "/lib/end_lod.glsl"
#endif
#endif

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 worldNormal;
in vec3 relPos;
flat in int mat;
#ifdef PROG_TERRAIN
flat in vec2 lavaSpriteMid;
flat in vec2 lavaSpriteHalfExtent;
flat in float lavaFlowing;
#endif
#if defined PROG_TERRAIN || defined PROG_DH
#include "/lib/lava.glsl"
#endif
#if defined PROG_TERRAIN && defined LIGHT_FIELD
#include "/lib/voxel.glsl"
uniform usampler3D voxelSampler;
uniform ivec3 cameraPositionInt;

// 1 where a lava surface touches a solid block beside it, falling to 0 about 1.3 blocks away. Reads the voxel
// grid the shadow pass wrote this frame; outside the grid there is no shore detail.
float lavaShore(vec3 wp, vec3 n) {
    ivec3 block = ivec3(floor(wp - n * 0.05));
    ivec3 v = worldBlockToVoxel(block, cameraPositionInt);
    if (!voxelInside(v - 1) || !voxelInside(v + 1)) return 0.0;
    vec2 f = fract(wp.xz);
    float d = 8.0;
    for (int z = -1; z <= 1; z++) {
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && z == 0) continue;
            if (voxelType(texelFetch(voxelSampler, v + ivec3(x, 0, z), 0).r) != VOXEL_SOLID) continue;
            // Distance from this point to the neighbour's footprint.
            vec2 lo = vec2(x, z), hi = lo + 1.0;
            vec2 q = max(max(lo - f, f - hi), vec2(0.0));
            d = min(d, length(q));
        }
    }
    return 1.0 - smoothstep(0.0, 1.3, d);
}
#endif

/* RENDERTARGETS: 0,1,2 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormalLight;
layout(location = 2) out vec4 outMaterial;

#ifdef PROG_TERRAIN
#endif

void main() {
#ifdef PROG_TERRAIN
    // Derivatives are evaluated before the material branch so textureGrad remains defined across edges.
    vec3 relPosDx = dFdx(relPos);
    vec3 relPosDy = dFdy(relPos);
#endif
#if defined PROG_BASIC || defined PROG_DH
    vec4 albedo = glcolor;
#elif defined PROG_TERRAIN
    vec4 albedo;
    float lavaEmit = 1.0;
    if (mat == MAT_LAVA) {
        vec3 lavaN = normalize(worldNormal);
        vec3 lavaWp = relPos + cameraPosition;
        vec4 lava;
        if (abs(lavaN.y) > 0.5 && lavaFlowing < 0.5) {
            // Pool UVs are world anchored; falls keep their native flowing sprite and UVs.
            float shore = 0.0;
#ifdef LIGHT_FIELD
            shore = lavaShore(lavaWp, lavaN);
#endif
            lava = lavaSurface(lavaWp, relPosDx, relPosDy, lavaN, lavaSpriteMid, lavaSpriteHalfExtent,
                               frameTimeCounter, shore);
        } else {
            lava = lavaFall(texture(gtexture, texcoord).rgb, lavaWp, frameTimeCounter);
        }
        albedo = vec4(lava.rgb, 1.0);
        lavaEmit = lava.a;
    } else {
        vec4 texel = texture(gtexture, texcoord);
        albedo = vec4(texel.rgb * glcolor.rgb, texel.a);
    }
#else
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
#endif
    float ao = 1.0;
#ifdef PROG_TERRAIN
    // separateAo: vertex alpha carries ambient occlusion, texture alpha carries coverage.
    ao = glcolor.a;
#endif
#ifdef PROG_ENTITIES
    albedo.rgb = mix(albedo.rgb, entityColor.rgb, entityColor.a);
#endif
    if (albedo.a < 0.1) discard;

#ifdef PROG_TERRAIN
    // Dither vanilla chunks out before the render edge so chunk-border cross-sections never show; DH fills in.
    float edge = length(relPos.xz) / far;
    if (edge > mix(0.84, 0.94, ignTemporal(gl_FragCoord.xy, frameCounter))) discard;
#endif

#ifdef PROG_DH
    // Skip LOD fragments that overlap real chunks so the two never z-fight.
    vec3 ndc = vec3(gl_FragCoord.xy / vec2(viewWidth, viewHeight), gl_FragCoord.z) * 2.0 - 1.0;
    vec3 viewPos = projectAndDivide(dhProjectionInverse, ndc);
    float lodDistance = length(viewPos);
    if (lodDistance < far * 0.1) discard;
#if defined DIM_END
    if (!endLodVisible(lodDistance, gl_FragCoord.xy, frameCounter)) discard;
#endif
    // Break up flat LOD faces with a little world-space value noise.
    vec3 wp = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz + cameraPosition;
    vec3 cell = floor(wp - worldNormal * 0.5);
    albedo.rgb *= 0.93 + 0.14 * hash12(cell.xz + cell.y * vec2(17.3, 5.1));
    if (mat == MAT_LAVA) {
        float heat = lavaBroadHeat(lavaPlane(wp, normalize(worldNormal)), wp.y, frameTimeCounter);
        albedo.rgb *= lavaPoolTint(heat);
    }
#endif

    float emissive = 0.0;
    if (mat == MAT_EMISSIVE) emissive = smoothstep(0.45, 0.85, max(albedo.r, max(albedo.g, albedo.b)));
    // Glow berries: the orange fruit glows, the leaves around it do not.
    if (mat == MAT_GLOWBERRY) emissive = smoothstep(0.08, 0.3, albedo.r - albedo.g * 0.8) * smoothstep(0.5, 0.8, albedo.r);
#ifdef PROG_TERRAIN
    if (mat == MAT_LAVA) emissive = lavaEmit;
#else
    // LOD lava: the molten-body level of the near pools (lighting squares this).
    if (mat == MAT_LAVA) emissive = 0.6;
#endif
#ifdef PROG_BASIC
    emissive = 0.4;
#endif
#ifdef PROG_HAND
    // Holding a light source: the flame texels of held items burn (bright, mostly warm pixels), so a torch in
    // hand glows instead of rendering as a dark stick.
    if (max(heldBlockLightValue, heldBlockLightValue2) > 0) {
        float hmx = max(albedo.r, max(albedo.g, albedo.b)), hmn = min(albedo.r, min(albedo.g, albedo.b));
        float hsat = (hmx - hmn) / max(hmx, 1e-3);
        // Flame texels are bright and clearly saturated (yellow/orange); the light wood of the stick is not.
        emissive = max(emissive, smoothstep(0.72, 0.95, hmx) * smoothstep(0.35, 0.6, hsat));
    }
#endif

    vec3 n = normalize(worldNormal);
#ifdef PROG_TEXTURED
    n = vec3(0.0, 1.0, 0.0);
#endif

    outAlbedo = vec4(albedo.rgb, 1.0);
    outNormalLight = vec4(encodeNormal(n), lmcoord);
    // Smoothness for the screen-space reflections in composite (0 = none). Brighter texels of a block are the
    // polished faces; darker ones are grout, pits and edges, so gloss follows the texture.
    float smoothness = 0.0;
#ifdef PROG_TERRAIN
    float tl = luminance(albedo.rgb);
    if (mat == MAT_POLISHED) smoothness = mix(0.45, 0.82, smoothstep(0.15, 0.75, tl));
    else if (mat == MAT_METAL) smoothness = mix(0.62, 0.9, smoothstep(0.2, 0.8, tl));
    // Obsidian (Complementary's rule): only its purple-sheened texels are glossy, patchy and mostly subtle.
    else if (mat == MAT_GLASSY) smoothness = min(max(0.3 - abs(albedo.r - 0.3), 0.0) * 1.5 + 0.07, 1.0);
    else if (mat == MAT_ICE_SOLID) smoothness = mix(0.8, 0.95, tl);
    else if (mat == MAT_STONE) {
        // Damp cave rock: only where the sky cannot reach, in world-anchored patches (seepage, not a uniform
        // coat), wettest in the darker texels (cracks hold water). Wet stone darkens and turns glossy, so a
        // torch or lava glints across it as you move.
        float under = 1.0 - smoothstep(0.25, 0.65, lmcoord.y);
        if (under > 0.0) {
            vec3 wp = relPos + cameraPosition;
            float seep = valueNoise(wp.xz * 0.16 + wp.y * 0.07) * 0.6 + valueNoise(vec2(wp.x + wp.z, wp.y) * 0.35) * 0.4;
            float wet = under * smoothstep(0.42, 0.72, seep) * CAVE_WETNESS;
            outAlbedo.rgb *= 1.0 - 0.22 * wet; // albedo was already written above
            smoothness = wet * mix(0.62, 0.38, smoothstep(0.1, 0.5, tl));
        }
    } else if (mat == MAT_SCULK) {
        // Sculk's cyan specks are bioluminescent: they breathe with the travelling heartbeat (lib/cave.glsl).
        float cyan = saturate(((albedo.g + albedo.b) * 0.5 - albedo.r) * 4.0) * smoothstep(0.22, 0.5, max(albedo.g, albedo.b));
        emissive = max(emissive, cyan * SCULK_GLOW * sculkPulse(relPos + cameraPosition, frameTimeCounter));
        smoothness = cyan * 0.4;
    } else if (mat == MAT_ORE) {
        // Gem and metal texels stand out from the grey host rock by saturation (or, for iron and gold, warm
        // brightness). They are glossy and throw tiny glints that re-roll with the view direction, so a vein
        // twinkles as you walk past; glints scale with nearby block light, so they sparkle under a torch.
        float mx = max(albedo.r, max(albedo.g, albedo.b)), mn = min(albedo.r, min(albedo.g, albedo.b));
        float sat = (mx - mn) / max(mx, 1e-3);
        float gem = smoothstep(0.2, 0.45, sat) * smoothstep(0.12, 0.3, mx);
        smoothness = gem * 0.85;
        vec2 tx = floor(texcoord * vec2(textureSize(gtexture, 0)));
        vec3 view = floor(normalize(relPos) * 60.0 + relPos * 0.8);
        float h = hash12(tx * 0.618 + view.xz * 1.37 + view.y * 3.11);
        float glint = step(0.9, h) * gem;
        emissive = max(emissive, glint * ORE_SPARKLE * saturate(lmcoord.x * 1.3 + 0.08));
    }
#endif
    outMaterial = vec4(float(mat) / 255.0, emissive, ao, smoothness);
}
#endif
