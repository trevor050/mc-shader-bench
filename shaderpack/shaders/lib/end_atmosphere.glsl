// End storm: the player stands in the eye of a violent vortex. A towering, fast-turning eye wall of clumpy cloud
// rings the main island; above the island a clear funnel opens up to a glowing core; lightning flashes inside the
// wall, lighting the clouds from within. Marched at half resolution in vl_march (DIM_END branch), accumulated
// temporally and composited in composite.glsl. Requires clouds.glsl's cloudTex().
//
// After Bliss (Chocapic13 edit, lib/end_fog.glsl, by Xonk and contributors): a vortex over the main island, a
// glowing light at its core, self-shadowed clumps, flashes in the storm. Idea only; the code is our own.
// Improvements over the original:
//  - Real 3D noise (our 64^3 cloud texture, two octaves on rotated domains) instead of a y-sliced 2D texture, so
//    the storm does not repeat and has proper depth.
//  - Structure: an eye wall (a ring of dense cloud) and an open funnel over the island, so the storm has a shape
//    you are inside of rather than a uniform fog, and the dragon fight stays readable.
//  - The swirl tightens toward the axis and rises with height: the wall reads as a spiral funnel.
//  - Colour is not uniform (Trevor: Dreamer's Fantasy's End felt too uniformly purple): violet and magenta light
//    drifts across the storm with rare teal accents, the core is pale cyan-white, the void glows magenta below.
//  - Lightning lights the cloud interiors around a random point on the wall, with a flicker, not a flat flash.

const vec3 END_VORTEX_CENTRE = vec3(0.0, 100.0, 0.0);
const vec3 END_CORE_LIGHT = vec3(0.0, 260.0, 0.0);
const float END_EYE_RADIUS = 250.0;

// Storm state from the ClaudeBench Ambience mod, carried by the End's unused weather (see StormAmbience):
// rain = 0.2 + 0.8 * intensity (0.5 at rest, 1.0 during the dragon fight). Without the mod: a moderate storm.
float endStormIntensity() {
    if (rainStrength < 0.1) return 0.55;
    return saturate((rainStrength - 0.2) / 0.8 * 1.001);
}
// Thunder channel from the mod: 0.5..1.0 = lightning flash, 0..0.5 = gust strength (Minecraft reports thunder
// multiplied by rain, so divide it back out).
float endThunderRaw() { return rainStrength < 0.1 ? 0.0 : thunderStrength / max(rainStrength, 1e-3); }
float endGust() {
    if (rainStrength < 0.1) return 0.5 + 0.5 * sin(frameTimeCounter * 0.9) * sin(frameTimeCounter * 0.37 + 2.0);
    float v = endThunderRaw();
    return v < 0.5 ? saturate(v / 0.499) : 1.0;
}
// During a strike: thunder = 0.5 + 0.5 * (direction + flash) / 16.
float endBoltCode() {
    return floor(max(endThunderRaw() - 0.5, 0.0) * 2.0 * 16.0 + 1e-3) / 16.0;
}

// Wind at a point: a fast tangential gale around the vortex axis with an updraft, faster when the storm rages.
vec3 endWind(vec3 p, float intensity) {
    vec3 rel = p - END_VORTEX_CENTRE;
    vec3 tangent = normalize(vec3(-rel.z, 0.0, rel.x) + vec3(1e-3, 0.0, 0.0));
    return tangent * (18.0 + 42.0 * intensity) + vec3(0.0, 4.0 + 6.0 * intensity, 0.0);
}

// x = extinction per block, y = colour variation 0..1.
vec2 endStorm(vec3 p, float t) {
    vec3 rel = p - END_VORTEX_CENTRE;
    float r = length(rel.xz);
    // Spiral: tighter and faster near the axis, rising with height.
    float ang = rel.y / 55.0 + t * 0.05 + 90.0 / (r + 40.0) + t * 1.8 / (r * 0.02 + 1.0) * 0.1;
    float swirl = 1.0 - smoothstep(300.0, 700.0, r);
    float c = cos(ang * swirl), s = sin(ang * swirl);
    vec2 xz = mat2(c, -s, s, c) * rel.xz;
    vec3 q = vec3(xz.x, rel.y, xz.y);
    vec4 n = cloudTex(vec3(q.x * 0.0042, q.y * 0.007 - t * 0.004, q.z * 0.0042));
    float shape = n.r * 0.6 + n.g * 0.28 + n.b * 0.12;
    // Churning detail, rising fast: ragged, tumbling edges.
    float detail = cloudTex(vec3(q.z * 0.016 + 0.37, q.y * 0.028 + t * 0.012, -q.x * 0.016)).g;
    shape -= (1.0 - detail) * 0.2;
    // Eye wall: a broad ring of dense storm around the island, towering up; thinner storm beyond.
    float wall = exp(-sqr((r - END_EYE_RADIUS) / 120.0));
    float clump = smoothstep(0.42 - wall * 0.14, 0.7 - wall * 0.08, shape);
    // The eye: clear over the island and in a funnel straight up to the core.
    float eye = smoothstep(END_EYE_RADIUS * 0.5, END_EYE_RADIUS * 0.8, r + max(20.0 - rel.y, 0.0) * 0.6);
    // Vertical extent: from the void up far past the pillars.
    float band = smoothstep(-60.0, 20.0, p.y) * (1.0 - smoothstep(300.0, 420.0, p.y));
    float voidMist = exp(-max(p.y + 10.0, 0.0) / 30.0);
    float sigma = clump * band * eye * (0.026 + 0.085 * wall) + voidMist * 0.007 + 0.0005;

    // Maelstrom: fast, turbulent storm filling everything, the eye included, thicker the harder the storm rages.
    // At full intensity visibility drops to a few dozen blocks.
    float I = endStormIntensity();
    vec3 w = endWind(p, I);
    vec3 m = p - w * t;
    float churn = cloudTex(vec3(m.x * 0.011, m.y * 0.017, m.z * 0.011) + 0.23).r * 0.65
                + cloudTex(vec3(m.z * 0.034, m.y * 0.05, -m.x * 0.034) + 0.61).g * 0.35;
    float maelstrom = smoothstep(0.3, 0.75, churn) * smoothstep(-20.0, 40.0, p.y) * (1.0 - smoothstep(260.0, 380.0, p.y));
    sigma += maelstrom * (0.004 + 0.05 * I * I) + (0.002 + 0.012 * I * I);

    // The storm reaches into the eye, so it is not only a wall around you (Trevor: from the island it read as a
    // backdrop). Everything here moves fast enough to show parallax against the wall behind it.
    float inEye = 1.0 - eye;
    float theta = atan(rel.z, rel.x);
    // Spiral feeder arms sweeping in over the island between y 60 and 220.
    float arms = smoothstep(0.55, 0.9, 0.5 + 0.5 * sin(3.0 * theta - r / 45.0 + rel.y / 70.0 - t * 0.35));
    float armBand = smoothstep(-40.0, 10.0, rel.y) * (1.0 - smoothstep(90.0, 130.0, rel.y));
    float armCloud = smoothstep(0.45, 0.7, shape + 0.08) * arms * armBand;
    // Low scud: small fast wisps just above the pillars, the nearest cloud there is.
    float scudNoise = cloudTex(vec3(q.x * 0.02 + t * 0.02, q.y * 0.03, q.z * 0.02 - t * 0.015) + 0.71).r;
    float scud = smoothstep(0.62, 0.8, scudNoise) * exp(-sqr((rel.y - 12.0) / 22.0));
    // Ground mist creeping over the island (surface around y 60), pooling in low spots and around the pillars.
    float mistNoise = cloudTex(vec3(p.x * 0.012 + t * 0.006, p.y * 0.05 - t * 0.01, p.z * 0.012 - t * 0.004) + 0.13).g;
    float mist = smoothstep(0.35, 0.7, mistNoise) * exp(-max(p.y - 58.0, 0.0) / 5.0) * step(50.0, p.y);
    sigma += inEye * (armCloud * 0.03 + scud * 0.05) + mist * 0.06 * (1.0 - smoothstep(180.0, 260.0, r));
    return vec2(sigma, n.a);
}

// Heartbeat: a slow double thump every ~4.8 s. The vortex core and the abyss below pulse with it, as if
// something alive were down there (Trevor: "fantastical... almost horrifying").
float endPulse(float t) {
    float x = fract(t / 4.8);
    return exp(-sqr((x - 0.10) / 0.035)) + 0.65 * exp(-sqr((x - 0.24) / 0.035));
}

// Lightning in the eye wall: returns (world position of the current bolt, brightness). A new strike every few
// seconds at a random point on the wall, flickering for a fraction of a second.
// thunderStrength is declared by cloud_weather.glsl, which every caller includes first.

vec4 endLightning(float t) {
    // With the ClaudeBench Ambience mod installed, the mod decides the strikes (so each flash gets its thunderclap)
    // and hands them over through the End's otherwise unused weather: rain = bolt direction code (0.2..1.0),
    // thunder (which Minecraft reports multiplied by rain) = flash brightness. Mirrors StormAmbience.boltPosition.
    if (rainStrength > 0.1) {
        float code = endBoltCode();
        float v = endThunderRaw();
        float flash = v >= 0.5 ? fract((v - 0.5) * 2.0 * 16.0) : 0.0;
        float ang = code * TAU;
        float y = 90.0 + 170.0 * fract(code * 7.31);
        return vec4(END_VORTEX_CENTRE.x + cos(ang) * END_EYE_RADIUS, y, END_VORTEX_CENTRE.z + sin(ang) * END_EYE_RADIUS, flash);
    }
    float slot = floor(t / 5.0);
    float h = hash12(vec2(slot, 7.13));
    float phase = fract(t / 5.0) * 5.0;
    // Occasional single flashes with a soft after-glow (no strobe).
    float on = step(0.7, h) * (exp(-phase * 8.0) + (phase > 0.2 ? 0.35 * exp(-(phase - 0.2) * 8.0) : 0.0));
    float a = hash12(vec2(slot, 3.7)) * TAU;
    float y = mix(90.0, 260.0, hash12(vec2(slot, 11.9)));
    vec3 pos = END_VORTEX_CENTRE + vec3(cos(a) * END_EYE_RADIUS, y - END_VORTEX_CENTRE.y, sin(a) * END_EYE_RADIUS);
    return vec4(pos, max(on, 0.0));
}

// Light arriving at a storm point: the vortex core (pale cyan-white, self-shadowed), violet/magenta ambient with
// rare teal, the void's magenta glow, and lightning.
vec3 endStormLight(vec3 p, float t, float variation, vec4 bolt) {
    vec3 toCore = END_CORE_LIGHT - p;
    float d = length(toCore);
    vec3 l = toCore / max(d, 1e-3);
    float occ = endStorm(p + l * 14.0, t).x * 14.0 + endStorm(p + l * 40.0, t).x * 26.0;
    float pulse = endPulse(t);
    // A baleful magenta-violet core (no white: it washed the storm out to grey), swelling with the heartbeat.
    // Strong and far-reaching, so the storm's sunlit side (toward the core) is bright against dark gaps.
    vec3 core = vec3(0.85, 0.24, 1.0) * (1.5 + 0.35 * pulse) * exp(-d / 280.0) * exp(-occ * 2.2);
    // Bruised, dark cloud bodies: deep violet and wine, with rare teal.
    vec3 ambient = mix(vec3(0.15, 0.03, 0.30), vec3(0.26, 0.02, 0.18), smoothstep(0.3, 0.7, variation));
    ambient = mix(ambient, vec3(0.04, 0.16, 0.22), smoothstep(0.85, 0.96, variation) * 0.5);
    vec3 voidGlow = vec3(0.6, 0.04, 0.42) * (0.8 + 0.3 * pulse) * exp(-max(p.y + 20.0, 0.0) / 45.0);
    // Flashes light only the storm right around the bolt. The storm's own light is dim, so a wide falloff (this
    // was 16 * exp(-d / 70)) still outshone it dozens of times over 200 blocks away and flooded the whole view
    // lavender on every strike: Trevor's "random pink frame".
    float bd = length(p - bolt.xyz);
    vec3 flash = vec3(0.9, 0.5, 1.0) * bolt.w * 10.0 * exp(-bd / 28.0);
    return core + ambient * 0.06 + voidGlow * 0.4 + flash;
}

// Gust sheets: ragged sheets of storm smoke ripping past right in front of the camera, like a sandstorm, drawn at
// full resolution in composite. Four thin layers at increasing distance (2.5 to 16 blocks) sample wind-advected 3D
// noise, stretched only mildly along the wind, so they read as torn smoke rushing past with depth and speed
// (nearer layers sweep across the view faster), never as particles or streaks. Lightning lights them up.
vec3 endGusts(vec3 col, vec3 rd, float sceneDist, float I, vec4 bolt) {
    vec3 wind = endWind(cameraPosition, I);
    float speed = length(wind);
    vec3 wdir = wind / speed;
    // A basis aligned with the wind so the noise can be stretched along it.
    vec3 side = normalize(cross(wdir, vec3(0.0, 1.0, 0.0)) + vec3(1e-4));
    vec3 up = cross(side, wdir);
    float t = frameTimeCounter;
    float gust = 0.5 + 0.5 * sin(t * 0.9) * sin(t * 0.37 + 2.0);
    const float dists[4] = float[4](2.5, 4.5, 8.5, 16.0);
    for (int i = 3; i >= 0; i--) {
        float d = dists[i];
        if (d > sceneDist) continue;
        vec3 p = cameraPosition + rd * d - wind * t;
        vec3 q = vec3(dot(p, wdir) * 0.05, dot(p, side) * 0.14, dot(p, up) * 0.14) + float(i) * 0.37;
        float n = cloudTex(q).r * 0.65 + cloudTex(q * 2.7 + 0.5).g * 0.35;
        float sheet = smoothstep(0.52 - 0.1 * gust * I, 0.82, n);
        // Near sheets are thinner (you see through them), far ones a little denser; all grow with the storm.
        float alpha = sheet * (0.12 + 0.3 * I) * mix(0.55, 1.0, float(i) / 3.0) * smoothstep(1.5, 3.0, d);
        vec3 smoke = vec3(0.03, 0.012, 0.05) + vec3(0.12, 0.05, 0.2) * I + vec3(0.9, 0.5, 1.0) * bolt.w * 0.6;
        col = mix(col, smoke, alpha);
    }
    return col;
}
