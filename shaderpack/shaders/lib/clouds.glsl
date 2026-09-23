// Raymarched volumetric cumulus layer. Requires cloudNoise (3D Perlin-Worley), atmosphere.glsl.

#define VC_BOTTOM 420.0
#define VC_TOP 760.0
#define VC_STEPS 24
#define VC_LIGHT_STEPS 4

uniform sampler3D cloudNoise;

// Raw 3D custom textures load with clamp-to-edge, so tile manually.
vec4 cloudTex(vec3 p) { return texture(cloudNoise, fract(p)); }

float remap(float v, float lo, float hi, float nlo, float nhi) {
    return nlo + (v - lo) * (nhi - nlo) / (hi - lo);
}

float cloudCoverage() {
    return mix(CLOUD_COVERAGE, 0.85, rainStrength);
}

// Density at a world-space position. detail=false skips erosion (used for light marches).
float vcDensity(vec3 p, bool detail) {
    float h = (p.y - VC_BOTTOM) / (VC_TOP - VC_BOTTOM);
    if (h <= 0.0 || h >= 1.0) return 0.0;
    vec3 wind = vec3(frameTimeCounter * 4.0, 0.0, frameTimeCounter * 1.5);
    vec3 q = (p + wind) / 2400.0;

    // Large-scale weather map decides where clouds exist at all.
    float weather = cloudTex(vec3(q.xz * 0.35, 0.37)).r;
    weather = smoothstep(0.25, 0.85, weather);

    vec4 n = cloudTex(q * vec3(1.0, 1.6, 1.0));
    float fbm = n.g * 0.625 + n.b * 0.25 + n.a * 0.125;
    float base = remap(n.r, fbm - 1.0, 1.0, 0.0, 1.0);

    // Rounded bottoms, anvil-ish tops: density profile over the layer height.
    float profile = smoothstep(0.0, 0.12, h) * smoothstep(1.0, 0.45, h);
    float cov = cloudCoverage() * mix(0.55, 1.15, weather);
    float d = saturate(remap(base * profile, 1.0 - cov, 1.0, 0.0, 1.0));
    if (d <= 0.0 || !detail) return d;

    vec3 dn = cloudTex(q * 5.0 + wind / 900.0).gba;
    float erode = dn.x * 0.625 + dn.y * 0.25 + dn.z * 0.125;
    // Wispy at the bottom, billowy at the top.
    erode = mix(erode, 1.0 - erode, saturate(h * 4.0));
    return saturate(remap(d, erode * 0.35, 1.0, 0.0, 1.0));
}

// Transmittance of direct light through the cloud layer above a world position.
float cloudShadow(vec3 worldPos, vec3 lightDir) {
    if (lightDir.y < 0.05) return 1.0;
    float od = 0.0;
    for (int i = 0; i < 3; i++) {
        float y = mix(VC_BOTTOM, VC_TOP, (float(i) + 0.5) / 3.0);
        vec3 p = worldPos + lightDir * ((y - worldPos.y) / lightDir.y);
        // Undo the missing detail erosion: base-only density overestimates cloud extent.
        od += saturate(vcDensity(p, false) * 1.6 - 0.35);
    }
    return mix(exp(-od * 1.8), 1.0, 0.18);
}

// Tileable caustic pattern (after joltz0r's water shader). Returns roughly 0..1 bright filaments.
float caustics(vec2 uv, float time) {
    vec2 p = mod(uv * TAU, TAU) - 250.0;
    vec2 i = p;
    float c = 1.0;
    const float inten = 0.005;
    for (int n = 0; n < 4; n++) {
        float t = time * (1.0 - (3.5 / float(n + 1)));
        i = p + vec2(cos(t - i.x) + sin(t + i.y), sin(t - i.y) + cos(t + i.x));
        c += 1.0 / length(vec2(p.x / (sin(i.x + t) / inten), p.y / (cos(i.y + t) / inten)));
    }
    c /= 4.0;
    c = 1.17 - pow(c, 1.4);
    return pow(abs(c), 8.0);
}

float hgPhase(float mu, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * mu, 1.5));
}

// Returns premultiplied cloud radiance in rgb and transmittance in a.
// ro is camera world position, rd view direction, maxDist limits the march (scene depth).
vec4 marchClouds(vec3 ro, vec3 rd, float maxDist, vec3 lightDir, vec3 directLight, vec3 ambient, float dither) {
    float tBottom = (VC_BOTTOM - ro.y) / rd.y;
    float tTop = (VC_TOP - ro.y) / rd.y;
    float t0 = max(min(tBottom, tTop), 0.0);
    float t1 = max(tBottom, tTop);
    if (abs(rd.y) < 1e-4 || t1 <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);
    t1 = min(t1, min(maxDist, 24000.0));
    if (t0 >= t1) return vec4(0.0, 0.0, 0.0, 1.0);

    float stepLen = (t1 - t0) / float(VC_STEPS);
    float mu = dot(rd, lightDir);
    // Two-lobe phase: strong forward silver lining plus soft back-scatter.
    float phase = mix(hgPhase(mu, 0.8), hgPhase(mu, -0.25), 0.3);
    float sigma = 0.045;

    vec3 radiance = vec3(0.0);
    float trans = 1.0;
    for (int i = 0; i < VC_STEPS; i++) {
        vec3 p = ro + rd * (t0 + (float(i) + dither) * stepLen);
        float d = vcDensity(p, true);
        if (d <= 0.001) continue;

        float lightOD = 0.0;
        float ls = (VC_TOP - VC_BOTTOM) / float(VC_LIGHT_STEPS) * 0.6;
        for (int j = 1; j <= VC_LIGHT_STEPS; j++) {
            lightOD += vcDensity(p + lightDir * ls * float(j), false) * ls;
        }
        float h = saturate((p.y - VC_BOTTOM) / (VC_TOP - VC_BOTTOM));
        // Octave-style multiple scattering: a softer second term lets light reach deep into the cloud.
        float beer = exp(-lightOD * sigma * 0.55) + 0.35 * exp(-lightOD * sigma * 0.12);
        float powder = 1.0 - exp(-d * stepLen * sigma * 2.0);
        vec3 sun = directLight * beer * phase * mix(1.0, powder * 2.0, 0.5) * 9.0;
        vec3 amb = ambient * (0.35 + 0.65 * h);

        float sampleSigma = d * sigma;
        float stepT = exp(-sampleSigma * stepLen);
        // Energy-conserving integration of in-scatter over the step.
        radiance += trans * (sun + amb) * (1.0 - stepT);
        trans *= stepT;
        if (trans < 0.01) break;
    }
    // Fade distant clouds into the sky so the layer has no hard far edge.
    float fade = exp(-t0 * 0.00006);
    return vec4(radiance * fade, mix(1.0, trans, fade));
}
