// Nether portal sheet. Keep the motion broad and block-anchored: vanilla portals
// read as a purple animated surface, not turbulent marble or a set of bright veins.
struct PortalSurface {
    vec3 color;
    float alpha;
};

PortalSurface shadePortal(vec2 p, float time, float grazing) {
    // One slow, mostly vertical current with a small cross-current bend. The bend
    // moves the bands by only a few pixels so the portal shimmers without warping.
    float bend = 0.045 * sin(p.x * 1.55 - time * 0.28)
               + 0.018 * sin(p.x * 3.1 + p.y * 0.55 + time * 0.16);
    float current = 0.5 + 0.5 * sin(p.y * 0.92 + p.x * 0.12 + bend + time * 0.34);
    float undercurrent = 0.5 + 0.5 * sin((p.y * 0.42 - p.x * 0.08) * TAU - time * 0.17);
    float field = saturate(mix(current, undercurrent, 0.24));

    // A very fine, stable block pattern keeps the surface from looking airbrushed.
    // The amplitude is deliberately tiny; no cellular edges or high-contrast veins.
    float blocks = hash12(floor(p * 3.0));
    field = saturate(field + (blocks - 0.5) * 0.045);

    vec3 deep = vec3(0.025, 0.003, 0.038);
    vec3 violet = vec3(0.115, 0.010, 0.145);
    vec3 orchid = vec3(0.31, 0.040, 0.270);
    vec3 rose = vec3(0.53, 0.115, 0.365);

    float body = smoothstep(0.06, 0.86, field);
    float glow = smoothstep(0.66, 0.98, field);
    vec3 color = mix(deep, violet, body * 0.88);
    color = mix(color, orchid, smoothstep(0.30, 0.88, field) * 0.52);
    color = mix(color, rose, glow * 0.32);

    // The plane picks up a restrained rose rim at grazing angles, hinting at depth.
    color += vec3(0.115, 0.018, 0.092) * grazing;
    color *= 0.98 + 0.02 * sin(time * 0.7 + p.x * 0.5);

    PortalSurface result;
    result.color = color;
    result.alpha = mix(0.93, 0.97, grazing);
    return result;
}
