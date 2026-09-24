// Screen-space reflections for glossy opaque blocks (MAT_POLISHED, MAT_METAL, MAT_GLASSY, MAT_ICE_SOLID), traced
// in composite against the fully lit frame, so whatever lights the scene shows up in the reflection: lava glowing
// in obsidian, torches in a polished floor, the sky in packed ice.
//
// Lineage: Complementary Unbound's SSR (exponential march with binary refinement, reflections of the lit scene,
// per-texel smoothness from the texture). Differences:
//  - Roughness is a per-frame jittered microfacet normal resolved by TAA, rather than mip blur of a separate
//    reflection buffer: no extra buffers or passes, and blurry reflections stay sharp at contact.
//  - Accepting a hit uses a thickness that grows with distance and a check that the ray was genuinely behind
//    the surface, which removes the smeared "stretched trees" artefact of naive depth tests.
//  - Misses fall back per dimension: the real sky model gated by sky light in the Overworld (none in caves),
//    ember-lit smoke in the Nether, violet void in the End.
//  - Metals tint their reflection by the block's own colour.
// Requires: gbufferProjection, gbufferProjectionInverse, depthtex0, colortex0, projectAndDivide.

vec3 reflViewFromDepth(vec2 uv, float depth) {
    return projectAndDivide(gbufferProjectionInverse, vec3(uv, depth) * 2.0 - 1.0);
}

// Returns the reflected colour in rgb and its confidence (0 = miss) in a.
vec4 traceReflection(vec3 viewPos, vec3 viewDir, float dither) {
    float stepLen = 0.25 + 0.02 * -viewPos.z;
    vec3 p = viewPos + viewDir * stepLen * dither;
    vec3 prev = p;
    for (int i = 0; i < 28; i++) {
        prev = p;
        p += viewDir * stepLen;
        stepLen *= 1.2;
        if (p.z > -0.05) break;
        vec3 s = projectAndDivide(gbufferProjection, p) * 0.5 + 0.5;
        if (any(lessThan(s.xy, vec2(0.0))) || any(greaterThan(s.xy, vec2(1.0)))) break;
        float d = texture(depthtex0, s.xy).r;
        if (d >= 1.0 || d < 0.56) continue;
        if (s.z > d) {
            vec3 a = prev, b = p, hs = s;
            for (int j = 0; j < 6; j++) {
                vec3 m = (a + b) * 0.5;
                vec3 ms = projectAndDivide(gbufferProjection, m) * 0.5 + 0.5;
                if (ms.z > texture(depthtex0, ms.xy).r) { b = m; hs = ms; } else a = m;
            }
            float hitZ = reflViewFromDepth(hs.xy, texture(depthtex0, hs.xy).r).z;
            if (abs(hitZ - b.z) > 0.4 + 0.02 * -b.z) return vec4(0.0);
            vec2 edge = smoothstep(0.0, 0.06, hs.xy) * (1.0 - smoothstep(0.94, 1.0, hs.xy));
            // Rays heading back toward the camera have little on-screen information; fade them.
            float facing = 1.0 - smoothstep(-0.25, 0.05, viewDir.z);
            return vec4(texture(colortex0, hs.xy).rgb, edge.x * edge.y * facing);
        }
    }
    return vec4(0.0);
}
