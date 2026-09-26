// Night-time sky and air effects. Requires common/settings, cloud weather uniforms,
// cameraPosition. Aurora geometry is in kilometres, in a north-facing magnetic frame.

#ifndef MOON_PHASE_UNIFORM
#define MOON_PHASE_UNIFORM
uniform int moonPhase;
#endif

// Integer avalanche: stable on shader reload, across biomes, and across the midnight tick.
float auroraNightRoll(int day) {
    uint x = uint(day) ^ 0xa511e9b3u;
    x ^= x >> 16u; x *= 0x7feb352du;
    x ^= x >> 15u; x *= 0x846ca68bu;
    x ^= x >> 16u;
    return float(x >> 8u) * (1.0 / 16777216.0);
}

float auroraNightActive(int day) {
    // p(1-p) = 0.10. A veto by yesterday's proposal prevents back-to-back displays
    // without a save file or stateful mod. worldDay advances at dawn, not midnight.
    const float proposal = 0.1127016654;
    return auroraNightRoll(day) < proposal && auroraNightRoll(day - 1) >= proposal ? 1.0 : 0.0;
}

float auroraVisibility(float sunHeight) {
    float dark = 1.0 - smoothstep(-0.32, -0.08, sunHeight);
    #if AURORA_MODE == 1
    float event = inSnowy;
#elif AURORA_MODE == 2
    float event = inSnowy * (moonPhase == 0 ? 1.0 : 0.0);
#elif AURORA_MODE == 4
    float event = 1.0;
#else
    float event = auroraNightActive(worldDay);
#endif
    return AURORA * event * dark * dark * (1.0 - rainStrength);
}

// Height shell intersection on a 6371 km sphere. Rationalized to retain precision
// near zenith; unlike rd.xz/rd.y, it stays finite at the horizon.
float auroraShell(vec3 rd, float h) {
    float b = 6371.0 * rd.y;
    float c = h * (12742.0 + h);
    return c / (sqrt(b * b + c) + b);
}

// Smooth sheets with a bounded spatial slope. Every visible curtain has a
// unique ray crossing, so three roots can be solved together without a march.
vec3 auroraField(vec3 s, vec3 rd, vec2 observer, float phase, float seed,
                 out vec3 derivative, out vec3 curvature, out vec3 h, out vec3 x) {
    vec3 radius = sqrt(vec3(6371.0 * 6371.0) + s * (12742.0 * rd.y + s));
    h = s * (12742.0 * rd.y + s) / (radius + 6371.0);
    vec3 dh = (6371.0 * rd.y + s) / radius;
    vec3 ddh = (6371.0 * 6371.0) * (1.0 - rd.y * rd.y) / (radius * radius * radius);
    x = s * rd.x + observer.x - 0.10 * h;
    vec3 z = s * rd.z + observer.y + 0.16 * h;
    vec3 offset = vec3(0.0, 2.17, 4.61) + seed;
    vec3 bend = x * 0.0036 + offset + sin(phase * 5.0) * 0.35;
    vec3 ripple = x * 0.0075 + offset * 1.7 - phase * 11.0;
    vec3 fold = sin(bend) * vec3(42.0, 60.0, 76.0) + sin(ripple) * vec3(5.0, 7.0, 9.0);
    vec3 slope = cos(bend) * vec3(0.1512, 0.216, 0.2736) + cos(ripple) * vec3(0.0375, 0.0525, 0.0675);
    vec3 dSlope = -sin(bend) * vec3(0.00054432, 0.0007776, 0.00098496)
                 -sin(ripple) * vec3(0.00028125, 0.00039375, 0.00050625);
    vec3 dx = rd.x - 0.10 * dh;
    derivative = rd.z + 0.16 * dh - slope * dx;
    curvature = (0.16 + 0.10 * slope) * ddh - dSlope * dx * dx;
    return z - (vec3(-155.0, -285.0, -445.0) + fold);
}

// Normal CDF, used to integrate a finite-width Gaussian sheet analytically.
// Partial crossings at bracket/altitude boundaries remain continuous.
vec3 auroraGaussianCDF(vec3 x) {
    vec3 a = abs(x) * 0.70710678118;
    vec3 k = 1.0 / (1.0 + 0.3275911 * a);
    vec3 polynomial = (((((1.061405429 * k - 1.453152027) * k)
                        + 1.421413741) * k - 0.284496736) * k + 0.254829592) * k;
    return 0.5 + 0.5 * sign(x) * (1.0 - polynomial * exp(-a * a));
}

// Radiance is evaluated at each sheet's actual continuous footpoint.
vec3 auroraEmission(vec3 column, vec3 h, vec3 x, float phase, float seed) {
    vec3 offset = vec3(0.0, 2.17, 4.61) + seed;
    float drift = 2.1 * sin(phase * 23.0 + seed) + 0.8 * sin(phase * 61.0);
    vec3 coarse, activity;
    for (int j = 0; j < 3; ++j) {
#if NIGHT_DETAIL_QUALITY == 0
        coarse[j] = valueNoise(vec2(x[j] * 0.010 + drift * 0.07, offset[j] + sin(phase * 7.0)));
        activity[j] = 0.65;
#else
        // A slow, irregular warp gives each billow a different width. There is
        // no fine-frequency comb underneath the luminous cloth-like sheet.
        float flow = valueNoise(vec2(x[j] * 0.0037 + drift * 0.025, offset[j] * 4.1));
        coarse[j] = valueNoise(vec2(x[j] * 0.010 + 1.6 * flow + drift * 0.07,
                                    offset[j] + sin(phase * 7.0)));
        activity[j] = valueNoise(vec2(x[j] * 0.006 + sin(phase * 3.0), offset[j] + 0.2));
#endif
    }
    // Continuous emission with broad uneven billows, no narrow parallel pickets.
    vec3 rays = 0.42 + 0.50 * coarse;
    vec3 activityPatch = 0.10 + 0.90 * smoothstep(vec3(0.18), vec3(0.82), activity);
    vec3 surge = 0.78 + 0.22 * sin(phase * 31.0 + x * 0.008 + offset);
    vec3 edge = 1.0 - smoothstep(vec3(380.0), vec3(780.0), abs(x));
    vec3 lip = 103.0 + 10.0 * coarse + 3.0 * sin(x * 0.022 + phase * 11.0 + offset);
    vec3 green = smoothstep(lip - 7.0, lip + 8.0, h)
               * exp(-max(h - lip - 8.0, 0.0) / (23.0 + 54.0 * coarse));
    vec3 red = exp(-((h - 220.0) / 58.0) * ((h - 220.0) / 58.0)) * 0.12
             * (1.0 - smoothstep(vec3(270.0), vec3(320.0), h));
    vec3 violet = exp(-((h - 104.0) / 7.0) * ((h - 104.0) / 7.0)) * 0.035;
    vec3 energy = column * vec3(1.0, 0.74, 0.48) * rays * activityPatch * surge * edge;
    return vec3(0.13, 1.0, 0.34) * dot(energy, green)
         + vec3(1.0, 0.055, 0.075) * dot(energy, red)
         + vec3(0.32, 0.09, 0.65) * dot(energy, violet);
}

vec3 aurora(vec3 rd, float t) {
    if (rd.y <= 0.0 || rd.z > -0.08) return vec3(0.0);
    const vec3 WIDTH = vec3(2.4, 3.1, 3.8);
    float phase = t * (TAU / 3600.0);
    float seed = auroraNightRoll(worldDay + 7919) * TAU;
    float strength = mix(0.65, 1.2, auroraNightRoll(worldDay + 104729));
    vec2 observer = 20.0 * sin(cameraPosition.xz * (0.001 / 200.0));
    float nearS = auroraShell(rd, 94.0), farS = auroraShell(rd, 320.0);
    float dhNear = (6371.0 * rd.y + nearS) / 6465.0;
    float dhFar = (6371.0 * rd.y + farS) / 6691.0;
    float dxBound = max(abs(rd.x - 0.10 * dhNear), abs(rd.x - 0.10 * dhFar));
    // The maximum fold slopes are proven from the two sinusoid amplitudes.
    // Fade only directions where a sheet could turn back along the ray.
    vec3 upperDerivative = rd.z + 0.16 * dhFar + vec3(0.1887, 0.2685, 0.3411) * dxBound;
    vec3 monotone = smoothstep(vec3(0.025), vec3(0.10), -upperDerivative);
    if (dot(monotone, vec3(1.0)) < 0.0001) return vec3(0.0);
    vec3 root = vec3(155.0, 285.0, 445.0) / max(-(rd.z + 0.16 * rd.y), 0.04);
    vec3 dr, cr, h, x, fr;
#if NIGHT_DETAIL_QUALITY == 0
    const int AURORA_REFINEMENTS = 2;
#else
    const int AURORA_REFINEMENTS = 4;
#endif
    for (int refine = 0; refine < AURORA_REFINEMENTS; ++refine) {
        fr = auroraField(root, rd, observer, phase, seed, dr, cr, h, x);
        root = clamp(root - fr / min(dr, vec3(-0.025)), 0.0, 5000.0);
    }
    fr = auroraField(root, rd, observer, phase, seed, dr, cr, h, x);
    vec3 opticalSlope = sqrt(dr * dr + WIDTH * abs(cr) * 0.03 + 0.00001);
    vec3 column = (auroraGaussianCDF((farS - root) * opticalSlope / WIDTH)
                 -auroraGaussianCDF((nearS - root) * opticalSlope / WIDTH))
                * (2.50662827463 * WIDTH / opticalSlope);
    column *= monotone * exp(-0.5 * (fr / WIDTH) * (fr / WIDTH));
    if (dot(column, vec3(1.0)) < 0.0001) return vec3(0.0);
    vec3 acc = auroraEmission(column, h, x, phase, seed);
    acc *= AURORA_BRIGHTNESS * 0.45 * strength;
    acc /= 1.0 + luminance(acc) / 1.1;
    float air = exp(-0.12 / max(rd.y + 0.025, 0.025));
    return acc * air * smoothstep(0.0, 0.045, rd.y);
}

// Fireflies: soft yellow-green points drifting a block or two above the ground near the camera, blinking on and off.
// An exact 3D DDA over 3-block cells along the view ray; a few cells hold one firefly each. Cells are limited to a
// band around the camera's feet (there is no height map to put them over the ground elsewhere).
vec3 fireflies(vec3 camPos, vec3 rd, float maxDist, float t) {
    const float CELL = 3.0;
    const int STEPS = 28;
    vec3 ro = camPos / CELL;
    vec3 cell = floor(ro);
    vec3 stepDir = sign(rd);
    vec3 tDelta = abs(1.0 / max(abs(rd), vec3(1e-4)));
    vec3 tMax = (stepDir * (cell - ro) + stepDir * 0.5 + 0.5) * tDelta;
    vec3 acc = vec3(0.0);
    float limit = min(maxDist, 42.0) / CELL;
    float yLo = floor((camPos.y - 5.0) / CELL), yHi = floor((camPos.y + 1.5) / CELL);
    for (int i = 0; i < STEPS; i++) {
        float tCell = min(tMax.x, min(tMax.y, tMax.z));
        if (cell.y >= yLo && cell.y <= yHi) {
            float h = hash12(cell.xz * 0.917 + cell.y * 2.131 + 5.3);
            if (h > 0.72) {
                float h2 = hash12(cell.zy * 1.73 + 8.1), h3 = hash12(cell.xy * 2.57 + 1.9);
                vec3 m = cell + vec3(h2, fract(h * 5.7), h3) * 0.7 + 0.15;
                // Lazy looping flight.
                m += vec3(sin(t * 0.31 + h * 30.0), 0.6 * sin(t * 0.47 + h2 * 30.0), cos(t * 0.27 + h3 * 30.0)) * 0.22;
                vec3 d = m - ro;
                float along = dot(d, rd);
                if (along > 0.05 && along < limit) {
                    float perp2 = max(dot(d, d) - along * along, 0.0);
                    // Blink: on for about a second and a half, dark for a few seconds.
                    float cycle = fract(t / (3.5 + 2.0 * h3) + h2);
                    float blink = smoothstep(0.0, 0.12, cycle) * smoothstep(0.42, 0.25, cycle);
                    // A tight core and a faint soft halo (the halo keeps distant ones from aliasing to nothing).
                    const float r = 0.014;
                    float glow = exp(-perp2 / (r * r)) + 0.06 * exp(-perp2 / (r * r * 30.0));
                    acc += vec3(0.75, 1.0, 0.22) * glow * blink * smoothstep(limit, limit * 0.55, along);
                }
            }
        }
        if (tCell > limit) break;
        if (tMax.x < tMax.y && tMax.x < tMax.z) { cell.x += stepDir.x; tMax.x += tDelta.x; }
        else if (tMax.y < tMax.z) { cell.y += stepDir.y; tMax.y += tDelta.y; }
        else { cell.z += stepDir.z; tMax.z += tDelta.z; }
    }
    return acc;
}
