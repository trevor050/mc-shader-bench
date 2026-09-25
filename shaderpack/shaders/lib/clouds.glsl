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
#include "/lib/cloud_weather.glsl"
uniform vec4 lightningBoltPosition;   // player-relative; w = 1 while a bolt exists

#define L0_BASE 250.0         // lowest cloud base (blocks)
#define L0_THICK 300.0        // tallest towers reach L0_BASE + L0_THICK plus base variation
#define L1_ALT 1150.0         // broken mid-level altocumulus, visibly separate from the cumulus towers
#define L1_THICK 220.0        // deep enough to read as volume from below, not a painted band
#define L2_ALT 2600.0         // high, fibrous cirrus volume
#define L2_THICK 180.0
#define CLOUD_MAX_DIST 18000.0

// Raw 3D custom textures clamp at the edges, so tile manually. The texture is 65^3 with the first slice
// repeated at the end; mapping [0,1) onto texel centers 0..64 lets filtering cross the wrap without a seam.
vec4 cloudTex(vec3 p) { return texture(cloudNoise, fract(p) * (64.0 / 65.0) + 0.5 / 65.0); }

float remap(float v, float lo, float hi, float nlo, float nhi) {
    return nlo + (v - lo) * (nhi - nlo) / (hi - lo);
}

vec3 cloudWind() { return vec3(frameTimeCounter * 3.2, 0.0, frameTimeCounter * 1.3); }

// The cumulus volume spans a tall slab; inside it every region picks its own cloud base and depth, so one
// march covers low decks that hug mountain tops, ordinary fair-weather cumulus higher up, and the occasional
// thunderstorm tower whose flat anvil spreads out near the top of the slab.
#define L0_SLAB_BOTTOM 132.0
#define L0_SLAB_TOP 1080.0

struct CloudColumn {
    float base;   // cloud base altitude here
    float thick;  // depth from base to the tallest possible top here
    float cb;     // 0..1 thunderstorm-cell strength (towers and anvils)
    float low;    // 0..1 how much this region belongs to the low deck
};

CloudColumn cloudColumn(vec2 xz, CloudWeather w) {
    CloudColumn c;
    // One fetch drives the regional structure: R = height regions, G = base wobble, B = storm cells.
    vec4 m = cloudTex(vec3(xz / 14000.0, 0.21));
    // Per-cloud offset at roughly the scale of single clouds, so neighbours never line up into a shelf.
    float own = cloudTex(vec3(xz / 2300.0, 0.93)).r;
    float region = saturate((m.r - 0.42) / 0.3);
    // Continuous height field: w.low pushes the whole distribution down (low-deck days) or up.
    float lowness = saturate(smoothstep(0.0, 1.0, 1.0 - region) * (0.4 + w.low));
    c.low = smoothstep(0.55, 0.95, lowness);
    // Fair-weather cumulus bases sit just above the peaks (about y 200-300), low enough to reach on foot from a
    // mountain top or with a short flight.
    c.base = mix(305.0, 190.0, lowness) + 60.0 * (m.g - 0.5) + 90.0 * (own - 0.55);
    c.base = max(c.base, 178.0);
    // Low clouds are flatter layers; higher ones build taller cumulus.
    c.thick = mix(320.0, 130.0, lowness);
    float storm = saturate((m.b - 0.55) / 0.15);
    c.cb = smoothstep(0.55, 0.95, storm) * w.cb * (1.0 - c.low);
    c.thick += c.cb * 520.0;
    return c;
}

// Upper deck: in some regions a second, flatter layer of puffy stratocumulus floats well above the first, so
// clouds stack on clouds and there is a gap to fly between them. Returns thick = 0 where there is none.
float upperDeckAmount(vec2 xz) {
    return saturate((cloudTex(vec3(xz / 9000.0, 0.55)).g - 0.38) / 0.2);
}

CloudColumn upperColumn(vec2 xz, CloudColumn lower, CloudWeather w, float stack) {
    CloudColumn c;
    c.base = max(lower.base + mix(lower.thick * 0.55, lower.thick, w.tower) + 90.0, 520.0)
           + 90.0 * (cloudTex(vec3(xz / 2700.0, 0.71)).r - 0.5);
    c.thick = stack > 0.0 && c.base + 120.0 < L0_SLAB_TOP ? min(170.0, L0_SLAB_TOP - c.base) : 0.0;
    c.cb = 0.0;
    c.low = 0.45;
    return c;
}

// One cumulus deck. seed shifts the coverage and shape noise so decks do not mirror each other; covScale
// thins a deck (upper decks are patchier).
float cumulusDeck(vec3 p, CloudWeather w, int lod, CloudColumn col, float seed, float covScale) {
    vec3 wind = cloudWind();
    vec2 xzw = p.xz + wind.xz;
    float h = (p.y - col.base) / col.thick;
    if (h <= 0.0 || h >= 1.0) return 0.0;

    // Coverage map: where cloud cells exist, and a convection field that decides how tall each grows.
    vec2 cq = xzw / 3000.0 + seed;
    vec4 cm = cloudTex(vec3(cq, 0.37));
    float field = saturate(((cm.r * 0.7 + cm.g * 0.3) - 0.42) / 0.27);
    // Low decks spread wider (more coverage); storm cells merge into one massive body.
    float cov = (w.cov0 + col.low * w.lowCov + col.cb * 0.35) * covScale;
    float local = saturate(remap(field, 1.0 - cov - 0.15, 1.0 - cov + 0.22, 0.0, 1.0));
    // Anvil: near the top of a storm cell the cloud spreads sideways into a flat shelf.
    float anvil = col.cb * smoothstep(0.72, 0.86, h) * (1.0 - smoothstep(0.96, 1.0, h));
    local = max(local, anvil * saturate(field * 1.6 + 0.2));
    if (local <= 0.0) return 0.0;
    float convect = saturate((cloudTex(vec3(cq * 0.6 + 0.3, 0.63)).r - 0.45) / 0.28);
    float top = mix(0.38, 1.0, convect * w.tower) * mix(0.6, 1.0, local);
    // Storm cells reach the full depth.
    top = mix(top, 1.0, col.cb);
    if (h >= top) return 0.0;
    float hn = h / top;

    vec3 q = (p + wind) / 700.0 + seed;
    vec4 n = cloudTex(q * vec3(1.0, 2.6, 1.0));
    float fbm = n.g * 0.625 + n.b * 0.25 + n.a * 0.125;
    float shape = remap(n.r, fbm - 1.0, 1.0, 0.0, 1.0);
    // Turrets: in the upper half, a coarse puff field pushes up rounded domes so tops are lumpy rather than
    // one smooth pillow.
    float dome = cloudTex(q * 1.7 + 0.37).g;
    shape = mix(shape, shape * (0.55 + 0.9 * dome), smoothstep(0.25, 0.75, hn) * (1.0 - anvil));
    // Flat base; rounded cauliflower top for cumulus, a flat shelf for anvils.
    float roundTop = 1.0 - smoothstep(0.45, 1.0, hn);
    float profile = smoothstep(0.0, 0.07, hn) * mix(roundTop, 1.0 - smoothstep(0.9, 1.0, hn), max(anvil, col.low * 0.6));
    float d = saturate(remap(shape * profile, 1.0 - local, 1.0, 0.0, 1.0));
    if (d <= 0.0 || lod >= 2) return sqrt(d) * 1.6;

    vec3 dn = cloudTex(q * 4.0 + wind / 700.0).gba;
    float erode = dn.x * 0.625 + dn.y * 0.25 + dn.z * 0.125;
    // G/B/A are inverted Worley (high at puff centres). Tops erode along cell borders (1 - erode), which
    // leaves rounded cauliflower lobes; bases erode inside the cells, which tears them into wisps.
    erode = mix(erode, 1.0 - erode, smoothstep(0.1, 0.5, hn));
    d = saturate(remap(d, erode * 0.55, 1.0, 0.0, 1.0));
    if (lod < 1 && d > 0.0) {
        // Close-range octave: small puffs and torn edges that only matter when the camera is near the cloud.
        vec2 fine = cloudTex(q * 9.0 - wind / 400.0).gb;
        float billow = mix(fine.x, 1.0 - fine.y, smoothstep(0.1, 0.5, hn));
        d = saturate(remap(d, billow * 0.35, 1.0, 0.0, 1.0));
        if (lod < 0 && d > 0.0) {
            // Within a few hundred blocks: small puffs and torn wisps, so flying into a cloud shows texture.
            float puff = cloudTex(q * 26.0 + wind / 150.0).g;
            d = saturate(remap(d, puff * 0.3, 1.0, 0.0, 1.0));
        }
    }
    // Dense cores: real cumulus are optically thick a few blocks inside the edge.
    return smoothstep(0.0, 0.45, d) * 1.5;
}

// Scud: ragged, low fractus drifting below the cumulus, around mountain shoulders and over valleys. Patchy on
// fair days, a broken grey deck on low-cloud days and in rain. Returns 0 outside its thin band.
#define SCUD_BASE 138.0
#define SCUD_TOP 188.0
float scudDensity(vec3 p, CloudWeather w, int lod) {
    if (p.y <= SCUD_BASE || p.y >= SCUD_TOP) return 0.0;
    vec2 xzw = p.xz + cloudWind().xz * 1.7;
    float region = cloudTex(vec3(xzw / 5200.0, 0.81)).r;
    float amount = saturate((region - 0.5) / 0.22) * mix(0.35, 1.0, max(w.low, rainStrength));
    if (amount <= 0.0) return 0.0;
    CloudColumn c;
    c.base = SCUD_BASE + 18.0 * (cloudTex(vec3(xzw / 1900.0, 0.27)).g - 0.3);
    c.thick = SCUD_TOP - c.base;
    c.cb = 0.0;
    c.low = 1.0;
    return cumulusDeck(p, w, lod, c, 0.71, amount * 0.9) * 0.7;
}

// Cumulus density. lod -1 = extra close detail, 0 = full detail, 1 = no close detail, 2 = shape only.
float l0Density(vec3 p, CloudWeather w, int lod) {
    if (p.y <= L0_SLAB_BOTTOM || p.y >= L0_SLAB_TOP) return 0.0;
    if (p.y < SCUD_TOP) {
        float s = scudDensity(p, w, lod);
        if (s > 0.0 || p.y < 178.0) return s;
    }
    vec2 xzw = p.xz + cloudWind().xz;
    CloudColumn col = cloudColumn(xzw, w);
    float d = cumulusDeck(p, w, lod, col, 0.0, 1.0);
    if (d > 0.0 || p.y < col.base + col.thick * 0.5) return d;
    float stack = upperDeckAmount(xzw);
    if (stack <= 0.0) return 0.0;
    CloudColumn up = upperColumn(xzw, col, w, stack);
    if (up.thick <= 0.0) return 0.0;
    return cumulusDeck(p, w, lod, up, 0.43, 0.75 * smoothstep(0.0, 1.0, stack));
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

// Lightning inside the clouds. During thunder, a flash fires every few seconds somewhere near the camera
// (a fixed spot per time slot, so it does not slide with the player), flickering in two or three pulses.
// A real bolt adds a brighter flash at its own position. Returns flash position (xyz) and radiance (w).
vec4 cloudFlash(vec3 camPos) {
    vec4 f = vec4(0.0);
    if (thunderStrength > 0.01) {
        const float slot = 3.3;
        float epoch = floor(frameTimeCounter / slot);
        float local = frameTimeCounter - epoch * slot;
        float h = fract(sin(epoch * 12.9898) * 43758.5453);
        float h2 = fract(sin(epoch * 78.233) * 43758.5453);
        if (h < 0.6) {
            float flicker = exp(-local * 9.0) + 0.7 * exp(-abs(local - 0.18) * 25.0) + 0.4 * exp(-abs(local - 0.42) * 20.0);
            vec2 anchor = floor(camPos.xz / 900.0) * 900.0;
            vec2 off = (vec2(h, h2) - 0.5) * 2600.0;
            f = vec4(anchor.x + off.x, 380.0 + h2 * 260.0, anchor.y + off.y, flicker * thunderStrength * 6.0);
        }
    }
    if (lightningBoltPosition.w > 0.5) {
        f = vec4(lightningBoltPosition.x + camPos.x, 420.0, lightningBoltPosition.z + camPos.z, 14.0);
    }
    return f;
}

// Cumulus march. Returns premultiplied radiance in rgb, transmittance in a; dist gets the
// transmittance-weighted distance to the cloud (for reprojection and fog).
vec4 marchL0(vec3 ro, vec3 rd, float maxDist, CloudWeather w, vec3 lightDir, vec3 directLight,
             vec3 skyLight, vec3 groundLight, float dither, out float dist) {
    dist = 1e6;
    const float bottom = L0_SLAB_BOTTOM, topAlt = L0_SLAB_TOP;
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
    for (int i = 0; i < 64; i++) {
        if (t >= t1 || trans < 0.02) break;
        vec3 p = ro + rd * t;
        int lod = t < 450.0 ? -1 : (t < 3000.0 ? 0 : 1);
        float d = l0Density(p, w, lod);
        if (d > 0.002) {
            float fade = 1.0 - smoothstep(CLOUD_MAX_DIST * 0.7, CLOUD_MAX_DIST, t);
            d *= fade;
            // Light march: growing steps toward the light, shape-only density.
            float lightOD = 0.0;
            float ls = 12.0;
            vec3 lp = p;
            for (int j = 0; j < 4; j++) {
                lp += lightDir * ls;
                vec3 lightP = lp + lightDir * ls * (dither - 0.5);
                // Once the monotonically advancing light ray leaves the full L0 slab, later taps are empty.
                if (lightP.y <= bottom || lightP.y >= topAlt) break;
                lightOD += l0Density(lightP, w, 2) * ls;
                ls *= 2.1;
            }
            float skyOD = l0Density(p + vec3(0.0, 45.0, 0.0), w, 2) * 70.0;
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
            t += stepLen;
        } else {
            // Empty air: stride faster until something is found.
            t += stepLen * 1.0;
        }
        stepLen = min(stepLen * 1.035, 12.0 + t * 0.02);
    }
    if (wSum > 0.0) dist = dSum / wSum;
    return vec4(rad, trans);
}

// Altocumulus: broken, soft-edged puffs in a shallow mid-level band. Track the contributing sample
// distance rather than only the band entry; a zero entry distance while inside the band makes TAA
// reproject the cloud through the camera and smear it when flying through.
vec4 marchL1(vec3 ro, vec3 rd, float maxDist, CloudWeather w, vec3 lightDir, vec3 directLight,
             vec3 skyLight, float dither, out float dist) {
    dist = 1e6;
    if (w.cov1 < 0.02) return vec4(0.0, 0.0, 0.0, 1.0);
    float t0, t1;
    if (abs(rd.y) < 1e-4) {
        // A horizontal ray inside the layer still travels through cloud; one outside it never enters.
        if (ro.y < L1_ALT || ro.y > L1_ALT + L1_THICK) return vec4(0.0, 0.0, 0.0, 1.0);
        t0 = 0.0;
        t1 = min(maxDist, 900.0);
    } else {
        float ta = (L1_ALT - ro.y) / rd.y, tb = (L1_ALT + L1_THICK - ro.y) / rd.y;
        t0 = max(min(ta, tb), 0.0);
        t1 = max(ta, tb);
    }
    if (t1 <= t0 || t0 >= maxDist) return vec4(0.0, 0.0, 0.0, 1.0);
    t1 = min(t1, min(t0 + 900.0, maxDist));
    if (t1 <= t0) return vec4(0.0, 0.0, 0.0, 1.0);
    if (t0 > 40000.0) return vec4(0.0, 0.0, 0.0, 1.0);
    vec3 wind = cloudWind() * 1.6;
    float mu = dot(rd, lightDir);
    const int N = 6;
    float stepLen = (t1 - t0) / float(N);
    vec3 rad = vec3(0.0);
    float trans = 1.0, dSum = 0.0, wSum = 0.0;
    for (int i = 0; i < N; i++) {
        float t = t0 + (float(i) + dither) * stepLen;
        vec3 p = ro + rd * t;
        float h = saturate((p.y - L1_ALT) / L1_THICK);
        // Broad cell spacing and a slower weather field make layered banks rather than rows of tiny puffs.
        vec2 q = (p.xz + wind.xz) / 2400.0;
        float big = cloudTex(vec3(q * 0.30, 0.13)).r;
        vec4 n = cloudTex(vec3(q * 1.8, 0.5));
        float cells = n.r * 0.65 + n.g * 0.35;
        float weatherCoverage = w.cov1 * mix(0.56, 1.0, smoothstep(0.05, 0.6, rainStrength));
        float cov = weatherCoverage * smoothstep(0.18, 0.64, big);
        float local = saturate(remap(cells, 1.0 - cov - 0.13, 1.0 - cov + 0.09, 0.0, 1.0));
        // Cloud cells reach different heights. Bases stay broad while ragged, lobe-shaped tops leave
        // visible openings between banks when seen from above.
        float cellTop = mix(0.38, 1.0, smoothstep(0.3, 0.84, cells));
        if (h >= cellTop) continue;
        float hn = h / cellTop;
        float profile = smoothstep(0.0, 0.12, hn) * (1.0 - smoothstep(0.45, 1.0, hn));
        float d = saturate(local * profile - cloudTex(vec3(q * 5.5, 0.71)).b * 0.16) * 1.2;
        if (d <= 0.0) continue;
        float lightOD = d * 25.0 / max(lightDir.y, 0.1) * 0.5;
        const float sigma = 0.01;
        vec3 s = cloudScatter(lightOD * sigma, d * 15.0 * sigma, 0.0, mu, 1.0, directLight, skyLight, vec3(0.0));
        float stepT = exp(-d * sigma * stepLen);
        float weight = trans * (1.0 - stepT);
        rad += trans * s * (1.0 - stepT);
        dSum += t * weight;
        wSum += weight;
        trans *= stepT;
    }
    if (wSum > 0.0) dist = dSum / wSum;
    float fade = 1.0 - smoothstep(20000.0, 40000.0, t0);
    return vec4(rad * fade, mix(1.0, trans, fade));
}

// Cirrus: a shallow high-altitude volume of thin, fibrous ice streaks combed out by high winds ("mares' tails").
// Its projected pattern stays continuous through the band, so it reads from above and while flying through.
// Mostly forward-scattering ice, so it glows near the sun and nearly vanishes against the dark sky opposite.
vec4 cirrus(vec3 ro, vec3 rd, float maxDist, CloudWeather w, vec3 lightDir,
            vec3 directLight, vec3 skyLight, float dither, out float dist) {
    dist = 1e6;
    if (w.cirrus < 0.02) return vec4(0.0, 0.0, 0.0, 1.0);
    float bottom = L2_ALT - 0.5 * L2_THICK, top = L2_ALT + 0.5 * L2_THICK;
    float t0, t1;
    if (abs(rd.y) < 1e-4) {
        if (ro.y < bottom || ro.y > top) return vec4(0.0, 0.0, 0.0, 1.0);
        t0 = 0.0;
        t1 = min(maxDist, 600.0);
    } else {
        float ta = (bottom - ro.y) / rd.y, tb = (top - ro.y) / rd.y;
        t0 = max(min(ta, tb), 0.0);
        t1 = max(ta, tb);
    }
    if (t1 <= t0 || t0 >= maxDist || t0 > 60000.0) return vec4(0.0, 0.0, 0.0, 1.0);
    // Bound grazing-angle work while retaining enough depth for a smooth, stable veil.
    t1 = min(t1, min(t0 + 600.0, maxDist));
    if (t1 <= t0) return vec4(0.0, 0.0, 0.0, 1.0);
    const int N = 3;
    float stepLen = (t1 - t0) / float(N);
    float trans = 1.0, dSum = 0.0, wSum = 0.0;
    vec3 rad = vec3(0.0);
    vec3 wind = cloudWind() * 4.0;
    float mu = dot(rd, lightDir);
    const vec2 wdir = vec2(0.93, 0.37);
    float phase = 0.45 * hgPhase(mu, 0.6) + 0.55 / (4.0 * PI);
    for (int i = 0; i < N; i++) {
        float t = t0 + (float(i) + dither) * stepLen;
        vec3 samplePos = ro + rd * t;
        float h = saturate((samplePos.y - bottom) / L2_THICK);
        vec2 p = samplePos.xz + wind.xz;
        vec2 q = vec2(dot(p, wdir), dot(p, vec2(-wdir.y, wdir.x)));
        float patch = saturate((cloudTex(vec3(q / 16000.0, 0.9)).r - 0.68 + w.cirrus * 0.16) / 0.14);
        float bend = cloudTex(vec3(q / 12000.0, 0.2)).g - 0.5;
        vec2 f = vec2(q.x / 9000.0, (q.y + bend * 1700.0 + (h - 0.5) * 180.0) / 380.0);
        float fineFade = 1.0 - smoothstep(6000.0, 20000.0, t);
        float fib = valueNoise(f) * 0.6 + mix(0.5, valueNoise(f * vec2(1.7, 2.6) + 13.1), fineFade) * 0.4;
        float d = saturate((fib - 0.47) / 0.3) * patch * 0.75;
        d *= smoothstep(0.3, 0.7, valueNoise(vec2(q.x / 4000.0, q.y / 1800.0) + 7.7));
        d *= smoothstep(0.0, 0.18, h) * (1.0 - smoothstep(0.78, 1.0, h));
        if (d <= 0.0) continue;
        float T = exp(-d * 0.001 * stepLen);
        vec3 s = (directLight * phase * 1.2 + skyLight * (0.35 / (4.0 * PI))) * (1.0 - T);
        float weight = trans * (1.0 - T);
        rad += trans * s;
        dSum += t * weight;
        wSum += weight;
        trans *= T;
    }
    if (wSum > 0.0) dist = dSum / wSum;
    float fade = 1.0 - smoothstep(30000.0, 60000.0, t0);
    return vec4(rad * fade, mix(1.0, trans, fade));
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
    vec3 groundLight = directLight * max(lightDir.y, 0.0) * vec3(0.14, 0.14, 0.12) + skyLight * 0.05;
    float d0, d1 = 1e6, d2 = 1e6;
    vec4 c0 = marchL0(ro, rd, maxDist, w, lightDir, directLight, skyLight, groundLight, dither, d0);
    vec4 c1 = marchL1(ro, rd, maxDist, w, lightDir, directLight, skyLight, dither, d1);
    vec4 c2 = cirrus(ro, rd, maxDist, w, lightDir, directLight, skyLight, dither, d2);
    // Thin ice cloud all but disappears by moonlight; keep it from smearing grey over the stars.
    float cirrusDaylight = smoothstep(-0.1, 0.05, sunDir.y);
    c2 = mix(vec4(0.0, 0.0, 0.0, 1.0), c2, cirrusDaylight);
    if (cirrusDaylight < 0.001) d2 = 1e6;
    float d01;
    vec4 c = mergeClouds(c0, d0, c1, d1, d01);
    c = mergeClouds(c, d01, c2, d2, dist);
    // Aerial perspective: distant clouds sink into the haze instead of staying crisp and bright.
    if (dist < 1e5) {
        float air = 1.0 - exp(-dist * mix(0.000055, 0.0003, rainStrength));
        vec3 haze = hazeColor(normalize(vec3(rd.x, max(rd.y, 0.0), rd.z)), sunDir);
        c.rgb = mix(c.rgb, haze * (1.0 - c.a), air);
    }
    // Clouds stay fully opaque at night: stars and the Milky Way show only through real gaps in the deck.
    return c;
}

// Transmittance of direct light through the cumulus volume above a world position. Taps are spread over the
// heights where cloud bodies live (low deck to storm towers).
float cloudShadow(vec3 worldPos, vec3 lightDir, CloudWeather w) {
    if (lightDir.y < 0.05) return 1.0;
    const float ys[5] = float[5](162.0, 215.0, 275.0, 360.0, 540.0);
    const float thick[5] = float[5](40.0, 55.0, 70.0, 110.0, 250.0);
    if (worldPos.y > ys[4]) return 1.0;
    float od = 0.0;
    for (int i = 0; i < 5; i++) {
        if (ys[i] < worldPos.y) continue;
        vec3 p = worldPos + lightDir * ((ys[i] - worldPos.y) / lightDir.y);
        od += l0Density(p, w, 2) * thick[i];
    }
    // Light scattered in from cloud edges and through thinner parts keeps cloud shade at roughly a third of the
    // sun. With the clouds now low and broad, the old 12% floor turned whole valleys dark blue at noon.
    return mix(exp(-od * 0.035), 1.0, CLOUD_SHADOW_FLOOR);
}

float cloudShadow(vec3 worldPos, vec3 lightDir) {
    if (lightDir.y < 0.05 || worldPos.y > 560.0) return 1.0;
    return cloudShadow(worldPos, lightDir, cloudWeather());
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
