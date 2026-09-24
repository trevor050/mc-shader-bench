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

uniform mat4 gbufferModelViewInverse;
uniform float rainStrength;
uniform float frameTimeCounter;
#include "/lib/atmosphere.glsl"

#ifdef VERTEX
out vec2 texcoord;
flat out vec3 whiteBalance;
uniform vec3 sunPosition;
void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    // Eyes adapt to the colour of daylight: sunlight filtered through the air is slightly warm, but a white
    // cloud at noon still looks white. Neutralize most of that tint by day; let golden hour stay golden.
    vec3 sd = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    vec3 sunCol = sunTransmittance(sd);
    sunCol /= max(luminance(sunCol), 1e-4);
    float strength = 0.85 * smoothstep(0.08, 0.45, sd.y);
    whiteBalance = mix(vec3(1.0), 1.0 / max(sunCol, vec3(0.05)), strength);
    whiteBalance /= luminance(whiteBalance);
}
#endif

#ifdef FRAGMENT
uniform sampler2D colortex0;
uniform sampler2D colortex3;
uniform sampler2D colortex7;
uniform sampler2D colortex5;
uniform vec3 sunPosition;
uniform mat4 gbufferProjection;
uniform float viewWidth;
uniform float viewHeight;
uniform sampler2D depthtex0;
uniform sampler2D dhDepthTex0;
uniform int frameCounter;
uniform ivec2 eyeBrightnessSmooth;

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

    // Test the sun radiance before the depth taps. When it is below the streak threshold, visibility cannot
    // affect the zero result, so skip 34 depth reads for every pixel in that frame.
    vec3 src = textureLod(colortex0, sc, 2.0).rgb;
    float avgLum = luminance(textureLod(colortex0, vec2(0.5), 11.0).rgb);
    // Clouds in front of the sun lower its measured brightness; streaks need a truly blinding source.
    float blinding = smoothstep(avgLum * 30.0, avgLum * 300.0, luminance(src));
    if (blinding <= 0.0) return vec3(0.0);

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
flat in vec3 whiteBalance;
layout(location = 0) out vec4 fragColor;

// AgX (Troy Sobotka), polynomial fit by Benjamin Wrensch.
vec3 agxContrast(vec3 x) {
    // Horner form exposes multiply-adds and avoids separately constructing x^2, x^3, x^4, x^5, and x^6.
    return (((((15.5 * x - 40.14) * x + 31.96) * x - 6.868) * x + 0.4298) * x + 0.1191) * x - 0.00232;
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

// AgX tonemaps each channel on its own, so a very bright saturated colour (lava, fire, a sunset) has its dominant
// channel crushed first and drifts toward salmon-pink and then white. For bright, saturated colours, tonemap
// the brightest channel instead and keep the colour's own proportions, with a partial path to white only at the
// very top, so lava stays a vivid yellow-orange (Trevor's Solas reference) while the rest of the image keeps
// AgX's look.
// Filmic tonemap after Jim Hejl (2015), as used by Bliss's "v2.0.4 colour processing" profile (Trevor's pick
// over AgX: deeper, more saturated colour and firmer contrast). White point 3.0; output linear, then sRGB-encoded.
vec3 hejl2015(vec3 hdr) {
    vec4 vh = vec4(hdr * 0.85, 3.0);
    vec4 va = 1.75 * vh + 0.05;
    vec4 vf = (vh * va + 0.004) / (vh * (va + 0.55) + 0.0491) - 0.0821 + 0.000633604888;
    return vf.xyz / vf.www;
}
vec3 linearToSrgb(vec3 c) {
    c = max(c, 0.0);
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}
vec3 filmic(vec3 c) { return saturate(linearToSrgb(hejl2015(c))); }

// Hejl's curve (like AgX) runs each channel on its own, so a very bright saturated colour (lava, fire, a sunset)
// has its dominant channel compressed first and drifts toward pink and white. For bright, saturated colours,
// tonemap the brightest channel instead and keep the colour's proportions, with a partial path to white only
// at the very top, so lava stays a vivid yellow-orange.
vec3 agxHuePreserving(vec3 c) {
    // TAA sharpening can leave a channel slightly negative next to very bright lava; a negative base in pow()
    // returned NaN and showed up as black pixels on flowing lava.
    c = max(c, vec3(0.0));
    vec3 a = filmic(c);
    float m = max(c.r, max(c.g, c.b));
    if (m <= 1e-5) return a;
    float mn = min(c.r, min(c.g, c.b));
    float chroma = (m - mn) / m;
    float w = smoothstep(0.35, 0.8, chroma) * smoothstep(0.4, 3.0, m);
    if (w <= 0.0) return a;
    float mt = filmic(vec3(m)).g;
    // AgX's output is display-encoded, so carry the colour's proportions over in display space too.
    vec3 hp = pow(c / m, vec3(1.0 / 2.2)) * mt;
    // The hottest pixels still run toward yellow-white, the way molten rock and the sun's disc do.
    float white = smoothstep(0.82, 1.0, mt);
    hp = mix(hp, vec3(mt) * vec3(1.0, 0.93, 0.75), white * 0.45);
    return mix(a, hp, w);
}

vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

vec3 hsv2rgb(vec3 c) {
    vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(vec3(1.0), saturate(p - 1.0), c.y);
}

// Display-referred colour grade, applied to the whole image so it never depends on recognizing blocks.
// A gentle filmic S-curve, vibrance (lifts muted colours more than already vivid ones), per-hue shaping
// that deepens Minecraft's yellowish grass toward green and its washed-out skies and water toward blue,
// and a split tone: cool shadows, warm highlights.
vec3 colorGrade(vec3 c) {
    c = saturate(c);
    // S-curve around the midtones.
    vec3 s = c * c * (3.0 - 2.0 * c);
    c = mix(c, s, GRADE_CONTRAST);

    vec3 hsv = rgb2hsv(c);
    // Work directly in turns; this avoids scaling the hue for degree-based ranges and scaling it back.
    float h = hsv.x;
    // Hue shaping: yellow-greens (60-110 deg) nudge toward green and gain saturation; cyans/blues gain depth.
    // Only genuine yellow-greens (grass, leaves) shift; starting lower dragged autumn and red-orange modded
    // foliage toward green.
    float green = smoothstep(72.0 / 360.0, 92.0 / 360.0, h) * (1.0 - smoothstep(130.0 / 360.0, 160.0 / 360.0, h));
    float blue = smoothstep(180.0 / 360.0, 200.0 / 360.0, h) * (1.0 - smoothstep(245.0 / 360.0, 270.0 / 360.0, h));
    float warm = 1.0 - smoothstep(25.0 / 360.0, 50.0 / 360.0, h) + smoothstep(330.0 / 360.0, 350.0 / 360.0, h);
    hsv.x += green * (1.0 / 60.0) * smoothstep(0.1, 0.4, hsv.y);
    hsv.y *= 1.0 + green * 0.08 + blue * 0.12 + warm * 0.04;
    hsv.z *= 1.0 - blue * 0.04 * hsv.y;
    // Vibrance.
    hsv.y = saturate(hsv.y * (1.0 + GRADE_VIBRANCE * (1.0 - hsv.y)));
    c = hsv2rgb(hsv);

    float l = luminance(c);
    vec3 shadowTint = vec3(0.95, 1.0, 1.07);
    vec3 highTint = vec3(1.05, 1.0, 0.94);
    // Near-white stays neutral so clouds and snow do not turn cream.
    float tone = smoothstep(0.08, 0.6, l);
    vec3 tint = mix(shadowTint, highTint, tone);
    c *= mix(tint, vec3(1.0), smoothstep(0.72, 0.95, l));
    return saturate(c);
}

#ifdef DIM_END
uniform mat4 gbufferModelView;
uniform vec3 cameraPosition;
uniform float thunderStrength;

// Being inside the End storm, as camera effects only (Trevor: no geometry in front of the lens). Everything is
// driven by the gust envelope the ClaudeBench Ambience mod sends through the End's thunder level (see
// end_atmosphere.glsl), so the image is hit at the same moment the wind is heard. Layers, in order:
//  1. Roll and zoom surge: the view rolls with smooth noise and pushes in slightly as a gust hits (trauma model:
//     strength is trauma squared, Eiserloh, GDC 2016). The mod sways yaw and pitch; roll can only happen here.
//  2. Air flow: the image refracts through streaky noise racing along the wind, so the air visibly tears past.
//  3. Gust smear: a directional blur along the wind that swells only with gusts.
//  4. Dust fronts: soft, large blotches of dusty haze stream across the view during gusts, lowering contrast.
//  5. Edge fringe: a slight radial colour split toward the edges while a gust is on.
vec3 endStormCamera(vec2 uv) {
    float I = rainStrength < 0.1 ? 0.55 : clamp((rainStrength - 0.2) / 0.8 * 1.001, 0.0, 1.0);
    float raw = rainStrength < 0.1 ? 0.0 : thunderStrength / max(rainStrength, 1e-3);
    float t = frameTimeCounter;
    float gust = rainStrength < 0.1 ? 0.5 + 0.5 * sin(t * 0.9) * sin(t * 0.37 + 2.0) : (raw < 0.5 ? clamp(raw / 0.499, 0.0, 1.0) : 1.0);
    float aspect = viewWidth / viewHeight;
    float trauma = min(1.0, I * (0.25 + 0.75 * gust));
    float shake = trauma * trauma;

    // Wind direction on screen: the gale circles the vortex at the world origin.
    vec3 rel = cameraPosition - vec3(0.0, 100.0, 0.0);
    vec3 windWorld = normalize(vec3(-rel.z, 0.0, rel.x) + vec3(1e-3, 0.0, 0.0));
    vec3 windView = mat3(gbufferModelView) * windWorld;
    vec2 d = length(windView.xy) > 0.05 ? normalize(windView.xy) : vec2(1.0, 0.0);
    vec2 nrm = vec2(-d.y, d.x);

    // 1. Roll and zoom surge.
    float roll = (sin(t * 1.9 + 1.3) * 0.5 + sin(t * 3.7 + 0.4) * 0.3 + sin(t * 7.1) * 0.2) * radians(1.6) * shake;
    float zoom = 1.0 - 0.014 * gust * gust * I;
    vec2 c = (uv - 0.5) * vec2(aspect, 1.0);
    c = mat2(cos(roll), -sin(roll), sin(roll), cos(roll)) * c * zoom;
    uv = c / vec2(aspect, 1.0) + 0.5;

    // 2. Air flow refraction: streaky noise stretched along the wind, racing with it.
    vec2 p = uv * vec2(aspect, 1.0);
    float along = dot(p, d), across = dot(p, nrm);
    float speed = 1.5 + 3.5 * I;
    float n1 = valueNoise(vec2(along * 2.5 - t * speed, across * 16.0));
    float n2 = valueNoise(vec2(along * 5.0 - t * speed * 1.6 + 5.0, across * 29.0 + 3.0));
    float flow = (n1 - 0.5) * 0.7 + (n2 - 0.5) * 0.3;
    vec2 refr = (nrm * flow * 0.006 + d * (n1 - 0.5) * 0.003) * (0.25 + 0.75 * gust) * I;
    refr.x /= aspect;
    uv += refr;

    // 3. Gust smear: 9 taps along the wind.
    vec2 dirUV = d / vec2(aspect, 1.0);
    float len = 0.018 * gust * gust * I * I;
    vec3 acc = vec3(0.0);
    float wsum = 0.0;
    for (int k = -4; k <= 4; k++) {
        float w = 1.0 - abs(float(k)) / 5.0;
        acc += texture(colortex0, uv + dirUV * len * float(k) / 4.0).rgb * w;
        wsum += w;
    }
    vec3 col = acc / wsum;

    // 5. Edge fringe during gusts (red outward, blue inward), strongest at the corners.
    vec2 fromCentre = uv - 0.5;
    float fringe = 0.004 * gust * I * dot(fromCentre, fromCentre) * 4.0;
    if (fringe > 1e-4) {
        col.r = mix(col.r, texture(colortex0, uv + fromCentre * fringe * 2.0).r, 0.7);
        col.b = mix(col.b, texture(colortex0, uv - fromCentre * fringe * 2.0).b, 0.7);
    }

    // 4. Dust fronts: large soft blotches of dusty haze streaming across with the wind.
    float dust = valueNoise(vec2(along * 1.1 - t * speed * 0.55, across * 2.2 + 11.0)) * 0.6
               + valueNoise(vec2(along * 2.3 - t * speed * 0.8 + 3.0, across * 4.5)) * 0.4;
    float haze = smoothstep(0.45, 0.85, dust) * gust * I;
    vec3 dustCol = vec3(luminance(col)) * 1.35 + vec3(0.006, 0.0035, 0.009);
    col = mix(col, dustCol, haze * 0.45);
    // Dust in the air flattens colour a little during gusts.
    col = mix(col, vec3(luminance(col)), 0.18 * gust * I);
    return col;
}
#endif

void main() {
#ifdef DIM_END
    vec3 col = endStormCamera(texcoord);
#else
    vec3 col = texture(colortex0, texcoord).rgb;
#endif
    // composite4 stores bloom in the retired cloud/VL scratch buffer and weighted glare+rays in colortex3.
    // This keeps the original additive order: (scene + glare + rays) is mixed toward bloom afterward.
    col += texture(colortex3, texcoord).rgb;
    // Energy-conserving bloom (Photon, COD: AW): a fraction of every pixel's light is redistributed into its
    // wide blur instead of being added on top. Only sources far brighter than their surroundings, like the
    // sun, produce a visible glow; everything else just softens very slightly.
    col = mix(col, texture(colortex7, texcoord).rgb, BLOOM_STRENGTH);
    // Streaks go on after bloom so they stay crisp instead of being blurred away.
    col += sunStreaks(texcoord) * SUN_STREAK_STRENGTH;

    // Eye adaptation (see taa.glsl): expose so the adapted scene brightness maps to a mid tone.
    float adaptedLog = texelFetch(colortex5, ivec2(0), 0).a;
    // Partial adaptation around a daylight reference: bright views (the sun) darken steeply, dark views
    // (night, caves) open up gently so night still reads as night.
    const float refLog = -0.75;
    float slope = adaptedLog > refLog ? 0.45 : 0.36;
    float exposure = exp2(log2(EXPOSURE_KEY) - slope * (adaptedLog - refLog));
#if !defined DIM_NETHER && !defined DIM_END
    // Underground the eye may not open all the way: dark caves must stay dark, torch-lit ones stay readable.
    float underground = 1.0 - smoothstep(0.05, 0.6, float(eyeBrightnessSmooth.y) / 240.0);
    exposure = clamp(exposure, EXPOSURE_MIN, mix(EXPOSURE_MAX, EXPOSURE_MAX_CAVE, underground));
#else
    // A narrow range: glowing lava and lit smoke must not stop the eye down until the rock around them goes black
    // (Trevor, comparing with Solas, where the Nether's rock stays readable beside blazing lava).
    exposure = clamp(exposure * EXPOSURE_KEY_OTHERWORLD / EXPOSURE_KEY, EXPOSURE_MIN_OTHERWORLD, EXPOSURE_MAX_OTHERWORLD);
#endif
    col *= exposure;
#if !defined DIM_NETHER && !defined DIM_END
    col *= whiteBalance;
#endif

    // Night vision: in dim light eyes lose color and shift toward blue (rods take over from cones).
    // Blend by exposed brightness so torchlit areas keep their warm color.
    float lum = luminance(col);
    float scotopic = 1.0 - smoothstep(0.004, 0.06, lum);
    vec3 rodColor = vec3(0.55, 0.72, 1.0) * lum * 1.4;
    // Kept subtle: a strong shift painted every dark cave wall blue-grey.
    col = mix(col, rodColor, scotopic * 0.35);

    vec3 exposed = col;
    col = agxHuePreserving(col);
    // Complementary's dark lift and dark desaturation (composite5 DoCompTonemap): below a luminance of 0.1 the
    // tonemap's toe is mostly undone, so shade, caves and night stay readable instead of crushing to black, and
    // the darkest tones lose a little saturation (the eye's own behaviour in low light).
    float initialLum = luminance(exposed);
    float darkLift = smoothstep(0.1, 0.0, initialLum);
    col = mix(col, pow(max(exposed, 0.0), vec3(1.0 / 2.2)), darkLift * 0.75);
    col = mix(col, vec3(luminance(col)), darkLift * 0.25);
    col = colorGrade(col);

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
