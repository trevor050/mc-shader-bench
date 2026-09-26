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
    for (int i = 0; i < WATER_WAVE_OCTAVES; i++) {
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
#if WATER_WAVE_OCTAVES == 0
    return flatN;
#else
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
#endif
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

// Sample a cloud model at the point where a reflected sky ray crosses one layer.
float reflectedCloudDensityAt(vec3 ro, vec3 rd, float y, float maxDist, CloudWeather w, int layer,
                              float cirrusDaylight, out float distanceFade, out float rayDistance) {
    float t = (y - ro.y) / rd.y;
    distanceFade = 0.0;
    rayDistance = 1e6;
    if (t <= 0.0 || t >= maxDist) return 0.0;
    vec3 p = ro + rd * t;
    float d = 0.0;
    if (layer == 0) d = l0Density(p, w, 2);
    else if (layer == 1) d = altocumulusDensity(p, w, t, 2);
    else if (layer == 2) d = deckDensity(p, fractusStyle(w), t, 2);
    else if (layer == 3) d = virgaDensity(p, w, virgaAmount(w));
    else if (layer == 4) d = deckDensity(p, veilStyle(w), t, 2);
    else {
        vec3 wind = cloudWind() * 4.0;
        float h = saturate((p.y - (L2_ALT - 0.5 * L2_THICK)) / L2_THICK);
        d = cirrusDensity(p.xz + wind.xz, h, w, t) * cirrusDaylight;
    }
    distanceFade = cloudDistanceFade(t * length(rd.xz));
    rayDistance = t;
    return d;
}

// Reflect the same cloud layers as the sky, with a small set of representative vertical taps instead of a
// second full volumetric march at every water pixel. SSR supplies exact camera-visible detail for screen hits.
vec3 reflectedClouds(vec3 sky, vec3 rd, vec3 ro, vec3 lightDir, vec3 directLight, vec3 highDirect,
                     vec3 sunDir, vec3 skyLight) {
#if defined CLOUDS && !defined DIM_NETHER && !defined DIM_END && WATER_CLOUD_REFLECTION_QUALITY > 0
    if (rd.y <= 0.02) return sky;
    CloudWeather w = cloudWeather();
    // Some regional masks are camera-anchored; keep water reflections in the same coordinate frame as the sky march.
    gCloudCamera = cameraPosition;
    float rayLimit = cloudRayLimit(rd, 1e6);
    float cirrusDaylight = smoothstep(-0.1, 0.05, sunDir.y);
    float l0 = 0.0, l0Fade = 0.0, l0Distance = 1e6;
    vec3 p = ro;
    const int LOW_TAPS = WATER_CLOUD_REFLECTION_QUALITY > 1 ? 5 : 3;
    for (int i = 0; i < LOW_TAPS; i++) {
        float y = WATER_CLOUD_REFLECTION_QUALITY > 1
            ? (i == 0 ? 163.0 : (i == 1 ? 240.0 : (i == 2 ? 390.0 : (i == 3 ? 700.0 : 1020.0))))
            : (i == 0 ? 190.0 : (i == 1 ? 360.0 : 800.0));
        float fade, sampleDistance;
        float d = reflectedCloudDensityAt(ro, rd, y, rayLimit, w, 0, cirrusDaylight, fade, sampleDistance);
        if (d > l0) {
            l0 = d;
            l0Fade = fade;
            l0Distance = sampleDistance;
            p = ro + rd * sampleDistance;
        }
    }
    DeckStyle altoStyleValue = altoStyle(w);
    DeckStyle fractusStyleValue = fractusStyle(w);
    DeckStyle veilStyleValue = veilStyle(w);
    float alto = 0.0, altoFade = 0.0, altoDistance = 1e6;
    float fractus = 0.0, fractusFade = 0.0, fractusDistance = 1e6;
    float virga = 0.0, virgaFade = 0.0, virgaDistance = 1e6;
    float veil = 0.0, veilFade = 0.0, veilDistance = 1e6;
    float cirrus = 0.0, cirrusFade = 0.0, cirrusDistance = 1e6;
    const int DECK_TAPS = WATER_CLOUD_REFLECTION_QUALITY > 1 ? 2 : 1;
    for (int i = 0; i < DECK_TAPS; i++) {
        float f = (float(i) + 1.0) / float(DECK_TAPS + 1);
        float fade, sampleDistance;
        float d = reflectedCloudDensityAt(ro, rd, altoStyleValue.alt + altoStyleValue.thick * f,
                                          rayLimit, w, 1, cirrusDaylight, fade, sampleDistance);
        if (d > alto) { alto = d; altoFade = fade; altoDistance = sampleDistance; }
        d = reflectedCloudDensityAt(ro, rd, fractusStyleValue.alt + fractusStyleValue.thick * f,
                                    rayLimit, w, 2, cirrusDaylight, fade, sampleDistance);
        if (d > fractus) { fractus = d; fractusFade = fade; fractusDistance = sampleDistance; }
        float virgaF = 0.72 + 0.18 * float(i);
        d = reflectedCloudDensityAt(ro, rd, L1_ALT - VIRGA_DEPTH + VIRGA_DEPTH * virgaF,
                                    rayLimit, w, 3, cirrusDaylight, fade, sampleDistance);
        if (d > virga) { virga = d; virgaFade = fade; virgaDistance = sampleDistance; }
        d = reflectedCloudDensityAt(ro, rd, veilStyleValue.alt + veilStyleValue.thick * f,
                                    rayLimit, w, 4, cirrusDaylight, fade, sampleDistance);
        if (d > veil) { veil = d; veilFade = fade; veilDistance = sampleDistance; }
        d = reflectedCloudDensityAt(ro, rd, L2_ALT - 0.5 * L2_THICK + L2_THICK * f,
                                    rayLimit, w, 5, cirrusDaylight, fade, sampleDistance);
        if (d > cirrus) { cirrus = d; cirrusFade = fade; cirrusDistance = sampleDistance; }
    }
    float cover = (1.0 - exp(-l0 * 3.0)) * l0Fade;
    float cloudDistance = l0Distance;
    float layerCover = (1.0 - exp(-alto * 1.6)) * altoFade;
    if (layerCover > cover) { cover = layerCover; cloudDistance = altoDistance; }
    layerCover = (1.0 - exp(-fractus * 1.6)) * fractusFade;
    if (layerCover > cover) { cover = layerCover; cloudDistance = fractusDistance; }
    layerCover = (1.0 - exp(-virga * 2.0)) * virgaFade;
    if (layerCover > cover) { cover = layerCover; cloudDistance = virgaDistance; }
    layerCover = (1.0 - exp(-veil * 1.6)) * veilFade;
    if (layerCover > cover) { cover = layerCover; cloudDistance = veilDistance; }
    layerCover = (1.0 - exp(-cirrus * 1.6)) * cirrusFade;
    if (layerCover > cover) { cover = layerCover; cloudDistance = cirrusDistance; }
    if (rd.y < 0.25) {
        float hazeDist;
        float hazeNight = smoothstep(-0.10, -0.30, sunDir.y);
        vec4 horizon = cloudHorizonHaze(ro, rd, 1e6, w, directLight, highDirect, highDirect,
                                        skyLight, cirrusDaylight, hazeNight, hazeDist);
        sky = sky * horizon.a + horizon.rgb;
    }
    if (cover <= 0.01) return sky;
    float lit = exp(-l0Density(p + lightDir * 80.0, w, 2) * 1.5);
    vec3 col = directLight * (0.08 + 0.1 * lit) + skyLight * 0.08;
    if (cloudDistance < 1e5) {
        float air = 1.0 - exp(-cloudDistance * mix(0.000055, 0.0003, rainStrength));
        float detailAir = 1.0 - cloudDistanceFade(cloudDistance * length(rd.xz));
        air = 1.0 - (1.0 - air) * (1.0 - detailAir);
        vec3 haze = hazeColor(normalize(vec3(rd.x, max(rd.y, 0.0), rd.z)), sunDir);
        col = mix(col, haze, air);
    }
    float fade = smoothstep(0.02, 0.15, rd.y);
    return mix(sky, col, cover * fade);
#else
    return sky;
#endif
}
