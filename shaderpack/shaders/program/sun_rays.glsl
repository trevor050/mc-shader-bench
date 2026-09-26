// Screen-space scattering from open sky around the sun. Run after TAA so the input is stable, then retain
// the expensive bloom, glare, and ray work at half resolution for final's additive composite.

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

#ifdef VERTEX
out vec2 texcoord;
flat out float frameLum;
flat out int frameLastMip;
uniform sampler2D colortex0;
void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    frameLum = luminance(textureLod(colortex0, vec2(0.5), 11.0).rgb);
    ivec2 fullSize = textureSize(colortex0, 0);
    frameLastMip = int(floor(log2(float(max(fullSize.x, fullSize.y)))));
}
#endif

#ifdef FRAGMENT
#include "/lib/bloom_filter.glsl"
uniform sampler2D colortex0;
uniform sampler2D depthtex0;
uniform sampler2D dhDepthTex0;
uniform vec3 sunPosition;
uniform vec3 upPosition;
uniform mat4 gbufferProjection;
uniform float viewWidth;
uniform float viewHeight;

/*
const int colortex3Format = RGBA16F;
*/
const bool colortex0MipmapEnabled = true;

in vec2 texcoord;
flat in float frameLum;
flat in int frameLastMip;

/* RENDERTARGETS: 3,7 */
layout(location = 0) out vec4 outGlareAndRays;
layout(location = 1) out vec4 outBloom;
// The former cloud/VL scratch buffer is dead by composite4, so its slot holds bloom for final.

// Sum of progressively blurrier copies of the frame. Keeping this in the half-resolution pass removes
// the mip work per final pixel; the final pass reconstructs these smooth HDR targets separately from the scene.
void bloomAndGlare(vec2 uv, out vec3 b, out vec3 g, out vec3 e) {
    b = vec3(0.0);
    g = vec3(0.0);
    e = vec3(0.0);
    float totalEmit = 0.0;
    float emitThreshold = max(frameLum * EMITTER_BLOOM_THRESHOLD, 1e-3);
    vec2 px = 1.0 / vec2(viewWidth, viewHeight);
    float totalBloom = 0.0;
    float totalGlare = 0.0;
    float threshold = max(frameLum * 12.0, 1e-3);
    for (int lod = 1; lod <= 9; lod++) {
#if BLOOM_QUALITY == 2
        if (lod == 6 || lod == 8) continue;
#elif BLOOM_QUALITY == 1
        if ((lod & 1) == 0) continue;
#elif BLOOM_QUALITY == 0
        // Retain fine, medium and wide positive cubic blur on Low, avoiding a coarse mip halo grid.
        if (lod != 2 && lod != 5 && lod != 8) continue;
#endif
        float scale = exp2(float(lod));
        int sampleLod = min(lod, frameLastMip);
        vec3 bloomSamples = vec3(0.0);
        vec3 glareSamples = vec3(0.0);
        vec3 u, v, wx, wy;
        // Coarse mip texels cover many screen pixels. Reconstruct their blur smoothly, folding the cubic
        // kernel into nine normalized linear taps rather than evaluating four fetches for each old tap.
        bloomBlurCoordinates(colortex0, uv, sampleLod, px * scale * 0.75, u, v, wx, wy);
        for (int y = 0; y < 3; y++)
            for (int x = 0; x < 3; x++) {
                float w = wx[x] * wy[y];
                vec3 c = textureLod(colortex0, vec2(u[x], v[y]), float(sampleLod)).rgb;
                bloomSamples += c * w;
            }
        // Threshold the fully reconstructed blur. Applying a nonlinear threshold to the paired reads
        // would expose their moving grouping boundaries as rectangular seams around large emitters.
        if (lod >= 2 && lod <= 7)
            e += bloomBrightPass(bloomSamples, emitThreshold);
        if (lod >= 4)
            glareSamples = bloomBrightPass(bloomSamples, threshold);
        // Nearly flat weights: the wide levels carry the big soft glow around very bright sources.
        float bloomWeight = pow(0.86, float(lod - 1));
        b += bloomSamples * bloomWeight;
        if (lod >= 2 && lod <= 7) totalEmit += 1.0;
        totalBloom += bloomWeight;
        if (lod >= 4) {
            float glareWeight = float(lod - 3);
            g += glareSamples * glareWeight;
            totalGlare += glareWeight;
        }
    }
    b /= totalBloom;
    g /= totalGlare;
    e /= max(totalEmit, 1.0);
}

// Only open sky within a small radius of the sun feeds the rays. Testing both depth buffers keeps the
// effect behind vanilla terrain and Distant Horizons terrain while allowing cloud gaps to scatter light.
vec3 sunRays(vec2 uv) {
#if SUN_RAY_SAMPLES > 0
    vec4 clip = gbufferProjection * vec4(sunPosition, 1.0);
    if (clip.w <= 0.0) return vec3(0.0);
    vec2 sunUV = clip.xy / clip.w * 0.5 + 0.5;
    vec2 aspect = vec2(viewWidth / viewHeight, 1.0);
    // Fade as the sun leaves the frame instead of popping.
    float onScreen = smoothstep(-0.25, 0.05, min(min(sunUV.x, sunUV.y), min(1.0 - sunUV.x, 1.0 - sunUV.y)));
    if (onScreen <= 0.0) return vec3(0.0);

    const int N = SUN_RAY_SAMPLES;
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
                acc += max(textureLod(colortex0, p, 4.0).rgb, 0.0) * nearSun * decay;
        }
        // The final two taps are symmetric around the sun because the loop samples at 1.5..48.5 steps.
        if (i < N - 2) nearSun *= nearSunStep;
        // Match the attenuation across the full ray at every tier.
        decay *= pow(0.965, 48.0 / float(N));
    }
    return acc / float(N) * onScreen * reach;
#else
    return vec3(0.0);
#endif
}

void main() {
    vec3 bloomColor, glareColor, emitColor;
    bloomAndGlare(texcoord, bloomColor, glareColor, emitColor);
    // The original final result is mix(scene + GLARE_STRENGTH * glare + SUN_RAYS_STRENGTH * rays,
    // bloom, BLOOM_STRENGTH). Weight the additive terms here and preserve that order in final.
    // A low sun blinds: its wide glare (the veil that matches the bloom) grows strongly near the horizon.
    float elev = dot(normalize(sunPosition), normalize(upPosition));
    float lowSun = (1.0 - smoothstep(0.03, 0.35, elev)) * smoothstep(-0.04, 0.01, elev);
    vec3 glareAndRays = glareColor * GLARE_STRENGTH * (1.0 + LOW_SUN_GLARE * lowSun);
#if !defined DIM_NETHER && !defined DIM_END
    glareAndRays += sunRays(texcoord) * SUN_RAYS_STRENGTH;
#endif
    glareAndRays += emitColor * EMITTER_BLOOM;
    outGlareAndRays = vec4(glareAndRays, 1.0);
    outBloom = vec4(bloomColor, 1.0);
}
#endif
