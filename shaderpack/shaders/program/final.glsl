// Bloom, eye adaptation, AgX tonemap, and a light grade.
//
// The sun is an HDR source with a small, antialiased disc. Bloom spreads its
// energy; source-gated glare adds a wider halo and subtle lens rays. Covering
// the sun suppresses those rays. Center-weighted eye adaptation responds to
// bright views before tonemapping.

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
uniform sampler2D colortex5;
uniform vec3 sunPosition;
uniform mat4 gbufferProjection;
uniform float viewWidth;
uniform float viewHeight;

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
    float l = luminance(c);
    // "Punchy" look (after Blender's AgX looks): keeps sunset oranges vivid instead of drifting to brown.
    c = pow(max(c, 0.0), vec3(1.2));
    c = l + SATURATION * (c - l);
    return c;
}

// Sum of progressively blurrier copies of the frame. Weights fall off slowly, approximating the long
// tail of real optical scattering: a small bright core with a faint halo reaching far across the view.
vec3 bloom(vec2 uv) {
    vec3 b = vec3(0.0);
    vec2 px = 1.0 / vec2(viewWidth, viewHeight);
    float total = 0.0;
    for (int lod = 1; lod <= 9; lod++) {
        float scale = exp2(float(lod));
        vec3 s = vec3(0.0);
        for (int y = -1; y <= 1; y++)
            for (int x = -1; x <= 1; x++) {
                float w = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
                s += textureLod(colortex0, uv + vec2(x, y) * px * scale * 0.75, float(lod)).rgb * w;
            }
        float weight = pow(0.72, float(lod - 1));
        b += s / 16.0 * weight;
        total += weight;
    }
    return b / total;
}

// A small solar disc needs a much wider optical halo than a few mip levels can
// provide. Sample the rendered disc so clouds and terrain still occlude it.
vec3 solarGlare(vec2 uv) {
    vec4 clip = gbufferProjection * vec4(sunPosition, 1.0);
    if (clip.w <= 0.0) return vec3(0.0);
    vec2 sunUV = clip.xy / clip.w * 0.5 + 0.5;
    if (any(lessThan(sunUV, vec2(0.0))) || any(greaterThan(sunUV, vec2(1.0)))) return vec3(0.0);

    vec3 source = textureLod(colortex0, sunUV, 0.0).rgb;
    float visible = smoothstep(12.0, 100.0, luminance(source));
    if (visible <= 0.001) return vec3(0.0);

    vec2 delta = (uv - sunUV) * vec2(viewWidth, viewHeight);
    float r = length(delta);
    if (r > 420.0) return vec3(0.0);
    float halo = 5.0 * exp2(-sqr(r / 24.0))
               + 2.0 * exp2(-r / 28.0) + 0.4 * exp2(-r / 135.0);

    // A restrained six-point lens diffraction pattern, separate from the
    // shadowed volumetric shafts in composite.glsl.
    float armDistance = min(abs(delta.y),
                            min(abs(dot(delta, vec2(-0.8660254, 0.5))),
                                abs(dot(delta, vec2(-0.8660254, -0.5)))));
    float blades = exp2(-2.0 * sqr(armDistance / (2.0 + 0.012 * r)));
    float star = 0.7 * blades * exp2(-r / 100.0) * smoothstep(8.0, 30.0, r);

    vec3 sourceTint = clamp(source / max(luminance(source), 0.001), vec3(0.35), vec3(1.65));
    vec3 tint = mix(vec3(1.0, 0.92, 0.78), sourceTint, 0.4);
    float edgeFade = 1.0 - smoothstep(260.0, 420.0, r);
    return tint * visible * (halo + star) * edgeFade;
}

void main() {
    vec3 col = texture(colortex0, texcoord).rgb;
    col += bloom(texcoord) * BLOOM_STRENGTH;
    col += solarGlare(texcoord);

    // Eye adaptation (see taa.glsl): expose so the adapted scene brightness maps to a mid tone.
    float adaptedLog = texelFetch(colortex5, ivec2(0), 0).a;
    // Partial adaptation around a daylight reference: bright views (the sun) darken steeply, dark views
    // (night, caves) open up gently so night still reads as night.
    const float refLog = -0.75;
    float slope = adaptedLog > refLog ? 0.8 : 0.4;
    float exposure = exp2(log2(EXPOSURE_KEY) - slope * (adaptedLog - refLog));
    exposure = clamp(exposure, EXPOSURE_MIN, EXPOSURE_MAX);
    col *= exposure;

    col = agx(col);

    vec2 v = texcoord - 0.5;
    col *= 1.0 - dot(v, v) * 0.35;
    col += (hash12(gl_FragCoord.xy) - 0.5) / 255.0;
    fragColor = vec4(col, 1.0);

#ifdef EXPOSURE_DEBUG
    // Corner readout for calibration: red = adapted log2 brightness, green = log2 exposure (both /20 + 0.5).
    if (gl_FragCoord.x < 12.0 && gl_FragCoord.y < 12.0)
        fragColor = vec4(adaptedLog / 20.0 + 0.5, log2(exposure) / 20.0 + 0.5, 0.0, 1.0);
#endif
}
#endif
