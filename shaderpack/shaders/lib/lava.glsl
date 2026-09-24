// Procedural lava, replacing the tiled vanilla texture. Requires common.glsl (valueNoise, hash12).
//
// Lava seas: irregular plates of dark basalt crust (a Voronoi pattern a few blocks across, jittered and warped
// so plates are angular and uneven), drifting with a slow current. Seams only exist where plates meet, and
// every seam segment gets its own width and temperature from the pair of plates it separates: a few blaze,
// many barely glow, the rest are cold. Hot seams bleed a faint ember rim into the plates next to them. A plate
// here and there has broken up into an open molten pool. The drift uses a two-phase flow map so the pattern
// moves without stretching.
//
// Lava falls: a churning curtain. The streaks wobble sideways with time, dark clots of crust tumble down
// faster than the flow, and the heat flickers at small scale.

// Blackbody-ish ramp for molten rock: basalt -> deep red -> orange -> yellow.
vec3 lavaRamp(float heat) {
    vec3 c = mix(vec3(0.012, 0.006, 0.005), vec3(0.42, 0.035, 0.004), smoothstep(0.05, 0.35, heat));
    c = mix(c, vec3(1.0, 0.25, 0.02), smoothstep(0.32, 0.65, heat));
    c = mix(c, vec3(1.0, 0.62, 0.2), smoothstep(0.65, 1.0, heat));
    return c;
}

vec2 lavaHash2(vec2 p) {
    return vec2(hash12(p), hash12(p + vec2(17.31, 5.77)));
}

// Crust at plate-space coordinates q. Returns (seam heat 0..1, rim glow 0..1, pool 0..1).
vec3 lavaCrust(vec2 q, float widthScale) {
    vec2 cell = floor(q);
    vec2 f = fract(q);
    float d1 = 8.0, d2 = 8.0;
    vec2 id1 = vec2(0.0), id2 = vec2(0.0);
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            vec2 o = vec2(x, y);
            vec2 c = cell + o;
            vec2 r = o + lavaHash2(c) * 0.9 + 0.05 - f;
            float d = dot(r, r);
            if (d < d1) { d2 = d1; id2 = id1; d1 = d; id1 = c; }
            else if (d < d2) { d2 = d; id2 = c; }
        }
    d1 = sqrt(d1); d2 = sqrt(d2);
    float edge = d2 - d1;                                      // 0 on the seam between two plates
    // Each seam (plate pair) has its own width and temperature; most are cool.
    vec2 lo = min(id1, id2), hi = max(id1, id2);
    float pairH = hash12(lo * 1.37 + hi * 0.61 + 4.1);
    float hot = smoothstep(0.45, 0.95, pairH);
    float width = mix(0.02, 0.11, pairH) * widthScale;
    float seam = (1.0 - smoothstep(0.0, width, edge)) * (0.12 + 0.88 * hot);
    float rim = (1.0 - smoothstep(0.0, width * 4.0, edge)) * hot;
    // A few plates have melted into open pools.
    // Pools keep a crusted rim along their plate's edges and glow brightest in the middle.
    float pool = step(0.96, hash12(id1 + 91.3)) * smoothstep(0.06, 0.4, edge);
    return vec3(seam, rim, pool);
}

float lavaSurfaceHeat(vec2 p, float time, float dist) {
    // Slow currents that change direction across a lake; two phases so the drift never stretches.
    vec2 flow = vec2(valueNoise(p / 80.0 + 3.1), valueNoise(p / 80.0 + 17.7)) - 0.5;
    flow = normalize(flow + 1e-4) * 0.3;
    const float period = 10.0;
    float ph0 = fract(time / period), ph1 = fract(time / period + 0.5);
    float blend = abs(ph0 * 2.0 - 1.0);

    // Warp the plate lattice so edges wander and plates vary in size.
    vec2 warp = vec2(valueNoise(p * 0.18 + 2.0), valueNoise(p * 0.18 + 9.0)) - 0.5;
    float farFade = smoothstep(20.0, 120.0, dist);
    float widthScale = 1.0 + farFade * 1.5;   // widen far seams a little instead of aliasing
    const float plateSize = 4.5;
    vec3 c0 = lavaCrust((p - flow * ph0 * period) / plateSize + warp * 0.9, widthScale);
    vec3 c1 = lavaCrust((p - flow * ph1 * period) / plateSize + warp * 0.9 + vec2(3.7, 1.9), widthScale);
    vec3 c = mix(c0, c1, blend);

    // Seams flicker and vary along their length.
    float along = 0.65 + 0.35 * valueNoise(p * 1.3 + time * 0.4);
    // Widened far seams are dimmed so the sea's average brightness stays put with distance.
    float heat = 0.06 + c.y * 0.22 + c.x * 0.75 * along * mix(1.0, 0.7, farFade);
    float churn = valueNoise(p * 0.8 - time * 0.3) * 0.6 + valueNoise(p * 2.3 + time * 0.5) * 0.4;
    heat = mix(heat, 0.45 + 0.5 * churn, c.z);
    // Rare wider molten rivers where the crust never forms.
    float river = smoothstep(0.78, 0.9, valueNoise(p / 30.0 + time * 0.01));
    heat = mix(heat, 0.72 + 0.2 * along, river * 0.85);
    return saturate(heat);
}

float lavaFallHeat(vec3 wp, vec3 n, float time) {
    float u = dot(wp.xz, vec2(n.z, -n.x));
    float v = wp.y + time * 4.2;
    // Churn: streaks wobble sideways as the curtain pours.
    float wob = (valueNoise(vec2(u * 0.6, v * 0.12)) - 0.5) * 0.5;
    float uu = u + wob;
    float streak = valueNoise(vec2(uu * 5.0, v * 0.07)) * 0.6 + valueNoise(vec2(uu * 12.0, v * 0.15)) * 0.4;
    // Dark clots of crust tumbling down faster than the flow.
    vec2 cq = vec2(uu * 2.5, (wp.y + time * 6.5) * 0.35);
    vec2 cc = floor(cq);
    vec2 cf = fract(cq) - 0.5 - (lavaHash2(cc) - 0.5) * vec2(0.4, 0.3);
    // Elongated smears of cooler skin, soft-edged.
    float clot = step(0.78, hash12(cc + 3.3)) * (1.0 - smoothstep(0.05, 0.3, length(cf * vec2(2.2, 0.8))));
    float flicker = valueNoise(vec2(uu * 14.0, v * 1.5)) * 0.2;
    float heat = 0.32 + 0.55 * smoothstep(0.3, 0.8, streak) + flicker - 0.3 * clot;
    return saturate(heat);
}

// Emitted radiance of a lava surface at world position wp with geometric normal n, viewed along rd at dist.
vec3 lavaRadiance(vec3 wp, vec3 n, float time, vec3 rd, float dist) {
    bool falling = abs(n.y) < 0.5;
    float heat = falling ? lavaFallHeat(wp, n, time) : lavaSurfaceHeat(wp.xz, time, dist);
    // Emission rises steeply with temperature, so cold crust stays nearly black.
    float intensity = mix(0.02, falling ? 2.6 : 3.4, heat * heat);
    return lavaRamp(heat) * intensity;
}
