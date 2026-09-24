// Minecraft-identity pool lava. The animated terrain atlas remains the source of every pixel;
// world-anchored tile symmetries break the repeated motif without tinting it into a crust material.

vec2 lavaPlane(vec3 p, vec3 n) {
    vec3 an = abs(n);
    return an.y >= max(an.x, an.z) ? p.xz : (an.x >= an.z ? p.zy : p.xy);
}

vec2 lavaSpriteTransform(vec2 p, float transform) {
    vec2 q = p - 0.5;
    q.x = mix(q.x, -q.x, step(4.0, transform));
    float turn = mod(transform, 4.0);
    vec2 r = mix(q, vec2(-q.y, q.x), step(0.5, turn));
    r = mix(r, -q, step(1.5, turn));
    r = mix(r, vec2(q.y, -q.x), step(2.5, turn));
    return r + 0.5;
}

vec2 lavaSpriteTransformVector(vec2 v, float transform) {
    v.x = mix(v.x, -v.x, step(4.0, transform));
    float turn = mod(transform, 4.0);
    vec2 r = mix(v, vec2(-v.y, v.x), step(0.5, turn));
    r = mix(r, -v, step(1.5, turn));
    r = mix(r, vec2(v.y, -v.x), step(2.5, turn));
    return r;
}

// Keep this surface modulation in step with the DH lava branch in deferred.glsl so the broad
// animated pattern carries across the vanilla-chunk / LOD transition.
float lavaPoolVariation(vec2 p, float worldY, float time) {
    float broad = valueNoise(p * 0.035 + worldY * 0.017);
    float flicker = valueNoise(p * 0.21 + vec2(time * 0.08, -time * 0.05));
    return 0.78 + 0.24 * broad + 0.08 * flicker;
}

vec3 lavaSpriteAlbedo(vec3 worldPos, vec3 posDx, vec3 posDy, vec3 normal,
                      vec2 spriteMid, vec2 spriteHalfExtent, float time) {
    vec2 p = lavaPlane(worldPos, normal);
    vec2 pDx = lavaPlane(posDx, normal);
    vec2 pDy = lavaPlane(posDy, normal);

    // One block maps to the original 16x16 animated sprite. Each block gets one of its eight
    // seamless rotations/reflections, chosen in absolute world space so chunk borders stay stable.
    const float textureScale = 1.0;
    vec2 tile = floor(p / textureScale);
    float transform = floor(hash12(tile + vec2(19.17, 43.71)) * 8.0);
    vec2 local = lavaSpriteTransform(fract(p / textureScale), transform);
    vec2 localDx = lavaSpriteTransformVector(pDx / textureScale, transform);
    vec2 localDy = lavaSpriteTransformVector(pDy / textureScale, transform);

    vec2 texel = 1.0 / vec2(textureSize(gtexture, 0));
    vec2 halfExtent = max(spriteHalfExtent, vec2(0.0));
    // Iris uses a packed terrain atlas. Keep bilinear and mip filtering inside lava's current frame.
    vec2 safeHalf = max(halfExtent - texel, vec2(0.0));
    vec2 uv = clamp(spriteMid + (local * 2.0 - 1.0) * halfExtent,
                    spriteMid - safeHalf, spriteMid + safeHalf);
    vec3 sprite = textureGrad(gtexture, uv,
                              localDx * (2.0 * halfExtent),
                              localDy * (2.0 * halfExtent)).rgb;
    return sprite * lavaPoolVariation(p, worldPos.y, time);
}
