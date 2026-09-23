// Cloud system: a volumetric cumulus layer low enough to fly into, a thin altocumulus layer, and high cirrus.
// Requires atmosphere.glsl (hazeColor, skyRadiance), uniforms frameTimeCounter, rainStrength, worldDay, worldTime.
//
// Lighting follows Photon's approach (SixthSurge, used under the Photon license): multiple scattering
// approximated by a series of progressively weaker, wider, less extinguished octaves, a sharp forward peak
// for silver linings, and powder darkening. Changes relative to Photon's cumulus layer:
//   1. Per-cell cloud heights: a "convection" field lifts the top of each cloud separately, so flat
//      fair-weather cumulus and tall towers share one layer instead of a fixed slab thickness.
//   2. Minecraft scale: the layer sits a few hundred blocks up, so it can be flown into, wraps mountain peaks,
//      and hangs in front of terrain when the camera is inside or above it.
//   3. Distance-adaptive stepping with a close-range detail octave, so clouds stay crisp up close instead of
//      turning into blur when you fly through them.
//   4. Continuous weather: coverage, cloud type and cirrus amount drift smoothly across in-game days rather
//      than being rolled once per day.
//   5. Coloured ground bounce: cloud bases pick up light reflected off the land below (warm, green-tinted),
//      and night clouds are lit by the moon with the same model instead of a flat dimming factor.

uniform sampler3D cloudNoise;
uniform int worldDay;
uniform int worldTime;

#define L0_BASE 250.0         // lowest cloud base (blocks)
#define L0_THICK 300.0        // tallest towers reach L0_BASE + L0_THICK plus base variation
#define L1_ALT 1150.0         // altocumulus
#define L1_THICK 70.0
#define L2_ALT 2600.0         // cirrus (flat)
#define CLOUD_MAX_DIST 18000.0

// Raw 3D custom textures clamp at the edges, so tile manually. The texture is 65^3 with the first slice
// repeated at the end; mapping [0,1) onto texel centers 0..64 lets filtering cross the wrap without a seam.
vec4 cloudTex(vec3 p) { return texture(cloudNoise, fract(p) * (64.0 / 65.0) + 0.5 / 65.0); }

float remap(float v, float lo, float hi, float nlo, float nhi) {
    return nlo + (v - lo) * (nhi - nlo) / (hi - lo);
}

float noise1(float x) {
    float i = floor(x), f = fract(x);
    float a = fract(sin(i * 127.1) * 43758.5453), b = fract(sin((i + 1.0) * 127.1) * 43758.5453);
    return mix(a, b, f * f * (3.0 - 2.0 * f));
}

struct CloudWeather {
    float cov0;    // cumulus coverage
    float tower;   // how tall cumulus grow
    float cov1;    // altocumulus coverage
    float cirrus;  // cirrus amount
};

CloudWeather cloudWeather() {
    // Weather clock in days; octaves drift at different rates so the sky never repeats on a fixed cycle.
    float t = float(worldDay) + float(worldTime) / 24000.0;
    CloudWeather w;
    float a = noise1(t * 0.9) * 0.65 + noise1(t * 2.3 + 5.0) * 0.35;
    float b = noise1(t * 0.7 + 17.0);
    float c = noise1(t * 1.1 + 41.0);
    w.cov0 = mix(0.26, 0.58, a) * CLOUD_COVERAGE / 0.34;
    w.tower = mix(0.35, 1.0, noise1(t * 1.3 + 71.0));
    w.cov1 = mix(0.05, 0.62, b);
    w.cirrus = mix(0.15, 1.0, c);
    // Rain: thick, low, flat-bottomed overcast.
    w.cov0 = mix(w.cov0, 0.9, rainStrength);
    w.tower = mix(w.tower, 0.8, rainStrength);
    w.cov1 = mix(w.cov1, 0.85, rainStrength);
    w.cirrus *= 1.0 - rainStrength;
#ifdef CLOUD_DEBUG_WEATHER
    w.cov0 = 0.45; w.tower = 0.8; w.cov1 = 0.0; w.cirrus = 0.0;
#endif
    return w;
}

vec3 cloudWind() { return vec3(frameTimeCounter * 3.2, 0.0, frameTimeCounter * 1.3); }

// Cloud base varies gently across the map so the underside is not one flat sheet.
float l0Base(vec2 xz) {
    return L0_BASE + 45.0 * cloudTex(vec3(xz / 9000.0, 0.81)).g;
}

// Cumulus density. lod 0 = full detail, 1 = no close detail, 2 = shape only (light marches, shadows).
float l0Density(vec3 p, CloudWeather w, int lod) {
    vec3 wind = cloudWind();
    vec2 cq = (p.xz + wind.xz) / 3000.0;
    float base = l0Base(p.xz);
    float h = (p.y - base) / L0_THICK;
    if (h <= 0.0 || h >= 1.0) return 0.0;

    // Coverage map: where cloud cells exist, and a convection field that decides how tall each grows.
    vec4 cm = cloudTex(vec3(cq, 0.37));
    // The raw field spans roughly 0.42..0.69; stretch it to 0..1 so coverage maps to area fraction.
    float field = saturate(((cm.r * 0.7 + cm.g * 0.3) - 0.42) / 0.27);
    float local = saturate(remap(field, 1.0 - w.cov0 - 0.15, 1.0 - w.cov0 + 0.22, 0.0, 1.0));
    if (local <= 0.0) return 0.0;
    float convect = saturate((cloudTex(vec3(cq * 0.6 + 0.3, 0.63)).r - 0.45) / 0.28);
    float top = mix(0.22, 1.0, convect * w.tower) * mix(0.55, 1.0, local);
    if (h >= top) return 0.0;
    float hn = h / top;

    vec3 q = (p + wind) / 700.0;
    vec4 n = cloudTex(q * vec3(1.0, 1.5, 1.0));
    float fbm = n.g * 0.625 + n.b * 0.25 + n.a * 0.125;
    float shape = remap(n.r, fbm - 1.0, 1.0, 0.0, 1.0);

    // Flat base, rounded cauliflower top.
    float profile = smoothstep(0.0, 0.07, hn) * (1.0 - smoothstep(0.45, 1.0, hn));
    float d = saturate(remap(shape * profile, 1.0 - local, 1.0, 0.0, 1.0));
    if (d <= 0.0 || lod >= 2) return sqrt(d) * 1.6;

    vec3 dn = cloudTex(q * 4.0 + wind / 700.0).gba;
    float erode = dn.x * 0.625 + dn.y * 0.25 + dn.z * 0.125;
    // Wispy, torn bases; billowy tops.
    erode = mix(1.0 - erode, erode, smoothstep(0.1, 0.5, hn));
    d = saturate(remap(d, erode * 0.55, 1.0, 0.0, 1.0));
    if (lod < 1 && d > 0.0) {
        // Close-range octave: small puffs and torn edges that only matter when the camera is near the cloud.
        vec2 fine = cloudTex(q * 9.0 - wind / 400.0).gb;
        float billow = mix(fine.x, 1.0 - fine.y, smoothstep(0.1, 0.5, hn));
        d = saturate(remap(d, billow * 0.35, 1.0, 0.0, 1.0));
    }
    // Dense cores: real cumulus are optically thick a few blocks inside the edge.
    return sqrt(d) * 1.6;
}

float hgPhase(float mu, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * mu, 1.5));
}

// Direct light phase: broad forward lobe, a very narrow peak for the bright rim around the sun, and a
// back-scatter lobe so clouds facing away from the sun are not flat.
float cloudPhase(float mu) {
    return 0.62 * max(hgPhase(mu, 0.8), 0.6 * hgPhase(mu, 0.97)) + 0.38 * hgPhase(mu, -0.3);
}

// Scattered light from one sample, given optical depths toward the light and the sky. Octave series after
// Photon: each order is weaker, less extinguished and more isotropic.
vec3 cloudScatter(float lightOD, float skyOD, float groundOD, float mu, float powder,
                  vec3 directLight, vec3 skyLight, vec3 groundLight) {
    vec3 s = vec3(0.0);
    float a = 1.0, b = 1.0, g = 1.0;
    for (int i = 0; i < 5; i++) {
        float phase = mix(1.0 / (4.0 * PI), cloudPhase(mu), g);
        s += directLight * (a * exp(-b * lightOD) * phase * powder);
        s += skyLight * (a * exp(-b * skyOD) * (1.0 / (4.0 * PI)));
        s += groundLight * (a * exp(-b * groundOD) * (1.0 / (4.0 * PI)));
        a *= 0.62;
        b *= 0.35;
        g *= 0.55;
        powder = mix(powder, 1.0, 0.5);
    }
    return s;
}

// Cumulus march. Returns premultiplied radiance in rgb, transmittance in a; dist gets the
// transmittance-weighted distance to the cloud (for reprojection and fog).
vec4 marchL0(vec3 ro, vec3 rd, float maxDist, CloudWeather w, vec3 lightDir, vec3 directLight,
             vec3 skyLight, vec3 groundLight, float dither, out float dist) {
    dist = 1e6;
    const float bottom = L0_BASE, topAlt = L0_BASE + 45.0 + L0_THICK;
    float tb = (bottom - ro.y) / rd.y, tt = (topAlt - ro.y) / rd.y;
    float t0, t1;
    if (ro.y > bottom && ro.y < topAlt) {
        t0 = 0.0;
        t1 = rd.y > 0.0 ? tt : (rd.y < 0.0 ? tb : CLOUD_MAX_DIST);
    } else {
        if (abs(rd.y) < 1e-5) return vec4(0.0, 0.0, 0.0, 1.0);
        t0 = min(tb, tt); t1 = max(tb, tt);
        if (t1 <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);
        t0 = max(t0, 0.0);
    }
    t1 = min(t1, min(maxDist, CLOUD_MAX_DIST));
    if (t0 >= t1) return vec4(0.0, 0.0, 0.0, 1.0);

    float mu = dot(rd, lightDir);
    const float sigma = 0.07;
    vec3 rad = vec3(0.0);
    float trans = 1.0;
    float dSum = 0.0, wSum = 0.0;
    float t = t0;
    // Steps grow with distance: fine near the camera (crisp when flying through), coarse far away.
    float stepLen = clamp((t1 - t0) / 40.0, 3.0, 12.0 + t0 * 0.02);
    t += stepLen * dither;
    for (int i = 0; i < 72; i++) {
        if (t >= t1 || trans < 0.02) break;
        vec3 p = ro + rd * t;
        int lod = t < 3000.0 ? 0 : 1;
        float d = l0Density(p, w, lod);
        if (d > 0.002) {
            float fade = 1.0 - smoothstep(CLOUD_MAX_DIST * 0.7, CLOUD_MAX_DIST, t);
            d *= fade;
            // Light march: growing steps toward the light, shape-only density.
            float lightOD = 0.0;
            float ls = 10.0;
            vec3 lp = p;
            for (int j = 0; j < 5; j++) {
                lp += lightDir * ls;
                lightOD += l0Density(lp + lightDir * ls * (dither - 0.5), w, 2) * ls;
                ls *= 1.9;
            }
            float skyOD = (l0Density(p + vec3(0.0, 30.0, 0.0), w, 2) * 30.0
                         + l0Density(p + vec3(0.0, 90.0, 0.0), w, 2) * 60.0);
            float hFrac = saturate((p.y - bottom) / (topAlt - bottom));
            float groundOD = d * hFrac * 120.0;
            // Photon's powder term: dense cloud interiors send multiply scattered light back toward a viewer
            // on the lit side (up to pi times brighter); looking toward the light it fades to neutral.
            float powder = PI * d / (d + 0.15);
            powder = mix(powder, 1.0, 0.8 * sqr(mu * 0.5 + 0.5));
            vec3 s = cloudScatter(lightOD * sigma, skyOD * sigma, groundOD * sigma, mu, powder,
                                  directLight, skyLight, groundLight);
            float stepT = exp(-d * sigma * stepLen);
            rad += trans * s * (1.0 - stepT);
            dSum += t * trans * (1.0 - stepT);
            wSum += trans * (1.0 - stepT);
            trans *= stepT;
        }
        t += stepLen;
        stepLen = min(stepLen * 1.035, 12.0 + t * 0.02);
    }
    if (wSum > 0.0) dist = dSum / wSum;
    return vec4(rad, trans);
}

// Altocumulus: a thin sheet of small puffs, integrated with a handful of samples.
vec4 marchL1(vec3 ro, vec3 rd, CloudWeather w, vec3 lightDir, vec3 directLight, vec3 skyLight, float dither, out float dist) {
    dist = 1e6;
    if (w.cov1 < 0.02) return vec4(0.0, 0.0, 0.0, 1.0);
    float tb = (L1_ALT - ro.y) / rd.y, tt = (L1_ALT + L1_THICK - ro.y) / rd.y;
    float t0 = max(min(tb, tt), 0.0), t1 = max(tb, tt);
    if (t1 <= 0.0 || abs(rd.y) < 1e-4) return vec4(0.0, 0.0, 0.0, 1.0);
    t1 = min(t1, t0 + 900.0);
    if (t0 > 40000.0) return vec4(0.0, 0.0, 0.0, 1.0);
    vec3 wind = cloudWind() * 1.6;
    float mu = dot(rd, lightDir);
    const int N = 6;
    float stepLen = (t1 - t0) / float(N);
    vec3 rad = vec3(0.0);
    float trans = 1.0;
    for (int i = 0; i < N; i++) {
        vec3 p = ro + rd * (t0 + (float(i) + dither) * stepLen);
        float h = saturate((p.y - L1_ALT) / L1_THICK);
        vec2 q = (p.xz + wind.xz) / 2600.0;
        float big = cloudTex(vec3(q * 0.35, 0.13)).r;
        vec4 n = cloudTex(vec3(q * 2.2, h * 0.1 + 0.5));
        float cells = n.r * 0.6 + n.g * 0.4;
        float cov = w.cov1 * smoothstep(0.25, 0.75, big);
        float d = saturate(remap(cells * (1.0 - abs(h * 2.0 - 1.0)), 1.0 - cov, 1.0, 0.0, 1.0));
        d = saturate(d - cloudTex(vec3(q * 9.0, 0.71)).b * 0.25) * 1.4;
        if (d <= 0.0) continue;
        float lightOD = d * 25.0 / max(lightDir.y, 0.1) * 0.5;
        const float sigma = 0.05;
        vec3 s = cloudScatter(lightOD * sigma, d * 15.0 * sigma, 0.0, mu, 1.0, directLight, skyLight, vec3(0.0));
        float stepT = exp(-d * sigma * stepLen);
        rad += trans * s * (1.0 - stepT);
        trans *= stepT;
    }
    dist = t0;
    float fade = 1.0 - smoothstep(20000.0, 40000.0, t0);
    return vec4(rad * fade, mix(1.0, trans, fade));
}

// Cirrus: flat, wind-stretched streaks. Mostly forward-scattering ice, so it glows near the sun.
vec4 cirrus(vec3 ro, vec3 rd, CloudWeather w, vec3 lightDir, vec3 directLight, vec3 skyLight, out float dist) {
    dist = 1e6;
    if (rd.y <= 0.0 || w.cirrus < 0.02 || ro.y > L2_ALT) return vec4(0.0, 0.0, 0.0, 1.0);
    float t = (L2_ALT - ro.y) / rd.y;
    if (t > 60000.0) return vec4(0.0, 0.0, 0.0, 1.0);
    vec2 p = ro.xz + rd.xz * t + cloudWind().xz * 3.0;
    // Stretch along the wind and warp for hooked, combed filaments.
    vec2 q = p / vec2(7000.0, 3500.0);
    vec2 warp = vec2(cloudTex(vec3(q * 0.4, 0.2)).r, cloudTex(vec3(q * 0.4, 0.6)).r) - 0.55;
    q += warp * 1.6;
    float base = saturate((cloudTex(vec3(q * 0.35, 0.9)).r - 0.4) / 0.32);
    float streak = saturate((cloudTex(vec3(q * vec2(1.0, 2.2), 0.45)).g - 0.3) / 0.4);
    float fine = cloudTex(vec3(q * vec2(2.5, 7.0), 0.15)).b;
    float d = saturate(remap(base * 0.65 + streak * 0.35, 1.0 - w.cirrus * 0.6, 1.0, 0.0, 1.0));
    d *= 0.7 + 0.3 * fine;
    d *= 0.6;
    d *= smoothstep(0.0, 0.08, rd.y);
    if (d <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);
    float mu = dot(rd, lightDir);
    float phase = 0.6 * hgPhase(mu, 0.75) + 0.4 * hgPhase(mu, 0.0);
    float od = d * 0.9;
    float T = exp(-od);
    vec3 s = (directLight * phase * 1.2 + skyLight * (0.35 / (4.0 * PI))) * (1.0 - T);
    dist = t;
    float fade = 1.0 - smoothstep(30000.0, 60000.0, t);
    return vec4(s * fade, mix(1.0, T, fade));
}

// Front-to-back merge of two cloud results sorted by distance.
vec4 mergeClouds(vec4 a, float da, vec4 b, float db, out float d) {
    d = min(da, db);
    if (da <= db) return vec4(a.rgb + a.a * b.rgb, a.a * b.a);
    return vec4(b.rgb + b.a * a.rgb, a.a * b.a);
}

// All cloud layers along a ray. Radiance includes aerial perspective toward the horizon haze.
vec4 renderClouds(vec3 ro, vec3 rd, float maxDist, vec3 sunDir, vec3 lightDir, vec3 directLight,
                  vec3 skyLight, float dither, out float dist) {
    CloudWeather w = cloudWeather();
    // Ground bounce: land reflects a warm, slightly green share of the direct light back up at cloud bases.
    vec3 groundLight = directLight * max(lightDir.y, 0.0) * vec3(0.16, 0.15, 0.11) + skyLight * 0.05;
    float d0, d1 = 1e6, d2 = 1e6;
    vec4 c0 = marchL0(ro, rd, maxDist, w, lightDir, directLight, skyLight, groundLight, dither, d0);
    vec4 c1 = vec4(0.0, 0.0, 0.0, 1.0), c2 = vec4(0.0, 0.0, 0.0, 1.0);
    if (maxDist > 1e5) {
        c1 = marchL1(ro, rd, w, lightDir, directLight, skyLight, dither, d1);
        c2 = cirrus(ro, rd, w, lightDir, directLight, skyLight, d2);
    }
    float d01;
    vec4 c = mergeClouds(c0, d0, c1, d1, d01);
    c = mergeClouds(c, d01, c2, d2, dist);
    // Aerial perspective: distant clouds sink into the haze instead of staying crisp and bright.
    if (dist < 1e5) {
        float air = 1.0 - exp(-dist * mix(0.000055, 0.0003, rainStrength));
        vec3 haze = hazeColor(normalize(vec3(rd.x, max(rd.y, 0.0), rd.z)), sunDir);
        c.rgb = mix(c.rgb, haze * (1.0 - c.a), air);
    }
    return c;
}

// Transmittance of direct light through the cumulus layer above a world position.
float cloudShadow(vec3 worldPos, vec3 lightDir) {
    if (lightDir.y < 0.05) return 1.0;
    CloudWeather w = cloudWeather();
    float od = 0.0;
    for (int i = 0; i < 4; i++) {
        float y = L0_BASE + 30.0 + L0_THICK * 0.6 * (float(i) + 0.5) / 4.0;
        if (y < worldPos.y) continue;
        vec3 p = worldPos + lightDir * ((y - worldPos.y) / lightDir.y);
        od += l0Density(p, w, 2) * L0_THICK * 0.15;
    }
    return mix(exp(-od * 0.07), 1.0, 0.12);
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
