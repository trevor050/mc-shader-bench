// Cubic B-spline reconstruction for smooth HDR halos. Positive weights sum to one, so a constant field
// stays constant and bright samples cannot produce ringing or negative colour. The four bilinear taps
// combine the sixteen separable cubic weights (Sigg/Hadwiger, GPU Gems 2 chapter 20).
// Use only for bloom/glare targets; the scene and emitter texture remain sharp.
vec3 sampleBloomCubic(sampler2D source, vec2 uv, int lod) {
    vec2 size = vec2(max(textureSize(source, lod), ivec2(1)));
    vec2 p = uv * size - 0.5;
    vec2 base = floor(p);
    vec2 f = p - base;
    vec2 f2 = f * f;
    vec2 f3 = f2 * f;
    vec2 omf = 1.0 - f;
    vec2 w0 = omf * omf * omf / 6.0;
    vec2 w1 = (3.0 * f3 - 6.0 * f2 + 4.0) / 6.0;
    vec2 w2 = (-3.0 * f3 + 3.0 * f2 + 3.0 * f + 1.0) / 6.0;
    vec2 w3 = f3 / 6.0;
    vec2 g0 = w0 + w1;
    vec2 g1 = w2 + w3;
    vec2 a = (base - 1.0 + w1 / g0 + 0.5) / size;
    vec2 b = (base + 1.0 + w3 / g1 + 0.5) / size;
    return mix(mix(textureLod(source, a, float(lod)).rgb,
                   textureLod(source, vec2(b.x, a.y), float(lod)).rgb, g1.x),
               mix(textureLod(source, vec2(a.x, b.y), float(lod)).rgb,
                   textureLod(source, b, float(lod)).rgb, g1.x), g1.y);
}

vec2 bloomSplineBasis(vec2 x) {
    vec2 a = abs(x);
    vec2 tail = max(2.0 - a, 0.0);
    return mix(tail * tail * tail / 6.0, (4.0 + a * a * (3.0 * a - 6.0)) / 6.0,
               1.0 - step(vec2(1.0), a));
}

// A convex quartic knee joins zero and the usual (luminance - threshold) response with a continuous slope.
// The bright core is unchanged; near-threshold halo samples fade without a hard contour or lost shoulder.
vec3 bloomBrightPass(vec3 c, float threshold) {
    float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
    // At the emitter's default threshold of 3x the frame average, the knee begins at that average.
    // Uniform scenes therefore contribute no emitter halo, while a faint bright shoulder remains smooth.
    float knee = max(threshold * (2.0 / 3.0), 1e-6);
    float t = clamp((l - threshold + knee) / (2.0 * knee), 0.0, 1.0);
    // At t=0: value/slope 0. At t=1: value=knee, slope=1 in luminance units.
    // The second derivative is nonnegative; this fuller shoulder keeps near-threshold glow without ringing.
    float soft = knee * t * t * (3.0 - 4.0 * t + 2.0 * t * t);
    return c * (max(l - threshold, soft) / max(l, 1e-5));
}

// Fold the original 1:2:1 blur at -offset/0/+offset into cubic reconstruction. The convolution occupies
// six consecutive texels on each axis; pair adjacent positive weights into three hardware-linear taps.
// Its separable 3x3 evaluation therefore keeps the original nine reads per mip instead of using 36.
void bloomBlurCoordinates(sampler2D source, vec2 uv, int lod, vec2 offset,
                          out vec3 u, out vec3 v, out vec3 wx, out vec3 wy) {
    vec2 size = vec2(max(textureSize(source, lod), ivec2(1)));
    vec2 p = uv * size - 0.5;
    vec2 base = floor(p);
    vec2 f = p - base;
    vec2 radius = offset * size;
    vec2 weights[6];
    for (int i = 0; i < 6; i++) {
        vec2 x = vec2(float(i - 2)) - f;
        weights[i] = 0.25 * bloomSplineBasis(x - radius) + 0.5 * bloomSplineBasis(x)
                   + 0.25 * bloomSplineBasis(x + radius);
    }
    for (int i = 0; i < 3; i++) {
        vec2 g = weights[i * 2] + weights[i * 2 + 1];
        vec2 coord = (base + float(i * 2 - 2) + weights[i * 2 + 1] / max(g, 1e-6) + 0.5) / size;
        u[i] = coord.x; v[i] = coord.y;
        wx[i] = g.x; wy[i] = g.y;
    }
    // Very small windows can run out of mip levels: the last mip is one texel, and every read there has
    // the same value. Keep unit gain even when the requested screen-space blur extends past this mip.
    wx /= max(wx.x + wx.y + wx.z, 1e-6);
    wy /= max(wy.x + wy.y + wy.z, 1e-6);
}

// Keep the accepted half-grid reconstruction support in full-screen pixels when the effect grid shrinks.
// Positive normalized B-spline weights preserve constant radiance and cannot ring below zero.
vec3 sampleBloomPhysical(sampler2D source, vec2 uv, int lod, vec2 fullSize) {
    // All active selected tiers use less than A's half-grid; preserve its physical footprint.
    vec2 size = vec2(max(textureSize(source, lod), ivec2(1)));
    vec2 reference = max(floor(fullSize * 0.5), vec2(1.0));
    vec2 width = max(size / reference, vec2(1e-6));
    vec2 p = uv * size - 0.5;
    vec2 base = floor(p);
    vec2 f = p - base;
    vec2 w0 = bloomSplineBasis((vec2(-1.0) - f) / width);
    vec2 w1 = bloomSplineBasis((vec2( 0.0) - f) / width);
    vec2 w2 = bloomSplineBasis((vec2( 1.0) - f) / width);
    vec2 w3 = bloomSplineBasis((vec2( 2.0) - f) / width);
    vec2 g0 = w0 + w1;
    vec2 g1 = w2 + w3;
    vec2 total = max(g0 + g1, vec2(1e-6));
    vec2 a = (base - 1.0 + w1 / max(g0, vec2(1e-6)) + 0.5) / size;
    vec2 b = (base + 1.0 + w3 / max(g1, vec2(1e-6)) + 0.5) / size;
    vec2 blend = g1 / total;
    return mix(mix(textureLod(source, a, float(lod)).rgb,
                   textureLod(source, vec2(b.x, a.y), float(lod)).rgb, blend.x),
               mix(textureLod(source, vec2(a.x, b.y), float(lod)).rgb,
                   textureLod(source, b, float(lod)).rgb, blend.x), blend.y);

}
