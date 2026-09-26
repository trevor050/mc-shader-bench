// End-only Distant Horizons silhouette dissolve. Temporal interleaved-gradient coverage avoids a hard LOD
// cutoff; TAA resolves the changing coverage while the End's own distance haze masks its far edge.
bool endLodVisible(float distance, vec2 pixel, int frame) {
    float coverage = 1.0 - smoothstep(END_DH_FADE_START, END_DH_FADE_END, distance);
    return ignTemporal(pixel, frame) <= coverage;
}
