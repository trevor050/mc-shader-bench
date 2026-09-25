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

#ifdef FIELD_SHADING
// Set by the caller (sampleLightField) before shadeSurface; lets the same entry point serve passes that do
// not read the voxel field.
FieldLight surfaceField;
#endif

uniform vec3 skyColor;
uniform float screenBrightness;
uniform float inSnowy; // custom uniform: smoothed 1 in biomes where it snows

// Snowfields: fresh snow reflects most of the light it receives, so shade is lifted by a strong, cool bounce
// and the air holds a bright ice haze that whites out the distance (composite).
vec3 snowWhiteout(vec3 haze) {
    float l = luminance(haze);
    return mix(haze, vec3(l) * vec3(0.96, 1.0, 1.07) * 1.45, 0.75);
}
// How far the horizon (sky and far fog alike) whitens: partly in clear weather, fully in snowfall.
float snowHorizonShare() { return 0.55 + 0.45 * rainStrength; }

// ---------------------------------------------------------------------------------------------------------------
// Surface lighting, ported from Complementary Unbound r5.9.3 (EminGT; lib/lighting/mainLighting.glsl DoLighting,
// lib/colors/lightAndAmbientColors.glsl, lib/lighting/minimumLighting.glsl). Credit to EminGT; Trevor asked for
// this engine specifically. The structure is kept: every light term is combined under one square root in
// display ("gamma") space, sqrt(shade^2 * (block + scene^2 + minimum) + emission^2), which is why torches dominate
// dark caves yet vanish in daylight, why shade never collapses to black, and why coloured light reads as a tint
// of the surface rather than an added glow. Our pipeline is linear, so the result is raised to 2.2 at the end
// (identical to Complementary's own late pow(color, 2.2)).
//
// Changes from the original:
//  - Block light colour and direction come from our voxel field: the field's gradient brightens faces turned
//    toward a source (Complementary's volume only gives a hue), and emitters take their colour from their own
//    texture, so modded light blocks need no table.
//  - Extra light (lava seas, portals) accumulates across many source blocks, so a lava lake reaches farther
//    than a single lava block, and the smoke in the Nether is lit by the same field.
//  - Sun and moon colour follow our physical sky (the transmittance hue at the current sun height) blended into
//    Complementary's hand-tuned palette, so sunsets carry the actual colour of the sky overhead.
//  - The sealed-cave leak guard (direct light needs some vanilla sky light) is kept from our engine: shadow maps
//    are not reliable occluders deep underground.
//  - Cloud shadows, our shadow filter and SSAO are applied as before.
// ---------------------------------------------------------------------------------------------------------------

const vec3 CU_BLOCKLIGHT_COL = vec3(0.1775, 0.104, 0.077);

float cuLuminance(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
vec3 cuLuminanceCorrection(vec3 c) { return c / (cuLuminance(c) + 0.0001); }
float cuSmoothstep1(float x) { return x * x * (3.0 - 2.0 * x); }

struct CuTime {
    float sunVisibility2, noonFactor, invNoonFactor, invNoonFactor2, shadowTime, vsBrightness, rainFactor;
};

CuTime cuTime(vec3 sunDir) {
    CuTime t;
    float SdotU = sunDir.y;
    float sunVisibility = clamp(SdotU + 0.0625, 0.0, 0.125) / 0.125;
    t.sunVisibility2 = sunVisibility * sunVisibility;
    // sin(timeAngle * 2pi) is the sun's height on its (rotated) path.
    t.noonFactor = sqrt(saturate(SdotU / 0.9063));
    t.invNoonFactor = 1.0 - t.noonFactor;
    t.invNoonFactor2 = t.invNoonFactor * t.invNoonFactor;
    float s1 = abs(sunVisibility - 0.5) * 2.0;
    float s2 = s1 * s1;
    t.shadowTime = s2 * s2;
    t.vsBrightness = clamp(screenBrightness, 0.0, 1.0);
    t.rainFactor = rainStrength;
    return t;
}

// Sun/moon light colour and sky ambient colour (Complementary's palette, gamma-space units).
void cuLightAndAmbient(CuTime t, LightEnv env, out vec3 lightColor, out vec3 ambientColor) {
#if defined DIM_NETHER
    lightColor = vec3(0.0);
    vec3 fc = toLinear(fogColor) + 1e-4;
    vec3 netherColor = pow(fc, vec3(1.0 / 2.2)) * 0.6 + 0.2 * normalize(fc);
    const vec3 lavaLightColor = vec3(0.15, 0.06, 0.01);
    ambientColor = (netherColor + 0.5 * lavaLightColor) * (0.9 + 0.45 * t.vsBrightness);
#elif defined DIM_END
    const vec3 endLightColor = vec3(0.68, 0.51, 1.07);
    float endLightBalancer = 0.2 * t.vsBrightness;
    // Brighter than Complementary's so the storm's moving cloud shadows read on the islands.
    lightColor = endLightColor * (0.35 - endLightBalancer) * 1.8;
    ambientColor = endLightColor * (0.2 + endLightBalancer);
#else
    vec3 noonClearLightColor = vec3(0.65, 0.55, 0.375) * 2.05;
    vec3 noonClearAmbientColor = pow(skyColor, vec3(0.75)) * 0.85;
    vec3 sunsetClearLightColor = pow(vec3(0.64, 0.45, 0.3), vec3(1.5 + t.invNoonFactor)) * 5.0;
    // Golden hour: the shared sunset palette (gold -> orange as the sun sinks), a little brighter than
    // Complementary's, so everything it touches glows. Shade stays cool violet from the sky: the warm/cool
    // contrast is what makes golden hour look like golden hour.
    sunsetClearLightColor = sunsetLightTint(env.sunDir.y) * cuLuminance(sunsetClearLightColor) * 1.3;
    vec3 sunsetClearAmbientColor = noonClearAmbientColor * vec3(1.02, 0.86, 1.12);
    vec3 nightClearLightColor = 0.9 * vec3(0.15, 0.14, 0.20) * (0.4 + t.vsBrightness * 0.4);
    vec3 nightClearAmbientColor = 0.9 * vec3(0.09, 0.12, 0.17) * (1.55 + t.vsBrightness * 0.77);
    vec3 dayRainLightColor = vec3(0.21, 0.16, 0.13) * 0.85 + t.noonFactor * vec3(0.0, 0.02, 0.06);
    vec3 dayRainAmbientColor = vec3(0.2, 0.2, 0.25) * (1.8 + 0.5 * t.vsBrightness);
    vec3 nightRainLightColor = vec3(0.03, 0.035, 0.05) * (0.5 + 0.5 * t.vsBrightness);
    vec3 nightRainAmbientColor = vec3(0.16, 0.20, 0.3) * (0.75 + 0.6 * t.vsBrightness);

    vec3 dayLightColor = mix(sunsetClearLightColor, noonClearLightColor, t.noonFactor);
    // Our physical sky's transmittance colour, carried into the day palette as a hue (luminance kept).
    vec3 skyHue = env.directLight / max(cuLuminance(env.directLight), 1e-5);
    dayLightColor = mix(dayLightColor, skyHue * cuLuminance(dayLightColor), mix(0.35, 0.1, sunsetWindow(env.sunDir.y)));
    vec3 dayAmbientColor = mix(sunsetClearAmbientColor, noonClearAmbientColor, t.noonFactor);
    vec3 clearLightColor = mix(nightClearLightColor, dayLightColor, t.sunVisibility2);
    vec3 clearAmbientColor = mix(nightClearAmbientColor, dayAmbientColor, t.sunVisibility2);
    const float rainShadowVisReduce = 0.4;
    vec3 rainLightColor = mix(nightRainLightColor, dayRainLightColor * (1.0 - rainShadowVisReduce), t.sunVisibility2) * 2.5;
    vec3 rainAmbientColor = mix(nightRainAmbientColor, dayRainAmbientColor * (1.0 + rainShadowVisReduce), t.sunVisibility2);
    lightColor = mix(clearLightColor, rainLightColor, t.rainFactor);
    ambientColor = mix(clearAmbientColor, rainAmbientColor, t.rainFactor);
#endif
}

// Kept for callers outside the surface path (handheld light).
float blockLightLevel(float lmBlock) {
    float l2 = lmBlock * lmBlock;
    return BLOCKLIGHT_STRENGTH * pow(lmBlock, 1.6) * (0.35 + 0.65 * l2 * l2);
}
vec3 blockLight(float lmBlock) { return BLOCKLIGHT_COLOR * blockLightLevel(lmBlock); }

// albedo is linear. shadow is the filtered visibility for the light (1 = lit), not yet multiplied by N.L.
vec3 shadeSurface(LightEnv env, vec3 albedo, vec3 n, vec3 viewDir, vec2 lm, float ao, int mat, vec3 shadow, float emissive) {
    CuTime t = cuTime(env.sunDir);
    vec3 lightColorM, ambientColorM;
    cuLightAndAmbient(t, env, lightColorM, ambientColorM);
#if !defined DIM_NETHER && !defined DIM_END
    ambientColorM *= 1.0 + inSnowy * (0.6 * t.sunVisibility2 + 0.2) * (1.0 - 0.5 * t.rainFactor);
#endif
    vec3 gammaAlbedo = pow(max(albedo, vec3(0.0)), vec3(1.0 / 2.2));

    bool foliage = mat == MAT_FOLIAGE || mat == MAT_LEAVES || mat == MAT_TALL_UPPER;
    int subsurfaceMode = (mat == MAT_FOLIAGE || mat == MAT_TALL_UPPER) ? 1 : (mat == MAT_LEAVES ? 2 : 0);
    float NdotU = n.y;
    float NdotUmax0 = max(NdotU, 0.0);
    float absNdotN = abs(n.z);
    float absNdotE = abs(n.x);
    float NdotL = dot(n, env.lightDir);
    float lightmapY2 = lm.y * lm.y;
    float lightmapYM = cuSmoothstep1(lm.y);
    float ambientMult = 1.0;

    // Sun / moon.
    vec3 shadowMult = vec3(0.0);
#if !defined DIM_NETHER
    float NdotLM = subsurfaceMode != 0 ? 1.0 : max(NdotL + 0.4, 0.0) * 0.714; // side shadowing
#ifdef DIM_END
    NdotLM = pow(NdotLM, 1.0 / 3.0);
#endif
    shadowMult = shadow * max(NdotLM * t.shadowTime, 0.0);
#if !defined DIM_END
    // Direct light needs open sky: caves never see the sun or moon even where the shadow map is unreliable. On 26.2
    // Iris culls the rock overhead out of the shadow pass beyond voxelDistance when the camera is underground, so a
    // cave with a little sky light (near any opening) got hard-edged "phantom" moonlight. Open-air surfaces, even
    // under trees and overhangs, sit at sky light 13-15; only the first blocks inside an opening pass this gate.
    shadowMult *= smoothstep(0.55, 0.87, lm.y);
#endif
#endif
    float shadowMultFloat = min(cuLuminance(shadowMult), 1.0);

    // Block light: Complementary's vanilla curve, coloured (and here also directed and extended) by the field.
    float vsB = t.vsBrightness;
    const float XLIGHT_CURVE = 1.0;
    float steep = pow(lm.x * lm.x, 4.0) * (2.8 - 0.6 * vsB + XLIGHT_CURVE);
    float calm = lm.x * (2.8 + 0.6 * vsB - XLIGHT_CURVE);
    float lightmapXM = pow(steep + calm, 2.25);
    vec3 blockLighting = lightmapXM * CU_BLOCKLIGHT_COL;
#ifdef FIELD_SHADING
    if (surfaceField.weight > 0.0 && mat != MAT_HAND) {
        FieldLight f = surfaceField;
        float volA = f.extraRaw;
        vec3 special = f.radiance / LIGHT_FIELD_GAIN;
        lightmapXM = max(lightmapXM, mix(lightmapXM, 10.0, volA));
        // The field may brighten but never darken: low-level coloured lights (redstone, amethyst) glow around
        // themselves, while vanilla's level stays the floor so a lagging field cannot leave black pockets.
#if !defined DIM_NETHER
        // (Not in the Nether: its lava-lit balance is tuned on vanilla levels plus the extra channel.)
        lightmapXM = max(lightmapXM, cuLuminance(special) * FIELD_BRIGHTNESS * f.weight);
#endif
        special *= 1.0 + 50.0 * volA;
        // The square-root light mix below halves chroma; pre-expand it so coloured light survives as colour.
        float specialL = cuLuminance(special);
        special = max(specialL + (special - specialL) * BLOCKLIGHT_SATURATION, vec3(0.0));
        special = lightmapXM * 0.13 * cuLuminanceCorrection(special + CU_BLOCKLIGHT_COL * 0.05);
        // Direction from the field's gradient (ours): faces toward the source a little brighter, away darker.
        float facing = f.focus > 0.0 ? dot(n, f.dir) : 0.0;
        special *= mix(1.0, saturate(facing * 0.5 + 0.6) * 1.2, f.focus * 0.6);
        // Complementary's AddSpecialLightDetail: a non-contrasty lift that carries the light's hue into dark texels.
        vec3 lightM = max(special, vec3(0.0));
        lightM /= (0.2 + 0.8 * cuLuminance(lightM));
        lightM *= (1.0 / (1.0 + emissive)) * 0.22;
        special = special * 0.9 + (lightM / (gammaAlbedo + 0.1)) * (lightM / (gammaAlbedo + 0.1));
        blockLighting = mix(blockLighting, special, f.weight);
    }
#endif

    // Minimum (cave) light: cool, only where sky light is absent.
    vec3 minLighting = vec3(0.0);
#if !defined DIM_END
    minLighting = vec3(0.005625 + vsB * 0.043) * vec3(0.45, 0.475, 0.6) * (1.0 - lightmapYM);
#endif

#if !defined DIM_NETHER && !defined DIM_END
    ambientMult = mix(lightmapYM, lightmapYM * lightmapYM * lightmapYM, t.rainFactor);
    // Daylight suppresses block light; nearer surfaces a little brighter at night and in rain.
    float lxFactor = (t.sunVisibility2 * 0.4 + (0.6 - 0.6 * t.invNoonFactor2)) * (6.0 - 5.0 * t.rainFactor);
    lxFactor *= lightmapY2 + lightmapY2 * 2.0 * shadowMultFloat * shadowMultFloat;
    lxFactor = max(lxFactor - emissive * 1000000.0, 0.0);
    blockLighting *= pow(lightmapXM / 60.0 + 0.001, 0.09 * lxFactor);
#endif

    // Directional shading.
    float absNdotE2 = absNdotE * absNdotE;
#if !defined DIM_NETHER
    float NdotUM = 0.75 + NdotU * 0.25;
#else
    float NdotUM = 0.75 + abs(NdotU + 0.5) * 0.16666;
#endif
    float directionShade = NdotUM * (1.0 - 0.1 * absNdotE2) * (1.0 + 0.075 * absNdotN);
#if !defined DIM_NETHER && !defined DIM_END
    lightColorM *= 1.0 + absNdotE2 * 0.75;
    // Fake bounced light, and a more natural noon.
    ambientColorM = mix(ambientColorM, lightColorM, (0.05 + 0.03 * float(subsurfaceMode)) * absNdotN * lightmapY2);
    lightColorM *= 1.0 + max(1.0 - float(subsurfaceMode), 0.0) * pow(t.noonFactor, 20.0) * (absNdotN * absNdotN * 0.8 - absNdotE2 * 0.2);
#elif defined DIM_NETHER
    directionShade *= directionShade;
    // Glow of the lava seas on ceilings and north/south faces.
    ambientColorM += vec3(0.15, 0.06, 0.01) * pow(absNdotN * 0.5 + max(-NdotU, 0.0), 2.0) * (0.7 + 0.35 * vsB);
#endif

    vec3 sceneLighting = lightColorM * shadowMult + ambientColorM * ambientMult;
    float dotSceneLighting = dot(sceneLighting, sceneLighting);

    // Vanilla ambient occlusion curve.
    float vanillaAO = ao;
    if (subsurfaceMode != 0) vanillaAO = mix(min(vanillaAO * 1.15, 1.0), 1.0, shadowMultFloat);
    else {
        vanillaAO = min(vanillaAO + 0.08, 1.0);
#if !defined DIM_NETHER && !defined DIM_END
        vanillaAO = pow(pow(vanillaAO, 1.5), 1.0 + dotSceneLighting * 0.02 + NdotUmax0 * (0.15 + 0.25 * pow(t.noonFactor * lightmapY2, 2.0)));
#elif defined DIM_NETHER
        vanillaAO = pow(pow(vanillaAO, 1.5), 1.0 + NdotUmax0 * 0.5);
#else
        vanillaAO = pow(vanillaAO, 0.75 + NdotUmax0 * 0.25);
#endif
    }
    vanillaAO = vanillaAO * 0.9 + 0.1;

    float shadeAO = directionShade * vanillaAO;
    vec3 finalDiffuse = shadeAO * shadeAO * (blockLighting + sceneLighting * sceneLighting + minLighting);
    finalDiffuse = sqrt(max(finalDiffuse, vec3(0.0)));

    // Back to linear: albedo_lin * finalDiffuse^2.2 == (gammaAlbedo * finalDiffuse)^2.2.
    vec3 col = albedo * pow(finalDiffuse, vec3(2.2)) * CU_EXPOSURE_SCALE;

    // Foliage: a soft translucent highlight looking toward the sun.
#if !defined DIM_NETHER
    if (subsurfaceMode != 0) {
        float sss = pow(saturate(dot(-viewDir, env.lightDir)), 10.0);
        vec3 highlightColor = normalize(pow(max(lightColorM, 1e-4), vec3(0.37))) * (0.3 + 1.5 * t.sunVisibility2) * (1.0 - 0.85 * t.rainFactor);
        col += pow(albedo, vec3(0.5)) * shadowMult * highlightColor * sss * (subsurfaceMode == 1 ? 0.8 : 0.6) * CU_EXPOSURE_SCALE;
    }
#endif

    // Emission, kept additive in linear: lava is far brighter than the rest.
    col += albedo * (mat == MAT_LAVA ? emissive * emissive * LAVA_EMISSION : emissive * BLOCK_EMISSION);
#if defined DIM_END
    if (mat == MAT_NONE || mat == MAT_LOD || mat == MAT_GLASSY) {
        float darkSurface = 1.0 - smoothstep(0.012, 0.075, luminance(albedo));
        col += vec3(0.006, 0.002, 0.012) * darkSurface * ao;
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
