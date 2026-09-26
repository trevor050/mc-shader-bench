// Cloud march into half-resolution color and distance targets.
// Writes colortex7 = premultiplied cloud radiance + transmittance, colortex8 = (cloud distance, scene distance).
// colortex3 preserves normalized distances until composite2; VL reuses colortex8 before that consumer.
// Every pixel is marched every frame with a fresh dither; clouds_temporal.glsl accumulates the result.

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

uniform vec3 sunPosition;
uniform mat4 gbufferModelViewInverse;
uniform float rainStrength;
uniform float frameTimeCounter;
#include "/lib/atmosphere.glsl"
#include "/lib/lighting.glsl"
#include "/lib/clouds.glsl"

#ifdef VERTEX
flat out vec3 sunDir;
flat out vec3 envLightDir;
flat out vec3 envDirect;
flat out vec3 skyLight;
flat out vec3 envLightDirHi;
flat out vec3 envDirect1;
flat out vec3 envDirect2;
flat out vec4 weather0;
flat out vec3 weather1;
flat out vec3 deckWeather;
void main() {
    gl_Position = ftransform();
    sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    CloudLightEnv e = makeCloudLightEnv(sunDir);
    envLightDir = e.lightDir;
    envDirect = e.directLight;
    envLightDirHi = e.lightDirHi;
    envDirect1 = e.directLight1;
    envDirect2 = e.directLight2;
    skyLight = e.skyLight;
    CloudWeather w = cloudWeather();
    weather0 = vec4(w.cov0, w.tower, w.cov1, w.cirrus);
    weather1 = vec3(w.low, w.lowCov, w.cb);
    deckWeather = vec3(veilAmount(w), fractusAmount(w), virgaAmount(w));
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

flat in vec3 sunDir;
flat in vec3 envLightDir;
flat in vec3 envDirect;
flat in vec3 skyLight;
flat in vec3 envLightDirHi;
flat in vec3 envDirect1;
flat in vec3 envDirect2;
flat in vec4 weather0;
flat in vec3 weather1;
flat in vec3 deckWeather;

/* RENDERTARGETS: 7,8,3 */
layout(location = 0) out vec4 outClouds;
layout(location = 1) out vec4 outDist;
layout(location = 2) out vec4 outCloudFogDepth;

void main() {
    // Use the actual half-resolution target grid. Iris truncates relative buffer sizes, so this keeps
    // normalized sample positions aligned with consumers when the full-resolution viewport is odd-sized.
    vec2 targetRes = max(floor(vec2(viewWidth, viewHeight) * 0.5), vec2(1.0));
    vec2 uv = gl_FragCoord.xy / targetRes;

#if defined DIM_NETHER || defined DIM_END || !defined CLOUDS
    outClouds = vec4(0.0, 0.0, 0.0, 1.0);
    outDist = vec4(1e6, 1e6, 0.0, 0.0);
    outCloudFogDepth = vec4(vec2(1e6 / 65536.0), 0.0, 0.0);
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
    CloudWeather w = CloudWeather(weather0.x, weather0.y, weather0.z, weather0.w, weather1.x, weather1.y, weather1.z);
    gCloudDeckWeather = deckWeather;
    vec4 c = renderClouds(cameraPosition, rd, sceneDist, sunDir, envLightDir, envDirect, envLightDirHi, envDirect1, envDirect2,
                          skyLight, dither, w, dist);
    outClouds = c;
    outDist = vec4(min(dist, 1e6), sceneDist, 0.0, 0.0);
    // colortex3 is RGBA16F. Scaling keeps the no-cloud sentinel finite without allocating another target.
    outCloudFogDepth = vec4(min(vec2(dist, sceneDist), vec2(1e6)) / 65536.0, 0.0, 0.0);
}
#endif
