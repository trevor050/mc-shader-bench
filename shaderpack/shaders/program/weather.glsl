// Rain and snow, drawn after lighting. Vanilla's rain texture is saturated blue; real rain is clear water
// that only shows as faint silvery streaks catching the ambient light. Both are lit by the sky's current
// brightness (Iris skyColor), so precipitation darkens at night and goes silver by day.
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
uniform vec3 skyColor;
uniform ivec2 eyeBrightnessSmooth;
in vec2 texcoord;
in vec4 glcolor;
/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;
void main() {
#ifdef DIM_END
    // The End has no weather; its rain level only carries storm data from the ClaudeBench Ambience mod.
    discard;
#endif
    vec4 c = texture(gtexture, texcoord) * glcolor;
    if (c.a < 0.05) discard;
    bool rain = c.b > c.r * 1.25;
    vec3 sky = pow(skyColor, vec3(2.2));
    float light = dot(sky, vec3(0.2126, 0.7152, 0.0722)) * (0.25 + 0.75 * float(eyeBrightnessSmooth.y) / 240.0);
    vec3 tint = rain ? vec3(0.85, 0.9, 1.0) : pow(c.rgb, vec3(2.2));
    float alpha = rain ? c.a * 0.4 : c.a * 0.6;
    outColor = vec4(tint * (light * 2.2 + 0.004), alpha);
}
#endif
