// Night sky from real data: 15k catalogue stars (HYG database, CC BY-SA 4.0) drawn as analytic points, over
// a Milky Way glow aligned with the real galactic plane. Textures are baked by tools/bake_sky.py.
// Requires clouds.glsl (worldDay uniform), common.glsl.
//
// The celestial sphere turns with the sun: its pole is perpendicular to the sun's path (sunPathRotation
// -25 degrees gives a pole 25 degrees above the northern horizon, where Polaris sits still while the rest of
// the sky wheels around it), and the sun's right ascension advances through the year, so the constellations
// on show change with the seasons.

uniform sampler2D starmap;
uniform sampler2D milkyway;

const vec3 CELESTIAL_NORTH = vec3(0.0, 0.42262, -0.90631);
#define STAR_BRIGHTNESS 3.0e-5
#define MILKYWAY_BRIGHTNESS 0.15

vec3 starColor(float bv) {
    // B-V colour index -> temperature (Ballesteros 2012) -> approximate blackbody colour.
    float T = 4600.0 * (1.0 / (0.92 * bv + 1.7) + 1.0 / (0.92 * bv + 0.62));
    float t = T / 100.0;
    float r = t <= 66.0 ? 1.0 : 1.2929 * pow(t - 60.0, -0.1332);
    float g = t <= 66.0 ? 0.3901 * log(t) - 0.6318 : 1.1299 * pow(t - 60.0, -0.0755);
    float b = t >= 66.0 ? 1.0 : (t <= 19.0 ? 0.0 : 0.5432 * log(t - 10.0) - 1.1963);
    vec3 c = toLinear(clamp(vec3(r, g, b), 0.0, 1.0));
    // Stars look far less coloured to the eye than their spectra suggest; keep a hint of it.
    return mix(vec3(luminance(c)), c, 0.55) / max(luminance(c), 0.05);
}

// rd: world view direction. fragPx: this pixel's position in pixels. worldToScreen maps a world direction to
// pixels, so every star is drawn as a round, sub-pixel-accurate point regardless of projection distortion.
vec2 starToScreen(vec3 dir, mat3 view, vec2 projScale, vec2 res) {
    vec3 v = view * dir;
    return (v.xy / max(-v.z, 1e-4) * projScale * 0.5 + 0.5) * res;
}

vec3 nightSky(vec3 rd, vec3 sunDir, float pixelAngle, float time, vec2 fragPx, mat3 view, vec2 projScale, vec2 res) {
    vec3 b1 = normalize(sunDir - dot(sunDir, CELESTIAL_NORTH) * CELESTIAL_NORTH);
    vec3 b2 = cross(CELESTIAL_NORTH, b1);
    // Sun's right ascension: pinned near the June solstice, when the galactic core (RA 266 deg) crosses the
    // meridian around midnight, so the brightest part of the Milky Way arcs overhead on every clear night.
    // A slow drift (one cycle per ten years of game days) keeps the sky from being perfectly static.
    float raSun = fract(float(worldDay) / 3650.0 + 0.44) * TAU;

    float sinDec = clamp(dot(rd, CELESTIAL_NORTH), -1.0, 1.0);
    float dec = asin(sinDec);
    float ra = mod(raSun + atan(dot(rd, b2), dot(rd, b1)), TAU);
    vec2 uv = vec2(ra / TAU, dec / PI + 0.5);

    vec3 mw = textureLod(milkyway, uv, 0.0).rgb;
    // Contrast: the faint wide glow stays faint while the bright star clouds and dust lanes stand out.
    mw = pow(mw, vec3(1.25)) * 1.2;
    // Starlight is only faintly warm to the eye: pull the dusty core toward cream.
    mw = mix(vec3(luminance(mw)), mw, 0.45) * vec3(0.95, 0.97, 1.05);
    vec3 col = mw * MILKYWAY_BRIGHTNESS;

    // Faint star dust: the unresolved glow is really countless dim stars, so sprinkle tiny pinpoints whose
    // density follows the galaxy's brightness (dense in the band, sparse elsewhere). Cells are fixed on the
    // celestial sphere so the dust turns with the sky.
    {
        vec3 cs = vec3(dot(rd, b1), dot(rd, b2), sinDec);
        vec3 sp = cs / pixelAngle / 2.2;
        vec3 cell = floor(sp);
        float hsh = hash12(cell.xy * 0.713 + cell.z * 1.37);
        float density = 0.006 + 0.42 * smoothstep(0.02, 0.4, luminance(mw));
        if (hsh < density) {
            vec3 f = fract(sp) - 0.5;
            float core = exp(-dot(f, f) * 9.0);
            float b = hash12(cell.zy * 1.91 + 4.3);
            col += vec3(0.85, 0.9, 1.0) * core * (0.25 + b * b * 1.6) * STAR_BRIGHTNESS * 6000.0 / (pixelAngle * pixelAngle * 1.0e6);
        }
    }

    const vec2 size = vec2(2048.0, 1024.0);
    vec2 st = uv * size;
    ivec2 c = ivec2(floor(st));
    // Near the poles one pixel spans many columns of right ascension; search wider there.
    int spanX = min(int(1.5 / max(cos(dec), 0.02)) + 1, 20);
    // Star profile in pixels; flux is normalized to the angular area so exposure behaves physically.
    const float sigmaPx = 0.75;
    float norm = 1.0 / (TAU * sqr(sigmaPx * pixelAngle));
    // A star's support is capped at 4 sigma; use the brightest representable magnitude for a safe
    // angular prefilter. Perspective projection maps angular distance to at least the smaller
    // focal length in pixels, so candidates outside this cone cannot reach the screen-space support test.
    const float maxStarRadiusPx = 4.0 * sigmaPx * (1.0 + 0.45 * 4.5); // mag -2 -> sigma 2.26875 px
    float focalMinPx = 0.5 * min(projScale.x * res.x, projScale.y * res.y);
    float maxStarAngle = min(maxStarRadiusPx / max(focalMinPx, 1e-3) + 1e-4, PI);
    // For unit directions, chord distance is sqrt(2 - 2*dot) and never exceeds angular distance.
    // This lower dot threshold is conservative and avoids a per-fragment cosine.
    float minStarDot = 1.0 - 0.5 * maxStarAngle * maxStarAngle;
    bool canCullByAngle = maxStarAngle < PI;
    vec3 acc = vec3(0.0);
    for (int dy = -1; dy <= 1; dy++) {
        int y = c.y + dy;
        if (y < 0 || y >= 1024) continue;
        for (int dx = -spanX; dx <= spanX; dx++) {
            ivec2 t = ivec2((c.x + dx + 2048) % 2048, y);
            vec4 s = texelFetch(starmap, t, 0);
            if (s.b == 0.0 && s.r == 0.0) continue;
            vec2 sp = (vec2(t) + s.rg) / size;
            float sra = sp.x * TAU - raSun, sdec = (sp.y - 0.5) * PI;
            vec3 dir = cos(sdec) * (cos(sra) * b1 + sin(sra) * b2) + sin(sdec) * CELESTIAL_NORTH;
            float starDot = dot(dir, rd);
            if (starDot < 0.99) continue;
            // Keep the existing broad rejection, then skip stars outside the exact support radius.
            // Normalize the comparison because the rounded celestial basis makes dir slightly non-unit.
            if (canCullByAngle && starDot * inversesqrt(dot(dir, dir)) < minStarDot) continue;
            vec2 dp = starToScreen(dir, view, projScale, res) - fragPx;
            float d2 = dot(dp, dp);
            float mag = s.b * 10.0 - 2.0;
            // Bright stars read larger to the eye (glare in the eye's optics), faint ones as sharp points.
            float sp2 = sqr(sigmaPx * (1.0 + 0.45 * max(2.5 - mag, 0.0)));
            if (d2 > 16.0 * sp2) continue;
            float flux = exp2(-1.3288 * mag); // 10^(-0.4 mag)
            // Twinkling: the long air path near the horizon makes stars scintillate; overhead they hold still.
            float seed = fract(sin(dot(vec2(t), vec2(12.9898, 78.233))) * 43758.5453);
            float airmass = 1.0 - smoothstep(0.05, 0.6, rd.y);
            flux *= 1.0 + airmass * 0.55 * (sin(time * (7.0 + seed * 9.0) + seed * 40.0) * 0.5
                                           + sin(time * (13.0 + seed * 5.0) + seed * 17.0) * 0.5);
            acc += starColor(s.a * 2.5 - 0.5) * flux * exp(-d2 / (2.0 * sp2)) * norm * (sigmaPx * sigmaPx / sp2);
        }
    }
    col += acc * STAR_BRIGHTNESS;
    // Atmospheric extinction: stars and the galaxy fade into the horizon haze.
    col *= exp(-0.2 / max(rd.y + 0.03, 0.02)) * smoothstep(-0.02, 0.05, rd.y);
    return col;
}

uniform int moonPhase;

// A round moon instead of the square vanilla sprite: a lit sphere whose terminator follows the moon phase,
// with darker maria, faint earthshine on the unlit side, and a soft halo from forward scattering in the air.
// Drawn slightly larger than the real moon so it reads at game field-of-view, and kept white (it only warms a
// little right at the horizon, never into a second sun).
vec3 moonSky(vec3 rd, vec3 moonDir) {
    const float R = 0.02;                            // angular radius (radians)
    float phaseAngle = float(moonPhase) / 8.0 * TAU; // 0 = full moon, pi = new moon
    float illum = 0.5 + 0.5 * cos(phaseAngle);       // lit fraction
    float horizon = smoothstep(-0.03, 0.05, moonDir.y);
    // Air mass reddening near the horizon, softened: a hint of warmth, not orange.
    vec3 airTint = mix(vec3(1.0), sunTransmittance(moonDir) / max(luminance(sunTransmittance(moonDir)), 1e-3), 0.35);

    vec3 col = vec3(0.0);
    vec3 right = normalize(cross(moonDir, CELESTIAL_NORTH));
    vec3 up = cross(right, moonDir);
    vec2 p = vec2(dot(rd - moonDir, right), dot(rd - moonDir, up)) / R;
    float r2 = dot(p, p);
    if (r2 < 1.3 && dot(rd, moonDir) > 0.0) {
        vec3 n = vec3(p, sqrt(max(1.0 - r2, 0.0)));
        vec3 L = vec3(sin(phaseAngle), 0.0, cos(phaseAngle));
        float lit = smoothstep(-0.04, 0.12, dot(n, L));
        // Maria: large dark basins plus finer mottling, fixed to the disc (the moon always shows one face).
        float m = valueNoise(p * 2.1 + 3.7) * 0.65 + valueNoise(p * 5.3 + 11.0) * 0.35;
        float albedo = mix(1.0, 0.58, smoothstep(0.45, 0.7, m)) * (0.9 + 0.1 * valueNoise(p * 17.0));
        float edge = 1.0 - smoothstep(0.96, 1.02, sqrt(r2));
        vec3 surface = vec3(0.95, 0.97, 1.0) * albedo * (lit * 1.1 + 0.012);
        col += surface * edge;
    }
    // Halo.
    float a = acos(clamp(dot(rd, moonDir), -1.0, 1.0));
    col += vec3(0.75, 0.85, 1.0) * (exp(-a * 30.0) * 0.05 + exp(-a * 6.0) * 0.005) * illum;
    return col * airTint * horizon * (1.0 - rainStrength);
}
