// Nether portal sheet. Keep the motion broad and block-anchored: vanilla portals
// read as a purple animated surface, not turbulent marble or a set of bright veins.
struct PortalSurface {
    vec3 color;
    float alpha;
};

PortalSurface shadePortal(vec2 p, float time, float grazing) {
    // Broad vertical bands travel slowly across the sheet. A low-amplitude cross
    // current bends their edges just enough to suggest a moving surface.
    float bend = 0.11 * sin(p.x * 0.75 - time * 0.20);
    float current = 0.5 + 0.5 * sin(p.y * 2.15 + p.x * 0.28 + bend + time * 0.32);
    float undercurrent = 0.5 + 0.5 * sin(p.y * 0.84 - p.x * 0.48 - time * 0.11);
    float field = saturate(mix(current, undercurrent, 0.18));

    // A very fine, stable block pattern keeps the surface from looking airbrushed.
    // The amplitude is deliberately tiny; no cellular edges or high-contrast veins.
    float blocks = hash12(floor(p * 3.0));
    field = saturate(field + (blocks - 0.5) * 0.045);

    vec3 deep = vec3(0.038, 0.005, 0.056);
    vec3 violet = vec3(0.18, 0.018, 0.225);
    vec3 orchid = vec3(0.39, 0.055, 0.320);
    vec3 rose = vec3(0.60, 0.140, 0.430);

    float body = smoothstep(0.08, 0.92, field);
    float glow = smoothstep(0.66, 0.98, field);
    vec3 color = mix(deep, violet, 0.55 + body * 0.25);
    color = mix(color, orchid, smoothstep(0.15, 0.86, field) * 0.62);
    color = mix(color, rose, glow * 0.28);

    // The plane picks up a restrained rose rim at grazing angles, hinting at depth.
    color += vec3(0.15, 0.025, 0.11) * grazing;
    color *= 0.98 + 0.02 * sin(time * 0.7 + p.x * 0.5);

    PortalSurface result;
    result.color = color;
    result.alpha = 1.0;
    return result;
}
