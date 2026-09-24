// Voxel light field: a camera-centred block grid written by the shadow pass (voxelImg) and a coloured light
// volume diffused through it by shadowcomp (lightFieldA/B, ping-ponged by frame parity).
//
// Lineage: the flood fill and the split of responsibilities follow Complementary Unbound's "ACT" coloured
// lighting (reimplemented, not copied). As there, surface brightness comes from Minecraft's own light level,
// which is always correct and never lags, and the volume supplies the light's colour (energy-weighted: sources
// are stored squared and read back through a square root, so a strong saturated source such as lava wins over a
// weaker white one nearby) plus an "extra light" channel (alpha) that lets lava and portals light areas beyond
// vanilla's 15-block reach. Differences from the original:
//  - Emitters describe themselves: strength is Iris's per-block emission (at_midBlock.w) and colour is read from
//    the block's own texture (brightest, most saturated texels), so new or modded light blocks work unchanged.
//    Only lava and portals get fixed colours, for their extra-light class.
//  - Area emitters add up in the extra channel: a lava sea throws light farther than one lava block.
//  - Surfaces read the field's gradient for directional block light and a specular glint (lighting.glsl), and
//    the Nether smoke is lit by the same field.
//  - Fire-like sources flicker per voxel, so firelight moves on nearby walls.
//
// Voxel encoding (r32ui): bits 0-1 type, bits 2-5 emission level, bits 6-7 extra-light class, bits 8-31 RGB8
// (emitter colour / tint).

#define VOXEL_AIR 0u
#define VOXEL_SOLID 1u
#define VOXEL_TINT 2u
#define VOXEL_EMITTER 3u

const ivec3 VOXEL_SIZE = ivec3(VOXEL_EXTENT, VOXEL_EXTENT_Y, VOXEL_EXTENT);

uint packVoxel(uint type, uint level, vec3 rgb, uint extra) {
    uvec3 c = uvec3(saturate(rgb) * 255.0 + 0.5);
    return type | (min(level, 15u) << 2u) | (min(extra, 3u) << 6u) | (c.r << 8u) | (c.g << 16u) | (c.b << 24u);
}
uint packVoxel(uint type, uint level, vec3 rgb) { return packVoxel(type, level, rgb, 0u); }

uint voxelType(uint v) { return v & 3u; }
uint voxelLevel(uint v) { return (v >> 2u) & 15u; }
uint voxelExtra(uint v) { return (v >> 6u) & 3u; }
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
// Raw field (energy units): rgb = colour energy, a = extra-light energy.
vec4 lightFieldTapRaw(vec3 uvw) {
    return (frameCounter & 1) == 0 ? texture(lightFieldSamplerB, uvw) : texture(lightFieldSamplerA, uvw);
}
// Amplitude of the coloured light (square root of the stored energy), scaled for surfaces and smoke.
vec3 lightFieldTap(vec3 uvw) {
    return sqrt(max(lightFieldTapRaw(uvw).rgb, vec3(0.0))) * LIGHT_FIELD_GAIN;
}

struct FieldLight {
    vec3 radiance;  // light amplitude at the surface (for glints), scaled by LIGHT_FIELD_GAIN
    vec3 hue;       // colour of the block light, luminance 1
    float extra;    // extra light level (0..1) from lava seas and portals, beyond vanilla's reach
    float extraRaw; // square root of the stored extra-light energy (Complementary's lightVolume.a)
    vec3 dir;       // world direction toward where the light comes from (zero when isotropic)
    float focus;    // 0 = light from everywhere, 1 = a single dominant direction
    float weight;   // 0 outside the volume
};

// Reads the field in the open cell in front of the surface (so a wall's far side stays dark) and estimates
// the local light direction from the field's gradient with three forward differences.
FieldLight sampleLightField(vec3 playerPos, vec3 n) {
    FieldLight f;
    f.radiance = vec3(0.0);
    f.hue = BLOCKLIGHT_COLOR / luminance(BLOCKLIGHT_COLOR);
    f.extra = 0.0;
    f.extraRaw = 0.0;
    f.dir = vec3(0.0);
    f.focus = 0.0;
    vec3 uvw = voxelUVW(playerPos + n * 0.55, cameraPositionFract);
    f.weight = voxelEdgeFade(uvw);
    if (f.weight <= 0.0) return f;
    vec4 raw = lightFieldTapRaw(uvw);
    vec3 amp = sqrt(max(raw.rgb, vec3(0.0)));
    float l0 = luminance(amp);
    f.extraRaw = sqrt(max(raw.a, 0.0));
    f.extra = saturate(f.extraRaw * LIGHT_FIELD_EXTRA_GAIN);
    // Hue needs only a trace of field: far-away light still tells the colour. A pinch of the default warm tint
    // keeps it defined where the field is empty.
    vec3 h = amp + BLOCKLIGHT_COLOR * 0.004;
    f.hue = h / luminance(h);
    if (l0 < 1e-4) return f;
    vec3 texel = 0.75 / vec3(VOXEL_SIZE);
    vec3 g = vec3(luminance(sqrt(max(lightFieldTapRaw(uvw + vec3(texel.x, 0.0, 0.0)).rgb, 0.0))),
                  luminance(sqrt(max(lightFieldTapRaw(uvw + vec3(0.0, texel.y, 0.0)).rgb, 0.0))),
                  luminance(sqrt(max(lightFieldTapRaw(uvw + vec3(0.0, 0.0, texel.z)).rgb, 0.0)))) - l0;
    float gl = length(g);
    f.dir = gl > 1e-6 ? g / gl : vec3(0.0);
    // Relative gradient: close to a source the field changes fast relative to its value.
    f.focus = saturate(gl / l0 * 1.6);
    f.radiance = amp * LIGHT_FIELD_GAIN;
    return f;
}
#endif
