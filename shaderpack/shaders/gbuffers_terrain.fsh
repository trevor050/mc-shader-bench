#version 330 compatibility
uniform sampler2D gtexture;
uniform sampler2D lightmap;
in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 color;
void main() {
    color = texture(gtexture, texcoord) * glcolor;
    color *= texture(lightmap, lmcoord);
    if (color.a < 0.1) discard;
}
