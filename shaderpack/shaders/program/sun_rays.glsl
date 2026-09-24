// Screen-space scattering from open sky around the sun. Run after TAA so the input is stable, then retain
// the expensive bloom, glare, and ray work at half resolution for final's additive composite.

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
uniform sampler2D depthtex0;
uniform sampler2D dhDepthTex0;
uniform vec3 sunPosition;
uniform mat4 gbufferProjection;
uniform float viewWidth;
uniform float viewHeight;

/*
const int colortex3Format = RGBA16F;
*/
const bool colortex0MipmapEnabled = true;

in vec2 texcoord;

/* RENDERTARGETS: 3,7 */
layout(location = 0) out vec4 outGlareAndRays;
layout(location = 1) out vec4 outBloom;
// The former cloud/VL scratch buffer is dead by composite4, so its slot holds bloom for final.

// Sum of progressively blurrier copies of the frame. Keeping this in the half-resolution pass removes
// 81 explicit LOD samples per final pixel; the final pass linearly reconstructs the smooth HDR result.
// Quality risk: half-resolution evaluation can soften the smallest bloom variations versus per-pixel sampling.
void bloomAndGlare(vec2 uv, out vec3 b, out vec3 g) {
    b = vec3(0.0);
    g = vec3(0.0);
    vec2 px = 1.0 / vec2(viewWidth, viewHeight);
    float totalBloom = 0.0;
    float totalGlare = 0.0;
    float avgLum = luminance(textureLod(colortex0, vec2(0.5), 11.0).rgb);
    float threshold = max(avgLum * 12.0, 1e-3);
    for (int lod = 1; lod <= 9; lod++) {
        float scale = exp2(float(lod));
        vec3 bloomSamples = vec3(0.0);
        vec3 glareSamples = vec3(0.0);
        for (int y = -1; y <= 1; y++)
            for (int x = -1; x <= 1; x++) {
                float w = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
                vec3 c = textureLod(colortex0, uv + vec2(x, y) * px * scale * 0.75, float(lod)).rgb;
                bloomSamples += c * w;
                if (lod >= 4) {
                    // Soft knee keeps glare from switching on abruptly.
                    float l = luminance(c);
                    glareSamples += c * (max(l - threshold, 0.0) / max(l, 1e-5)) * w;
                }
            }
        // Nearly flat weights: the wide levels carry the big soft glow around very bright sources.
        float bloomWeight = pow(0.86, float(lod - 1));
        b += bloomSamples / 16.0 * bloomWeight;
        totalBloom += bloomWeight;
        if (lod >= 4) {
            float glareWeight = float(lod - 3);
            g += glareSamples / 16.0 * glareWeight;
            totalGlare += glareWeight;
        }
    }
    b /= totalBloom;
    g /= totalGlare;
}

// Only open sky within a small radius of the sun feeds the rays. Testing both depth buffers keeps the
// effect behind vanilla terrain and Distant Horizons terrain while allowing cloud gaps to scatter light.
vec3 sunRays(vec2 uv) {
    vec4 clip = gbufferProjection * vec4(sunPosition, 1.0);
    if (clip.w <= 0.0) return vec3(0.0);
    vec2 sunUV = clip.xy / clip.w * 0.5 + 0.5;
    vec2 aspect = vec2(viewWidth / viewHeight, 1.0);
    // Fade as the sun leaves the frame instead of popping.
    float onScreen = smoothstep(-0.25, 0.05, min(min(sunUV.x, sunUV.y), min(1.0 - sunUV.x, 1.0 - sunUV.y)));
    if (onScreen <= 0.0) return vec3(0.0);

    const int N = 48;
    vec2 delta = (sunUV - uv) / float(N);
    // Pixels far from the sun get nothing; fade smoothly so the effect never ends in a visible circle.
    float len = length(delta * aspect) * float(N);
    float reach = 1.0 - smoothstep(0.35, 0.9, len);
    if (reach <= 0.0) return vec3(0.0);

    // The pass runs after TAA, so avoid per-frame dither. A blurred mip keeps the fixed step pattern from showing.
    vec2 p = uv + delta * 0.5;
    float invN = 1.0 / float(N);
    // The sample starts 1.5 steps from the pixel and advances toward the sun by one step each tap.
    // Reuse that fixed distance increment instead of measuring a vector and evaluating exp per tap.
    float nearSun = exp(-len * (1.0 - 1.5 * invN) * 9.0);
    float nearSunStep = exp(len * invN * 9.0);
    vec3 acc = vec3(0.0);
    float decay = 1.0;
    for (int i = 0; i < N; i++) {
        p += delta;
        if (any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0)))) break;
        // Opaque vanilla geometry already rejects this tap; avoid the DH depth and color lookups.
        if (texture(depthtex0, p).r >= 1.0) {
            if (texture(dhDepthTex0, p).r >= 1.0)
                acc += textureLod(colortex0, p, 4.0).rgb * nearSun * decay;
        }
        // The final two taps are symmetric around the sun because the loop samples at 1.5..48.5 steps.
        if (i < N - 2) nearSun *= nearSunStep;
        decay *= 0.965;
    }
    return acc / float(N) * onScreen * reach;
}

void main() {
    vec3 bloomColor, glareColor;
    bloomAndGlare(texcoord, bloomColor, glareColor);
    // The original final result is mix(scene + GLARE_STRENGTH * glare + SUN_RAYS_STRENGTH * rays,
    // bloom, BLOOM_STRENGTH). Weight the additive terms here and preserve that order in final.
    vec3 glareAndRays = glareColor * GLARE_STRENGTH;
#if !defined DIM_NETHER && !defined DIM_END
    glareAndRays += sunRays(texcoord) * SUN_RAYS_STRENGTH;
#endif
    outGlareAndRays = vec4(glareAndRays, 1.0);
    outBloom = vec4(bloomColor, 1.0);
}
#endif
