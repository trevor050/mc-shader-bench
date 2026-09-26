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
#define L1_THICK 260.0        // deep enough for lumpy, pendulous undersides with real relief
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

// Sunlight by altitude. Near sunset a cloud's colour depends on its height: the sun sets later the higher you are, so
// the Earth's shadow climbs a tall cloud from its base, leaving grey-lavender bases under still-pink tops. renderClouds
// sets the light of the altocumulus level here; cumulus samples blend toward it with height.
vec3 gLightAlto = vec3(0.0);
bool gAltitudeLight = false;
vec3 cloudSunAt(float y, vec3 base) {
    if (!gAltitudeLight) return base;
    return mix(base, gLightAlto, smoothstep(180.0, L1_ALT, y));
}

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
                                  cloudSunAt(p.y, directLight), skyLight, groundLight);
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

// ---- Cloud decks: authored styles on one volumetric model ----
// Stratiform and layered clouds (altocumulus, altostratus veils, ragged fractus under a storm shield) share one model,
// configured per deck by a DeckStyle. Studied against the 2026-09-25 New York / New Jersey sunset photos, which show
// what the model must produce:
//  - true 3D forms: lobes and curls whose outline changes with height (a cloud's top is not its base shifted up), so
//    all shape and erosion noise is sampled in 3D, never as a 2D texture with a height profile;
//  - thick parts that hang lower and bulge higher than thin parts (pendulous, lit undersides at sunset);
//  - hard, detailed, torn edges on the lower decks and soft ones on the high veil;
//  - several decks at distinct heights, so the bright lower clouds stand against a darker veil above them.

struct DeckStyle {
    float alt;      // base altitude (blocks)
    float thick;    // depth of the layer
    float cov;      // coverage, 0..1
    float scale;    // size of the large forms (blocks)
    float stretch;  // elongation along the wind
    float warp;     // domain warp (blocks): swirls and bends
    float sharp;    // 0 = soft edges, 1 = hard edges
    float lumps;    // strength of the 3D billow erosion (rounded lobes)
    float wisp;     // strength of fibrous, torn edge erosion
    float sigma;    // extinction per unit density per block
    float seed;
};

// The camera, for presets that anchor a frontal edge relative to it (set by renderClouds).
vec3 gCloudCamera = vec3(0.0);

float deckDensity(vec3 p, DeckStyle s, float dist, int lod) {
    float h = (p.y - s.alt) / s.thick;
    if (h <= 0.0 || h >= 1.0 || s.cov <= 0.01) return 0.0;
    vec2 xz = p.xz + cloudWind().xz * 1.6;
    // Where the deck exists: very broad patches, so even a full-sky deck has thinner and thicker regions.
    float cov = s.cov * mix(0.55, 1.15, cloudTex(vec3(xz / 26000.0, 0.13 + s.seed)).r);
    // Mid-scale structure: thick bands and broad holes a few kilometres across, through which the deck above shows.
    vec4 mid = cloudTex(vec3(xz / (s.scale * 7.0), 0.59 + s.seed));
    cov *= mix(0.25, 1.35, smoothstep(0.25, 0.7, mid.r * 0.7 + mid.g * 0.3));
#if SKY_PRESET == 1
    // Storm shield: the deck ends some kilometres west of the observer, leaving the western horizon clear so the
    // setting sun lights the whole shield from underneath.
    cov *= smoothstep(-9000.0, -4500.0, p.x - gCloudCamera.x);
#endif
    const vec2 dir = vec2(0.82, 0.57);
    vec4 wn = cloudTex(vec3(xz / (s.scale * 2.7), 0.37 + s.seed));
    vec2 wxz = xz + (wn.gb - 0.5) * s.warp;
    vec2 q = vec2(dot(wxz, dir) / s.stretch, dot(wxz, vec2(-dir.y, dir.x)));
    float y = p.y;
    // Large forms, in 3D.
    float n = cloudTex(vec3(q.x, y * 0.8, q.y) / s.scale + s.seed).r * 0.58
            + cloudTex(vec3(q.x, y, q.y) / (s.scale * 0.34) + s.seed * 2.0).r * 0.28;
    float fdist = 1.0 - smoothstep(6000.0, 20000.0, dist);
    n += mix(0.5, cloudTex(vec3(q.x, y, q.y) / (s.scale * 0.11) + 0.5).g, fdist) * 0.14;
    float soft = mix(0.24, 0.07, s.sharp);
    float d0 = saturate((n - (0.8 - cov * 0.52)) / soft);
    if (d0 <= 0.0) return 0.0;
    // Thick parts reach lower and higher: pendulous undersides, domed tops.
    float base = mix(0.55, 0.04, d0);
    float top = mix(0.58, 1.0, d0);
    float d = d0 * smoothstep(base, base + 0.1, h) * (1.0 - smoothstep(top - 0.12, top, h));
    if (d <= 0.0 || lod >= 2) return d;
    // Rounded lobes: inverted Worley (high at puff centres) in 3D eats the edges into cauliflower billows.
    vec4 e = cloudTex(vec3(q.x, y, q.y) / (s.scale * 0.32) + s.seed * 3.0);
    float billow = e.g * 0.62 + e.b * 0.38;
    d = saturate(remap(d, (1.0 - billow) * s.lumps * fdist, 1.0, 0.0, 1.0));
    if (lod == 0 && d > 0.0 && s.wisp > 0.0) {
        // Torn, fibrous edges: fine noise stretched along the wind and squashed vertically.
        vec4 f = cloudTex(vec3(q.x / (s.scale * 0.3), y / (s.scale * 0.06), q.y / (s.scale * 0.05)) + 0.7);
        float fib = f.g * 0.6 + f.b * 0.4;
        d = saturate(remap(d, fib * s.wisp * (1.0 - d) * fdist, 1.0, 0.0, 1.0));
    }
    return d;
}

vec4 marchDeck(vec3 ro, vec3 rd, float maxDist, DeckStyle s, vec3 lightDir, vec3 directLight, vec3 skyLight,
               float dither, bool iridescent, out float dist) {
    dist = 1e6;
    if (s.cov < 0.02) return vec4(0.0, 0.0, 0.0, 1.0);
    float top = s.alt + s.thick;
    float t0, t1;
    if (abs(rd.y) < 1e-4) {
        if (ro.y < s.alt || ro.y > top) return vec4(0.0, 0.0, 0.0, 1.0);
        t0 = 0.0;
        t1 = min(maxDist, 1200.0);
    } else {
        float ta = (s.alt - ro.y) / rd.y, tb = (top - ro.y) / rd.y;
        t0 = max(min(ta, tb), 0.0);
        t1 = max(ta, tb);
    }
    if (t1 <= t0 || t0 >= maxDist || t0 > 45000.0) return vec4(0.0, 0.0, 0.0, 1.0);
    t1 = min(t1, min(t0 + 1200.0, maxDist));
    if (t1 <= t0) return vec4(0.0, 0.0, 0.0, 1.0);
    float mu = dot(rd, lightDir);
    const int N = 14;
    float stepLen = (t1 - t0) / float(N);
    vec3 rad = vec3(0.0);
    float trans = 1.0, dSum = 0.0, wSum = 0.0;
    int lod = t0 < 6000.0 ? 0 : 1;
    float lowSun = 1.0 - smoothstep(0.0, 0.25, lightDir.y);
    // Thin decks keep much of their single-scattering directionality at a low sun: they blaze toward it, and off to
    // the side the lavender skylight takes over.
    float dirW = mix(1.0, mix(0.45, 2.1, sqr(mu * 0.5 + 0.5)), lowSun);
    for (int i = 0; i < N; i++) {
        if (trans < 0.03) break;
        float t = t0 + (float(i) + dither) * stepLen;
        vec3 p = ro + rd * t;
        float d = deckDensity(p, s, t, lod);
        if (d <= 0.004) continue;
        // Self-shadowing toward the light, through the deck's own lobes: lit faces and shaded crevices.
        float lightOD = deckDensity(p + lightDir * 7.0, s, t, 1) * 10.0
                      + deckDensity(p + lightDir * 22.0, s, t, 1) * 22.0
                      + deckDensity(p + lightDir * 60.0, s, t, 2) * 45.0;
        lightOD *= 2.8;
        float skyOD = d * (top - p.y) * 0.7;
        float powder = mix(PI * d / (d + 0.2), 1.0, 0.75 * sqr(mu * 0.5 + 0.5));
        vec3 sc = cloudScatter(lightOD * s.sigma, skyOD * s.sigma, 0.0, mu, powder,
                                 (p.y < L1_ALT ? cloudSunAt(p.y, directLight) : directLight) * dirW, skyLight, vec3(0.0));
        if (iridescent) {
            // Near the sun, the thin rims (small, uniform droplets) diffract light into faint pastel bands.
            float fromSun = acos(clamp(mu, -1.0, 1.0));
            if (fromSun < 0.38) {
                float rim = 1.0 - smoothstep(0.05, 0.4, d);
                vec3 bands = 0.5 + 0.5 * cos(TAU * (d * 2.5 + fromSun * 7.0) + vec3(0.0, 2.1, 4.2));
                sc *= mix(vec3(1.0), bands * 1.7, rim * (1.0 - fromSun / 0.38) * 0.45 * CLOUD_IRIDESCENCE);
            }
        }
        float stepT = exp(-d * s.sigma * stepLen);
        float weight = trans * (1.0 - stepT);
        rad += sc * weight;
        dSum += t * weight;
        wSum += weight;
        trans *= stepT;
    }
    if (wSum > 0.0) dist = dSum / wSum;
    float fade = 1.0 - smoothstep(25000.0, 45000.0, t0);
    return vec4(rad * fade, mix(1.0, trans, fade));
}

// ---- The decks ----
// Weather decides how much of each there is; SKY_PRESET (settings.glsl) can force a designed sky.

float weatherClock() { return float(worldDay) + float(worldTime) / 24000.0; }

// Altocumulus: lumpy mid-level deck, from broken rafts to a sky-filling sheet.
DeckStyle altoStyle(CloudWeather w) {
    return DeckStyle(L1_ALT, L1_THICK, w.cov1, 800.0, 1.6, 320.0, 0.5, 0.45, 0.18, 0.035, 0.0);
}

// Altostratus veil: a high, smooth, thick sheet, the dim ceiling that lower lit clouds stand against.
float veilAmount(CloudWeather w) {
#if SKY_PRESET == 1
    return 0.85;
#elif SKY_PRESET >= 2
    return 0.0;
#else
    return smoothstep(0.55, 0.85, noise1(weatherClock() * 0.9 + 301.0)) * mix(0.8, 1.0, rainStrength);
#endif
}
DeckStyle veilStyle(CloudWeather w) {
    return DeckStyle(1850.0, 380.0, veilAmount(w), 2600.0, 2.6, 900.0, 0.1, 0.18, 0.25, 0.014, 0.41);
}

// Fractus: ragged, torn low cloud with hard lit edges (under a storm shield, and on grey days).
float fractusAmount(CloudWeather w) {
#if SKY_PRESET == 1
    return 0.6;
#elif SKY_PRESET >= 2
    return 0.0;
#else
    return smoothstep(0.6, 0.9, noise1(weatherClock() * 1.3 + 331.0)) * 0.6 + rainStrength * 0.3;
#endif
}
DeckStyle fractusStyle(CloudWeather w) {
    return DeckStyle(560.0, 200.0, fractusAmount(w), 380.0, 2.2, 260.0, 0.8, 0.6, 0.8, 0.05, 0.73);
}

// Compatibility for virga, the cloud dome and anything else that samples "the altocumulus".
float altocumulusDensity(vec3 p, CloudWeather w, float dist, int lod) {
    return deckDensity(p, altoStyle(w), dist, lod);
}

vec4 marchL1(vec3 ro, vec3 rd, float maxDist, CloudWeather w, vec3 lightDir, vec3 directLight,
             vec3 skyLight, float dither, out float dist) {
    return marchDeck(ro, rd, maxDist, altoStyle(w), lightDir, directLight, skyLight, dither, true, dist);
}

// ---- Virga: fallstreaks under the altocumulus ----
// On some evenings the mid-level deck drops rain or ice that evaporates in dry air before reaching the ground: grey
// curtains hanging a few hundred blocks under the cloud, bent into hooks by the wind shear (the falling streak lags
// behind the cloud that dropped it, more the further it has fallen), thinning out as it evaporates. At a low sun they
// glow like the cloud above them, and they are what a rainbow can stand in on a day when no rain reaches the ground.

#define VIRGA_DEPTH 460.0

// How much of the altocumulus is precipitating today, 0..1 (drifts with the weather clock).
float virgaAmount(CloudWeather w) {
#ifdef CLOUD_DEBUG_ALTO
    return w.cov1;
#endif
    float t = float(worldDay) + float(worldTime) / 24000.0;
    return w.cov1 * smoothstep(0.45, 0.8, noise1(t * 1.4 + 211.0)) * (1.0 - rainStrength * 0.5);
}

float virgaDensity(vec3 p, CloudWeather w, float amount) {
    float below = L1_ALT - p.y;
    if (below <= 0.0 || below >= VIRGA_DEPTH) return 0.0;
    float fall = below / VIRGA_DEPTH;
    // Shear: the streak trails downwind of its source, increasingly with depth, so it curves.
    const vec2 shearDir = vec2(-0.82, -0.57);
    vec2 src = p.xz + shearDir * (below * 0.55 + below * below * 0.0012);
    // Only thick parts of the deck precipitate, in patches.
    float parent = altocumulusDensity(vec3(src.x, L1_ALT + 18.0, src.y), w, 1e5, 1);
    float patchN = cloudTex(vec3((src + cloudWind().xz * 1.6) / 5200.0, 0.73)).g;
    float source = parent * smoothstep(0.5, 0.75, patchN) * amount;
    if (source <= 0.0) return 0.0;
    // Vertical streaks, finer than the parent cells.
    vec2 q = src + cloudWind().xz * 1.6;
    float streak = valueNoise(vec2(q.x / 9.0 + q.y / 23.0, fall * 1.5)) * 0.6 + valueNoise(q / 31.0 + 4.4) * 0.4;
    return source * smoothstep(0.35, 0.75, streak) * (1.0 - smoothstep(0.35, 1.0, fall)) * smoothstep(0.0, 0.06, fall);
}

vec4 marchVirga(vec3 ro, vec3 rd, float maxDist, CloudWeather w, vec3 lightDir, vec3 directLight,
                vec3 skyLight, float dither, out float dist) {
    dist = 1e6;
    float amount = virgaAmount(w);
    if (amount < 0.02 || abs(rd.y) < 1e-4) return vec4(0.0, 0.0, 0.0, 1.0);
    float bottom = L1_ALT - VIRGA_DEPTH;
    float ta = (bottom - ro.y) / rd.y, tb = (L1_ALT - ro.y) / rd.y;
    float t0 = max(min(ta, tb), 0.0), t1 = min(max(ta, tb), min(maxDist, t0 + 1500.0));
    if (t1 <= t0 || t0 > 30000.0) return vec4(0.0, 0.0, 0.0, 1.0);
    const int N = 8;
    float stepLen = (t1 - t0) / float(N);
    float mu = dot(rd, lightDir);
    // Drops and ice scatter mostly forward.
    float phase = 0.6 * hgPhase(mu, 0.6) + 0.4 / (4.0 * PI);
    vec3 rad = vec3(0.0);
    float trans = 1.0, dSum = 0.0, wSum = 0.0;
    for (int i = 0; i < N; i++) {
        float t = t0 + (float(i) + dither) * stepLen;
        vec3 p = ro + rd * t;
        float d = virgaDensity(p, w, amount);
        if (d <= 0.0) continue;
        float T = exp(-d * 0.006 * stepLen);
        vec3 s = (cloudSunAt(p.y, directLight) * phase * 1.3 + skyLight * (0.5 / (4.0 * PI))) * (1.0 - T);
        float weight = trans * (1.0 - T);
        rad += trans * s;
        dSum += t * weight;
        wSum += weight;
        trans *= T;
    }
    if (wSum > 0.0) dist = dSum / wSum;
    float fade = 1.0 - smoothstep(15000.0, 30000.0, t0);
    return vec4(rad * fade, mix(1.0, trans, fade));
}

// Virga along a view ray (optical depth, a few taps), for the rainbow.
float virgaColumn(vec3 ro, vec3 rd, CloudWeather w) {
    float amount = virgaAmount(w);
    if (amount < 0.02 || rd.y < 0.01) return 0.0;
    float bottom = L1_ALT - VIRGA_DEPTH;
    float t0 = max((bottom - ro.y) / rd.y, 0.0), t1 = (L1_ALT - ro.y) / rd.y;
    if (t1 <= t0) return 0.0;
    float od = 0.0;
    for (int i = 0; i < 4; i++) {
        float t = mix(t0, t1, (float(i) + 0.5) / 4.0);
        od += virgaDensity(ro + rd * t, w, amount);
    }
    return od * (t1 - t0) / 4.0 * 0.006;
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
    gCloudCamera = ro;
    // Altitude-dependent sunlight only when every layer is lit from the same direction (the sun, near sunset).
    gAltitudeLight = dot(lightDir, lightDirHi) > 0.9999;
    gLightAlto = directLight1;
    // Ground bounce: land reflects a warm, slightly green share of the direct light back up at cloud bases.
    vec3 groundLight = directLight * max(lightDir.y, 0.0) * vec3(0.14, 0.14, 0.12) + skyLight * 0.05;
    float d0, d1 = 1e6, d2 = 1e6;
    vec4 c0 = marchL0(ro, rd, maxDist, w, lightDir, directLight, skyLight, groundLight, dither, d0);
    vec4 c1 = marchL1(ro, rd, maxDist, w, lightDirHi, directLight1, skyLight, dither, d1);
    vec4 c2 = cirrus(ro, rd, maxDist, w, lightDirHi, directLight2, skyLight, dither, d2);
    float dv = 1e6;
    vec4 cv = marchVirga(ro, rd, maxDist, w, lightDirHi, directLight, skyLight, dither, dv);
    // Veil above the altocumulus and ragged fractus below it.
    float dVeil = 1e6, dFrac = 1e6;
    vec4 cVeil = marchDeck(ro, rd, maxDist, veilStyle(w), lightDirHi, directLight2, skyLight, dither, false, dVeil);
    vec4 cFrac = marchDeck(ro, rd, maxDist, fractusStyle(w), lightDir, directLight, skyLight, dither, false, dFrac);
    // Thin ice cloud all but disappears by moonlight; keep it from smearing grey over the stars.
    float cirrusDaylight = smoothstep(-0.1, 0.05, sunDir.y);
    c2 = mix(vec4(0.0, 0.0, 0.0, 1.0), c2, cirrusDaylight);
    if (cirrusDaylight < 0.001) d2 = 1e6;
    float d01;
    vec4 c = mergeClouds(c0, d0, c1, d1, d01);
    float d012;
    c = mergeClouds(c, d01, c2, d2, d012);
    float d0123, d01234;
    c = mergeClouds(c, d012, cv, dv, d0123);
    c = mergeClouds(c, d0123, cVeil, dVeil, d01234);
    c = mergeClouds(c, d01234, cFrac, dFrac, dist);
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
