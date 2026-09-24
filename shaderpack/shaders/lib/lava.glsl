// Procedural lava surface, replacing the tiled vanilla texture. Requires clouds.glsl (cloudTex) and common.
//
// Lava seen up close is mostly a dark, cooling crust broken into drifting plates, with molten rock glowing
// through the cracks between them; the hottest seams run toward yellow-white. The pattern lives in world
// space, drifts slowly, and "breathes" (heat pulses along the cracks), so large seas read as one moving
// surface instead of a grid of identical tiles. Falling lava (side faces) streams downward and runs hotter.

// Blackbody-ish ramp for molten rock: black crust -> deep red -> orange -> yellow-white.
vec3 lavaRamp(float heat) {
    vec3 c = mix(vec3(0.03, 0.006, 0.002), vec3(0.55, 0.05, 0.005), smoothstep(0.0, 0.35, heat));
    c = mix(c, vec3(1.0, 0.28, 0.02), smoothstep(0.3, 0.65, heat));
    c = mix(c, vec3(1.0, 0.72, 0.28), smoothstep(0.65, 1.0, heat));
    return c;
}

// Emitted radiance of a lava surface at world position wp with geometric normal n.
vec3 lavaRadiance(vec3 wp, vec3 n, float time) {
    bool falling = abs(n.y) < 0.5;
    vec2 p = falling ? vec2(dot(wp.xz, vec2(n.z, -n.x)), wp.y + time * 1.6) : wp.xz;
    vec2 drift = falling ? vec2(0.0) : vec2(time * 0.05, time * 0.032);

    // Plates: cellular noise (inverted Worley in G/B, high in cell centres) gives crust islands; the gaps
    // between them are the glowing cracks. A second, larger layer makes some areas more molten than others.
    vec4 big = cloudTex(vec3((p + drift * 0.6) / 48.0, time * 0.002));
    vec4 mid = cloudTex(vec3((p + drift) / 9.0, 0.3 + time * 0.004));
    float plates = mid.g * 0.7 + mid.b * 0.3;
    float crust = smoothstep(0.3, 0.46, plates);
    float molten = smoothstep(0.52, 0.78, big.r);

    // Fine texture inside the crust (lumpy cooled rock) and flickering heat along the cracks.
    float fine = cloudTex(vec3((p + drift * 1.3) / 2.2, 0.61 + time * 0.01)).a;
    float pulse = 0.85 + 0.15 * sin(time * 1.3 + big.g * 12.0);
    float heat = mix(1.0 - crust * 0.72, 1.0, molten * 0.6);
    heat = heat * pulse * (0.82 + 0.25 * fine);
    if (falling) heat = max(heat, 0.55 + 0.35 * fine);
    heat = saturate(heat);

    // Emission rises steeply with temperature; crust stays nearly black but glints faintly.
    float intensity = mix(0.03, 4.0, heat * heat);
    return lavaRamp(heat) * intensity;
}
