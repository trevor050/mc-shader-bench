// Water surface waves. Requires clouds.glsl (cloudTex) for smooth animated noise.
//
// Still water gets calm, wind-driven ripples: every octave drifts the same general way (a light breeze), with
// only a small spread in direction, so the surface reads as water moved by wind rather than noise boiling in
// place. Sloped (flowing) surfaces run downhill along their slope, faster and choppier, following Photon's
// idea of taking the flow direction from the tilted face.

const vec2 WATER_WIND = vec2(0.82, 0.57);

float waterHeight(vec2 p, float t, vec2 dir, float speed) {
    float h = 0.0;
    float amp = 1.0, freq = 1.0 / 9.0, total = 0.0;
    // Small, fixed rotations keep octaves from all lining up (no grid) while staying roughly downwind.
    const mat2 rot = mat2(0.94, -0.34, 0.34, 0.94);
    vec2 d = dir;
    for (int i = 0; i < 4; i++) {
        vec2 q = (p - d * t * speed * (1.0 + float(i) * 0.35)) * freq;
        // Stretch across the wind: ripples are longer along their crest than across it.
        vec2 qs = vec2(dot(q, d), dot(q, vec2(-d.y, d.x)) * 0.55);
        h += amp * cloudTex(vec3(qs, 0.13 + t * 0.012 + float(i) * 0.21)).g;
        total += amp;
        amp *= 0.5;
        freq *= 2.2;
        d = rot * d;
    }
    return h / total;
}

// worldPos is the fragment's world position, flatN its geometric normal. strength fades waves with distance.
vec3 waterNormal(vec3 worldPos, vec3 flatN, float t, float strength) {
    bool flowing = flatN.y < 0.995;
    vec2 dir = flowing ? normalize(flatN.xz + 1e-5) : WATER_WIND;
    float speed = flowing ? 2.4 : 0.55;
    float amp = (flowing ? 0.35 : 0.13) * strength;
    // Wind picks up in rain and storms: taller, choppier waves.
    amp *= 1.0 + STORM_WAVES * max(rainStrength * 0.4, thunderStrength);
    vec2 p = worldPos.xz;
    const float e = 0.08;
    float h = waterHeight(p, t, dir, speed);
    float hx = waterHeight(p + vec2(e, 0.0), t, dir, speed);
    float hz = waterHeight(p + vec2(0.0, e), t, dir, speed);
    vec3 n = normalize(vec3((h - hx) * amp / e, 1.0, (h - hz) * amp / e));
    if (flowing) n = normalize(n + flatN - vec3(0.0, 1.0, 0.0));
    return n;
}

float fresnelSchlick(float cosTheta, float f0) {
    float x = 1.0 - saturate(cosTheta);
    float x2 = x * x;
    return f0 + (1.0 - f0) * (x2 * x2 * x);
}

// Exact dielectric Fresnel for unpolarized light (needed from below the surface, where total internal
// reflection happens past about 48.6 degrees).
float fresnelDielectric(float cosI, float eta) {
    float sinT2 = eta * eta * (1.0 - cosI * cosI);
    if (sinT2 >= 1.0) return 1.0;
    float cosT = sqrt(1.0 - sinT2);
    float rs = (eta * cosI - cosT) / (eta * cosI + cosT);
    float rp = (cosI - eta * cosT) / (cosI + eta * cosT);
    return 0.5 * (rs * rs + rp * rp);
}

// Cheap reflection of the cumulus layer for water: the cloud field sampled once where the reflected ray
// crosses the layer, shaded from its thickness. It follows the real clouds, unlike a separate 2D layer.
vec3 reflectedClouds(vec3 sky, vec3 rd, vec3 ro, vec3 lightDir, vec3 directLight, vec3 skyLight) {
#if defined CLOUDS && !defined DIM_NETHER && !defined DIM_END
    if (rd.y <= 0.02) return sky;
    CloudWeather w = cloudWeather();
    float y = L0_BASE + 70.0;
    vec3 p = ro + rd * max((y - ro.y) / rd.y, 0.0);
    float d = l0Density(p, w, 2) + l0Density(p + vec3(0.0, 60.0, 0.0), w, 2) * 0.7;
    if (d <= 0.01) return sky;
    float cover = 1.0 - exp(-d * 3.0);
    float lit = exp(-l0Density(p + lightDir * 80.0, w, 2) * 1.5);
    vec3 col = directLight * (0.08 + 0.1 * lit) + skyLight * 0.08;
    float fade = smoothstep(0.02, 0.15, rd.y);
    return mix(sky, col, cover * fade);
#else
    return sky;
#endif
}
