// Cloud march into half-resolution color and distance targets.
// Writes colortex7 = premultiplied cloud radiance + transmittance, colortex8 = (cloud distance, scene distance).
// Every pixel is marched every frame with a fresh dither; clouds_temporal.glsl accumulates the result.

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

uniform vec3 sunPosition;
uniform mat4 gbufferModelViewInverse;
uniform float rainStrength;
uniform float frameTimeCounter;
#include "/lib/atmosphere.glsl"
#include "/lib/lighting.glsl"

#ifdef VERTEX
flat out vec3 sunDir;
flat out vec3 envLightDir;
flat out vec3 envDirect;
flat out vec3 skyLight;
flat out vec3 envLightDirHi;
flat out vec3 envDirect1;
flat out vec3 envDirect2;
void main() {
    gl_Position = ftransform();
    sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    LightEnv e = makeLightEnv(sunDir);
    envLightDir = e.lightDir;
    envDirect = e.directLight;
    // Sunset: clouds take the sunset palette (gold -> coral -> magenta -> crimson) and, being high up, keep
    // the sun's light for a while after it has set for the ground, lit from below: cotton-candy undersides
    // instead of dark silhouettes.
    float sw = sunsetWindow(sunDir.y);
    if (sw > 0.0 && sunDir.y > -0.16) {
        envLightDir = sunDir;
        envDirect = mix(e.directLight, cloudSunsetLight(sunDir), sw);
    }
    // Altocumulus and cirrus sit far higher: they see the sun set later, so each gets the palette a little behind
    // the cumulus (gold on the cirrus while the cumulus is already pink, rose-lilac on it after the rest have gone grey).
    envLightDirHi = envLightDir;
    envDirect1 = envDirect;
    envDirect2 = envDirect;
    {
        float sw1 = sunsetWindow(sunDir.y + 0.035), sw2 = sunsetWindow(sunDir.y + 0.07);
        if ((sw1 > 0.0 || sw2 > 0.0) && sunDir.y > -0.23) {
            envLightDirHi = sunDir;
            envDirect1 = mix(e.directLight, cloudSunsetLight(sunDir, 0.035), sw1);
            envDirect2 = mix(e.directLight, cloudSunsetLight(sunDir, 0.07), sw2);
        }
    }
    // Light arriving from the sky dome above a cloud (hemisphere integral of the zenith radiance).
    skyLight = skyRadiance(vec3(0.0, 1.0, 0.0), sunDir, 6) * TAU * 0.9;
    // At golden hour the direct light is deep orange; shaded cloud sides are lit by the still-blue sky
    // overhead, which is what turns them lilac instead of brown.
    skyLight *= mix(1.0, 1.4, 1.0 - smoothstep(0.02, 0.3, sunDir.y));
    // The dusk sky overhead is periwinkle-lavender, and that is the colour of every cloud flank the sun misses.
    skyLight = mix(skyLight, vec3(luminance(skyLight)) * vec3(0.86, 0.8, 1.25), sw * 0.6);
    // At dusk the lavender dome is a large share of what lights a cloud: it is what turns orange-lit clouds pink
    // away from the sun and fills their shaded bodies with lilac.
    skyLight *= mix(1.0, CLOUD_DUSK_SKYLIGHT, sw);
    // Moonlit clouds read a little brighter and cooler than the physical moonlight alone gives them.
    float moonNight = smoothstep(-0.06, -0.2, sunDir.y);
    envDirect *= mix(vec3(1.0), vec3(1.05, 1.15, 1.3), moonNight);
}
#endif

#ifdef FRAGMENT
uniform int frameCounter;
uniform float viewWidth;
uniform float viewHeight;
uniform sampler2D depthtex0;
uniform sampler2D dhDepthTex0;
uniform mat4 gbufferProjectionInverse;
uniform mat4 dhProjectionInverse;
uniform vec3 cameraPosition;
#include "/lib/clouds.glsl"

flat in vec3 sunDir;
flat in vec3 envLightDir;
flat in vec3 envDirect;
flat in vec3 skyLight;
flat in vec3 envLightDirHi;
flat in vec3 envDirect1;
flat in vec3 envDirect2;

/* RENDERTARGETS: 7,8 */
layout(location = 0) out vec4 outClouds;
layout(location = 1) out vec4 outDist;

void main() {
    // Use the actual half-resolution target grid. Iris truncates relative buffer sizes, so this keeps
    // normalized sample positions aligned with consumers when the full-resolution viewport is odd-sized.
    vec2 targetRes = max(floor(vec2(viewWidth, viewHeight) * 0.5), vec2(1.0));
    vec2 uv = gl_FragCoord.xy / targetRes;

#if defined DIM_NETHER || defined DIM_END || !defined CLOUDS
    outClouds = vec4(0.0, 0.0, 0.0, 1.0);
    outDist = vec4(1e6, 1e6, 0.0, 0.0);
    return;
#endif

    float depth = texture(depthtex0, uv).r;
    vec3 viewPos;
    bool sky = false;
    if (depth < 1.0) {
        viewPos = projectAndDivide(gbufferProjectionInverse, vec3(uv, depth) * 2.0 - 1.0);
    } else {
        float dh = texture(dhDepthTex0, uv).r;
        sky = dh >= 1.0;
        viewPos = projectAndDivide(sky ? gbufferProjectionInverse : dhProjectionInverse, vec3(uv, sky ? 1.0 : dh) * 2.0 - 1.0);
    }
    vec3 playerPos = mat3(gbufferModelViewInverse) * viewPos;
    vec3 rd = normalize(playerPos);
    // The first-person hand is right in front of the camera: nothing lies between it and the eye.
    float sceneDist = depth < 0.56 ? 0.25 : (sky ? 1e6 : length(playerPos));
    // The hand is not world geometry.

    float dither = ignTemporal(gl_FragCoord.xy, frameCounter);
    // By moonlight the bright rim toward the moon is what makes a night cloud: silver its edges.
    gCloudRim = mix(1.0, CLOUD_MOON_SILVER * 1.6, smoothstep(-0.06, -0.2, sunDir.y));
    float dist;
    vec4 c = renderClouds(cameraPosition, rd, sceneDist, sunDir, envLightDir, envDirect, envLightDirHi, envDirect1, envDirect2,
                          skyLight, dither, dist);
    outClouds = c;
    outDist = vec4(min(dist, 1e6), sceneDist, 0.0, 0.0);
}
#endif
