// Sub-pixel projection jitter for TAA. Include in every vertex shader that draws scene geometry.

uniform int frameCounter;
uniform float viewWidth;
uniform float viewHeight;

float halton(int i, int b) {
    float f = 1.0, r = 0.0;
    while (i > 0) {
        f /= float(b);
        r += f * float(i % b);
        i /= b;
    }
    return r;
}

vec2 taaOffset() {
    int i = frameCounter % 8 + 1;
    return (vec2(halton(i, 2), halton(i, 3)) - 0.5) * 2.0 / vec2(viewWidth, viewHeight);
}

void applyJitter(inout vec4 clipPos) {
#ifdef TAA
    clipPos.xy += taaOffset() * clipPos.w;
#endif
}
