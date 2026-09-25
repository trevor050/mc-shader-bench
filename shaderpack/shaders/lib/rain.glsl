// Raindrop ripples. Requires common.glsl (hash12).

// Expanding rings from raindrops landing on a flat surface. p is the world xz position (blocks), t time in
// seconds. Returns the surface slope (d height / d x, d height / d z) of the ripples, roughly -1..1; scale it by
// the wanted normal strength. Two interleaved drop grids at different sizes keep the pattern from repeating.
vec2 rainRipples(vec2 p, float t) {
    vec2 slope = vec2(0.0);
    for (int layer = 0; layer < 2; layer++) {
        float scale = layer == 0 ? 1.4 : 2.3;
        vec2 q = p * scale + float(layer) * 31.7;
        vec2 cell = floor(q);
        for (int y = -1; y <= 1; y++)
            for (int x = -1; x <= 1; x++) {
                vec2 c = cell + vec2(x, y);
                float h1 = hash12(c + 0.13), h2 = hash12(c + 7.31), h3 = hash12(c + 3.77);
                float life = fract(t * (0.8 + 0.5 * h3) + h3 * 5.0);
                vec2 dv = q - (c + vec2(h1, h2));
                float r = length(dv);
                float w = r - life * 0.95;
                // The ring fades as it spreads.
                float env = (1.0 - life) * (1.0 - life) * exp(-w * w * 90.0);
                slope += dv / max(r, 1e-3) * sin(w * 32.0) * env;
            }
    }
    return slope * 0.5;
}
