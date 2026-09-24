// Ice and snow surface looks. Direction (Trevor): ice "very silky, very reflective"; snow reflections redone.
//
// Clear ice is shaded forward like water: a refracted, cyan-absorbing body under a smooth dielectric surface
// (IOR 1.31) whose normal only undulates at block scale, so reflections glide instead of sparkling. Vanilla's
// white streaks survive as faint frost inside the body. Packed and blue ice are opaque, but get the same
// polished sky reflection in deferred.

const float ICE_IOR = 1.31;

// Gentle, broad undulation: frozen ripples a few blocks across. Deliberately low frequency (silk, not glitter).
vec3 iceNormal(vec3 wp, vec3 n) {
    if (abs(n.y) < 0.5) return n;
    vec2 p = wp.xz * 0.35;
    float e = 0.05;
    float h0 = valueNoise(p) + 0.5 * valueNoise(p * 2.3 + 7.1);
    float hx = valueNoise(p + vec2(e, 0.0)) + 0.5 * valueNoise((p + vec2(e, 0.0)) * 2.3 + 7.1);
    float hz = valueNoise(p + vec2(0.0, e)) + 0.5 * valueNoise((p + vec2(0.0, e)) * 2.3 + 7.1);
    vec2 g = vec2(hx - h0, hz - h0) / e;
    return normalize(n + vec3(-g.x, 0.0, -g.y) * 0.018 * sign(n.y));
}

float iceFresnel(float cosI) {
    // Schlick with F0 from the IOR.
    float f0 = sqr((ICE_IOR - 1.0) / (ICE_IOR + 1.0));
    return f0 + (1.0 - f0) * pow(1.0 - saturate(cosI), 5.0);
}

// Absorption of light through ice: pale cyan-blue, deepening with thickness.
vec3 iceTransmit(float thickness) {
    return exp(-vec3(0.16, 0.055, 0.03) * thickness);
}

// Sparse snow glints. Real snow glitter is a few percent of crystals, each a point of light that flashes as
// the view moves. Cells are 1/32 block; only ~2% hold a crystal, drawn as a tiny disc, and only near the camera
// where a crystal can still be a point.
float snowGlint(vec3 wp, vec3 n, vec3 rd, vec3 lightDir, float dist) {
    if (dist > 28.0) return 0.0;
    vec3 an = abs(n);
    vec2 p = (an.y > max(an.x, an.z) ? wp.xz : (an.x > an.z ? wp.zy : wp.xy)) * 32.0;
    vec2 cell = floor(p);
    float seed = hash12(cell + floor(wp.y) * 13.7);
    if (seed < 0.98) return 0.0;
    vec2 centre = vec2(hash12(cell + 3.1), hash12(cell + 7.9)) * 0.6 + 0.2;
    float disc = 1.0 - smoothstep(0.08, 0.22, length(fract(p) - centre));
    vec3 tilt = normalize(n + (vec3(hash12(cell + 1.3), hash12(cell + 5.5), hash12(cell + 9.1)) - 0.5) * 0.7);
    vec3 h = normalize(lightDir - rd);
    float mirror = pow(saturate(dot(tilt, h)), 400.0);
    return disc * mirror * (1.0 - smoothstep(14.0, 28.0, dist));
}
