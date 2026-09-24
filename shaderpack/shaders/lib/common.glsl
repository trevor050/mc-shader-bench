// Shared math and encoding helpers.

#define PI 3.14159265
#define TAU 6.28318531

// Material ids (block.properties values minus 10000), stored as id/255 in the material buffer.
#define MAT_NONE 0
#define MAT_FOLIAGE 1      // grass, flowers: anchored at the bottom
#define MAT_LEAVES 2
#define MAT_WATER 3
#define MAT_EMISSIVE 4
#define MAT_TRANSLUCENT 5  // stained glass, ice, slime
#define MAT_TALL_UPPER 6   // upper half of double plants
#define MAT_LAVA 7
#define MAT_PORTAL 8       // nether portal
#define MAT_SNOW 9
#define MAT_ENDPORTAL 10
#define MAT_ICE 11          // clear ice (translucent)
#define MAT_ICE_SOLID 12    // packed and blue ice (opaque, glossy)
#define MAT_POLISHED 13     // polished/smooth stone, quartz, glazed terracotta, amethyst (screen-space reflections)
#define MAT_METAL 14        // metal and gem blocks (tinted reflections)
#define MAT_GLASSY 15       // obsidian: volcanic glass
#define MAT_LAVA_FLOWING 16 // block id only: flowing lava, remapped to MAT_LAVA plus a flag in vertex shaders
#define MAT_ENTITY 20
#define MAT_HAND 21
#define MAT_LOD 30

float saturate(float x) { return clamp(x, 0.0, 1.0); }
vec2 saturate(vec2 x) { return clamp(x, 0.0, 1.0); }
vec3 saturate(vec3 x) { return clamp(x, 0.0, 1.0); }
float sqr(float x) { return x * x; }
float luminance(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 toLinear(vec3 c) { return pow(c, vec3(2.2)); }

vec3 projectAndDivide(mat4 m, vec3 p) {
    vec4 h = m * vec4(p, 1.0);
    return h.xyz / h.w;
}

// Octahedral normal encoding into [0,1]^2.
vec2 encodeNormal(vec3 n) {
    n /= abs(n.x) + abs(n.y) + abs(n.z);
    vec2 e = n.z >= 0.0 ? n.xy : (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return e * 0.5 + 0.5;
}

vec3 decodeNormal(vec2 e) {
    e = e * 2.0 - 1.0;
    vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
    float t = saturate(-n.z);
    n.xy += vec2(n.x >= 0.0 ? -t : t, n.y >= 0.0 ? -t : t);
    return normalize(n);
}

// Interleaved gradient noise: cheap per-pixel dither for ray marches.
float ign(vec2 p) {
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// Frame-varying dither: TAA integrates it into smooth results instead of fixed noise patterns.
float ignTemporal(vec2 p, int frame) {
    return ign(p + 5.588238 * float(frame % 64));
}

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
