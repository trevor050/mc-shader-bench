// Bloom from colortex0 mips, exposure, AgX tonemap, and a light grade.

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

#ifdef VERTEX
out vec2 texcoord;
void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
}
#endif

#ifdef FRAGMENT
uniform sampler2D colortex0;
uniform float viewWidth;
uniform float viewHeight;
uniform ivec2 eyeBrightnessSmooth;
uniform vec3 sunPosition;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;

const bool colortex0MipmapEnabled = true;

in vec2 texcoord;
layout(location = 0) out vec4 fragColor;

// AgX (Troy Sobotka), polynomial fit by Benjamin Wrensch.
vec3 agxContrast(vec3 x) {
    vec3 x2 = x * x, x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}

vec3 agx(vec3 c) {
    const mat3 inset = mat3(0.842479062253094, 0.0423282422610123, 0.0423756549057051,
                            0.0784335999999992, 0.878468636469772, 0.0784336,
                            0.0792237451477643, 0.0791661274605434, 0.879142973793104);
    const mat3 outset = mat3(1.19687900512017, -0.0528968517574562, -0.0529716355144438,
                             -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
                             -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
    const float minEv = -12.47393, maxEv = 4.026069;
    c = inset * c;
    c = clamp(log2(max(c, 1e-10)), minEv, maxEv);
    c = (c - minEv) / (maxEv - minEv);
    c = agxContrast(c);
    c = outset * c;
    // Mild "punchy" look.
    float l = luminance(c);
    c = pow(max(c, 0.0), vec3(1.08));
    c = l + SATURATION * (c - l);
    return c;
}

vec3 bloom(vec2 uv) {
    vec3 b = vec3(0.0);
    float total = 0.0;
    vec2 px = 1.0 / vec2(viewWidth, viewHeight);
    for (int lod = 2; lod <= 7; lod++) {
        float scale = exp2(float(lod));
        vec3 s = vec3(0.0);
        // 3x3 tent over each mip keeps blocky mip edges from showing.
        for (int y = -1; y <= 1; y++)
            for (int x = -1; x <= 1; x++) {
                float w = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
                s += textureLod(colortex0, uv + vec2(x, y) * px * scale, float(lod)).rgb * w;
            }
        float weight = 1.0 / float(lod - 1);
        b += s / 16.0 * weight;
        total += weight;
    }
    return b / total;
}

// Eye/lens glare around the sun. Its strength comes from a low mip of the frame at the sun's position,
// so terrain or clouds covering the sun dim the glare automatically.
vec3 sunGlare(vec2 uv) {
    vec4 clip = gbufferProjection * vec4(sunPosition, 1.0);
    if (clip.w <= 0.0) return vec3(0.0);
    vec2 sunUV = clip.xy / clip.w * 0.5 + 0.5;
    vec2 aspect = vec2(viewWidth / viewHeight, 1.0);
    // Fade out as the sun leaves the screen instead of popping.
    float onScreen = smoothstep(-0.15, 0.05, min(min(sunUV.x, sunUV.y), min(1.0 - sunUV.x, 1.0 - sunUV.y)));
    vec3 src = textureLod(colortex0, clamp(sunUV, 0.0, 1.0), 5.0).rgb * onScreen;
    float d = length((uv - sunUV) * aspect);
    float veil = exp(-d * 4.0) * 0.003 + exp(-d * 16.0) * 0.025 + exp(-d * 70.0) * 0.12;
    return src * veil;
}

void main() {
    vec3 col = texture(colortex0, texcoord).rgb;
    col = mix(col, bloom(texcoord), BLOOM_STRENGTH);
    col += sunGlare(texcoord);

    // Exposure: open up in caves and at night, stay tight in bright daylight.
    float skyLight = float(eyeBrightnessSmooth.y) / 240.0;
    float sunUp = normalize(mat3(gbufferModelViewInverse) * sunPosition).y;
    // Hold daytime exposure until the sun is nearly down so sunsets stay rich instead of washing out.
    float dayness = smoothstep(-0.12, 0.02, sunUp);
    float ev = mix(2.2, mix(2.0, 0.0, dayness), skyLight);
    col *= EXPOSURE * 0.42 * exp2(ev);

    col = agx(col);

    // Subtle vignette.
    vec2 v = texcoord - 0.5;
    col *= 1.0 - dot(v, v) * 0.35;

    // Dither to kill banding in skies.
    col += (hash12(gl_FragCoord.xy) - 0.5) / 255.0;
    fragColor = vec4(col, 1.0);
}
#endif
