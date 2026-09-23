// Wind animation for foliage. Requires frameTimeCounter, rainStrength, and mc_Entity/at_midBlock attributes.

vec3 windOffset(vec3 worldPos, float strength) {
    float t = frameTimeCounter * (1.4 + rainStrength);
    float gust = sin(t * 0.37 + worldPos.x * 0.05 + worldPos.z * 0.03) * 0.5 + 0.5;
    vec2 sway = vec2(
        sin(t * 1.7 + worldPos.x * 0.9 + worldPos.z * 0.3),
        cos(t * 1.3 + worldPos.z * 0.8 + worldPos.x * 0.2)
    );
    float flutter = sin(t * 5.1 + dot(worldPos, vec3(2.1, 1.7, 1.3))) * 0.25;
    vec2 xz = (sway + flutter) * (0.035 + 0.06 * gust) * (1.0 + rainStrength) * WAVE_STRENGTH * strength;
    return vec3(xz.x, flutter * 0.02 * strength, xz.y);
}

// Returns the displaced world position for a vertex of the given material.
vec3 waveVertex(vec3 worldPos, int mat, float midBlockY) {
#ifdef WAVING_FOLIAGE
    if (mat == MAT_FOLIAGE) {
        // at_midBlock.y is 32 at the bottom face and -32 at the top; only top vertices move.
        float top = midBlockY < 0.0 ? 1.0 : 0.0;
        if (top == 0.0) return worldPos;
        return worldPos + windOffset(worldPos, 1.0);
    }
    if (mat == MAT_TALL_UPPER) {
        float top = midBlockY < 0.0 ? 1.8 : 0.9;
        return worldPos + windOffset(worldPos, 1.0) * top;
    }
    if (mat == MAT_LEAVES) {
        return worldPos + windOffset(worldPos, 0.45);
    }
#endif
    return worldPos;
}
