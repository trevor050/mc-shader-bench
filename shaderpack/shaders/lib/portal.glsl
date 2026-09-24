// Nether portal: a window into a swirling violet void.
//
// Lineage: Solas's portal (the one Trevor rated best) lights the vanilla sheet with a sparse, cubed noise so
// drifting clouds of energy flare toward pink-white while the vanilla swirl pixels sparkle. Kept here: the
// vanilla pixels as the surface sparkle and the sparse cubed energy. Added:
//  - depth: three parallax layers behind the sheet, each drifting its own way and darker with depth, so the
//    portal reads as a volume you are looking into rather than a flat animated texture;
//  - a crackling energy rim where the sheet meets its obsidian frame (found in the voxel grid);
//  - a slow uneven "breath" in brightness, which makes it feel alive and slightly wrong;
//  - it lights the frame and the ground around it in purple through the light field (automatic: the portal
//    is an emitter with a violet texture).

struct PortalSurface {
    vec3 color;
    float alpha;
};

// Swirling energy field: domain-warped value noise, cubed so bright regions stay sparse.
float portalEnergy(vec2 p, float time, float seed) {
    vec2 w = vec2(valueNoise(p * 0.9 + vec2(time * 0.21, seed)), valueNoise(p * 0.9 + vec2(seed * 1.7, -time * 0.17)));
    vec2 s = p + (w - 0.5) * 1.6 + vec2(sin(time * 0.13 + seed), cos(time * 0.11 - seed)) * 0.7;
    float n = valueNoise(s * 1.35) * 0.65 + valueNoise(s * 2.9 + seed * 3.1) * 0.35;
    n = saturate((n - 0.28) / 0.6);
    return n * n * n;
}

vec3 portalPalette(float e) {
    vec3 deep = vec3(0.020, 0.002, 0.055);
    vec3 violet = vec3(0.22, 0.025, 0.62);
    vec3 magenta = vec3(0.80, 0.16, 0.95);
    vec3 core = vec3(0.95, 0.50, 1.00);  // hot orchid, never white: the sheet should stay unmistakably purple
    vec3 c = mix(deep, violet, smoothstep(0.0, 0.25, e));
    c = mix(c, magenta, smoothstep(0.2, 0.6, e));
    return mix(c, core, smoothstep(0.6, 1.0, e));
}

// q: position in the portal plane (blocks). viewPlane: view direction projected into the plane, divided by
// its depth component (parallax per block of depth). spriteLum: vanilla portal texel brightness.
// edge: 1 at the frame, 0 a block or more inside.
PortalSurface shadePortal(vec2 q, vec2 viewPlane, float spriteLum, float edge, float grazing, float time) {
    // Slow, uneven breathing.
    float breath = 0.88 + 0.12 * sin(time * 1.3) * sin(time * 0.47 + 1.0);

    vec3 col = vec3(0.0);
    // Deep layers first: each further behind the sheet, larger, slower, bluer and dimmer.
    const float depths[3] = float[3](2.8, 1.3, 0.45);
    const float scales[3] = float[3](0.55, 0.85, 1.25);
    const float gains[3] = float[3](0.55, 0.9, 1.4);
    for (int i = 0; i < 3; i++) {
        // Every layer lives on Minecraft's 16-per-block texel grid (in its own parallax space), so the void is
        // pixel art rather than an airbrushed nebula.
        vec2 lp = floor((q + viewPlane * depths[i]) * 16.0) / 16.0 * scales[i];
        float e = portalEnergy(lp, time * (0.6 + 0.25 * float(i)), float(i) * 11.3);
        vec3 layer = portalPalette(e * (0.45 + 0.15 * float(i))) * gains[i];
        // Nearer layers partly occlude deeper ones where they are bright.
        col = col * (1.0 - e * 0.5) + layer;
    }

    // Surface: vanilla swirl pixels as sparkle riding on a sparse energy veil (after Solas).
    float veil = portalEnergy(floor(q * 16.0) / 16.0 * 1.1, time, 5.0);
    float sparkle = pow(saturate(spriteLum), 3.0);
    col += portalPalette(0.5 + veil * 0.3) * (sparkle * (1.4 + 1.6 * veil) + veil * 0.7);

    // Energy rim along the obsidian frame, crackling.
    float crackle = valueNoise(q * 6.0 + vec2(time * 2.3, -time * 1.7));
    col += vec3(0.95, 0.35, 1.0) * pow(edge, 3.0) * (0.8 + 2.6 * crackle * crackle);

    // Grazing views see more of the glowing surface film.
    col += vec3(0.30, 0.05, 0.36) * grazing;

    PortalSurface result;
    result.color = col * breath * 1.6;
    result.alpha = 0.94;
    return result;
}
