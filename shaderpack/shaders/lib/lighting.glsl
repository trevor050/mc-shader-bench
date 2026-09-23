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
    bool day = sunDir.y > -0.05;
    e.lightDir = day ? sunDir : -sunDir;
    vec3 sunT = sunTransmittance(sunDir) * SUN_ILLUMINANCE;
    vec3 moonT = sunTransmittance(-sunDir) * SUN_ILLUMINANCE * MOON_ILLUMINANCE * vec3(0.55, 0.75, 1.25);
    // Fade across the horizon swap so the shadow direction change is not a pop.
    float fade = smoothstep(0.0, 0.08, abs(sunDir.y + 0.02));
    e.directLight = (day ? sunT : moonT) * fade * (1.0 - rainStrength * 0.9);

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
        float back = pow(saturate(dot(viewDir, env.lightDir)), 4.0);
        direct += env.directLight * shadow * leak * back * 0.9 * albedo;
    }

    // Sky light: favor upward-facing surfaces, keep some fill on walls.
    float skyFacing = 0.62 + 0.38 * n.y;
    vec3 skyAmb = mix(env.skyAmbient, vec3(luminance(env.skyAmbient)), 0.3);
    // Ground bounce: sunlight reflected off terrain fills shadows with warmer light, strongest on walls.
    vec3 bounce = env.directLight * vec3(0.30, 0.26, 0.20) * 0.18 * (1.0 - 0.6 * n.y);
    vec3 ambient = (skyAmb * skyFacing + bounce) * skyVis * ao;
    vec3 torch = blockLight(lm.x) * mix(ao, 1.0, 0.4);
    vec3 minLight = vec3(MIN_LIGHT) * vec3(0.7, 0.8, 1.0) * ao;

    vec3 col = albedo * (direct / PI + ambient / PI + torch + minLight);
    col += albedo * emissive * 6.0;
    return col;
}
