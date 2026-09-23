// Vanilla sky geometry. The atmosphere is computed in deferred; here only the moon texture survives.
// PROG_SKYTEXTURED: sun/moon quads. Otherwise skybasic (sky plane, sunrise fan, stars).

#include "/lib/common.glsl"
uniform int renderStage;

#ifdef VERTEX
out vec2 texcoord;
out vec4 glcolor;
void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor = gl_Color;
}
#endif

#ifdef FRAGMENT
uniform sampler2D gtexture;
in vec2 texcoord;
in vec4 glcolor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
#ifdef PROG_SKYTEXTURED
    if (renderStage != MC_RENDER_STAGE_MOON) discard;
    vec4 c = texture(gtexture, texcoord) * glcolor;
    outColor = vec4(toLinear(c.rgb) * c.a * 0.6, 1.0);
#else
    // Stars are procedural in deferred, and the vanilla gradient is replaced entirely.
    discard;
#endif
}
#endif
