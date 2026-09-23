// Bloom, glare, sun streaks, eye adaptation, AgX tonemap, and a light grade.
//
// How the sun is built (atmosphere.glsl + here), after studying Photon and Complementary:
//   1. an edgeless, physically bright core drawn in the sky (no visible disc edge once tonemapped),
//   2. a sky aureole around it (sunAureole), so the sky itself glows and occluders cut it naturally,
//   3. energy-conserving bloom plus a thresholded wide glare that only the sun is bright enough to trigger,
//   4. eye-style radial streaks on top, scaled by how much of the sun is actually visible,
//   5. faint screen-space rays from gaps in whatever is in front of the sun.
// None of these is a screen-space sticker: every term is driven by the rendered frame or the sky.

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
uniform sampler2D depthtex0;
uniform sampler2D dhDepthTex0;
uniform int frameCounter;

const bool colortex0MipmapEnabled = true;

// Sun rays: light from the bright sky around the sun, scattered toward the eye along the way, so any gap in
// trees, terrain or cloud edges in front of the sun throws a visible streak outward from it (screen-space
// light scattering, GPU Gems 3 ch. 13). Only open sky within a small radius of the sun feeds it; letting the
// whole sky contribute is what previously made rays shoot everywhere. Anything covering the sun removes the
// rays, because they are built from the visible sky itself.
vec3 sunRays(vec2 uv) {
    vec4 clip = gbufferProjection * vec4(sunPosition, 1.0);
    if (clip.w <= 0.0) return vec3(0.0);
    vec2 sunUV = clip.xy / clip.w * 0.5 + 0.5;
    vec2 aspect = vec2(viewWidth / viewHeight, 1.0);
    // Fade as the sun leaves the frame instead of popping.
    float onScreen = smoothstep(-0.25, 0.05, min(min(sunUV.x, sunUV.y), min(1.0 - sunUV.x, 1.0 - sunUV.y)));
    if (onScreen <= 0.0) return vec3(0.0);

    const int N = 40;
    vec2 delta = (sunUV - uv) / float(N);
    // Pixels far from the sun get nothing (their rays would be too faint to matter); fade smoothly so the
    // effect never ends in a visible circle.
    float len = length(delta * aspect) * float(N);
    float reach = 1.0 - smoothstep(0.35, 0.9, len);
    if (reach <= 0.0) return vec3(0.0);
    vec2 p = uv + delta * hash12(gl_FragCoord.xy + float(frameCounter % 64) * 11.7);
    vec3 acc = vec3(0.0);
    float decay = 1.0;
    for (int i = 0; i < N; i++) {
        p += delta;
        if (any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0)))) break;
        float sky = step(1.0, texture(depthtex0, p).r) * step(1.0, texture(dhDepthTex0, p).r);
        float nearSun = exp(-length((p - sunUV) * aspect) * 9.0);
        acc += textureLod(colortex0, p, 3.0).rgb * sky * nearSun * decay;
        decay *= 0.965;
    }
    return acc / float(N) * onScreen * reach;
}

uniform float frameTimeCounter;

// Glare streaks: the fine radial rays the eye itself adds around a blinding source (the ciliary corona, from
// scattering in the eye's lens). They sit on top of the blown-out core, never replace it. Many thin streaks
// of uneven brightness and length, a handful of longer ones, all slowly shimmering. Strength follows how much
// of the sun is actually visible (sampled against terrain depth and the sun's measured brightness, so clouds
// dim it), so walking behind a tree switches them off.
vec3 sunStreaks(vec2 uv) {
    vec4 clip = gbufferProjection * vec4(sunPosition, 1.0);
    if (clip.w <= 0.0) return vec3(0.0);
    vec2 sunUV = clip.xy / clip.w * 0.5 + 0.5;
    vec2 aspect = vec2(viewWidth / viewHeight, 1.0);
    float onScreen = smoothstep(-0.1, 0.03, min(min(sunUV.x, sunUV.y), min(1.0 - sunUV.x, 1.0 - sunUV.y)));
    if (onScreen <= 0.0) return vec3(0.0);
    vec2 sc = clamp(sunUV, 0.0, 1.0);

    // Visible fraction of the sun: open sky over a small cross around it.
    // A 17-tap Vogel disc resolves leaf-sized gaps, so sun glinting through foliage still flares a little.
    float open = 0.0;
    for (int i = 0; i < 17; i++) {
        float r = sqrt((float(i) + 0.5) / 17.0) * 0.012;
        float th = float(i) * 2.39996323;
        vec2 o = vec2(cos(th), sin(th)) * r / aspect;
        open += step(1.0, texture(depthtex0, sc + o).r) * step(1.0, texture(dhDepthTex0, sc + o).r);
    }
    // Even a sliver of visible sun is blinding: perceived glare rises quickly with the visible fraction.
    open = sqrt(open / 17.0);
    vec3 src = textureLod(colortex0, sc, 2.0).rgb;
    float avgLum = luminance(textureLod(colortex0, vec2(0.5), 11.0).rgb);
    // Clouds in front of the sun lower its measured brightness; streaks need a truly blinding source.
    float blinding = smoothstep(avgLum * 30.0, avgLum * 300.0, luminance(src));
    float vis = open * blinding * onScreen;
    if (vis <= 0.0) return vec3(0.0);

    vec2 dv = (uv - sunUV) * aspect;
    float d = length(dv);
    float a = atan(dv.y, dv.x) / TAU + 0.5;
    float t = frameTimeCounter * 0.03;
    // Wrap-safe angular noise: sample on a circle so there is no seam at a = 0 / 1.
    vec2 ca = vec2(cos(a * TAU), sin(a * TAU));
    float fine = valueNoise(ca * 38.0 + t) * valueNoise(ca * 61.0 - t * 1.3);
    float coarse = valueNoise(ca * 9.0 + 3.1 + t * 0.5);
    float streak = pow(fine, 3.0) * 1.6 + pow(coarse, 5.0) * 0.8;
    // Each streak fades with its own reach; they start just outside the blown-out core.
    // A high sun sits in a darker, clearer sky, where long streaks look artificial; keep them shorter.
    float reach = mix(0.06, 0.22, valueNoise(ca * 23.0 + 7.0)) * mix(1.0, 0.65, smoothstep(0.2, 0.7, normalize(sunPosition).y));
    float fade = exp(-d / reach) * smoothstep(0.004, 0.03, d);
    vec3 tint = src / max(luminance(src), 1e-4);
    return tint * avgLum * streak * fade * vis;
}

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
        // Nearly flat weights: the wide levels carry the big soft glow around very bright sources.
        float weight = pow(0.86, float(lod - 1));
        b += s / 16.0 * weight;
        total += weight;
    }
    return b / total;
}

// Glare: the long, faint scatter tail eyes and lenses have around very bright sources. Built only from what
// is far brighter than the average scene (in practice the sun and the sky right around it), so anything in
// front of the sun cuts it, and ordinary bright surfaces never glow. The widest blur levels dominate, which
// gives a large soft bloom instead of a tight halo.
vec3 glare(vec2 uv) {
    float avgLum = luminance(textureLod(colortex0, vec2(0.5), 11.0).rgb);
    float threshold = max(avgLum * 12.0, 1e-3);
    vec3 g = vec3(0.0);
    float total = 0.0;
    vec2 px = 1.0 / vec2(viewWidth, viewHeight);
    for (int lod = 4; lod <= 9; lod++) {
        float scale = exp2(float(lod));
        vec3 s = vec3(0.0);
        for (int y = -1; y <= 1; y++)
            for (int x = -1; x <= 1; x++) {
                float w = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
                vec3 c = textureLod(colortex0, uv + vec2(x, y) * px * scale * 0.75, float(lod)).rgb;
                // Soft knee keeps the glow from switching on abruptly.
                float l = luminance(c);
                s += c * (max(l - threshold, 0.0) / max(l, 1e-5)) * w;
            }
        float weight = float(lod - 3);
        g += s / 16.0 * weight;
        total += weight;
    }
    return g / total;
}

void main() {
    vec3 col = texture(colortex0, texcoord).rgb;
    col += glare(texcoord) * GLARE_STRENGTH;
    col += sunRays(texcoord) * SUN_RAYS_STRENGTH;
    // Energy-conserving bloom (Photon, COD: AW): a fraction of every pixel's light is redistributed into its
    // wide blur instead of being added on top. Only sources far brighter than their surroundings, like the
    // sun, produce a visible glow; everything else just softens very slightly.
    col = mix(col, bloom(texcoord), BLOOM_STRENGTH);
    // Streaks go on after bloom so they stay crisp instead of being blurred away.
    col += sunStreaks(texcoord) * SUN_STREAK_STRENGTH;

    // Eye adaptation (see taa.glsl): expose so the adapted scene brightness maps to a mid tone.
    float adaptedLog = texelFetch(colortex5, ivec2(0), 0).a;
    // Partial adaptation around a daylight reference: bright views (the sun) darken steeply, dark views
    // (night, caves) open up gently so night still reads as night.
    const float refLog = -0.75;
    float slope = adaptedLog > refLog ? 0.45 : 0.4;
    float exposure = exp2(log2(EXPOSURE_KEY) - slope * (adaptedLog - refLog));
    exposure = clamp(exposure, EXPOSURE_MIN, EXPOSURE_MAX);
    col *= exposure;

    // Night vision: in dim light eyes lose color and shift toward blue (rods take over from cones).
    // Blend by exposed brightness so torchlit areas keep their warm color.
    float lum = luminance(col);
    float scotopic = 1.0 - smoothstep(0.004, 0.06, lum);
    vec3 rodColor = vec3(0.55, 0.72, 1.0) * lum * 1.4;
    col = mix(col, rodColor, scotopic * 0.75);

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
