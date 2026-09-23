// Opaque geometry: writes the G-buffer that deferred.glsl lights.
//   colortex0 = albedo (sRGB) + alpha
//   colortex1 = world normal (octahedral) + lightmap (block, sky)
//   colortex2 = material id / 255, emissive, ambient occlusion
// Variants: PROG_TERRAIN, PROG_ENTITIES, PROG_TEXTURED (particles, fallbacks), PROG_BASIC, PROG_DH.

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

#ifdef VERTEX
#ifdef PROG_TERRAIN
in vec4 mc_Entity;
in vec4 at_midBlock;
uniform float frameTimeCounter;
uniform float rainStrength;
#include "/lib/waving.glsl"
#endif
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 worldNormal;
flat out int mat;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vec2 lm = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    lmcoord = saturate((lm - 1.0 / 32.0) * 16.0 / 15.0);
    glcolor = gl_Color;
    worldNormal = mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
    mat = MAT_NONE;

    vec3 viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
#if defined PROG_TERRAIN
    mat = int(mc_Entity.x + 0.5) - 10000;
    if (mat < 0 || mat > 100) mat = MAT_NONE;
    vec3 playerPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    vec3 worldPos = waveVertex(playerPos + cameraPosition, mat, at_midBlock.y);
    gl_Position = gl_ProjectionMatrix * (gbufferModelView * vec4(worldPos - cameraPosition, 1.0));
#elif defined PROG_DH
    mat = MAT_LOD;
    if (dhMaterialId == DH_BLOCK_LEAVES) mat = MAT_LEAVES;
    if (dhMaterialId == DH_BLOCK_ILLUMINATED || dhMaterialId == DH_BLOCK_LAVA) mat = MAT_EMISSIVE;
    gl_Position = gl_ProjectionMatrix * vec4(viewPos, 1.0);
#else
  #ifdef PROG_ENTITIES
    mat = MAT_ENTITY;
  #endif
    gl_Position = ftransform();
#endif
}
#endif

#ifdef FRAGMENT
uniform sampler2D gtexture;
#ifdef PROG_ENTITIES
uniform vec4 entityColor;
#endif
#ifdef PROG_DH
uniform vec3 cameraPosition;
uniform mat4 gbufferModelViewInverse;
uniform float far;
uniform float viewWidth;
uniform float viewHeight;
uniform mat4 dhProjectionInverse;
#endif

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 worldNormal;
flat in int mat;

/* RENDERTARGETS: 0,1,2 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormalLight;
layout(location = 2) out vec4 outMaterial;

void main() {
#if defined PROG_BASIC || defined PROG_DH
    vec4 albedo = glcolor;
#else
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
#endif
    float ao = 1.0;
#ifdef PROG_TERRAIN
    // separateAo: vertex alpha carries ambient occlusion, texture alpha carries coverage.
    ao = glcolor.a;
    albedo.a = texture(gtexture, texcoord).a;
#endif
#ifdef PROG_ENTITIES
    albedo.rgb = mix(albedo.rgb, entityColor.rgb, entityColor.a);
#endif
    if (albedo.a < 0.1) discard;

#ifdef PROG_DH
    // Skip LOD fragments that overlap real chunks so the two never z-fight.
    vec3 ndc = vec3(gl_FragCoord.xy / vec2(viewWidth, viewHeight), gl_FragCoord.z) * 2.0 - 1.0;
    vec3 viewPos = projectAndDivide(dhProjectionInverse, ndc);
    if (length(viewPos) < far * 0.85) discard;
    // Break up flat LOD faces with a little world-space value noise.
    vec3 wp = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz + cameraPosition;
    albedo.rgb *= 0.92 + 0.16 * hash12(floor(wp.xz + worldNormal.xz * 0.5) + floor(wp.y));
#endif

    float emissive = 0.0;
    if (mat == MAT_EMISSIVE) emissive = smoothstep(0.45, 0.85, max(albedo.r, max(albedo.g, albedo.b)));
    if (mat == MAT_LAVA) emissive = 1.0;
#ifdef PROG_BASIC
    emissive = 0.4;
#endif

    vec3 n = normalize(worldNormal);
#ifdef PROG_TEXTURED
    n = vec3(0.0, 1.0, 0.0);
#endif

    outAlbedo = vec4(albedo.rgb, 1.0);
    outNormalLight = vec4(encodeNormal(n), lmcoord);
    outMaterial = vec4(float(mat) / 255.0, emissive, ao, 1.0);
}
#endif
