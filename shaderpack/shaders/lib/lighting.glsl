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
    e.lightDir = day ? sunDir : -sunDir;
    // Only the active shadow caster needs a ground transmittance estimate.
    // Keep the original per-branch radiance scaling while avoiding four unused optical-depth samples.
    vec3 directT = day
        ? sunTransmittance(sunDir) * SUN_ILLUMINANCE
        : sunTransmittance(-sunDir) * SUN_ILLUMINANCE * MOON_ILLUMINANCE * 1.45 * vec3(0.55, 0.75, 1.25);
    // Fade across the horizon swap so the shadow direction change is not a pop.
    float fade = smoothstep(0.0, 0.08, abs(sunDir.y + 0.02));
    e.directLight = directT * fade * (1.0 - rainStrength * 0.9);

    vec3 up = scatter(vec3(0.0, 1.0, 0.0), sunDir, SUN_ILLUMINANCE, 6)
            + scatter(vec3(0.0, 1.0, 0.0), -sunDir, SUN_ILLUMINANCE * MOON_ILLUMINANCE, 4) * vec3(0.6, 0.8, 1.3);
    vec3 side = scatter(normalize(vec3(sunDir.x, 0.25, sunDir.z)), sunDir, SUN_ILLUMINANCE, 6);
    e.skyAmbient = (up * 2.2 + side * 1.1) * PI * 0.5 + vec3(0.0015, 0.002, 0.003);
    e.skyAmbient = mix(e.skyAmbient, vec3(luminance(e.skyAmbient)) * 0.8, rainStrength * 0.6);
    return e;
}

vec3 blockLight(float lmBlock) {
    // Inverse-square-ish falloff mapped onto Minecraft's linear light levels.
    float l = lmBlock * lmBlock;
    float falloff = l / (1.0 + (1.0 - lmBlock) * 22.0);
    return BLOCKLIGHT_COLOR * BLOCKLIGHT_STRENGTH * falloff;
}

// albedo is linear. shadow is the filtered visibility for the light (1 = lit).
vec3 shadeSurface(LightEnv env, vec3 albedo, vec3 n, vec3 viewDir, vec2 lm, float ao, int mat, vec3 shadow, float emissive) {
    float NdotL = dot(n, env.lightDir);
    bool foliage = mat == MAT_FOLIAGE || mat == MAT_LEAVES || mat == MAT_TALL_UPPER;

    float skyVis = lm.y * lm.y;
    float diffuse = foliage ? (0.45 + 0.55 * saturate(NdotL)) : saturate(NdotL);
    // Direct light also needs open sky: stops light leaking into sealed caves beyond shadow range.
    float leak = smoothstep(0.0, 0.35, lm.y);
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
    // Hot, directionless nether glow.
    ambient = vec3(1.1, 0.5, 0.32) * (0.7 + 0.3 * n.y) * ao;
#elif defined DIM_END
    // Dim violet ambient plus a soft light from the storm overhead, so pillars and islands keep their shape.
    const vec3 endLightDir = vec3(0.37, 0.83, 0.42);
    ambient = vec3(0.26, 0.18, 0.40) * (0.75 + 0.25 * n.y) * ao
            + vec3(0.9, 0.55, 1.5) * saturate(dot(n, endLightDir) * 0.8 + 0.2) * 0.55 * ao;
#endif
    vec3 torch = blockLight(lm.x) * mix(ao, 1.0, 0.4);
    vec3 minLight = vec3(MIN_LIGHT) * vec3(0.7, 0.8, 1.0) * ao;

    vec3 col = albedo * (direct / PI + ambient / PI + torch + minLight);
    col += albedo * emissive * 6.0;
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
// Heat rising off the lava seas: surfaces low down and facing down (ceilings, overhangs, cliff undersides)
// catch warm light from below.
vec3 netherUplight(vec3 wp, vec3 n, float ao) {
    float nearLava = exp(-max(wp.y - 31.0, 0.0) / 30.0);
    float facing = saturate(0.55 - n.y * 0.45);
    return vec3(3.2, 0.9, 0.18) * nearLava * facing * mix(ao, 1.0, 0.3);
}
#endif