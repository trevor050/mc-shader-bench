// Vanilla sky geometry. The atmosphere is computed in deferred; here only the moon texture survives.
// PROG_SKYTEXTURED: sun/moon quads. Otherwise skybasic (sky plane, sunrise fan, stars).

#include "/lib/common.glsl"

#ifdef VERTEX
#ifdef PROG_SKYTEXTURED
out vec2 texcoord;
out vec4 glcolor;
uniform int renderStage;
#endif
void main() {
#ifdef PROG_SKYTEXTURED
    if (renderStage != MC_RENDER_STAGE_MOON) {
        // The sun is replaced in deferred, so avoid rasterizing its discarded quad.
        gl_Position = vec4(2.0, 0.0, 0.0, 1.0);
        texcoord = vec2(0.0);
        glcolor = vec4(0.0);
        return;
    }
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor = gl_Color;
#else
    // Deferred supplies the sky and stars; the vanilla sky fragment shader discards all of them.
    gl_Position = vec4(2.0, 0.0, 0.0, 1.0);
#endif
}
#endif

#ifdef FRAGMENT
#ifdef PROG_SKYTEXTURED
uniform sampler2D gtexture;
in vec2 texcoord;
in vec4 glcolor;
uniform int renderStage;
#endif

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
