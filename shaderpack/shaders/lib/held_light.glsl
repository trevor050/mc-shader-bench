// Analytic hand light shared by the full lighting engine and the native-lightmap path.
#ifndef HELD_LIGHT_INCLUDED
#define HELD_LIGHT_INCLUDED
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;
uniform int heldItemId;
uniform int heldItemId2;

vec3 heldLightPalette() {
    int id = heldBlockLightValue >= heldBlockLightValue2 ? heldItemId : heldItemId2;
    vec3 c = vec3(1.0, 0.40, 0.09);
    if (id == 2) c = vec3(0.25, 0.78, 1.0);
    else if (id == 3) c = vec3(1.0, 0.12, 0.05);
    else if (id == 4) c = vec3(1.0, 0.72, 0.30);
    else if (id == 5) c = vec3(0.55, 0.95, 1.0);
    else if (id == 6) c = vec3(1.0, 0.88, 0.92);
    else if (id == 7) c = vec3(0.55, 1.0, 0.45);
    else if (id == 8) c = vec3(0.70, 0.30, 1.0);
    return c;
}

// Existing full-quality energy normalization, retained for the linear HDR surface engine.
vec3 heldLightColor() {
    vec3 c = heldLightPalette();
    vec3 e = c * c;
    e /= mix(1.0, max(luminance(e), 0.05), 0.65);
    return sqrt(e) * (luminance(BLOCKLIGHT_COLOR) / max(luminance(sqrt(e)), 1e-3)) * 0.85;
}

#if !VANILLA_LIGHTING
vec3 handheldLight(vec3 playerPos, vec3 n, float ao) {
    float level = float(max(heldBlockLightValue, heldBlockLightValue2));
    if (level <= 0.0) return vec3(0.0);
    vec3 toLight = vec3(0.0, -0.3, 0.0) - playerPos;
    float d = length(toLight);
    float lm = saturate((level - d) / 15.0);
    if (lm <= 0.0) return vec3(0.0);
    float wrap = saturate(dot(n, toLight / max(d, 1e-3)) * 0.75 + 0.25);
    return heldLightColor() * blockLightLevel(lm) * wrap * mix(ao, 1.0, 0.3) * 0.7;
}
#endif

// Display-space light amount. Add to the native lightmap before multiplying the original sprite,
// otherwise an unlit cave texel would have no colour left for the held light to illuminate.
vec3 cheapHeldLightSrgb(vec3 playerPos, vec3 n, float ao) {
    float level = float(max(heldBlockLightValue, heldBlockLightValue2));
    if (level <= 0.0) return vec3(0.0);
    vec3 toLight = vec3(0.0, -0.3, 0.0) - playerPos;
    float d = length(toLight);
    float lm = saturate((level - d) / 15.0);
    if (lm <= 0.0) return vec3(0.0);
    float wrap = saturate(dot(n, toLight / max(d, 1e-3)) * 0.65 + 0.35);
    return heldLightPalette() * lm * lm * wrap * mix(ao, 1.0, 0.3) * 0.85;
}
#endif
