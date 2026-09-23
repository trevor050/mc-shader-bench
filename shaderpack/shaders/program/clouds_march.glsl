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
void main() {
    gl_Position = ftransform();
    sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    LightEnv e = makeLightEnv(sunDir);
    envLightDir = e.lightDir;
    envDirect = e.directLight;
    // Light arriving from the sky dome above a cloud (hemisphere integral of the zenith radiance).
    skyLight = skyRadiance(vec3(0.0, 1.0, 0.0), sunDir, 6) * TAU * 0.9;
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
    float sceneDist = (sky || depth < 0.56) ? 1e6 : length(playerPos);
    // The hand is not world geometry.

    float dither = ignTemporal(gl_FragCoord.xy, frameCounter);
    float dist;
    vec4 c = renderClouds(cameraPosition, rd, sceneDist, sunDir, envLightDir, envDirect, skyLight, dither, dist);
    outClouds = c;
    outDist = vec4(min(dist, 1e6), sceneDist, 0.0, 0.0);
}
#endif
