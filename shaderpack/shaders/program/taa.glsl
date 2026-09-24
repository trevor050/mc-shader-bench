// Temporal anti-aliasing: reproject last frame's result, clamp it to the current neighborhood, blend.
// colortex5 holds the history and is never cleared.

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
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform sampler2D depthtex2;
uniform sampler2D dhDepthTex0;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjectionInverse;
uniform mat4 dhProjectionInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform float viewWidth;
uniform float viewHeight;
uniform float frameTime;

uniform sampler2D colortex6;
const bool colortex6MipmapEnabled = true;

in vec2 texcoord;

/* RENDERTARGETS: 0,5 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outHistory;

vec3 toYCoCg(vec3 c) {
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 fromYCoCg(vec3 c) {
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// Catmull-Rom history fetch in 5 bilinear taps keeps the image sharp under constant resampling.
vec3 sampleHistory(vec2 uv) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 pos = uv * size;
    vec2 center = floor(pos - 0.5) + 0.5;
    vec2 f = pos - center;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 tc12 = (center + w2 / w12) / size;
    vec2 tc0 = (center - 1.0) / size;
    vec2 tc3 = (center + 2.0) / size;
    vec3 c = texture(colortex5, vec2(tc12.x, tc0.y)).rgb * (w12.x * w0.y)
           + texture(colortex5, vec2(tc0.x, tc12.y)).rgb * (w0.x * w12.y)
           + texture(colortex5, tc12).rgb * (w12.x * w12.y)
           + texture(colortex5, vec2(tc3.x, tc12.y)).rgb * (w3.x * w12.y)
           + texture(colortex5, vec2(tc12.x, tc3.y)).rgb * (w12.x * w3.y);
    float wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return max(c / wsum, 0.0);
}

void main() {
    vec3 current = texture(colortex0, texcoord).rgb;
    vec3 result = current;

#ifdef TAA
    // Reconstruct this pixel's position and find where it was last frame.
    float depth = texture(depthtex0, texcoord).r;
    vec3 viewPos;
    bool sky = false;
    if (depth < 1.0) {
        viewPos = projectAndDivide(gbufferProjectionInverse, vec3(texcoord, depth) * 2.0 - 1.0);
    } else {
        float dh = texture(dhDepthTex0, texcoord).r;
        sky = dh >= 1.0;
        viewPos = projectAndDivide(sky ? gbufferProjectionInverse : dhProjectionInverse, vec3(texcoord, sky ? 1.0 : dh) * 2.0 - 1.0);
    }
    vec3 playerPos = mat3(gbufferModelViewInverse) * viewPos + gbufferModelViewInverse[3].xyz;
    // The sky is effectively at infinity: only camera rotation matters.
    vec3 prevPlayer = sky ? playerPos : playerPos + cameraPosition - previousCameraPosition;
    vec3 prevView = mat3(gbufferPreviousModelView) * prevPlayer + (sky ? vec3(0.0) : gbufferPreviousModelView[3].xyz);
    vec4 prevClip = gbufferPreviousProjection * vec4(prevView, 1.0);
    vec2 prevUV = prevClip.xy / prevClip.w * 0.5 + 0.5;
    // The first-person hand is locked to the screen (Iris draws it at depth < 0.56). Reprojecting it as world
    // geometry pulled the terrain behind it into the history, which made the hand look see-through.
    bool hand = depth < 0.56;
    if (hand) prevUV = texcoord;

    bool offscreen = any(lessThan(prevUV, vec2(0.0))) || any(greaterThan(prevUV, vec2(1.0)));
    // depthtex1 includes the solid hand while depthtex2 excludes it. The hand
    // uses a separate depth projection and follows the camera, so ordinary
    // world reprojection blends the scene through it.
    bool rejectHistory = offscreen || hand;
    if (!rejectHistory) {
        float solidDepth = texture(depthtex1, texcoord).r;
        float noHandDepth = texture(depthtex2, texcoord).r;
        rejectHistory = solidDepth < noHandDepth - 0.00001;
    }

    // Rejected history previously produced the current color through a zero blend weight,
    // after paying for neighborhood statistics and five history taps. Keep the same resolve
    // result while skipping those samples on disoccluded and off-screen pixels.
    if (!rejectHistory) {
        // 3x3 neighborhood bounds in YCoCg; history outside them is clipped (kills ghosting).
        vec2 px = 1.0 / vec2(viewWidth, viewHeight);
        // Reuse the center sample already fetched into current. All nine values still
        // contribute; only the floating-point addition order changes slightly.
        vec3 center = toYCoCg(current);
        vec3 m1 = center, m2 = center * center;
        for (int y = -1; y <= 1; y++)
            for (int x = -1; x <= 1; x++) {
                if (x == 0 && y == 0) continue;
                vec3 s = toYCoCg(texture(colortex0, texcoord + vec2(x, y) * px).rgb);
                m1 += s;
                m2 += s * s;
            }
        m1 /= 9.0;
        m2 /= 9.0;
        vec3 sigma = sqrt(max(m2 - m1 * m1, 0.0));
        vec3 lo = m1 - sigma * 1.25, hi = m1 + sigma * 1.25;

        vec3 history = toYCoCg(sampleHistory(prevUV));
        history = clamp(history, lo, hi);
        // Clipping in YCoCg can leave RGB slightly negative beside extreme contrast (the sun's disc against the sky).
        history = max(fromYCoCg(history), 0.0);

        float velocity = length((prevUV - texcoord) * vec2(viewWidth, viewHeight));
        float blend = mix(0.9, 0.75, saturate(velocity / 20.0));
        // (A former "hot pixel" history bypass made the sun re-alias every frame while turning, which read as
        // flicker. The sun's radiance is now soft-capped, so ordinary blending handles it.)
        float currentLum = max(luminance(current), 0.0);
        float historyLum = max(luminance(history), 0.0);
        // Weigh by inverse luminance so bright fireflies do not smear.
        float wc = (1.0 - blend) / (1.0 + currentLum);
        float wh = blend / (1.0 + historyLum);
        result = (current * wc + history * wh) / (wc + wh);
    }
#else
    result = current;
#endif

    // Only (0,0) is read by final and by this pass next frame. Keep the history alpha
    // meaningful there, and avoid repeating the frame-wide adaptation work per pixel.
    float adapted = 0.0;
    if (all(equal(ivec2(gl_FragCoord.xy), ivec2(0)))) {
        // The measurement is center-weighted, so looking at something bright (the sun) darkens the view.
        float whole = textureLod(colortex6, vec2(0.5), 11.0).r;
        float center = textureLod(colortex6, vec2(0.5), 7.0).r;
#if defined DIM_NETHER || defined DIM_END
        // composite meters log2(luminance) + 24 here, so the mip chain is already a log average.
        float target = mix(whole, center, 0.25) - 24.0;
#else
        // (Center weight 0.25 made the sun entering the middle of the view swing the exposure.)
        float target = log2(max(mix(whole, center, 0.12), 1e-5));
#endif
        float prev = texelFetch(colortex5, ivec2(0), 0).a;
        // Adapt faster toward bright scenes than dark ones, like eyes do.
        float rate = target > prev ? 1.6 : 1.0;
        adapted = isnan(prev) || isinf(prev) || prev == 0.0 ? target : mix(prev, target, 1.0 - exp(-frameTime * rate));
    }

    // Never let a bad value into the persistent history: a negative luminance of -1 once divided the blend by zero,
    // and the resulting NaN spread through the sun rays into a black circle around the sun.
    result = max(result, 0.0);
    if (any(isnan(result)) || any(isinf(result))) result = max(current, 0.0);
    outColor = vec4(result, 1.0);
    outHistory = vec4(result, adapted);
}
#endif
