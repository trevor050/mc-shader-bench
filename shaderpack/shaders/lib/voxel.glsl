// Voxel light field: a camera-centred block grid written by the shadow pass (voxelImg) and a coloured light
// volume diffused through it by shadowcomp (lightFieldA/B, ping-ponged by frame parity).
//
// Lineage: the flood-fill idea follows Complementary Reimagined/Unbound's "ACT" coloured lighting. Differences:
//  - Emitters describe themselves: strength is Iris's per-block emission (at_midBlock.w) and colour is a
//    brightness-weighted read of the block's own texture, so there is no hand-kept light colour table and new
//    or modded light blocks work unchanged.
//  - The volume carries radiance, not only a hue: area emitters add up (a lava sea outshines one lava block),
//    and surfaces read its gradient for directional diffuse and a specular glint (see lighting.glsl).
//  - Fire-like sources flicker per voxel, so firelight moves on nearby walls.
//
// Voxel encoding (r32ui): bits 0-1 type, bits 2-5 emission level, bits 8-31 RGB8 (emitter colour / tint).

#define VOXEL_AIR 0u
#define VOXEL_SOLID 1u
#define VOXEL_TINT 2u
#define VOXEL_EMITTER 3u

const ivec3 VOXEL_SIZE = ivec3(VOXEL_EXTENT, VOXEL_EXTENT_Y, VOXEL_EXTENT);

uint packVoxel(uint type, uint level, vec3 rgb) {
    uvec3 c = uvec3(saturate(rgb) * 255.0 + 0.5);
    return type | (min(level, 15u) << 2u) | (c.r << 8u) | (c.g << 16u) | (c.b << 24u);
}

uint voxelType(uint v) { return v & 3u; }
uint voxelLevel(uint v) { return (v >> 2u) & 15u; }
vec3 voxelColor(uint v) { return vec3(uvec3(v >> 8u, v >> 16u, v >> 24u) & 255u) / 255.0; }

// Integer voxel coordinate of a world block. The grid is re-centred on the camera's block every frame.
ivec3 worldBlockToVoxel(ivec3 block, ivec3 cameraBlock) {
    return block - cameraBlock + VOXEL_SIZE / 2;
}

bool voxelInside(ivec3 v) {
    return all(greaterThanEqual(v, ivec3(0))) && all(lessThan(v, VOXEL_SIZE));
}

#ifdef VOXEL_READ
// Normalized texture coordinate for a camera-relative position; cameraFract is Iris's cameraPositionFract.
vec3 voxelUVW(vec3 playerPos, vec3 cameraFract) {
    return (playerPos + cameraFract + vec3(VOXEL_SIZE / 2)) / vec3(VOXEL_SIZE);
}

// Fade to 0 over the outer 12% of the volume so the vanilla fallback takes over without a seam.
float voxelEdgeFade(vec3 uvw) {
    vec3 e = min(uvw, 1.0 - uvw);
    return smoothstep(0.0, 0.12, min(min(e.x, e.y), e.z));
}

// Requires uniforms lightFieldSamplerA/B, frameCounter, cameraPositionFract. shadowcomp writes B on even
// frames and A on odd ones; read whichever was written this frame.
vec3 lightFieldTap(vec3 uvw) {
    return (frameCounter & 1) == 0 ? texture(lightFieldSamplerB, uvw).rgb : texture(lightFieldSamplerA, uvw).rgb;
}

struct FieldLight {
    vec3 radiance;  // light arriving at the surface, already scaled by LIGHT_FIELD_GAIN
    vec3 dir;       // world direction toward where the light comes from (zero when isotropic)
    float focus;    // 0 = light from everywhere, 1 = a single dominant direction
    float weight;   // 0 outside the volume
};

// Reads the field in the open cell in front of the surface (so a wall's far side stays dark) and estimates
// the local light direction from the field's gradient with three forward differences.
FieldLight sampleLightField(vec3 playerPos, vec3 n) {
    FieldLight f;
    f.radiance = vec3(0.0);
    f.dir = vec3(0.0);
    f.focus = 0.0;
    vec3 uvw = voxelUVW(playerPos + n * 0.55, cameraPositionFract);
    f.weight = voxelEdgeFade(uvw);
    if (f.weight <= 0.0) return f;
    vec3 texel = 0.75 / vec3(VOXEL_SIZE);
    vec3 c = lightFieldTap(uvw);
    float l0 = luminance(c);
    if (l0 < 1e-4) return f;
    vec3 g = vec3(luminance(lightFieldTap(uvw + vec3(texel.x, 0.0, 0.0))),
                  luminance(lightFieldTap(uvw + vec3(0.0, texel.y, 0.0))),
                  luminance(lightFieldTap(uvw + vec3(0.0, 0.0, texel.z)))) - l0;
    float gl = length(g);
    f.dir = gl > 1e-6 ? g / gl : vec3(0.0);
    // Relative gradient: close to a source the field changes fast relative to its value.
    f.focus = saturate(gl / l0 * 1.6);
    f.radiance = c * LIGHT_FIELD_GAIN;
    return f;
}
#endif
