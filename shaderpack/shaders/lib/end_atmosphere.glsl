// End storm: a swirling vortex of clumpy cloud around the main island, marched at half resolution in vl_march
// (DIM_END branch), accumulated temporally and composited in composite.glsl. Requires clouds.glsl's cloudTex().
//
// After Bliss (Chocapic13 edit, lib/end_fog.glsl, by Xonk and contributors): a vortex centred over the main
// island, a clear bubble around the camera, a glowing light at the vortex core, self-shadowed clumps. Idea only;
// the code is our own. Improvements over the original:
//  - Real 3D noise (our 64^3 cloud texture, two octaves on rotated domains) instead of a y-sliced 2D texture, so
//    the storm does not repeat and has proper depth.
//  - The swirl tightens toward the axis and rises with height, so the vortex reads as a spiral funnel rather than
//    a uniformly rotated field.
//  - Colour is not uniform (Trevor: Dreamer's Fantasy's End felt too uniformly purple): ambient light drifts
//    between violet, magenta and teal across the storm, the vortex core is a pale cyan-white, and the void below
//    glows magenta through the lowest layers.
//  - The storm stays clear of the island's airspace (a flattened bubble over the island), so the dragon fight
//    stays readable while the sky around it is dense and alien.

const vec3 END_VORTEX_CENTRE = vec3(0.0, 100.0, 0.0);
const vec3 END_CORE_LIGHT = vec3(0.0, 230.0, 0.0);

// x = extinction per block, y = colour variation 0..1 (violet <-> teal).
vec2 endStorm(vec3 p, float t) {
    vec3 rel = p - END_VORTEX_CENTRE;
    float r = length(rel.xz);
    // Spiral: tighter near the axis, rising with height, slowly turning.
    float ang = rel.y / 70.0 + t * 0.015 + 60.0 / (r + 30.0);
    float swirl = 1.0 - smoothstep(180.0, 520.0, r);
    float c = cos(ang * swirl), s = sin(ang * swirl);
    vec2 xz = mat2(c, -s, s, c) * rel.xz;
    vec3 q = vec3(xz.x, rel.y, xz.y);
    vec4 n = cloudTex(vec3(q.x * 0.0042, q.y * 0.008 - t * 0.0015, q.z * 0.0042));
    float shape = n.r * 0.6 + n.g * 0.28 + n.b * 0.12;
    float detail = cloudTex(vec3(q.z * 0.016 + 0.37, q.y * 0.028 + t * 0.003, -q.x * 0.016)).g;
    shape -= (1.0 - detail) * 0.18;
    float clump = smoothstep(0.4, 0.7, shape);
    // Clear airspace above and around the main island: a flattened bubble.
    float bubble = length(vec3(rel.x, rel.y * 1.6, rel.z));
    float open = smoothstep(80.0, 170.0, bubble);
    // Vertical extent: a thick layer from the void up past the pillars, densest at island height and above.
    float band = smoothstep(-40.0, 30.0, p.y) * (1.0 - smoothstep(220.0, 340.0, p.y));
    // Mist rising out of the void.
    float voidMist = exp(-max(p.y + 10.0, 0.0) / 30.0);
    float sigma = clump * band * open * 0.05 + voidMist * 0.008 + 0.0006;
    return vec2(sigma, n.a);
}

// Light arriving at a storm point: the vortex core (pale cyan-white, self-shadowed by the storm), a shifting
// violet/magenta/teal ambient, and a magenta glow from the void below.
vec3 endStormLight(vec3 p, float t, float variation) {
    vec3 toCore = END_CORE_LIGHT - p;
    float d = length(toCore);
    vec3 l = toCore / max(d, 1e-3);
    float occ = endStorm(p + l * 14.0, t).x * 14.0 + endStorm(p + l * 40.0, t).x * 26.0;
    vec3 core = vec3(0.62, 0.86, 1.0) * 5.0 * exp(-d / 180.0) * exp(-occ * 1.6);
    vec3 ambient = mix(vec3(0.20, 0.09, 0.34), vec3(0.07, 0.22, 0.26), smoothstep(0.35, 0.75, variation));
    ambient = mix(ambient, vec3(0.30, 0.07, 0.24), smoothstep(0.6, 0.9, 1.0 - variation) * 0.5);
    vec3 voidGlow = vec3(0.5, 0.06, 0.4) * exp(-max(p.y + 20.0, 0.0) / 45.0);
    return core + ambient * 0.9 + voidGlow;
}
