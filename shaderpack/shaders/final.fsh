#version 330 compatibility
uniform sampler2D colortex0;
in vec2 texcoord;
layout(location = 0) out vec4 fragColor;
void main() {
    vec3 c = texture(colortex0, texcoord).rgb;
    // placeholder: slight warm grade so it's obvious the pack is active
    c *= vec3(1.08, 1.0, 0.92);
    fragColor = vec4(c, 1.0);
}
