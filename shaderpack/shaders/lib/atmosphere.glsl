// Single-scattering Rayleigh/Mie atmosphere, procedural clouds, and stars.
// Requires: common.glsl, settings.glsl, uniforms frameTimeCounter, rainStrength.

const float ATM_GROUND = 6360e3;
const float ATM_TOP = 6420e3;
const vec3 BETA_R = vec3(5.8e-6, 13.5e-6, 33.1e-6);
const vec3 BETA_M = vec3(9e-6);
const vec3 BETA_OZONE = vec3(0.65e-6, 1.88e-6, 0.085e-6);
const float H_R = 8000.0;
const float H_M = 1200.0;
const float MIE_G = 0.78;

vec2 raySphere(vec3 ro, vec3 rd, float radius) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - radius * radius;
    float d = b * b - c;
    if (d < 0.0) return vec2(-1.0);
    d = sqrt(d);
    return vec2(-b - d, -b + d);
}

float phaseRayleigh(float mu) { return 3.0 / (16.0 * PI) * (1.0 + mu * mu); }

float phaseMie(float mu, float g) {
    float g2 = g * g;
    return 3.0 / (8.0 * PI) * ((1.0 - g2) * (1.0 + mu * mu)) / ((2.0 + g2) * pow(1.0 + g2 - 2.0 * g * mu, 1.5));
}

vec3 extinction(vec2 od) {
    return exp(-(BETA_R * od.x + BETA_M * 1.11 * od.y + BETA_OZONE * od.x * 1.6));
}

// Optical depth (rayleigh, mie) from a point toward the light, 4 samples.
vec2 lightOpticalDepth(vec3 p, vec3 dir) {
    float len = raySphere(p, dir, ATM_TOP).y;
    float stepLen = len / 4.0;
    vec2 od = vec2(0.0);
    for (int i = 0; i < 4; i++) {
        vec3 q = p + dir * (float(i) + 0.5) * stepLen;
        float h = max(length(q) - ATM_GROUND, 0.0);
        od += exp(-h / vec2(H_R, H_M)) * stepLen;
    }
    return od;
}

// Transmittance of sunlight reaching the ground-level viewer.
vec3 sunTransmittance(vec3 lightDir) {
    vec3 ro = vec3(0.0, ATM_GROUND + 200.0, 0.0);
    lightDir.y = max(lightDir.y, -0.08);
    if (raySphere(ro, normalize(lightDir), ATM_GROUND).x > 0.0 && lightDir.y < -0.02) return vec3(0.0);
    return extinction(lightOpticalDepth(ro, normalize(lightDir)));
}

vec3 scatter(vec3 rd, vec3 lightDir, float intensity, int steps) {
    vec3 ro = vec3(0.0, ATM_GROUND + 200.0, 0.0);
    // Keep below-horizon rays from sampling the planet: bend them just above the horizon.
    rd.y = max(rd.y, 0.0) + 0.0005;
    rd = normalize(rd);
    // Cap grazing paths; past this the single-scatter estimate only gets darker and redder.
    float len = min(raySphere(ro, rd, ATM_TOP).y, 320e3);
    float mu = dot(rd, lightDir);
    vec2 od = vec2(0.0);
    vec3 sumR = vec3(0.0), sumM = vec3(0.0);
    for (int i = 0; i < steps; i++) {
        // Quadratic spacing: dense samples near the viewer where the air is thickest.
        float t0 = sqr(float(i) / float(steps)) * len;
        float t1 = sqr(float(i + 1) / float(steps)) * len;
        float stepLen = t1 - t0;
        vec3 p = ro + rd * (t0 + t1) * 0.5;
        float h = max(length(p) - ATM_GROUND, 0.0);
        vec2 d = exp(-h / vec2(H_R, H_M)) * stepLen;
        od += d;
        vec3 up = normalize(p);
        // Soft terminator so twilight keeps some color instead of a hard cutoff.
        float horizon = smoothstep(-0.12, 0.02, dot(up, lightDir));
        vec3 t = extinction(od + lightOpticalDepth(p, lightDir)) * horizon;
        sumR += d.x * t;
        sumM += d.y * t;
    }
    vec3 single = sumR * BETA_R * phaseRayleigh(mu) + sumM * BETA_M * phaseMie(mu, MIE_G);
    // Crude isotropic multiple-scattering term keeps the horizon luminous instead of dim.
    vec3 multi = (sumR * BETA_R + sumM * BETA_M) * (0.05 / (4.0 * PI));
    // Sky lit by the sky: higher-order Rayleigh scattering of already-blue skylight. Without it, a low sun
    // leaves the zenith grey (only reddened direct light reaches it); with it twilight stays blue overhead.
    float skyLit = smoothstep(-0.15, 0.1, lightDir.y);
    vec3 skySelf = (1.0 - exp(-BETA_R * od.x)) * 0.035 * skyLit;
    return intensity * (single + multi + skySelf);
}

#ifdef DIM_NETHER
uniform vec3 fogColor;

// Nether air: dark ashen smoke, lit from below by the lava seas (lava level is y = 31). The biome's fog
// colour only tints it (soul sand valley turns cold and ghostly, warped forest a little teal), instead of
// replacing it, so no biome turns into a glowing blue box.
vec3 netherHaze(vec3 rd, float y) {
    vec3 tint = toLinear(fogColor);
    tint = mix(vec3(luminance(tint)), tint, 0.45) / max(luminance(tint), 0.02);
    vec3 smoke = vec3(0.07, 0.028, 0.02) * mix(vec3(1.0), tint, 0.5);
    float nearLava = exp(-max(y - 31.0, 0.0) / 34.0);
    // Looking down toward the lava sea the haze glows; looking up into the smoke it goes dark.
    float look = min(saturate(0.35 - rd.y * 0.65), 0.55);
    vec3 ember = vec3(1.0, 0.3, 0.06) * (0.08 + 0.3 * nearLava) * look;
    return smoke + ember * mix(vec3(1.0), tint, 0.2);
}
#endif

// Twilight effects that single scattering misses, shaped by eye from photographs:
//  - afterglow: after sunset a warm glow over the sunset point that climbs and turns rose/magenta as the
//    sun sinks (light scattered twice, through the high stratosphere),
//  - belt of Venus: a pink band above the opposite horizon, lit by the last reddened sunlight,
//  - Earth's shadow: the darker blue band under it, rising as the sun sets.
vec3 twilightGlow(vec3 rd, vec3 sunDir) {
    float e = sunDir.y;                               // sine of sun elevation
    if (e > 0.12 || e < -0.25) return vec3(0.0);
    vec3 flatV = normalize(vec3(rd.x, 0.0, rd.z) + vec3(1e-5));
    vec3 flatS = normalize(vec3(sunDir.x, 0.0, sunDir.z) + vec3(1e-5));
    float az = dot(flatV, flatS);                     // 1 toward the sun, -1 away
    float up = max(rd.y, 0.0);
    vec3 col = vec3(0.0);

    // Afterglow: strongest a few degrees below the horizon, spreading wide along the sunset side.
    float glowT = smoothstep(0.1, 0.0, e) * smoothstep(-0.22, -0.04, e);
    float toward = pow(az * 0.5 + 0.5, 3.0);
    float height = mix(0.22, 0.09, smoothstep(0.05, -0.15, e));       // rises into a dome, then sinks
    float band = exp(-up / height);
    // Orange-gold at the horizon, rose above it, violet at the top of the glow.
    float k = up / height;
    vec3 warm = mix(vec3(1.0, 0.5, 0.16), vec3(0.95, 0.38, 0.42), smoothstep(0.2, 1.2, k));
    warm = mix(warm, vec3(0.55, 0.32, 0.75), smoothstep(1.2, 2.5, k));
    col += warm * band * toward * glowT * 0.55;

    // Belt of Venus over the anti-solar horizon, above Earth's shadow.
    float beltT = smoothstep(0.08, 0.0, e) * smoothstep(-0.14, -0.02, e);
    float away = pow(-az * 0.5 + 0.5, 2.0);
    float shadowTop = mix(0.0, 0.14, smoothstep(0.02, -0.12, e));
    float belt = exp(-sqr((up - shadowTop - 0.07) / 0.06));
    col += vec3(1.0, 0.55, 0.62) * belt * away * beltT * 0.012;
    return col * (1.0 - rainStrength) * SUN_ILLUMINANCE / 16.0;
}

float endFbm(vec2 p) {
    float n = 0.0, amp = 0.5;
    for (int i = 0; i < 5; i++) { n += valueNoise(p) * amp; p = p * 2.03 + vec2(11.3, 7.7); amp *= 0.5; }
    return n;
}

// The End sky: a black-violet void with a slow nebula storm wheeling around a dim glow overhead. Magenta
// dust and faint teal currents, a pale void haze along the horizon. Everything drifts very slowly.
vec3 endSky(vec3 rd) {
    float t = frameTimeCounter * 0.004;
    // Project the upper sky onto a plane so the storm has a centre overhead; swirl angle grows toward it.
    vec2 p = rd.xz / (max(rd.y, 0.0) + 0.45);
    float r = length(p);
    float ang = t * 2.0 + 1.6 / (r + 0.6);
    p = mat2(cos(ang), -sin(ang), sin(ang), cos(ang)) * p;
    vec2 warp = vec2(endFbm(p * 0.9 + 1.7), endFbm(p * 0.9 + 9.2)) - 0.5;
    float n = endFbm(p * 1.4 + warp * 2.2 + t);
    float m = endFbm(p * 2.6 - warp * 1.3 - t * 1.4 + 4.0);
    float dust = smoothstep(0.42, 0.85, n);
    float threads = pow(smoothstep(0.5, 0.9, m), 3.0);
    float up = saturate(rd.y * 1.2 + 0.2);

    vec3 col = vec3(0.010, 0.004, 0.022);
    col += vec3(0.34, 0.07, 0.46) * dust * dust * 0.28 * up;
    col += vec3(0.05, 0.30, 0.34) * threads * 0.22 * up;
    col += vec3(0.30, 0.12, 0.50) * exp(-r * 2.2) * 0.10 * up;              // heart of the storm
    col += vec3(0.10, 0.04, 0.16) * exp(-abs(rd.y) * 7.0) * 0.55;           // void haze at the horizon
    return col;
}

// Clear-sky radiance for a view direction, sun plus moon. Other dimensions have no atmosphere.
vec3 skyRadiance(vec3 rd, vec3 sunDir, int steps) {
#if defined DIM_NETHER
    return netherHaze(rd, 90.0);
#elif defined DIM_END
    return endSky(rd);
#endif
    vec3 day = scatter(rd, sunDir, SUN_ILLUMINANCE, steps);
    // Moonlit sky kept dim: a dark sky is what lets the Milky Way and faint stars show.
    vec3 night = scatter(rd, -sunDir, SUN_ILLUMINANCE * MOON_ILLUMINANCE, max(steps / 2, 4)) * vec3(0.6, 0.8, 1.3) * 0.4;
    vec3 col = day + night + vec3(0.0003, 0.00045, 0.0008) + twilightGlow(rd, sunDir);
    // Overcast: collapse toward a grey dome during rain.
    float overcast = rainStrength * 0.85;
    if (overcast == 0.0) return col;
    vec3 grey = vec3(luminance(scatter(vec3(0.0, 1.0, 0.0), sunDir, SUN_ILLUMINANCE, 4))) * 0.55 + vec3(0.0008);
    return mix(col, grey, overcast);
}

// Distant haze: the horizon sky color, darkening a little below the horizon like far-off land in fog.
// Shared by the sky (below the horizon) and the terrain fog so ungenerated LODs and fogged terrain match.
// It must equal the sky exactly at and just below the horizon line; any mismatch shows as a band where the
// fogged far ocean meets the sky. Darkening only starts well below the horizon (looking down into the void).
// Solar aureole: the bright, soft patch of sky around the sun, from strong forward scattering by haze and
// aerosols. Single-scatter Mie with one phase lobe cannot produce it, and it is most of what makes a sun read
// as blinding (the disc itself is tiny). It is part of the sky, so clouds, terrain and trees occlude it,
// water reflects it, and fog looking toward the sun glows with it. Colour follows the sunlight reaching us,
// so it turns orange at sunset. (The idea of a separate sky glow term came from reading Complementary's and
// Photon's source early on; the shape here was rebuilt and tuned by eye against screenshots.)
vec3 sunAureole(vec3 rd, vec3 sunDir) {
#if defined DIM_NETHER || defined DIM_END
    return vec3(0.0);
#endif
    float a = acos(clamp(dot(rd, sunDir), -1.0, 1.0));
    // Low sun: longer air path, more haze, a much larger and relatively stronger glow.
    float low = 1.0 - smoothstep(0.0, 0.5, sunDir.y);
    // Three scales, tuned by eye against reference screenshots: a blinding glow a few degrees across that
    // swallows the sun's outline, a broad halo, and a very wide skirt that warms a big part of the sky.
    float core = exp(-a * 38.0) * mix(1.2, 2.2, low);
    float halo = exp(-a * 9.0) * mix(0.22, 0.45, low);
    float skirt = exp(-a * 2.4) * mix(0.03, 0.10, low);
    // At sunset the haze layer is thickest along the horizon, so the glow spreads sideways along it.
    vec3 viewFlat = normalize(vec3(rd.x, 0.0, rd.z) + vec3(1e-5));
    vec3 sunFlat = normalize(vec3(sunDir.x, 0.0, sunDir.z) + vec3(1e-5));
    float along = exp(-acos(clamp(dot(viewFlat, sunFlat), -1.0, 1.0)) * 1.6);
    float band = exp(-max(rd.y, 0.0) * 12.0) * along * 0.18 * low;
    float strength = core + halo + skirt + band;
    vec3 t = sunTransmittance(sunDir);
    // Fades as the sun sets below the horizon, and is washed out by overcast.
    float up = smoothstep(-0.06, 0.02, sunDir.y);
    return t * SUN_ILLUMINANCE * strength * up * (1.0 - 0.85 * rainStrength);
}

vec3 hazeColor(vec3 rd, vec3 sunDir) {
    vec3 dir = normalize(vec3(rd.x, max(rd.y, 0.0), rd.z));
    vec3 h = skyRadiance(dir, sunDir, 8) + sunAureole(dir, sunDir);
    return h * mix(1.0, 0.5, smoothstep(-0.1, -0.4, rd.y));
}

#ifdef FRAGMENT
// The sun as the eye perceives it: not a disc with an edge but a blinding core that fades out smoothly. A
// sharp-edged disc tonemaps to a flat white circle, which reads as a sticker; a physically bright core with an
// exponential falloff saturates to white over a region a few times its size and then eases into the aureole,
// so no edge is ever visible. The profile carries the sun's full illuminance (integral of exp(-s/a) over the
// plane is 2 pi a^2), as Photon's disc does, so bloom and glare get the right amount of energy. It is drawn in
// the sky, so terrain, trees and clouds in front of it cut it off.
vec3 sunDisc(vec3 rd, vec3 sunDir) {
#if defined DIM_NETHER || defined DIM_END
    return vec3(0.0);
#endif
    const float a = 0.0062;        // falloff scale in radians (a little larger than the real sun reads better)
    float s = length(rd - sunDir);
    if (s > a * 30.0) return vec3(0.0);
    float core = exp(-s / a);
    vec3 t = sunTransmittance(sunDir);
    const float norm = 1.0 / (2.0 * PI * a * a);
    // The cap sets how much light bloom spreads around the sun. Uncapped (tens of thousands) a sliver of sun
    // peeking past a leaf flooded the screen with glow; this keeps the core blown out but the glow steady.
    vec3 disc = core * t * SUN_ILLUMINANCE * norm * (1.0 - rainStrength);
    return disc / (1.0 + max(max(disc.r, disc.g), disc.b) / 1800.0);
}
#endif

float starField(vec3 rd) {
    vec3 p = rd * 280.0;
    vec3 cell = floor(p);
    float h = hash12(cell.xy + cell.z * 17.13);
    float star = step(0.9965, h);
    vec3 f = fract(p) - 0.5;
    float core = smoothstep(0.35, 0.0, length(f));
    return star * core * (0.4 + 0.6 * hash12(cell.zx));
}

float cloudDensity(vec2 p) {
    p += frameTimeCounter * vec2(3.0, 1.2);
    float n = 0.0;
    float amp = 0.55;
    vec2 q = p * 0.0009;
    for (int i = 0; i < 5; i++) {
        n += valueNoise(q) * amp;
        q = q * 2.03 + vec2(13.1, 7.7);
        amp *= 0.5;
    }
    float coverage = mix(CLOUD_COVERAGE, 0.78, rainStrength);
    return smoothstep(1.0 - coverage, 1.0 - coverage + 0.32, n);
}

// Blends a flat procedural cloud layer over the sky. worldXZ offsets the layer so clouds stay fixed in the world.
vec3 applyClouds(vec3 sky, vec3 rd, vec3 sunDir, vec3 sunLight, vec3 ambient, vec2 worldXZ) {
#ifdef CLOUDS
    if (rd.y <= 0.01) return sky;
    float t = CLOUD_HEIGHT / rd.y;
    vec2 p = worldXZ + rd.xz * t;
    float dens = cloudDensity(p);
    if (dens <= 0.0) return sky;
    // Cheap self-shadowing: density a little toward the light.
    vec3 lightDir = sunDir.y > -0.1 ? sunDir : -sunDir;
    float toward = cloudDensity(p + lightDir.xz / max(lightDir.y, 0.15) * 60.0);
    float mu = dot(rd, lightDir);
    float powder = 1.0 - exp(-dens * 4.0);
    vec3 lit = sunLight * (exp(-toward * 2.2) * (0.35 + 1.6 * phaseMie(mu, 0.6)) * powder * 0.9);
    vec3 col = lit + ambient * (0.9 - 0.3 * toward);
    float fade = smoothstep(0.01, 0.12, rd.y);
    return mix(sky, col, dens * fade * 0.94);
#else
    return sky;
#endif
}
