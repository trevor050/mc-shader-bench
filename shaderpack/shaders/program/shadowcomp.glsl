// Light field propagation (see lib/voxel.glsl). One diffusion step per frame over the camera-centred grid:
// every open voxel becomes the attenuated mean of its six neighbours from the previous frame, re-indexed for
// camera movement; emitters inject their own radiance; solids hold nothing. The steady state of this update
// is a screened-Poisson field (roughly exp(-r/L)/r around a source), so light falls off smoothly, wraps around
// corners and pools in enclosed rooms instead of following Minecraft's linear diamond.

#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/voxel.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
// Must equal (VOXEL_EXTENT/8, VOXEL_EXTENT_Y/8, VOXEL_EXTENT/8). Keep this line free of trailing comments:
// Iris parses const directives line by line.
const ivec3 workGroups = ivec3(16, 8, 16);

uniform usampler3D voxelSampler;
uniform sampler3D lightFieldSamplerA;
uniform sampler3D lightFieldSamplerB;
layout(rgba16f) uniform writeonly image3D lightFieldA;
layout(rgba16f) uniform writeonly image3D lightFieldB;
uniform ivec3 cameraPositionInt;
uniform ivec3 previousCameraPositionInt;
uniform int frameCounter;
uniform float frameTimeCounter;

vec3 previousLight(ivec3 p, bool readA) {
    if (!voxelInside(p)) return vec3(0.0);
    return readA ? texelFetch(lightFieldSamplerA, p, 0).rgb : texelFetch(lightFieldSamplerB, p, 0).rgb;
}

void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID);
    // Even frames read A and write B; odd frames the reverse. Readers pick the buffer written this frame.
    bool readA = (frameCounter & 1) == 0;
    // Where this voxel's world block was stored last frame.
    ivec3 prev = pos + (cameraPositionInt - previousCameraPositionInt);

    uint data = texelFetch(voxelSampler, pos, 0).r;
    uint type = voxelType(data);
    vec3 light = vec3(0.0);

    if (type == VOXEL_EMITTER) {
        float level = float(voxelLevel(data)) / 15.0;
        vec3 c = voxelColor(data);
        // Fire-like colours (red-dominant) flicker a little, each voxel on its own phase.
        float warm = saturate((c.r - c.b) * 1.5);
        float phase = hash12(vec2(pos.xz + cameraPositionInt.xz) + float(pos.y + cameraPositionInt.y) * 7.13);
        float flicker = 1.0 + warm * 0.12 * (valueNoise(vec2(frameTimeCounter * 6.0 + phase * 40.0, phase * 13.0)) - 0.5);
        light = c * pow(level, 2.2) * LIGHT_FIELD_SOURCE * flicker;
    } else if (type != VOXEL_SOLID) {
        vec3 sum = previousLight(prev + ivec3(1, 0, 0), readA) + previousLight(prev - ivec3(1, 0, 0), readA)
                 + previousLight(prev + ivec3(0, 1, 0), readA) + previousLight(prev - ivec3(0, 1, 0), readA)
                 + previousLight(prev + ivec3(0, 0, 1), readA) + previousLight(prev - ivec3(0, 0, 1), readA);
        light = sum * (LIGHT_FIELD_KEEP / 6.0);
        if (type == VOXEL_TINT) light *= voxelColor(data);
    }

    light = clamp(light, vec3(0.0), vec3(4000.0)); // one bad value must not flood the volume
#ifdef LIGHT_FIELD_SELFTEST
    light = vec3(0.0, 6.0, 0.0); // proves this pass runs and later passes read the field
#endif
    if (readA) imageStore(lightFieldB, pos, vec4(light, 1.0));
    else imageStore(lightFieldA, pos, vec4(light, 1.0));
}
