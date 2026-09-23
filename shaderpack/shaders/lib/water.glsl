// Water surface waves. Sum of directional sine-ish waves with noise, evaluated in world space.

float waterHeight(vec2 p, float t) {
    float h = 0.0;
    float amp = 0.5;
    vec2 dir = vec2(0.8, 0.6);
    float freq = 0.55;
    for (int i = 0; i < 6; i++) {
        float phase = dot(dir, p) * freq + t * (1.1 + float(i) * 0.25);
        // Sharpened crests read more like real water than plain sines.
        h += amp * (1.0 - abs(sin(phase + valueNoise(p * freq * 0.4) * 2.0)));
        dir = mat2(0.74, -0.67, 0.67, 0.74) * dir;
        freq *= 1.72;
        amp *= 0.52;
    }
    return h * 0.06;
}

vec3 waterNormal(vec3 worldPos, float t, float strength) {
    vec2 p = worldPos.xz;
    float e = 0.06;
    float h = waterHeight(p, t);
    float hx = waterHeight(p + vec2(e, 0.0), t);
    float hz = waterHeight(p + vec2(0.0, e), t);
    return normalize(vec3((h - hx) * strength, e, (h - hz) * strength));
}

float fresnelSchlick(float cosTheta, float f0) {
    return f0 + (1.0 - f0) * pow(1.0 - saturate(cosTheta), 5.0);
}
