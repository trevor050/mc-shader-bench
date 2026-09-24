// Shadow map pass: distorted depth plus translucent tint in shadowcolor0.
// Also voxelizes terrain near the camera into voxelImg for the light field (lib/voxel.glsl).
// VOXEL_ONLY (Nether, End): no shadow map is needed, so every vertex is clipped after voxelizing and nothing
// is rasterized.

#define SHADOW_PASS
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/shadows.glsl"
#ifdef LIGHT_FIELD
#include "/lib/voxel.glsl"
#endif

#ifdef VERTEX
in vec4 mc_Entity;
in vec4 at_midBlock;
in vec2 mc_midTexCoord;
uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform vec3 cameraPosition;
uniform ivec3 cameraPositionInt;
uniform float frameTimeCounter;
uniform float rainStrength;
uniform int renderStage;
uniform sampler2D gtexture;
#include "/lib/waving.glsl"

#ifdef LIGHT_FIELD
layout(r32ui) uniform writeonly uimage3D voxelImg;

// The colour a light block casts: a brightness-weighted average over its sprite, so a torch contributes its
// flame rather than its stick and glowstone its bright crystals rather than the dark grout between them.
vec3 emitterColor(vec2 uv, vec2 mid) {
    vec2 halfExtent = abs(uv - mid);
    vec3 acc = vec3(0.0);
    float wsum = 0.0;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            vec2 o = (vec2(x, y) - 1.5) / 1.5 * 0.85;
            vec4 t = textureLod(gtexture, mid + o * halfExtent, 0.0);
            float l = luminance(t.rgb);
            float w = t.a * l * l * l + 1e-5;
            acc += t.rgb * w;
            wsum += w;
        }
    }
    vec3 c = acc / wsum;
    // Normalize brightness (level carries strength) and deepen the hue slightly: averaged sprites wash out.
    c /= max(max(c.r, max(c.g, c.b)), 1e-3);
    return pow(c, vec3(1.35));
}

void voxelize(int mat, vec3 worldPos, vec3 normal) {
#ifdef LIGHT_FIELD_SELFTEST
    // Unfiltered: every vertex marks its block solid, proving image stores from this stage land.
    {
        ivec3 sv = worldBlockToVoxel(ivec3(floor(worldPos + at_midBlock.xyz / 64.0)), cameraPositionInt);
        if (voxelInside(sv)) imageStore(voxelImg, sv, uvec4(VOXEL_SOLID, 0u, 0u, 0u));
        return;
    }
#endif
    if (renderStage != MC_RENDER_STAGE_TERRAIN_SOLID && renderStage != MC_RENDER_STAGE_TERRAIN_CUTOUT
        && renderStage != MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED && renderStage != MC_RENDER_STAGE_TERRAIN_TRANSLUCENT) return;
    vec3 toCentre = at_midBlock.xyz / 64.0;
    ivec3 block = ivec3(floor(worldPos + toCentre));
    ivec3 v = worldBlockToVoxel(block, cameraPositionInt);
    if (!voxelInside(v)) return;

    float emission = at_midBlock.w;
    uint data;
    if (emission > 0.5) {
        vec2 mid = (gl_TextureMatrix[0] * vec4(mc_midTexCoord, 0.0, 1.0)).xy;
        data = packVoxel(VOXEL_EMITTER, uint(emission + 0.5), emitterColor((gl_TextureMatrix[0] * gl_MultiTexCoord0).xy, mid));
    } else if (mat == MAT_WATER) {
        data = packVoxel(VOXEL_TINT, 0u, vec3(0.55, 0.80, 0.85));
    } else if (mat == MAT_LEAVES) {
        data = packVoxel(VOXEL_TINT, 0u, vec3(0.42, 0.50, 0.30));
    } else if (mat == MAT_TRANSLUCENT || mat == MAT_ICE) {
        // Glass and ice colour the light that passes; the vertex colour carries stained-glass tint poorly, so
        // read the sprite centre instead.
        vec2 mid = (gl_TextureMatrix[0] * vec4(mc_midTexCoord, 0.0, 1.0)).xy;
        vec4 t = textureLod(gtexture, mid, 0.0);
        data = packVoxel(VOXEL_TINT, 0u, mix(vec3(1.0), toLinear(t.rgb) * 1.6, t.a * 0.9));
    } else if (mat == MAT_FOLIAGE || mat == MAT_TALL_UPPER || mat == MAT_PORTAL) {
        return;
    } else {
        // Only faces lying on the block boundary mark it opaque; crosses, slab tops, rails and other partial
        // shapes pass light.
        if (abs(dot(toCentre, normal)) < 0.45) return;
        data = packVoxel(VOXEL_SOLID, 0u, vec3(0.0));
    }
    imageStore(voxelImg, v, uvec4(data, 0u, 0u, 0u));
}
#endif

out vec2 texcoord;
out vec4 glcolor;
flat out int mat;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor = gl_Color;
    mat = int(mc_Entity.x + 0.5) - 10000;

    vec3 shadowViewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    vec3 playerPos = (shadowModelViewInverse * vec4(shadowViewPos, 1.0)).xyz;
#ifdef LIGHT_FIELD
    // One vertex per quad is enough: all four land in the same block (as in Complementary), so this cuts
    // image writes and emitter-colour reads by four.
    if (gl_VertexID % 4 == 0)
        voxelize(mat, playerPos + cameraPosition, normalize(mat3(shadowModelViewInverse) * (gl_NormalMatrix * gl_Normal)));
#endif
#ifdef VOXEL_ONLY
    gl_Position = vec4(-10.0, -10.0, -10.0, 1.0);
    return;
#endif
    vec3 worldPos = waveVertex(playerPos + cameraPosition, mat, at_midBlock.y);
    vec4 clip = gl_ProjectionMatrix * (shadowModelView * vec4(worldPos - cameraPosition, 1.0));
    clip.xyz = distortShadow(clip.xyz);
    gl_Position = clip;
}
#endif

#ifdef FRAGMENT
uniform sampler2D gtexture;
in vec2 texcoord;
in vec4 glcolor;
flat in int mat;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 shadowColor;

void main() {
#ifdef VOXEL_ONLY
    discard;
#endif
    // Water is marked with zero alpha: lighting converts its shadow depth into an absorption distance.
    if (mat == MAT_WATER) {
        shadowColor = vec4(1.0, 1.0, 1.0, 0.0);
        return;
    }
    vec4 c = texture(gtexture, texcoord) * glcolor;
    if (c.a < 0.1) discard;
    shadowColor = vec4(c.rgb, c.a);
}
#endif
