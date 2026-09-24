// Opaque geometry: writes the G-buffer that deferred.glsl lights.
//   colortex0 = albedo (sRGB) + alpha
//   colortex1 = world normal (octahedral) + lightmap (block, sky)
//   colortex2 = material id / 255, emissive, ambient occlusion
// Variants: PROG_TERRAIN, PROG_ENTITIES, PROG_TEXTURED (particles, fallbacks), PROG_BASIC, PROG_DH.

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

#ifdef VERTEX
#include "/lib/jitter.glsl"
#ifdef PROG_TERRAIN
in vec4 mc_Entity;
in vec4 at_midBlock;
in vec2 mc_midTexCoord;
uniform float frameTimeCounter;
uniform float rainStrength;
#include "/lib/waving.glsl"
#endif
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;
#ifdef PROG_BLOCK
uniform int blockEntityId;
#endif

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 worldNormal;
out vec3 relPos;
flat out int mat;
#ifdef PROG_TERRAIN
flat out vec2 lavaSpriteMid;
flat out vec2 lavaSpriteHalfExtent;
#endif

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
#ifdef PROG_TERRAIN
    // mc_midTexCoord is Iris's raw quad UV average. Transform it just like texcoord so atlas bounds
    // remain correct when Minecraft animates or offsets the terrain texture matrix.
    lavaSpriteMid = (gl_TextureMatrix[0] * vec4(mc_midTexCoord, 0.0, 1.0)).xy;
    lavaSpriteHalfExtent = abs(texcoord - lavaSpriteMid);
#endif
    vec2 lm = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    lmcoord = saturate((lm - 1.0 / 32.0) * 16.0 / 15.0);
    glcolor = gl_Color;
    worldNormal = mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
    mat = MAT_NONE;

#ifdef PROG_BASIC
    // Iris rewrites line geometry around its own position attribute; touching gl_Vertex breaks linking.
    relPos = vec3(0.0);
    gl_Position = ftransform();
    applyJitter(gl_Position);
    return;
#endif
    vec3 viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    relPos = mat3(gbufferModelViewInverse) * viewPos;
#if defined PROG_TERRAIN
    mat = int(mc_Entity.x + 0.5) - 10000;
    if (mat < 0 || mat > 100) mat = MAT_NONE;
    vec3 playerPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    vec3 worldPos = waveVertex(playerPos + cameraPosition, mat, at_midBlock.y);
    gl_Position = gl_ProjectionMatrix * (gbufferModelView * vec4(worldPos - cameraPosition, 1.0));
#elif defined PROG_DH
    mat = MAT_LOD;
    if (dhMaterialId == DH_BLOCK_LEAVES) mat = MAT_LEAVES;
    if (dhMaterialId == DH_BLOCK_ILLUMINATED) mat = MAT_EMISSIVE;
    if (dhMaterialId == DH_BLOCK_LAVA) mat = MAT_LAVA;
    gl_Position = gl_ProjectionMatrix * vec4(viewPos, 1.0);
#else
  #ifdef PROG_ENTITIES
    mat = MAT_ENTITY;
  #endif
  #ifdef PROG_HAND
    mat = MAT_HAND;
  #endif
  #ifdef PROG_BLOCK
    mat = blockEntityId - 10000 == MAT_ENDPORTAL ? MAT_ENDPORTAL : MAT_NONE;
  #endif
    gl_Position = ftransform();
#endif
    applyJitter(gl_Position);
}
#endif

#ifdef FRAGMENT
uniform sampler2D gtexture;
#ifdef PROG_ENTITIES
uniform vec4 entityColor;
#endif
#ifdef PROG_TERRAIN
uniform float far;
uniform int frameCounter;
uniform float frameTimeCounter;
uniform vec3 cameraPosition;
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
in vec3 relPos;
flat in int mat;
#ifdef PROG_TERRAIN
flat in vec2 lavaSpriteMid;
flat in vec2 lavaSpriteHalfExtent;
#endif

/* RENDERTARGETS: 0,1,2 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormalLight;
layout(location = 2) out vec4 outMaterial;

#ifdef PROG_TERRAIN
// A triangular lattice gives continuous three-way blends. Each lattice vertex chooses a stable
// rotation/reflection of the animated vanilla atlas sprite, so the frame animation stays native.
vec2 lavaTransform(vec2 p, float turn, vec2 flip) {
    vec2 r90 = vec2(-p.y, p.x);
    vec2 r180 = -p;
    vec2 r270 = vec2(p.y, -p.x);
    vec2 r = mix(p, r90, step(0.5, turn));
    r = mix(r, r180, step(1.5, turn));
    r = mix(r, r270, step(2.5, turn));
    return r * flip;
}

vec3 sampleLavaVariant(vec2 p, vec2 pDx, vec2 pDy, float textureScale, vec2 latticeId) {
    float h = hash12(latticeId + vec2(19.17, 43.71));
    float turn = floor(h * 4.0);
    vec2 flip = vec2(hash12(latticeId + vec2(7.1, 13.7)) < 0.5 ? -1.0 : 1.0,
                     hash12(latticeId + vec2(29.3, 3.9)) < 0.5 ? -1.0 : 1.0);
    vec2 offset = vec2(hash12(latticeId + vec2(31.7, 11.9)), hash12(latticeId + vec2(5.3, 67.1)));
    // Each cell samples its own rotated and phase-shifted view of the source sprite. p is world-projected,
    // so the source image cannot restart at every chunk quad the way vanilla atlas UVs do.
    vec2 localRaw = lavaTransform(p / textureScale, turn, flip) + offset;
    vec2 localDx = lavaTransform(pDx / textureScale, turn, flip);
    vec2 localDy = lavaTransform(pDy / textureScale, turn, flip);
    vec2 local = fract(localRaw);

    vec2 halfExtent = max(lavaSpriteHalfExtent, vec2(0.0));
    vec2 texel = 1.0 / vec2(textureSize(gtexture, 0));
    // Stay a texel inside this quad's atlas rectangle, including under linear filtering/mip selection.
    vec2 safeHalf = max(halfExtent - texel, vec2(0.0));
    vec2 uv = clamp(lavaSpriteMid + (local * 2.0 - 1.0) * halfExtent,
                    lavaSpriteMid - safeHalf, lavaSpriteMid + safeHalf);
    return textureGrad(gtexture, uv, localDx * (2.0 * halfExtent), localDy * (2.0 * halfExtent)).rgb;
}

vec2 lavaPlane(vec3 p, vec3 n) {
    vec3 an = abs(n);
    return an.y >= max(an.x, an.z) ? p.xz : (an.x >= an.z ? p.zy : p.xy);
}

vec3 stochasticLavaAlbedo(vec3 wp, vec3 pDx3, vec3 pDy3, vec3 n) {
    // This path is for horizontal pools. Vertical lava curtains keep Minecraft's exact UVs below, so
    // their narrow faces retain the original pixel scale instead of being stretched by a projection.
    vec2 p = lavaPlane(wp, n);
    vec2 pDx = lavaPlane(pDx3, n);
    vec2 pDy = lavaPlane(pDy3, n);
    const float textureScale = 2.5;
    const float cellSize = 2.5;
    vec2 lattice = vec2(p.x / cellSize - p.y / (cellSize * 1.7320508),
                        2.0 * p.y / (cellSize * 1.7320508));
    vec2 base = floor(lattice);
    vec2 f = fract(lattice);

    vec2 id0, id1, id2;
    vec3 weight;
    if (f.x + f.y <= 1.0) {
        id0 = base;
        id1 = base + vec2(1.0, 0.0);
        id2 = base + vec2(0.0, 1.0);
        weight = vec3(1.0 - f.x - f.y, f.x, f.y);
    } else {
        id0 = base + vec2(1.0, 1.0);
        id1 = base + vec2(0.0, 1.0);
        id2 = base + vec2(1.0, 0.0);
        weight = vec3(f.x + f.y - 1.0, 1.0 - f.x, 1.0 - f.y);
    }

    vec3 lava = sampleLavaVariant(p, pDx, pDy, textureScale, id0) * weight.x
              + sampleLavaVariant(p, pDx, pDy, textureScale, id1) * weight.y
              + sampleLavaVariant(p, pDx, pDy, textureScale, id2) * weight.z;

    // Broad, slowly flowing heat swirls change the large-scale brightness while the atlas pixels
    // supply Minecraft's animated color and fine detail. Quantized levels keep the result blocky.
    float time = frameTimeCounter;
    vec2 flow = vec2(valueNoise(p * 0.045 + vec2(time * 0.012, -time * 0.008) + 4.7),
                     valueNoise(p * 0.045 + vec2(17.3, -8.1) + vec2(-time * 0.009, time * 0.011))) - 0.5;
    float broad = valueNoise(p * 0.13 + flow * 1.8 + vec2(time * 0.009, -time * 0.006));
    float breakup = valueNoise(p * 0.31 - flow * 0.7 + vec2(-time * 0.017, time * 0.013));
    float heat = floor((broad * 0.72 + breakup * 0.28) * 7.0 + 0.5) / 7.0;
    float brightness = mix(0.62, 1.48, heat);
    return lava * brightness;
}
#endif

void main() {
#ifdef PROG_TERRAIN
    // Derivatives are evaluated before the material branch so textureGrad remains defined across edges.
    vec3 relPosDx = dFdx(relPos);
    vec3 relPosDy = dFdy(relPos);
#endif
#if defined PROG_BASIC || defined PROG_DH
    vec4 albedo = glcolor;
#elif defined PROG_TERRAIN
    vec4 texel = texture(gtexture, texcoord);
    vec4 albedo = vec4(texel.rgb * glcolor.rgb, texel.a);
    if (mat == MAT_LAVA && abs(worldNormal.y) > 0.5) {
        albedo.rgb = stochasticLavaAlbedo(relPos + cameraPosition, relPosDx, relPosDy,
                                          normalize(worldNormal)) * glcolor.rgb;
    }
#else
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
#endif
    float ao = 1.0;
#ifdef PROG_TERRAIN
    // separateAo: vertex alpha carries ambient occlusion, texture alpha carries coverage.
    ao = glcolor.a;
#endif
#ifdef PROG_ENTITIES
    albedo.rgb = mix(albedo.rgb, entityColor.rgb, entityColor.a);
#endif
    if (albedo.a < 0.1) discard;

#ifdef PROG_TERRAIN
    // Dither vanilla chunks out before the render edge so chunk-border cross-sections never show; DH fills in.
    float edge = length(relPos.xz) / far;
    if (edge > mix(0.84, 0.94, ignTemporal(gl_FragCoord.xy, frameCounter))) discard;
#endif

#ifdef PROG_DH
    // Skip LOD fragments that overlap real chunks so the two never z-fight.
    vec3 ndc = vec3(gl_FragCoord.xy / vec2(viewWidth, viewHeight), gl_FragCoord.z) * 2.0 - 1.0;
    vec3 viewPos = projectAndDivide(dhProjectionInverse, ndc);
    if (length(viewPos) < far * 0.1) discard;
    // Break up flat LOD faces with a little world-space value noise.
    vec3 wp = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz + cameraPosition;
    vec3 cell = floor(wp - worldNormal * 0.5);
    albedo.rgb *= 0.93 + 0.14 * hash12(cell.xz + cell.y * vec2(17.3, 5.1));
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
