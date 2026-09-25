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
    // Close over the lava the fumes stream upward in wisps with clear gaps between them. A uniform sheet turned the
    // view from a lava shore into flat orange soup; broken wisps keep the sea visible and blinding through them.
    float wisp = cloudTex(vec3(p.x * 0.055, (p.y - time * 2.2) * 0.07, p.z * 0.055) + 0.61).r;
    sheet *= smoothstep(0.38, 0.78, wisp) * 1.5;
    float haze = 0.006 + 0.012 * nearSea + 0.01 * sheet;

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

#ifdef EMBERS_VOXEL
// Embers: sparks above broad lava pools, rising and swaying. A 3D DDA visits 2-block cells near the camera;
// the voxel map rejects stray sparks over solid ground and isolated lava blocks.
vec3 lavaEmbers(vec3 camPos, vec3 rd, float maxDist, float t) {
    const float CELL = 2.0;
    const int STEPS = 24;
    vec3 ro = camPos / CELL;
    // Rising: the grid scrolls down so each spark climbs about 1.5 blocks a second.
    ro.y -= t * 0.75;
    vec3 cell = floor(ro);
    vec3 stepDir = sign(rd);
    vec3 tDelta = abs(1.0 / max(abs(rd), vec3(1e-4)));
    vec3 tMax = (stepDir * (cell - ro) + stepDir * 0.5 + 0.5) * tDelta;
    vec3 acc = vec3(0.0);
    float limit = min(maxDist, 30.0) / CELL;
    for (int i = 0; i < STEPS; i++) {
        float tCell = min(tMax.x, min(tMax.y, tMax.z));
        float h = hash12(cell.xz * 1.131 + cell.y * 2.717 + 0.7);
        if (h > 0.8) {
            float h2 = hash12(cell.zy * 1.93 + 3.3), h3 = hash12(cell.xy * 2.39 + 6.1);
            vec3 m = cell + vec3(h2, fract(h * 9.1), h3) * 0.8 + 0.1;
            m.xz += 0.25 * vec2(sin(t * 1.7 + h * 50.0), cos(t * 1.3 + h2 * 50.0));
            vec3 d = m - ro;
            float along = dot(d, rd);
            if (along > 0.05 && along < limit) {
                float perp2 = max(dot(d, d) - along * along, 0.0);
                const float r = 0.018;
                vec3 worldSpark = m * CELL + vec3(0.0, t * 1.5, 0.0);
                float aboveSea = worldSpark.y - NETHER_LAVA_LEVEL;
                // The centre plus four points three blocks away must all be lava at sea level. That
                // gives the sparks room to rise over a real pool, without filling every nearby cave.
                ivec3 v = worldBlockToVoxel(ivec3(floor(worldSpark.x), int(NETHER_LAVA_LEVEL), floor(worldSpark.z)), cameraPositionInt);
                ivec3 dx = ivec3(3, 0, 0), dz = ivec3(0, 0, 3);
                if (aboveSea > 0.5 && aboveSea < 24.0 && perp2 < 0.015 &&
                    voxelInside(v - dx) && voxelInside(v + dx) && voxelInside(v - dz) && voxelInside(v + dz) &&
                    voxelExtra(texelFetch(voxelSampler, v, 0).r) == 3u &&
                    voxelExtra(texelFetch(voxelSampler, v - dx, 0).r) == 3u &&
                    voxelExtra(texelFetch(voxelSampler, v + dx, 0).r) == 3u &&
                    voxelExtra(texelFetch(voxelSampler, v - dz, 0).r) == 3u &&
                    voxelExtra(texelFetch(voxelSampler, v + dz, 0).r) == 3u) {
                    float life = fract(t * (0.35 + 0.3 * h3) + h2 * 7.0);
                    float flare = smoothstep(0.0, 0.1, life) * (1.0 - life);
                    vec3 c = mix(vec3(1.0, 0.25, 0.03), vec3(1.0, 0.75, 0.3), flare);
                    acc += c * (exp(-perp2 / (r * r)) + 0.05 * exp(-perp2 / (r * r * 25.0))) * flare * smoothstep(limit, limit * 0.5, along);
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
#endif

// Light arriving at a smoke point from the lava seas below: an analytic stand-in for sources beyond the voxel
// field. Strong, deep orange low down, falling off with height; slightly flickering heat.
vec3 netherSeaGlow(vec3 p, float time) {
    float h = max(p.y - NETHER_LAVA_LEVEL, 0.0);
    float pulse = 0.92 + 0.08 * valueNoise(p.xz * 0.02 + time * 0.15);
    // Falls off fast: smoke hanging low over the seas glows, smoke overhead stays sooty and dark.
    return vec3(1.0, 0.30, 0.05) * 1.55 * exp(-h / 18.0) * pulse;
}

// Soot and ember ambient that keeps high smoke from going pure black.
vec3 netherSmogAmbient(vec3 biomeAir) {
    // Grey-brown soot. The Nether's orange belongs to the lava, not the air: cold, dirty smoke is what makes the
    // lava read as blinding by contrast (Solas and Bliss both keep their smoke grey).
    return mix(vec3(0.10, 0.08, 0.066), biomeAir * 0.085, 0.4);
}
