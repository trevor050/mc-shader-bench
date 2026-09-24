// Lava: Minecraft's own animated sprite with its own colours, minus the wallpaper repeat.
//
// Trevor's brief: keep the vanilla look (bright orange blobs on a deep orange body), only stop the same tile
// from visibly repeating across a lake, and make it hot enough to hurt. So:
//  - Pools are cut into irregular patches a few blocks across (a jittered, domain-warped Voronoi evaluated on
//    the sprite's own texel grid, so patch borders are pixel staircases, never smooth curves). Each patch shows
//    the sprite with its own 90-degree orientation, texel-aligned offset and slow drift direction. Rotations by
//    quarter turns and whole-texel offsets map the 16x16 pixel grid onto itself, so every pixel is a genuine,
//    crisp lava pixel; neighbouring patches just disagree about which one, which reads as separate currents.
//  - Large, slow heat zones (tens of blocks) push the palette a little toward deep red or toward yellow-white
//    and scale the emission. The sprite still carries all fine detail.
//  - The shoreline burns where lava meets rock.
// Falls keep the vanilla flowing sprite and UVs.

vec2 lavaPlane(vec3 p, vec3 n) {
    vec3 an = abs(n);
    return an.y >= max(an.x, an.z) ? p.xz : (an.x >= an.z ? p.zy : p.xy);
}

// Broad heat field (0..1): two octaves of slowly drifting value noise, ~40 and ~12 blocks.
float lavaBroadHeat(vec2 p, float worldY, float time) {
    float broad = valueNoise(p * 0.025 + vec2(time * 0.008, -time * 0.006) + worldY * 0.017);
    float eddy = valueNoise(p * 0.085 + vec2(-time * 0.018, time * 0.014) + worldY * 0.043);
    return broad * 0.7 + eddy * 0.3;
}

// Kept for the DH far field: broad-scale tint only (DH supplies a flat lava colour).
vec3 lavaPoolTint(float heat) {
    return mix(vec3(0.82, 0.62, 0.55), vec3(1.08, 1.1, 1.25), smoothstep(0.25, 0.8, heat));
}

// Patch lookup on the texel grid. Returns three per-patch hashes and the F2-F1 border distance in w.
vec4 lavaPatch(vec2 q) {
    // Warp so patches are irregular and vary in size (3-6 blocks).
    vec2 w = vec2(valueNoise(q * 0.21 + 3.1), valueNoise(q * 0.21 + 8.7)) - 0.5;
    vec2 s = (q + w * 2.2) / 4.2;
    vec2 i = floor(s), f = fract(s);
    float d1 = 8.0, d2 = 8.0;
    vec2 best = vec2(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 g = vec2(x, y);
            vec2 o = vec2(hash12(i + g), hash12(i + g + 31.7)) * 0.85 + 0.075;
            float d = length(g + o - f);
            if (d < d1) { d2 = d1; d1 = d; best = i + g; }
            else if (d < d2) d2 = d;
        }
    }
    return vec4(hash12(best + 5.3), hash12(best + 11.9), hash12(best + 23.1), d2 - d1);
}

// Quarter-turn rotation and optional mirror, k in 0..7. Maps the texel grid onto itself.
vec2 lavaOrient(vec2 v, int k) {
    if ((k & 4) != 0) v.x = -v.x;
    if ((k & 1) != 0) v = vec2(-v.y, v.x);
    if ((k & 2) != 0) v = -v;
    return v;
}

// Heat-grade a vanilla lava pixel (sRGB). heat 0..1 from the broad field (0.5 = vanilla).
vec3 lavaGrade(vec3 s, float heat, float hot) {
    float l = luminance(s);
    // Cooler zones: the darker pixels sink toward deep red, bright blobs stay orange.
    vec3 cool = s * mix(vec3(0.8, 0.42, 0.3), vec3(0.95, 0.78, 0.66), smoothstep(0.45, 0.8, l));
    // Hotter zones: bright blobs run toward yellow-white.
    vec3 warm = mix(s, vec3(1.0, 0.86, 0.52), smoothstep(0.5, 0.85, l) * 0.55);
    vec3 c = heat < 0.5 ? mix(cool, s, smoothstep(0.1, 0.5, heat)) : mix(s, warm, smoothstep(0.5, 0.9, heat));
    // Upwellings: white-hot cores.
    return mix(c, vec3(1.0, 0.95, 0.75), hot * (0.35 + 0.65 * smoothstep(0.4, 0.8, l)));
}

// Emission (0..1, lighting squares it). Bright pixels and hot zones blaze; the body glows strongly anyway.
float lavaEmission(vec3 graded, float heat, float hot) {
    float l = luminance(graded);
    // Wide spread between the body and the blobs: lighting squares this, so 0.42 vs 0.95 is ~5x, which keeps
    // the body a deep saturated orange under the tonemapper while the bright blobs blaze.
    return saturate(mix(0.42, 0.95, smoothstep(0.35, 0.85, l)) * mix(0.85, 1.08, heat) + hot * 0.15);
}

#ifdef PROG_TERRAIN
// Returns sRGB albedo in rgb and emission in a.
vec4 lavaSurface(vec3 worldPos, vec3 posDx, vec3 posDy, vec3 normal,
                 vec2 spriteMid, vec2 spriteHalfExtent, float time, float shore) {
    vec2 texel = 1.0 / vec2(textureSize(gtexture, 0));
    vec2 halfExtent = max(spriteHalfExtent, vec2(0.0));
    vec2 safeHalf = max(halfExtent - texel * 0.5, vec2(0.0));

    vec2 p = lavaPlane(worldPos, normal);
    vec2 pDx = lavaPlane(posDx, normal);
    vec2 pDy = lavaPlane(posDy, normal);

    // Texel centre in world units (the sprite is 16 texels per block), so patch borders follow the pixel grid.
    // Up close only; when a texel shrinks below a screen pixel the quantization would only alias.
    float footprint = max(length(pDx), length(pDy)) * 16.0;
    vec2 q = mix((floor(p * 16.0) + 0.5) / 16.0, p, smoothstep(0.7, 1.6, footprint));
    vec4 pch = lavaPatch(q);
    int k = int(pch.x * 8.0);
    vec2 offset = floor(vec2(pch.y, pch.z) * 16.0) / 16.0;
    // Each patch creeps in its own direction at 0.05-0.12 blocks per second.
    float ang = pch.x * 37.0 + pch.z * TAU;
    vec2 drift = vec2(cos(ang), sin(ang)) * mix(0.05, 0.12, pch.y) * time;

    vec2 local = lavaOrient(p, k) + offset + drift;
    vec2 uv = clamp(spriteMid + (fract(local) * 2.0 - 1.0) * halfExtent, spriteMid - safeHalf, spriteMid + safeHalf);
    vec2 gx = lavaOrient(pDx, k) * (2.0 * halfExtent), gy = lavaOrient(pDy, k) * (2.0 * halfExtent);
    vec3 sprite = textureGrad(gtexture, uv, gx, gy).rgb;

    float heat = lavaBroadHeat(q, worldPos.y, time);
    // No painted hot spots (Trevor: they read as accidents); the life comes from the glow, the light the lava
    // throws on its surroundings and the smoke above it.
    const float hot = 0.0;

    vec3 c = lavaGrade(sprite, heat, hot);
    float e = lavaEmission(c, heat, hot);
    // Where lava meets rock: a thin white-hot contact line.
    float rim = shore * shore;
    c = mix(c, vec3(1.0, 0.9, 0.6), rim * 0.6);
    e = saturate(e + rim * 0.3);
    return vec4(c, e);
}

// Falls and side faces: the vanilla flowing sprite (already sampled by the caller), lightly heat-graded with
// a faint downward shimmer so a tall fall is not one flat sheet.
vec4 lavaFall(vec3 sprite, vec3 worldPos, float time) {
    float streak = valueNoise(vec2(worldPos.x * 3.0 + worldPos.z * 3.0, worldPos.y * 0.6 + time * 1.8));
    float heat = 0.4 + streak * 0.35;
    vec3 c = lavaGrade(sprite, heat, 0.0);
    return vec4(c, lavaEmission(c, heat, 0.0));
}
#endif
