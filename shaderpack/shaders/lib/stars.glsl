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
#define MILKYWAY_BRIGHTNESS 0.006

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
    // Sun's right ascension through a 365-day year (day 0 starts in late autumn, rich winter constellations).
    float raSun = fract(float(worldDay) / 365.0 + 0.62) * TAU;

    float sinDec = clamp(dot(rd, CELESTIAL_NORTH), -1.0, 1.0);
    float dec = asin(sinDec);
    float ra = mod(raSun + atan(dot(rd, b2), dot(rd, b1)), TAU);
    vec2 uv = vec2(ra / TAU, dec / PI + 0.5);

    vec3 col = texture(milkyway, uv).rgb * MILKYWAY_BRIGHTNESS;

    const vec2 size = vec2(2048.0, 1024.0);
    vec2 st = uv * size;
    ivec2 c = ivec2(floor(st));
    // Near the poles one pixel spans many columns of right ascension; search wider there.
    int spanX = min(int(1.5 / max(cos(dec), 0.02)) + 1, 20);
    // Star profile in pixels; flux is normalized to the angular area so exposure behaves physically.
    const float sigmaPx = 0.75;
    float norm = 1.0 / (TAU * sqr(sigmaPx * pixelAngle));
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
            if (dot(dir, rd) < 0.99) continue;
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
