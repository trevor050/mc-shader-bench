// Shadow map pass: distorted depth plus translucent tint in shadowcolor0.

#define SHADOW_PASS
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/shadows.glsl"

#ifdef VERTEX
in vec4 mc_Entity;
in vec4 at_midBlock;
uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform vec3 cameraPosition;
uniform float frameTimeCounter;
uniform float rainStrength;
#include "/lib/waving.glsl"

out vec2 texcoord;
out vec4 glcolor;
flat out int mat;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor = gl_Color;
    mat = int(mc_Entity.x + 0.5) - 10000;

    vec3 shadowViewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    vec3 playerPos = (shadowModelViewInverse * vec4(shadowViewPos, 1.0)).xyz;
    vec3 worldPos = waveVertex(playerPos + cameraPosition, mat, at_midBlock.y);
    vec4 clip = gl_ProjectionMatrix * (shadowModelView * vec4(worldPos - cameraPosition, 1.0));
    clip.xyz = distortShadow(clip.xyz);
    gl_Position = clip;
}
#endif

#ifdef FRAGMENT
uniform sampler2D gtexture;
in vec2 texcoord;
in vec4 glcolor;
flat in int mat;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 shadowColor;

void main() {
    // Water is marked with zero alpha: lighting converts its shadow depth into an absorption distance.
    if (mat == MAT_WATER) {
        shadowColor = vec4(1.0, 1.0, 1.0, 0.0);
        return;
    }
    vec4 c = texture(gtexture, texcoord) * glcolor;
    if (c.a < 0.1) discard;
    shadowColor = vec4(c.rgb, c.a);
}
#endif
