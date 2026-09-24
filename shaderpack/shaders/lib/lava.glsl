// Procedural lava, replacing the tiled vanilla texture. Requires common.glsl (valueNoise, hash).
//
// Lava seas: a dark basalt crust broken by a network of thin glowing cracks, drifting along a slow flow field.
// The pattern is advected with a two-phase flow map (two copies offset by half a period, cross-faded) so it
// moves in currents without stretching. Heat varies at three scales: broad hot channels versus cooler crusted
// regions, the crack network, and a soft glow sampled a little "below" the surface with parallax, which gives
// the crust depth: you see molten rock underneath the plates, not a flat decal. Fine detail fades with
// distance to avoid shimmer. Built from smooth value noise, so there is no visible tiling.
//
// Lava falls: fast downward streaks with a hot core, darker cooling ribbons sliding down, and a gentle surge.

// Blackbody-ish ramp for molten rock: basalt -> deep red -> orange -> yellow.
vec3 lavaRamp(float heat) {
    vec3 c = mix(vec3(0.02, 0.008, 0.005), vec3(0.45, 0.04, 0.004), smoothstep(0.0, 0.3, heat));
    c = mix(c, vec3(1.0, 0.26, 0.02), smoothstep(0.28, 0.62, heat));
    c = mix(c, vec3(1.0, 0.62, 0.18), smoothstep(0.62, 1.0, heat));
    return c;
}

float lavaRidge(vec2 p) { return 1.0 - abs(valueNoise(p) * 2.0 - 1.0); }

// Crack network at world coordinates uv. sharp: exponent that controls crack width.
float lavaCracks(vec2 uv, float sharp) {
    vec2 warp = vec2(valueNoise(uv * 0.21 + 5.3), valueNoise(uv * 0.21 + 11.9)) - 0.5;
    // Small-scale jitter makes the seams ragged, like torn crust, instead of smooth caustic curves.
    warp += (vec2(valueNoise(uv * 1.9 + 2.1), valueNoise(uv * 1.9 + 8.4)) - 0.5) * 0.35;
    float big = pow(lavaRidge(uv * 0.24 + warp * 1.6), sharp);
    float fine = pow(lavaRidge(uv * 0.7 - warp * 1.2 + 3.7), sharp * 1.8);
    return saturate(big + fine * 0.2);
}

float lavaSurfaceHeat(vec2 p, vec3 rd, float time, float dist) {
    // Flow field: slow currents that change direction across a lake.
    vec2 flow = vec2(valueNoise(p / 70.0 + 3.1), valueNoise(p / 70.0 + 17.7)) - 0.5;
    flow = normalize(flow + 1e-4) * 0.45;
    const float period = 7.0;
    float ph0 = fract(time / period);
    float ph1 = fract(time / period + 0.5);
    float blend = abs(ph0 * 2.0 - 1.0);

    // Far away the cracks are sub-pixel; widen them toward their average instead of letting them alias.
    float lod = smoothstep(16.0, 110.0, dist);
    float sharp = mix(6.0, 2.5, lod);

    vec2 uv0 = p - flow * ph0 * period;
    vec2 uv1 = p - flow * ph1 * period + vec2(7.3, 2.9);
    float cracks = mix(lavaCracks(uv0, sharp), lavaCracks(uv1, sharp), blend);

    // Molten rock under the crust, seen with parallax through the cracks and bleeding up around them.
    vec2 par = rd.xz / max(-rd.y, 0.25) * 0.35;
    float under = mix(lavaCracks(uv0 + par, 3.0), lavaCracks(uv1 + par, 3.0), blend);

    // Broad hot channels and cooler crusted regions, drifting very slowly.
    float channel = smoothstep(0.62, 0.9, valueNoise(p / 45.0 + time * 0.012));
    float pulse = 0.9 + 0.1 * sin(time * 1.1 + valueNoise(p * 0.1) * 9.0);

    // Crust plates keep a dull, mottled red glow; hotter near the seams (heat soaks in from below).
    float mottle = valueNoise(p * 0.9) * 0.6 + valueNoise(p * 2.7 + 4.0) * 0.4;
    float heat = 0.1 + mottle * 0.12 + under * 0.25 + cracks * 0.75;
    // Open molten pools where the crust has broken away.
    float pool = smoothstep(0.7, 0.82, valueNoise(p / 14.0 + 21.0 + time * 0.02));
    heat = mix(heat, 0.8 + 0.18 * mottle, pool);
    heat = mix(heat, 0.72 + cracks * 0.28, channel * 0.6);
    return saturate(heat * pulse);
}

float lavaFallHeat(vec3 wp, vec3 n, float time) {
    float u = dot(wp.xz, vec2(n.z, -n.x));
    float v = wp.y;
    float streak = valueNoise(vec2(u * 5.0, (v + time * 4.0) * 0.12)) * 0.6
                 + valueNoise(vec2(u * 11.0, (v + time * 5.5) * 0.25)) * 0.4;
    // Thin, cooler ribbons of skin sliding down the fall.
    float ribbon = smoothstep(0.5, 0.8, valueNoise(vec2(u * 3.0 + 9.0, (v + time * 3.0) * 0.08)));
    float surge = 0.05 * sin((v + time * 3.6) * 0.9 + u);
    // Contrast: bright molten streaks between darker cooling skin that slides down with the flow.
    float heat = 0.3 + 0.55 * smoothstep(0.35, 0.8, streak) - 0.2 * ribbon + surge;
    return saturate(heat);
}

// Emitted radiance of a lava surface at world position wp with geometric normal n, viewed along rd at dist.
vec3 lavaRadiance(vec3 wp, vec3 n, float time, vec3 rd, float dist) {
    bool falling = abs(n.y) < 0.5;
    float heat = falling ? lavaFallHeat(wp, n, time) : lavaSurfaceHeat(wp.xz, rd, time, dist);
    // Emission rises steeply with temperature; the crust keeps a faint red glow.
    float intensity = mix(0.05, falling ? 2.4 : 3.2, heat * heat);
    return lavaRamp(heat) * intensity;
}
