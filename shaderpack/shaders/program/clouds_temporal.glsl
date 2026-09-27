// Temporal accumulation of a half-resolution, per-frame-dithered march into a history buffer that is never
// cleared. History is reprojected through the marched point's own distance and clipped to the current
// neighborhood.
//   default:     clouds, colortex7 -> colortex9, distance = cloud distance (colortex8.r)
//   TEMPORAL_VL: light shafts and mist, colortex7 -> colortex11, distance = scene distance (colortex8.r)

#include "/lib/settings.glsl"
#include "/lib/common.glsl"

#ifdef VERTEX
void main() { gl_Position = ftransform(); }
#endif

#ifdef FRAGMENT
#ifdef TEMPORAL_VL
uniform sampler2D colortex7;
uniform sampler2D colortex11;
uniform sampler2D colortex8;
#define CUR_TEX colortex7
#define DIST_TEX colortex8
#define HIST_TEX colortex11
/* RENDERTARGETS: 11 */
#else
uniform sampler2D colortex7;
uniform sampler2D colortex8;
uniform sampler2D colortex9;
#define CUR_TEX colortex7
#define DIST_TEX colortex8
#define HIST_TEX colortex9
/* RENDERTARGETS: 9 */
#endif
uniform float viewWidth;
uniform float viewHeight;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
layout(location = 0) out vec4 outHistory;

void main() {
#if (defined DIM_END || defined DIM_NETHER) && !defined TEMPORAL_VL
    // The Nether uses the VL history for its smog; clouds (and everything in the End) stay off.
    // Keep the persistent half-resolution history invalid while the passes that produce these effects are off.
    // This prevents a stale Overworld frame from being blended after a dimension transition.
    outHistory = vec4(-1.0);
    return;
#else

    ivec2 bufferSize = textureSize(CUR_TEX, 0);
    vec2 bufferRes = vec2(bufferSize);
    ivec2 texel = ivec2(gl_FragCoord.xy);
    // Keep reprojection on the same normalized grid used to sample the half-resolution history.
    vec2 uv = gl_FragCoord.xy / bufferRes;

    vec4 current = texelFetch(CUR_TEX, texel, 0);
    float dist = texelFetch(DIST_TEX, texel, 0).r;

    // Reproject the cloud point (or the sky direction when there is no cloud).
    vec3 viewPos = projectAndDivide(gbufferProjectionInverse, vec3(uv, 1.0) * 2.0 - 1.0);
    vec3 rd = normalize(mat3(gbufferModelViewInverse) * viewPos);
    bool far = dist > 5e5;
    vec3 prevPlayer = far ? rd : rd * dist + cameraPosition - previousCameraPosition;
    vec3 prevView = mat3(gbufferPreviousModelView) * prevPlayer + (far ? vec3(0.0) : gbufferPreviousModelView[3].xyz);
    vec4 prevClip = gbufferPreviousProjection * vec4(prevView, 1.0);
    vec2 prevUV = prevClip.xy / prevClip.w * 0.5 + 0.5;

    // Neighborhood bounds from the current (noisy) frame. Nether smog must not use far-air
    // samples to bound a rock pixel: on camera motion that permits bright orange history to
    // follow a newly exposed silhouette for several frames.
    vec4 mn = current, mx = current, m1 = vec4(0.0), m2 = vec4(0.0);
    float count = 0.0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            ivec2 p = clamp(texel + ivec2(x, y), ivec2(0), bufferSize - 1);
#if defined TEMPORAL_VL && defined DIM_NETHER
            float neighborDist = texelFetch(DIST_TEX, p, 0).r;
            bool neighborFar = neighborDist > 5e5;
            if (neighborFar != far || (!far && abs(neighborDist - dist) > max(1.5, min(neighborDist, dist) * 0.05))) continue;
#endif
            // The center sample is already in `current`; reuse it without a second texture fetch.
            vec4 s = current;
            if (x != 0 || y != 0) s = texelFetch(CUR_TEX, p, 0);
            m1 += s; m2 += s * s;
            mn = min(mn, s); mx = max(mx, s);
            count += 1.0;
        }
    m1 /= count; m2 /= count;
    vec4 sigma = sqrt(max(m2 - m1 * m1, 0.0));
    vec4 lo = max(mn, m1 - sigma * 2.5), hi = min(mx, m1 + sigma * 2.5);
    lo = min(lo, current); hi = max(hi, current);

    bool offscreen = any(lessThan(prevUV, vec2(0.0))) || any(greaterThan(prevUV, vec2(1.0)));
    vec2 hUV = clamp(prevUV * bufferRes, vec2(0.5), bufferRes - 0.5) / bufferRes;
    vec4 history = texture(HIST_TEX, hUV);
    bool valid = !offscreen && history.a == history.a && all(greaterThanEqual(history, vec4(0.0)));
    history = clamp(history, lo, hi);
    // Slow camera motion keeps a long history; fast turns shorten it to avoid smearing.
    // Preserve A's full-screen motion/blend threshold when the history grid shrinks.
    vec2 referenceRes = max(floor(vec2(viewWidth, viewHeight) * 0.5), vec2(1.0));
    float motion = length((prevUV - uv) * referenceRes);
    float blend = valid ? mix(0.93, 0.7, saturate(motion / 12.0)) : 0.0;
    outHistory = mix(current, history, blend);
#endif
}
#endif
