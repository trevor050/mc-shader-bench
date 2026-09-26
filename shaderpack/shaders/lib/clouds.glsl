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
#define L1_THICK 110.0        // a thin sheet of cloudlets (mackerel sky)
#define L2_ALT 2600.0         // high, fibrous cirrus volume
#define L2_THICK 180.0
#define CLOUD_MAX_DIST 18000.0

// Raw 3D custom textures clamp at the edges, so tile manually. The texture is 65^3 with the first slice
// repeated at the end; mapping [0,1) onto texel centers 0..64 lets filtering cross the wrap without a seam.
vec4 cloudTex(vec3 p) { return texture(cloudNoise, fract(p) * (64.0 / 65.0) + 0.5 / 65.0); }

float remap(float v, float lo, float hi, float nlo, float nhi) {
    return nlo + (v - lo) * (nhi - nlo) / (hi - lo);
}

vec3 cloudWind() { return vec3(frameTimeCounter * 3.2, 0.0, frameTimeCounter * 1.3) * CLOUD_SPEED; }

// Strength of the narrow forward-scattering peak (the bright rim of a cloud seen against its light source).
// The cloud march raises it by moonlight, when the silver lining is most of what makes a night cloud readable.
float gCloudRim = 1.0;

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
    return 0.62 * max(hgPhase(mu, 0.8), 0.6 * gCloudRim * hgPhase(mu, 0.97)) + 0.38 * hgPhase(mu, -0.3);
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

// ---- Altocumulus: the mackerel sky ----
// A thin sheet of small, tightly packed cloudlets at mid level. From below it is a field of hundreds of cells with
// blue gaps between them, arranged in loose rows across the wind (billows); on some days it covers the whole sky.
// At sunset each cloudlet is lit from the side and from underneath, so the field turns into rows of glowing
// peach-pink puffs with lavender shadows. Cells are procedural (jittered-grid Worley), so they stay crisp at any
// distance until they shrink below a pixel, where they blend into the mean texture of the sheet.

vec2 cellHash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// Nearest (x) and second-nearest (y) jittered cell point distances. y - x is the distance to the lane between
// two cells. Cells are about one unit wide.
vec2 cloudletCells(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    float f1 = 8.0, f2 = 8.0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            vec2 o = vec2(x, y);
            vec2 r = o + 0.1 + cellHash(i + o) * 0.8 - f;
            float d = dot(r, r);
            if (d < f1) { f2 = f1; f1 = d; }
            else if (d < f2) f2 = d;
        }
    return sqrt(vec2(f1, f2));
}

// Density of the altocumulus sheet at p. lod 0 includes the fine texture, lod 1 only the large forms.
// The sheet is one continuous layer of fbm cloud; the cell pattern only carves thin lanes into it. Where the sheet
// is thick the lanes close and cells merge into rippled banks; where it thins, the lanes widen into gaps and
// cells break into separate cloudlets. So the field reads as texture with structure, never as a grid of dots.
float altocumulusDensity(vec3 p, CloudWeather w, float dist, int lod) {
    float h = (p.y - L1_ALT) / L1_THICK;
    if (h <= 0.0 || h >= 1.0) return 0.0;
    vec3 wind = cloudWind() * 1.6;
    vec2 xz = p.xz + wind.xz;
    // Where the sheet exists: broad patches; on high-coverage days it spreads edge to edge.
    float patchN = cloudTex(vec3(xz / 22000.0, 0.13)).r;
    float cov = w.cov1 * smoothstep(0.2, 0.6, patchN);
    if (cov <= 0.01) return 0.0;
    // Align with the upper wind: billow rows run across it, streaks along it.
    const vec2 dir = vec2(0.82, 0.57);
    vec2 q = vec2(dot(xz, dir), dot(xz, vec2(-dir.y, dir.x)));
    // The sheet itself: fbm stretched along the wind, so it forms streaks and ripples at the scale of many cells.
    vec4 s0 = cloudTex(vec3(q.x / 3800.0, q.y / 1700.0, 0.29));
    vec4 s1 = cloudTex(vec3(q.x / 900.0, q.y / 520.0, 0.61));
    float sheet = s0.r * 0.55 + s0.g * 0.2 + s1.r * 0.25;
    // Cells, gently warped so rows wander and no two share a shape.
    float wave = sin(q.x / 210.0 + s0.b * 6.0) * 12.0;
    vec2 cp = vec2(q.x / 44.0, (q.y + wave) / 62.0) + (vec2(s1.g, s1.b) - 0.5) * 1.2;
    vec2 c = cloudletCells(cp);
    float lane = c.y - c.x;
    // Soft cell body: dense near its centre, thinning toward the lanes.
    float body = smoothstep(0.0, 0.45, lane) * (1.0 - 0.45 * smoothstep(0.2, 0.75, c.x));
    // Coverage sets how much of the sheet survives; the lanes are carved harder where the sheet is thin.
    float field = sheet * 0.9 + body * 0.55;
    float d = saturate(remap(field, 1.15 - cov * 0.85, 1.45 - cov * 0.5, 0.0, 1.0));
    // Flat base, softly domed top that follows the cell body.
    float top = mix(0.4, 1.0, body * saturate(d * 1.5));
    d *= smoothstep(0.0, 0.2, h) * (1.0 - smoothstep(top * 0.55, top, h));
    if (lod == 0 && d > 0.0) {
        // Fuzz: fine fibres and puffs eat into the edges, so the cells have soft, torn rims.
        vec4 f = cloudTex(vec3(xz / 160.0, 0.83 + h * 0.2));
        d = saturate(remap(d, (f.g * 0.6 + f.b * 0.4) * 0.45, 1.0, 0.0, 1.0));
    }
    // Far away the cells are smaller than a pixel; blend toward the sheet's average so they do not shimmer.
    float far = smoothstep(7000.0, 22000.0, dist);
    float mean = saturate(remap(sheet * 0.9 + 0.3, 1.15 - cov * 0.85, 1.45 - cov * 0.5, 0.0, 1.0)) * 0.6
               * smoothstep(0.0, 0.2, h) * (1.0 - smoothstep(0.45, 0.85, h));
    return mix(d, mean, far);
}

vec4 marchL1(vec3 ro, vec3 rd, float maxDist, CloudWeather w, vec3 lightDir, vec3 directLight,
             vec3 skyLight, float dither, out float dist) {
    dist = 1e6;
    if (w.cov1 < 0.02) return vec4(0.0, 0.0, 0.0, 1.0);
    float t0, t1;
    if (abs(rd.y) < 1e-4) {
        if (ro.y < L1_ALT || ro.y > L1_ALT + L1_THICK) return vec4(0.0, 0.0, 0.0, 1.0);
        t0 = 0.0;
        t1 = min(maxDist, 900.0);
    } else {
        float ta = (L1_ALT - ro.y) / rd.y, tb = (L1_ALT + L1_THICK - ro.y) / rd.y;
        t0 = max(min(ta, tb), 0.0);
        t1 = max(ta, tb);
    }
    if (t1 <= t0 || t0 >= maxDist || t0 > 45000.0) return vec4(0.0, 0.0, 0.0, 1.0);
    t1 = min(t1, min(t0 + 900.0, maxDist));
    if (t1 <= t0) return vec4(0.0, 0.0, 0.0, 1.0);
    float mu = dot(rd, lightDir);
    const int N = 10;
    const float sigma = 0.035;
    float stepLen = (t1 - t0) / float(N);
    vec3 rad = vec3(0.0);
    float trans = 1.0, dSum = 0.0, wSum = 0.0;
    int lod = t0 < 5000.0 ? 0 : 1;
    for (int i = 0; i < N; i++) {
        if (trans < 0.03) break;
        float t = t0 + (float(i) + dither) * stepLen;
        vec3 p = ro + rd * t;
        float d = altocumulusDensity(p, w, t, lod);
        if (d <= 0.004) continue;
        // Self-shadowing toward the light: at a low sun it runs sideways through the neighbouring cloudlets, which
        // lights one flank of each puff and leaves the other in lavender shade.
        float lightOD = altocumulusDensity(p + lightDir * 9.0, w, t, 1) * 12.0
                      + altocumulusDensity(p + lightDir * 26.0, w, t, 1) * 26.0
                      + altocumulusDensity(p + lightDir * 65.0, w, t, 1) * 40.0;
        lightOD *= 2.2;
        float skyOD = d * (L1_ALT + L1_THICK - p.y) * 0.8;
        float powder = mix(PI * d / (d + 0.2), 1.0, 0.75 * sqr(mu * 0.5 + 0.5));
        vec3 s = cloudScatter(lightOD * sigma, skyOD * sigma, 0.0, mu, powder, directLight, skyLight, vec3(0.0));
        float stepT = exp(-d * sigma * stepLen);
        float weight = trans * (1.0 - stepT);
        rad += s * weight;
        dSum += t * weight;
        wSum += weight;
        trans *= stepT;
    }
    if (wSum > 0.0) dist = dSum / wSum;
    float fade = 1.0 - smoothstep(25000.0, 45000.0, t0);
    return vec4(rad * fade, mix(1.0, trans, fade));
}

// ---- Cirrus: feathers, mares' tails and fans ----
// High ice cloud combed into long fibres by the jet stream. The fibres follow a slowly curving flow field, so strokes
// bend and sweep instead of running in straight parallel lines; long parallel streaks converge toward the horizon in
// perspective, which is what makes cirrus fan out across the sky. Tufts (the dense heads where ice falls out) sit
// along the strokes. Ice scatters strongly forward, and at this height the sun sets last, so cirrus is the last
// cloud to glow gold and pink at dusk.

float cirrusFlowAngle(vec2 p) {
    return 0.38 + (cloudTex(vec3(p / 26000.0, 0.2)).g - 0.5) * 2.2 + (valueNoise(p / 7000.0 + 3.1) - 0.5) * 0.9;
}

float cirrusDensity(vec2 p, float h, CloudWeather w, float dist) {
    float patchN = cloudTex(vec3(p / 17000.0, 0.9)).r;
    float patch = saturate((patchN - 0.66 + w.cirrus * 0.34) / 0.16);
    if (patch <= 0.0) return 0.0;
    float a = cirrusFlowAngle(p);
    vec2 dir = vec2(cos(a), sin(a));
    vec2 q = vec2(dot(p, dir), dot(p, vec2(-dir.y, dir.x)));
    // Fibres: very stretched noise, three octaves; the fine ones fade out with distance to avoid shimmer.
    float fineFade = 1.0 - smoothstep(5000.0, 22000.0, dist);
    // Crosswise warp: without it the stretched noise formed evenly spaced contour lines (wood grain).
    q.y += (valueNoise(q / 1600.0 + 2.9) - 0.5) * 420.0 + (valueNoise(q / 520.0 + 8.3) - 0.5) * 90.0;
    float fib = valueNoise(vec2(q.x / 5200.0, q.y / 110.0 + h * 0.6)) * 0.55
              + mix(0.5, valueNoise(vec2(q.x / 2300.0, q.y / 42.0) + 7.7), fineFade) * 0.3
              + mix(0.5, valueNoise(vec2(q.x / 900.0, q.y / 17.0) + 19.1), fineFade) * 0.15;
    // Strokes: long bands that start and end, brightest at their tufted heads.
    float stroke = smoothstep(0.38, 0.72, valueNoise(vec2(q.x / 7000.0, q.y / 900.0) + 5.3));
    // Strands start and stop along their length, so the sky shows separate wisps rather than continuous lines.
    stroke *= smoothstep(0.3, 0.7, valueNoise(vec2(q.x / 1900.0, q.y / 260.0) + 1.7));
    float tuft = smoothstep(0.55, 0.85, valueNoise(p / 2400.0 + 11.0));
    float d = sqrt(saturate((fib - 0.48) / 0.3)) * stroke * (0.45 + 0.9 * tuft);
    return d * patch;
}

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
    t1 = min(t1, min(t0 + 600.0, maxDist));
    if (t1 <= t0) return vec4(0.0, 0.0, 0.0, 1.0);
    const int N = 3;
    float stepLen = (t1 - t0) / float(N);
    float trans = 1.0, dSum = 0.0, wSum = 0.0;
    vec3 rad = vec3(0.0);
    vec3 wind = cloudWind() * 4.0;
    float mu = dot(rd, lightDir);
    // Ice: a strong forward lobe and a faint back lobe.
    float phase = 0.55 * hgPhase(mu, 0.7) + 0.2 * hgPhase(mu, -0.2) + 0.25 / (4.0 * PI);
    for (int i = 0; i < N; i++) {
        float t = t0 + (float(i) + dither) * stepLen;
        vec3 sp = ro + rd * t;
        float h = saturate((sp.y - bottom) / L2_THICK);
        float d = cirrusDensity(sp.xz + wind.xz, h, w, t) * smoothstep(0.0, 0.2, h) * (1.0 - smoothstep(0.75, 1.0, h));
        if (d <= 0.0) continue;
        float T = exp(-d * 0.0024 * stepLen);
        vec3 s = (directLight * phase * 1.6 + skyLight * (0.4 / (4.0 * PI))) * (1.0 - T);
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
// lightDirHi/directLight1/directLight2 light the altocumulus and cirrus: higher clouds keep the sun after it has set
// for the cumulus below them, so at dusk each layer takes its own point on the sunset palette.
vec4 renderClouds(vec3 ro, vec3 rd, float maxDist, vec3 sunDir, vec3 lightDir, vec3 directLight,
                  vec3 lightDirHi, vec3 directLight1, vec3 directLight2, vec3 skyLight, float dither, out float dist) {
    CloudWeather w = cloudWeather();
    // Ground bounce: land reflects a warm, slightly green share of the direct light back up at cloud bases.
    vec3 groundLight = directLight * max(lightDir.y, 0.0) * vec3(0.14, 0.14, 0.12) + skyLight * 0.05;
    float d0, d1 = 1e6, d2 = 1e6;
    vec4 c0 = marchL0(ro, rd, maxDist, w, lightDir, directLight, skyLight, groundLight, dither, d0);
    vec4 c1 = marchL1(ro, rd, maxDist, w, lightDirHi, directLight1, skyLight, dither, d1);
    vec4 c2 = cirrus(ro, rd, maxDist, w, lightDirHi, directLight2, skyLight, dither, d2);
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

// Mist around a camera inside the cumulus volume, for the near field the cloud march cannot resolve. Returns the
// cloud density averaged over the eye position and a few points along the view ray (x) and the transmittance of
// the light toward the camera through the cloud above it (y).
vec2 cloudMistAt(vec3 camPos, vec3 rd, vec3 lightDir, CloudWeather w) {
    float d = l0Density(camPos, w, 1) * 0.4
            + l0Density(camPos + rd * 5.0, w, 1) * 0.3
            + l0Density(camPos + rd * 16.0, w, 1) * 0.3;
    if (d <= 0.002) return vec2(0.0, 1.0);
    float od = l0Density(camPos + lightDir * 14.0, w, 2) * 20.0
             + l0Density(camPos + lightDir * 40.0, w, 2) * 35.0
             + l0Density(camPos + lightDir * 95.0, w, 2) * 70.0;
    return vec2(d, exp(-od * 0.07 * 0.6));
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
