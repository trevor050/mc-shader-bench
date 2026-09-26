// Rain and snow, drawn after lighting. Vanilla's rain texture is saturated blue; real rain is clear water that
// shows as silvery streaks refracting the sky around it. Streaks are lit by the pack's own sky radiance (the scene
// is in those HDR units; vanilla skyColor is two orders of magnitude dimmer, which left rain visible only against
// dark water), scaled by how open the sky is where the player stands.
// Weather goes to its own buffer (colortex13, premultiplied colour + coverage) and final lays it over the finished
// scene. Drawn into the scene directly, the streaks had no depth of their own, so the composite fog treated them as
// the far land behind them and dissolved them into the rain haze: rain only survived in front of nearby water.
#include "/lib/settings.glsl"
#include "/lib/common.glsl"

uniform vec3 sunPosition;
uniform mat4 gbufferModelViewInverse;
uniform float rainStrength;
uniform float frameTimeCounter;
#include "/lib/atmosphere.glsl"

#ifdef VERTEX
out vec2 texcoord;
out vec4 glcolor;
#if VANILLA_LIGHTING
out vec2 lmcoord;
#endif
flat out vec3 skyLight;
void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor = gl_Color;
#if VANILLA_LIGHTING
    lmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    skyLight = vec3(0.0);
#else
#if defined DIM_NETHER || defined DIM_END
    skyLight = vec3(0.0);
#else
    vec3 sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    // Average of the overhead and horizon sky: what a falling drop refracts toward the eye.
    skyLight = (skyRadiance(vec3(0.0, 1.0, 0.0), sunDir, 4) + skyRadiance(normalize(vec3(sunDir.x, 0.15, sunDir.z) + vec3(0.0, 0.0, 1e-3)), sunDir, 4)) * 0.5;
#endif
#endif
}
#endif
#ifdef FRAGMENT
uniform sampler2D gtexture;
#if VANILLA_LIGHTING
uniform sampler2D lightmap;
in vec2 lmcoord;
#endif
uniform ivec2 eyeBrightnessSmooth;
in vec2 texcoord;
in vec4 glcolor;
flat in vec3 skyLight;
/* RENDERTARGETS: 13 */
layout(location = 0) out vec4 outColor;
void main() {
#ifdef DIM_END
    // The End has no weather; its rain level only carries storm data from the ClaudeBench Ambience mod.
    discard;
#endif
    vec4 c = texture(gtexture, texcoord) * glcolor;
    if (c.a < 0.05) discard;
#if VANILLA_LIGHTING
    outColor = vec4(c.rgb * texture(lightmap, lmcoord).rgb, c.a);
#else
    bool rain = c.b > c.r * 1.25;
    float open = 0.3 + 0.7 * float(eyeBrightnessSmooth.y) / 240.0;
    vec3 sky = vec3(luminance(skyLight)) * mix(vec3(1.0), vec3(0.9, 0.95, 1.05), 0.6);
    vec3 tint = rain ? vec3(0.85, 0.9, 1.0) : toLinear(c.rgb);
    float alpha = rain ? c.a * 0.5 : c.a * 0.75;
    // Drops are brighter than the sky they refract only at the rims; snow is a diffuse white lit by the sky.
    outColor = vec4(tint * sky * open * 1.6 + 0.004, alpha);
#endif
}
#endif
