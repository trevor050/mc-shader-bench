// Rain and snow, drawn after lighting: faint, slightly lit streaks.
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
    vec4 c = texture(gtexture, texcoord) * glcolor;
    if (c.a < 0.05) discard;
    outColor = vec4(pow(c.rgb, vec3(2.2)) * 0.35, c.a * 0.35);
}
#endif
