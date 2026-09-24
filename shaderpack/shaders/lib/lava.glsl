// Lava: Minecraft's own animated sprite, remapped through a heat palette with structure at three scales.
//
// Why pools usually look bad (Solas, vanilla): one noise scale at one brightness, so a lake is a flat mottled
// sheet with no focal points. Here most of the surface is molten orange, a few convection cells well up
// white-hot and pulse, their borders cool to deep red seams, broad slow currents move the whole field, and the
// shoreline burns where lava meets rock. The vanilla pixels still carry the fine detail (their brightness
// perturbs the heat), and heat is evaluated per sprite texel, so the result stays pixel art rather than a
// smooth "realistic" surface. Emission scales with heat, so only the hottest parts bloom.

vec2 lavaPlane(vec3 p, vec3 n) {
    vec3 an = abs(n);
    return an.y >= max(an.x, an.z) ? p.xz : (an.x >= an.z ? p.zy : p.xy);
}

float lavaValueNoiseGradient(vec2 p, out vec2 gradient) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    vec2 du = 6.0 * f * (1.0 - f);
    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));
    float row0 = mix(a, b, u.x);
    float row1 = mix(c, d, u.x);
    gradient = vec2(mix(b - a, d - c, u.y) * du.x, (row1 - row0) * du.y);
    return mix(row0, row1, u.y);
}

// Broad current (~40 blocks) and eddy (~11 blocks) fields. Their slow drift also warps the sprite coordinates,
// which hides the vanilla tile grid without introducing seams.
void lavaPoolFields(vec2 p, float worldY, float time, vec2 pDx, vec2 pDy,
                    out float heat, out vec2 warp, out vec2 warpDx, out vec2 warpDy) {
    vec2 broadGradient;
    vec2 eddyGradient;
    float broad = lavaValueNoiseGradient(p * 0.025 + vec2(time * 0.008, -time * 0.006) + worldY * 0.017, broadGradient);
    float eddy = lavaValueNoiseGradient(p * 0.09 + vec2(-time * 0.018, time * 0.014) + worldY * 0.043, eddyGradient);
    heat = broad * 0.74 + eddy * 0.26;
    warp = (vec2(broad, eddy) - 0.5) * 0.56;
    warpDx = 0.56 * vec2(dot(broadGradient, pDx * 0.025), dot(eddyGradient, pDx * 0.09));
    warpDy = 0.56 * vec2(dot(broadGradient, pDy * 0.025), dot(eddyGradient, pDy * 0.09));
}

// Convection cells: F1, F2 distances and a per-cell random, with centres that wander slowly.
vec3 lavaCells(vec2 p, float time) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float f1 = 8.0, f2 = 8.0, id = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 g = vec2(x, y);
            float h = hash12(i + g);
            float h2 = hash12(i + g + 17.17);
            vec2 o = 0.5 + 0.36 * sin(time * (0.05 + 0.05 * h) + TAU * vec2(h, h2));
            float d = length(g + o - f);
            if (d < f1) { f2 = f1; f1 = d; id = h; }
            else if (d < f2) f2 = d;
        }
    }
    return vec3(f1, f2, id);
}

// Heat (0 = cooling seam, 1 = white-hot) to sRGB albedo. Never brown or black: the coolest lava still glows red.
vec3 lavaRamp(float h) {
    h = saturate(h);
    vec3 c = mix(vec3(0.50, 0.07, 0.02), vec3(0.93, 0.30, 0.035), smoothstep(0.0, 0.42, h));
    c = mix(c, vec3(1.00, 0.60, 0.12), smoothstep(0.38, 0.74, h));
    return mix(c, vec3(1.00, 0.93, 0.62), smoothstep(0.72, 1.0, h));
}

// Emission strength stored in the material buffer's emissive channel (0..1); lighting squares it.
float lavaEmission(float h) {
    return mix(0.38, 1.0, smoothstep(0.1, 1.0, h));
}

// Kept for the DH far field: broad-scale tint only.
vec3 lavaPoolTint(float heat) {
    return lavaRamp(0.3 + heat * 0.5) / vec3(0.93, 0.45, 0.10);
}

// Pool heat at a (texel-quantized) position. shore: 0 far from rock, 1 touching it.
float lavaPoolHeat(vec2 q, float broadHeat, float spriteDetail, float shore, float time) {
    // Warp the cell domain so cells are irregular blobs, not a honeycomb.
    vec2 w = vec2(valueNoise(q * 0.19 + 3.7), valueNoise(q * 0.19 + 9.1)) - 0.5;
    vec3 c = lavaCells((q + w * 5.0) / 9.0, time);
    // Only a few cells well up (about a quarter), and they pulse slowly.
    float pulse = 0.55 + 0.45 * sin(time * (0.35 + 0.4 * c.z) + c.z * TAU);
    float upwell = exp(-c.x * c.x * 7.0) * pulse * smoothstep(0.7, 0.8, c.z);
    // Cooling seams only appear in patches (a slow mask), as thin dark-red lines: the body stays molten.
    float seamMask = smoothstep(0.58, 0.8, valueNoise(q * 0.045 + time * 0.004));
    float seam = (1.0 - smoothstep(0.0, 0.045, c.y - c.x)) * seamMask;
    float h = 0.42 + (broadHeat - 0.5) * 0.5 + upwell * 0.55 - seam * 0.2 + spriteDetail;
    // Where lava meets rock: a thin white-hot contact line with a slightly cooler band just behind it.
    h += shore * shore * 0.55 - smoothstep(0.25, 0.7, shore) * (1.0 - shore) * 0.25;
    return h;
}

#ifdef PROG_TERRAIN
// Returns sRGB albedo in rgb and emission in a.
vec4 lavaSurface(vec3 worldPos, vec3 posDx, vec3 posDy, vec3 normal,
                 vec2 spriteMid, vec2 spriteHalfExtent, float time, float shore) {
    vec2 texel = 1.0 / vec2(textureSize(gtexture, 0));
    vec2 halfExtent = max(spriteHalfExtent, vec2(0.0));
    vec2 safeHalf = max(halfExtent - texel, vec2(0.0));
    bool pool = abs(normal.y) > 0.5;

    if (!pool) {
        // Falls keep their vanilla flowing sprite and UVs (Trevor: showy falls look like they try too hard). Only
        // the palette changes, plus a faint downward shimmer in brightness.
        return vec4(0.0);
    }

    vec2 p = lavaPlane(worldPos, normal);
    vec2 pDx = lavaPlane(posDx, normal);
    vec2 pDy = lavaPlane(posDy, normal);
    float broad;
    vec2 warp, warpDx, warpDy;
    lavaPoolFields(p, worldPos.y, time, pDx, pDy, broad, warp, warpDx, warpDy);

    vec2 raw = p + warp;
    vec2 local = fract(raw);
    vec2 uv = clamp(spriteMid + (local * 2.0 - 1.0) * halfExtent, spriteMid - safeHalf, spriteMid + safeHalf);
    vec3 sprite = textureGrad(gtexture, uv, (pDx + warpDx) * (2.0 * halfExtent), (pDy + warpDy) * (2.0 * halfExtent)).rgb;

    // Evaluate heat once per sprite texel (the same warped 16x16 grid the sprite uses) so edges stay pixel
    // crisp. When a texel is smaller than a screen pixel, quantizing only aliases, so fade it out.
    float footprint = max(length(pDx), length(pDy)) * 16.0;
    vec2 q = mix((floor(raw * 16.0) + 0.5) / 16.0, raw, smoothstep(0.6, 1.5, footprint));
    float detail = (luminance(sprite) - 0.62) * 0.55;
    float h = lavaPoolHeat(q, broad, detail, shore, time);
    return vec4(lavaRamp(h), lavaEmission(h));
}

// Falls and side faces: vanilla flowing sprite (already sampled by the caller) through the same palette.
vec4 lavaFall(vec3 sprite, vec3 worldPos, float time) {
    float streak = valueNoise(vec2(worldPos.x * 3.0 + worldPos.z * 3.0, worldPos.y * 0.6 + time * 1.8));
    float h = 0.46 + (luminance(sprite) - 0.62) * 0.8 + (streak - 0.5) * 0.16;
    return vec4(lavaRamp(h), lavaEmission(h));
}
#endif
