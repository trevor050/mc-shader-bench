// Surface lighting shared by the deferred pass (opaque) and forward translucents.
// Requires: common, settings, atmosphere; shadows when SHADOWS_AVAILABLE is defined.

struct LightEnv {
    vec3 sunDir;      // world-space direction to the sun
    vec3 lightDir;    // sun or moon, whichever casts shadows
    vec3 directLight; // radiance of the shadow-casting body at the ground
    vec3 skyAmbient;  // irradiance from the sky dome (upward-facing, fully open)
};

LightEnv makeLightEnv(vec3 sunDir) {
    LightEnv e;
    e.sunDir = sunDir;
#if defined DIM_NETHER || defined DIM_END
    // No sun or sky light: ambient comes from shadeSurface's dimension term instead.
    e.lightDir = vec3(0.0, 1.0, 0.0);
    e.directLight = vec3(0.0);
    e.skyAmbient = vec3(0.0);
    return e;
#endif
    bool day = sunDir.y > -0.05;
    float nightBlend = 1.0 - smoothstep(-0.22, -0.05, sunDir.y);
    e.lightDir = day ? sunDir : -sunDir;
    // Only the active shadow caster needs a ground transmittance estimate.
    // Keep the original per-branch radiance scaling while avoiding four unused optical-depth samples.
    vec3 directT = day
        ? sunTransmittance(sunDir) * SUN_ILLUMINANCE
        : sunTransmittance(-sunDir) * SUN_ILLUMINANCE * MOON_ILLUMINANCE * 1.45 * vec3(0.55, 0.75, 1.25);
    // Fade across the horizon swap so the shadow direction change is not a pop.
    float fade = smoothstep(0.0, 0.08, abs(sunDir.y + 0.02));
    // Moonlight should shape the landscape without washing it silver. Keep a readable directional
    // cue at night; the permanent minimum light and block lights still carry playability in deep shade.
    e.directLight = directT * fade * mix(1.0, 0.86, nightBlend) * (1.0 - rainStrength * 0.9);

    vec3 up = scatter(vec3(0.0, 1.0, 0.0), sunDir, SUN_ILLUMINANCE, 6)
            + scatter(vec3(0.0, 1.0, 0.0), -sunDir, SUN_ILLUMINANCE * MOON_ILLUMINANCE, 4) * vec3(0.6, 0.8, 1.3);
    vec3 side = scatter(normalize(vec3(sunDir.x, 0.25, sunDir.z)), sunDir, SUN_ILLUMINANCE, 6);
    e.skyAmbient = (up * 2.2 + side * 1.1) * PI * 0.5 + vec3(0.0015, 0.002, 0.003);
    e.skyAmbient *= mix(1.0, 0.80, nightBlend);
    e.skyAmbient = mix(e.skyAmbient, vec3(luminance(e.skyAmbient)) * 0.8, rainStrength * 0.6);
    // Under a clear sky, skylight on a horizontal surface is roughly a fifth of the direct sun. Below that ratio
    // shadows read as black holes (Trevor: shadowed blue ice and snow crushed to near black). Raise the fill to
    // that floor, keeping the sky's own hue so shade stays cool.
    float ambientLum = luminance(e.skyAmbient);
    float floorLum = 0.22 * luminance(e.directLight); // both terms are divided by PI in shadeSurface
    e.skyAmbient *= max(1.0, floorLum / max(ambientLum, 1e-5));
    return e;
}

vec3 blockLight(float lmBlock) {
    // Inverse-square-ish falloff mapped onto Minecraft's linear light levels.
    float l = lmBlock * lmBlock;
    float falloff = l / (1.0 + (1.0 - lmBlock) * 22.0);
    return BLOCKLIGHT_COLOR * BLOCKLIGHT_STRENGTH * falloff;
}

#ifdef FIELD_SHADING
// Set by the caller (sampleLightField) before shadeSurface; lets the same entry point serve passes that do
// not read the voxel field.
FieldLight surfaceField;

// Block light from the voxel field. The field was read in the open cell in front of the surface, so faces
// turned away from a source are already darker; the gradient adds a wrap-lit directional term on top.
// Vanilla's lightmap guards against light the grid cannot see (sources outside it, stale frames).
vec3 fieldBlockLight(FieldLight f, vec3 n, float lmBlock, float ao) {
    float facing = f.focus > 0.0 ? dot(n, f.dir) : 0.0;
    float directional = mix(1.0, saturate(facing * 0.65 + 0.55) * 1.35, f.focus);
#ifdef DIM_NETHER
    // Lava seas outshine Minecraft's 15-block light range; trust the field alone here.
    float guard = 1.0;
#else
    float guard = smoothstep(0.0, 0.12, lmBlock);
#endif
    return f.radiance * directional * guard * mix(ao, 1.0, 0.35);
}
#endif

// albedo is linear. shadow is the filtered visibility for the light (1 = lit).
vec3 shadeSurface(LightEnv env, vec3 albedo, vec3 n, vec3 viewDir, vec2 lm, float ao, int mat, vec3 shadow, float emissive) {
    float NdotL = dot(n, env.lightDir);
    bool foliage = mat == MAT_FOLIAGE || mat == MAT_LEAVES || mat == MAT_TALL_UPPER;

    // Minecraft sky light only drops one level per block, so a cave seven blocks from an opening still reads
    // half-open. Real skylight falls with the visible solid angle of the opening, much faster: cube it.
    float skyVis = lm.y * lm.y * lm.y;
    float diffuse = foliage ? (0.45 + 0.55 * saturate(NdotL)) : saturate(NdotL);
    // Direct light also needs open sky: stops light leaking into sealed caves beyond shadow range.
    float leak = smoothstep(0.08, 0.45, lm.y);
    vec3 direct = env.directLight * diffuse * shadow * leak;

    // Subsurface glow when backlit, strongest looking toward the light.
    if (foliage) {
        float backFacing = saturate(dot(viewDir, env.lightDir));
        float backFacing2 = backFacing * backFacing;
        float back = backFacing2 * backFacing2;
        direct += env.directLight * shadow * leak * back * 0.9 * albedo;
    }

    // Sky light: favor upward-facing surfaces, keep some fill on walls.
    float skyFacing = 0.62 + 0.38 * n.y;
    vec3 skyAmb = mix(env.skyAmbient, vec3(luminance(env.skyAmbient)), 0.3);
    // Ground bounce: sunlight reflected off terrain fills shadows with warmer light, strongest on walls.
    vec3 bounce = env.directLight * vec3(0.30, 0.26, 0.20) * 0.18 * (1.0 - 0.6 * n.y);
    vec3 ambient = (skyAmb * skyFacing + bounce) * skyVis * ao;
#if defined DIM_NETHER
    // Smog fill: dim, lit from below by the lava seas, tinted by the biome's own air (crimson red, warped
    // teal-grey, soul sand valley cold grey, basalt ash). Hue only, partly desaturated, so blocks keep their own
    // colours: the old constant orange multiplier turned grey soul sand red. Local warmth comes from the light
    // field and netherUplight, not from here.
    vec3 biomeAir = toLinear(fogColor);
    biomeAir = mix(vec3(luminance(biomeAir)), biomeAir, 0.55) / max(luminance(biomeAir), 1e-3);
    ambient = mix(vec3(0.36, 0.29, 0.25), biomeAir * 0.30, 0.6) * 1.6 * (0.8 - 0.3 * n.y) * ao;
#elif defined DIM_END
    // Dim violet ambient plus a soft light from the storm overhead, so pillars and islands keep their shape.
    const vec3 endLightDir = vec3(0.37, 0.83, 0.42);
    ambient = vec3(0.26, 0.18, 0.40) * (0.75 + 0.25 * n.y) * ao
            + vec3(0.9, 0.55, 1.5) * saturate(dot(n, endLightDir) * 0.8 + 0.2) * 0.55 * ao;
#endif
    vec3 torch = blockLight(lm.x) * mix(ao, 1.0, 0.4);
#ifdef FIELD_SHADING
    if (surfaceField.weight > 0.0 && mat != MAT_HAND)
        torch = mix(torch, fieldBlockLight(surfaceField, n, lm.x, ao), surfaceField.weight);
#endif
#if defined DIM_NETHER
    // Keep the Nether's residual fill warm-neutral instead of the cool blue floor used elsewhere.
    vec3 minLight = vec3(MIN_LIGHT) * vec3(0.95, 0.72, 0.48) * ao;
#else
    // The floor only exists near open sky (moonless night, deep overhangs). Sealed caves get almost none, so an
    // unlit cave is dark and only its light sources reveal it.
    vec3 minLight = vec3(MIN_LIGHT) * vec3(0.7, 0.8, 1.0) * ao * mix(0.06, 1.0, smoothstep(0.0, 0.5, lm.y));
#endif

    vec3 col = albedo * (direct / PI + ambient / PI + torch + minLight);
#if defined DIM_NETHER
    // Obsidian, blackstone and basalt have near-zero albedo. Give those opaque stone surfaces a restrained
    // ashen floor so their texture and face-to-face shape survive exposure without lifting foliage or lava.
    float darkRock = (mat == MAT_NONE || mat == MAT_LOD)
        ? 1.0 - smoothstep(0.025, 0.16, luminance(albedo))
        : 0.0;
    col += vec3(0.016, 0.011, 0.008) * darkRock * ao * (0.72 + 0.28 * n.y);
#endif
    // Lava stores its heat-dependent emission here and is far brighter than other emitters: seams glow dull
    // red, the molten body is bright, white-hot upwellings are blinding and bloom.
    col += albedo * (mat == MAT_LAVA ? emissive * emissive * 20.0 : emissive * 6.0);
#if defined DIM_END
    // Near-black obsidian and unclassified terrain otherwise collapse into flat cutouts. A restrained violet
    // bounce lifts only dark terrain/LOD texels; AO and storm-facing direction keep it shaped and localized.
    if (mat == MAT_NONE || mat == MAT_LOD) {
        float darkSurface = 1.0 - smoothstep(0.012, 0.075, luminance(albedo));
        float textureDetail = 0.62 + 0.38 * sqrt(saturate(luminance(albedo) * 48.0));
        float stormFacing = 0.65 + 0.35 * saturate(dot(n, vec3(0.37, 0.83, 0.42)) * 0.5 + 0.5);
        col += vec3(0.006, 0.002, 0.012) * darkSurface * textureDetail * stormFacing * ao;
    }
#endif
    return col;
}

uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;

// Handheld light: a torch (or any light-emitting item) in either hand lights the surroundings like a placed
// block would, fading one light level per block, with a soft wrap so it also reaches surfaces edge-on.
// Requires uniforms heldBlockLightValue, heldBlockLightValue2 (dynamicHandLight=true in shaders.properties).
vec3 handheldLight(vec3 playerPos, vec3 n, float ao) {
    float level = float(max(heldBlockLightValue, heldBlockLightValue2));
    if (level <= 0.0) return vec3(0.0);
    // The item is held a little below and in front of the eye.
    vec3 toLight = vec3(0.0, -0.3, 0.0) - playerPos;
    float d = length(toLight);
    float lm = saturate((level - d) / 15.0);
    if (lm <= 0.0) return vec3(0.0);
    float wrap = saturate(dot(n, toLight / max(d, 1e-3)) * 0.75 + 0.25);
    return blockLight(lm) * wrap * mix(ao, 1.0, 0.3) * 0.7;
}

#ifdef DIM_NETHER
// Volcanic glass reflects the charcoal smoke overhead and a restrained ember band at the horizon. Keeping the
// reflection independent of biome fog tint avoids the cyan/blue sheen seen in warped and soul-sand biomes.
vec3 netherStoneReflection(vec3 rayDir) {
    vec3 r = normalize(vec3(rayDir.x, max(rayDir.y, 0.05), rayDir.z));
    float horizonEmber = exp(-r.y * 5.5);
    vec3 ash = vec3(0.022, 0.018, 0.015) * (0.85 + 0.15 * r.y);
    vec3 ember = vec3(0.13, 0.032, 0.006) * horizonEmber;
    return ash + ember;
}

// Heat rising off the lava seas: surfaces low down and facing down (ceilings, overhangs, cliff undersides)
// catch warm light from below.
// This is the far-field stand-in for the light field: beyond the voxel grid (or with the sea below it) the
// lava level is the only source of heat. fieldWeight fades it out where the grid sees the actual lava.
vec3 netherUplight(vec3 wp, vec3 n, float ao, float fieldWeight) {
    float nearLava = exp(-max(wp.y - 31.0, 0.0) / 54.0);
    float facing = saturate(0.55 - n.y * 0.45);
    return vec3(3.4, 0.82, 0.12) * 0.45 * nearLava * facing * mix(ao, 1.0, 0.3) * (1.0 - 0.75 * fieldWeight);
}
#endif
