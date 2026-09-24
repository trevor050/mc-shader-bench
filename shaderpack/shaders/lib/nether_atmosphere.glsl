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

// Extinction coefficient (per block). Haze is always present; billows rise in columns off the lava seas.
float netherSmogDensity(vec3 p, float time, float ash) {
    float h = p.y - NETHER_LAVA_LEVEL;
    float nearSea = exp(-max(h, 0.0) / 34.0);
    float haze = 0.0065 + 0.018 * nearSea;

    // Rising smoke: the noise domain scrolls downward so features climb, and is sheared with height so columns
    // lean and curl instead of rising as straight pipes.
    float rise = time * 0.9;
    vec3 q = vec3(p.x * 0.0105 + h * 0.0021, (p.y - rise) * 0.0072, p.z * 0.0105 - h * 0.0017);
    vec4 n = cloudTex(q + vec3(0.0, 0.0, time * 0.0009));
    float shape = n.r * 0.62 + n.g * 0.25 + n.b * 0.13;
    float billow = smoothstep(0.46, 0.78, shape);
    // Billows are born low and thin out as they climb, but a few reach the ceiling.
    float column = billow * (0.35 + 0.65 * exp(-max(h, 0.0) / 60.0));
    return (haze + column * 0.06) * (1.0 + ash * 0.9);
}

// Light arriving at a smoke point from the lava seas below: an analytic stand-in for sources beyond the voxel
// field. Strong, deep orange low down, falling off with height; slightly flickering heat.
vec3 netherSeaGlow(vec3 p, float time) {
    float h = max(p.y - NETHER_LAVA_LEVEL, 0.0);
    float pulse = 0.92 + 0.08 * valueNoise(p.xz * 0.02 + time * 0.15);
    return vec3(1.0, 0.30, 0.05) * 1.35 * exp(-h / 26.0) * pulse;
}

// Soot and ember ambient that keeps high smoke from going pure black.
vec3 netherSmogAmbient(vec3 biomeAir) {
    return mix(vec3(0.030, 0.018, 0.012), biomeAir * 0.024, 0.55);
}
