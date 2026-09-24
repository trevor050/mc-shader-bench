// Animated Minecraft lava atlas with continuous world-space breakup for broad Nether pools.

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

// The two fields give the surface distinct broad-current (~40 block) and eddy (~11 block) scales.
// Their slow drift also warps the atlas coordinates, softening the vanilla tile grid without tile seams.
void lavaPoolFields(vec2 p, float worldY, float time, vec2 pDx, vec2 pDy,
                    out float heat, out vec2 warp, out vec2 warpDx, out vec2 warpDy) {
    vec2 broadGradient;
    vec2 eddyGradient;
    float broad = lavaValueNoiseGradient(p * 0.025 + vec2(time * 0.008, -time * 0.006) + worldY * 0.017, broadGradient);
    float eddy = lavaValueNoiseGradient(p * 0.09 + vec2(-time * 0.018, time * 0.014) + worldY * 0.043, eddyGradient);
    heat = smoothstep(0.22, 0.78, broad * 0.74 + eddy * 0.26);
    warp = (vec2(broad, eddy) - 0.5) * 0.56;
    warpDx = 0.56 * vec2(dot(broadGradient, pDx * 0.025), dot(eddyGradient, pDx * 0.09));
    warpDy = 0.56 * vec2(dot(broadGradient, pDy * 0.025), dot(eddyGradient, pDy * 0.09));
}

// Vary from saturated molten orange to hot yellow while retaining the atlas sprite's pixels.
vec3 lavaPoolTint(float heat) {
    return mix(vec3(0.96, 0.58, 0.20), vec3(1.18, 1.46, 0.60), heat);
}

#ifdef PROG_TERRAIN
vec3 lavaSpriteAlbedo(vec3 worldPos, vec3 posDx, vec3 posDy, vec3 normal,
                      vec2 spriteMid, vec2 spriteHalfExtent, float time) {
    vec2 p = lavaPlane(worldPos, normal);
    vec2 pDx = lavaPlane(posDx, normal);
    vec2 pDy = lavaPlane(posDy, normal);
    float heat;
    vec2 warp;
    vec2 warpDx;
    vec2 warpDy;
    lavaPoolFields(p, worldPos.y, time, pDx, pDy, heat, warp, warpDx, warpDy);

    // Keep one block at the vanilla 16x16 pixel scale. Continuous warping and the macro color field
    // make large pools read as moving shapes while the actual animated Mojang sprite stays visible.
    const float textureScale = 1.0;
    vec2 raw = p / textureScale + warp;
    vec2 local = fract(raw);
    vec2 localDx = pDx / textureScale + warpDx;
    vec2 localDy = pDy / textureScale + warpDy;

    vec2 texel = 1.0 / vec2(textureSize(gtexture, 0));
    vec2 halfExtent = max(spriteHalfExtent, vec2(0.0));
    // Stay inside the current animated lava frame in Iris's packed terrain atlas.
    vec2 safeHalf = max(halfExtent - texel, vec2(0.0));
    vec2 uv = clamp(spriteMid + (local * 2.0 - 1.0) * halfExtent,
                    spriteMid - safeHalf, spriteMid + safeHalf);
    vec3 sprite = textureGrad(gtexture, uv,
                              localDx * (2.0 * halfExtent),
                              localDy * (2.0 * halfExtent)).rgb;
    return sprite * lavaPoolTint(heat);
}
#endif
