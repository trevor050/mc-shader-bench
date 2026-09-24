// Nether smog: a participating medium marched at half resolution (vl_march.glsl), accumulated temporally and
// composited in composite.glsl. Requires clouds.glsl's cloudTex() and atmosphere.glsl's fogColor.
//
// Direction (Trevor, after Bliss): smoke you can feel in your lungs, lava that burns, a hellish alien world.
// Bliss gets the mood from dense, uniformly lit fog. This version keeps that density but lights the medium
// from its actual sources: the voxel light field puts an orange glow in the smoke right above lava, fire and
// portals (purple haze around a portal, cold cyan over soul fire), while the far field is lit by the lava seas
// from below, so smoke is bright where it hangs low over lava and sooty and dark overhead.

const float NETHER_LAVA_LEVEL = 31.0;

// Biome air colour from the game's fog colour (crimson red, warped teal, soul sand valley cold blue-grey,
// basalt deltas ash, wastes ember). Returned hue-normalized and partly desaturated.
vec3 netherBiomeAir() {
    vec3 a = toLinear(fogColor);
    a = mix(vec3(luminance(a)), a, 0.6);
    return a / max(luminance(a), 1e-3);
}

// Ash-heavy biomes (basalt deltas' grey fog) get thicker smoke.
float netherAshiness() {
    vec3 a = toLinear(fogColor);
    float sat = (max(a.r, max(a.g, a.b)) - min(a.r, min(a.g, a.b))) / max(max(a.r, max(a.g, a.b)), 1e-3);
    return 1.0 - smoothstep(0.2, 0.6, sat);
}

// Smoke at a point: x = extinction (per block), y = soot fraction (0 = thin glowing haze, 1 = thick dark smoke).
//
// After Bliss (dense ceiling-to-floor smoke, a thick sheet on the lava seas, plumes that rise), improved where
// Bliss repeats and flattens: two octaves of 3D noise on rotated, non-integer-ratio domains (no 46-block tiling),
// a slow height- and time-dependent swirl so columns curl instead of shearing statically, haze that really
// absorbs (distant rock drowns in it), and soot that is dark because it is thick rather than because of a fixed
// radius around the camera.
vec2 netherSmog(vec3 p, float time, float ash) {
    float h = p.y - NETHER_LAVA_LEVEL;
    float hp = max(h, 0.0);
    float nearSea = exp(-hp / 30.0);
    // Fumes: a dense sheet hugging the lava seas.
    float sheet = exp(-hp / 3.5);
    float haze = 0.010 + 0.026 * nearSea + 0.05 * sheet;

    // Swirl: the domain rotates slowly with height and time, so rising columns twist and drift.
    vec2 swirl = vec2(sin(p.y * 0.047 + time * 0.13), cos(p.y * 0.039 - time * 0.11)) * 7.0;
    vec3 q = vec3(p.x + swirl.x, p.y, p.z + swirl.y);
    // Rising smoke: the noise domain scrolls downward so features climb, sheared with height so columns lean.
    float rise = time * 1.1;
    vec4 n = cloudTex(vec3(q.x * 0.0105 + h * 0.0021, (p.y - rise) * 0.0075, q.z * 0.0105 - h * 0.0017));
    float shape = n.r * 0.62 + n.g * 0.25 + n.b * 0.13;
    // Detail octave on a rotated domain, rising faster: ragged, tumbling edges.
    float detail = cloudTex(vec3(q.z * 0.029 - q.x * 0.011, (p.y - rise * 1.7) * 0.023, q.x * 0.029 + q.z * 0.011) + 0.37).g;
    shape -= (1.0 - detail) * 0.14;
    float billow = smoothstep(0.36, 0.66, shape);
    // Billows are born low and thin out as they climb, but many reach the ceiling.
    float soot = billow * (0.35 + 0.65 * exp(-hp / 70.0)) * 0.13;
    float scale = 1.0 + ash * 0.9;
    return vec2((haze + soot) * scale, soot / (haze + soot));
}

float netherSmogDensity(vec3 p, float time, float ash) { return netherSmog(p, time, ash).x; }

// Light arriving at a smoke point from the lava seas below: an analytic stand-in for sources beyond the voxel
// field. Strong, deep orange low down, falling off with height; slightly flickering heat.
vec3 netherSeaGlow(vec3 p, float time) {
    float h = max(p.y - NETHER_LAVA_LEVEL, 0.0);
    float pulse = 0.92 + 0.08 * valueNoise(p.xz * 0.02 + time * 0.15);
    // Falls off fast: smoke hanging low over the seas glows, smoke overhead stays sooty and dark.
    return vec3(1.0, 0.30, 0.05) * 1.9 * exp(-h / 14.0) * pulse;
}

// Soot and ember ambient that keeps high smoke from going pure black.
vec3 netherSmogAmbient(vec3 biomeAir) {
    // Grey-brown soot. The Nether's orange belongs to the lava, not the air: cold, dirty smoke is what makes the
    // lava read as blinding by contrast (Solas and Bliss both keep their smoke grey).
    return mix(vec3(0.017, 0.014, 0.012), biomeAir * 0.015, 0.4);
}
