// End storm: the player stands in the eye of a violent vortex. A towering, fast-turning eye wall of clumpy cloud
// rings the main island; above the island a clear funnel opens up to a glowing core; lightning flashes inside the
// wall, lighting the clouds from within. Marched at half resolution in vl_march (DIM_END branch), accumulated
// temporally and composited in composite.glsl. Requires clouds.glsl's cloudTex().
//
// After Bliss (Chocapic13 edit, lib/end_fog.glsl, by Xonk and contributors): a vortex over the main island, a
// glowing light at its core, self-shadowed clumps, flashes in the storm. Idea only; the code is our own.
// Improvements over the original:
//  - Real 3D noise (our 64^3 cloud texture, two octaves on rotated domains) instead of a y-sliced 2D texture, so
//    the storm does not repeat and has proper depth.
//  - Structure: an eye wall (a ring of dense cloud) and an open funnel over the island, so the storm has a shape
//    you are inside of rather than a uniform fog, and the dragon fight stays readable.
//  - The swirl tightens toward the axis and rises with height: the wall reads as a spiral funnel.
//  - Colour is not uniform (Trevor: Dreamer's Fantasy's End felt too uniformly purple): violet and magenta light
//    drifts across the storm with rare teal accents, the core is pale cyan-white, the void glows magenta below.
//  - Lightning lights the cloud interiors around a random point on the wall, with a flicker, not a flat flash.

const vec3 END_VORTEX_CENTRE = vec3(0.0, 100.0, 0.0);
const vec3 END_CORE_LIGHT = vec3(0.0, 260.0, 0.0);
const float END_EYE_RADIUS = 250.0;

// x = extinction per block, y = colour variation 0..1.
vec2 endStorm(vec3 p, float t) {
    vec3 rel = p - END_VORTEX_CENTRE;
    float r = length(rel.xz);
    // Spiral: tighter and faster near the axis, rising with height.
    float ang = rel.y / 55.0 + t * 0.05 + 90.0 / (r + 40.0) + t * 1.8 / (r * 0.02 + 1.0) * 0.1;
    float swirl = 1.0 - smoothstep(300.0, 700.0, r);
    float c = cos(ang * swirl), s = sin(ang * swirl);
    vec2 xz = mat2(c, -s, s, c) * rel.xz;
    vec3 q = vec3(xz.x, rel.y, xz.y);
    vec4 n = cloudTex(vec3(q.x * 0.0042, q.y * 0.007 - t * 0.004, q.z * 0.0042));
    float shape = n.r * 0.6 + n.g * 0.28 + n.b * 0.12;
    // Churning detail, rising fast: ragged, tumbling edges.
    float detail = cloudTex(vec3(q.z * 0.016 + 0.37, q.y * 0.028 + t * 0.012, -q.x * 0.016)).g;
    shape -= (1.0 - detail) * 0.2;
    // Eye wall: a broad ring of dense storm around the island, towering up; thinner storm beyond.
    float wall = exp(-sqr((r - END_EYE_RADIUS) / 120.0));
    float clump = smoothstep(0.42 - wall * 0.14, 0.7 - wall * 0.08, shape);
    // The eye: clear over the island and in a funnel straight up to the core.
    float eye = smoothstep(END_EYE_RADIUS * 0.5, END_EYE_RADIUS * 0.8, r + max(20.0 - rel.y, 0.0) * 0.6);
    // Vertical extent: from the void up far past the pillars.
    float band = smoothstep(-60.0, 20.0, p.y) * (1.0 - smoothstep(300.0, 420.0, p.y));
    float voidMist = exp(-max(p.y + 10.0, 0.0) / 30.0);
    float sigma = clump * band * eye * (0.02 + 0.07 * wall) + voidMist * 0.006 + 0.0004;
    return vec2(sigma, n.a);
}

// Lightning in the eye wall: returns (world position of the current bolt, brightness). A new strike every few
// seconds at a random point on the wall, flickering for a fraction of a second.
vec4 endLightning(float t) {
    float slot = floor(t / 2.6);
    float h = hash12(vec2(slot, 7.13));
    float phase = fract(t / 2.6) * 2.6;
    // About half the slots strike; each flash lasts ~0.45 s with two or three flickers.
    float on = step(0.45, h) * exp(-phase * 7.0) * (0.6 + 0.4 * sin(phase * 70.0 + h * 20.0));
    float a = hash12(vec2(slot, 3.7)) * TAU;
    float y = mix(90.0, 260.0, hash12(vec2(slot, 11.9)));
    vec3 pos = END_VORTEX_CENTRE + vec3(cos(a) * END_EYE_RADIUS, y - END_VORTEX_CENTRE.y, sin(a) * END_EYE_RADIUS);
    return vec4(pos, max(on, 0.0));
}

// Light arriving at a storm point: the vortex core (pale cyan-white, self-shadowed), violet/magenta ambient with
// rare teal, the void's magenta glow, and lightning.
vec3 endStormLight(vec3 p, float t, float variation, vec4 bolt) {
    vec3 toCore = END_CORE_LIGHT - p;
    float d = length(toCore);
    vec3 l = toCore / max(d, 1e-3);
    float occ = endStorm(p + l * 14.0, t).x * 14.0 + endStorm(p + l * 40.0, t).x * 26.0;
    vec3 core = vec3(0.7, 0.8, 1.0) * 1.0 * exp(-d / 180.0) * exp(-occ * 1.6);
    vec3 ambient = mix(vec3(0.24, 0.07, 0.40), vec3(0.36, 0.06, 0.30), smoothstep(0.3, 0.7, variation));
    ambient = mix(ambient, vec3(0.06, 0.20, 0.26), smoothstep(0.82, 0.95, variation) * 0.6);
    vec3 voidGlow = vec3(0.5, 0.06, 0.4) * exp(-max(p.y + 20.0, 0.0) / 45.0);
    vec3 flash = vec3(0.8, 0.55, 1.0) * 14.0 * bolt.w * exp(-length(p - bolt.xyz) / 70.0);
    return core + ambient * 0.17 + voidGlow * 0.35 + flash;
}
