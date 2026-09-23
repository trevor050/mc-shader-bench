// Shadow-space distortion and filtered lookups.
// Requires uniforms shadowModelView, shadowProjection, shadowtex0, shadowtex1, shadowcolor0.

const float SHADOW_DISTORT = 0.86;

vec3 distortShadow(vec3 p) {
    float f = length(p.xy) * SHADOW_DISTORT + (1.0 - SHADOW_DISTORT);
    return vec3(p.xy / f, p.z * 0.2);
}

#ifndef SHADOW_PASS
// Average blocks of water the light crossed on the last sampleShadow call (0 = none). Drives caustics.
float shadowWaterDepth = 0.0;

// Unit-rotation Vogel offsets for n=12. The six blocker radii are sqrt(2) times these.
const vec2 VOGEL_12[12] = vec2[12](
    vec2(0.2041241527, 0.000000000),
    vec2(-0.2606992424, 0.2388219088),
    vec2(0.03990412131, -0.4546878040),
    vec2(0.3285947442, 0.4285932183),
    vec2(-0.6030114889, -0.1066640094),
    vec2(0.5712249875, -0.3633667231),
    vec2(-0.1910628825, 0.7107473016),
    vec2(-0.3643796146, -0.7015892863),
    vec2(0.7905568480, 0.2887094617),
    vec2(-0.8224422932, 0.3394927680),
    vec2(0.3964712918, -0.8472369909),
    vec2(0.2929826975, 0.9340741038)
);

vec2 rotateVogel12(int i, float c, float s) {
    vec2 v = VOGEL_12[i];
    return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// Returns colored shadow visibility. playerPos is relative to the camera; normal is world space.
vec3 sampleShadow(vec3 playerPos, vec3 normal, float NdotL, float dither) {
    shadowWaterDepth = 0.0;
    float dist = length(playerPos);
    if (dist > SHADOW_DIST) return vec3(1.0);

    // Normal offset scaled by distance keeps acne away on far, low-res texels.
    vec3 offsetPos = playerPos + normal * (0.035 + dist * 0.0018) * (1.0 + 2.0 * (1.0 - NdotL));
    vec3 sp = (shadowProjection * (shadowModelView * vec4(offsetPos, 1.0))).xyz;
    float f = length(sp.xy) * SHADOW_DISTORT + (1.0 - SHADOW_DISTORT);
    // Reuse f from the offset and bias calculations instead of recomputing it in distortShadow.
    vec3 ds = vec3(sp.xy / f, sp.z * 0.2) * 0.5 + 0.5;
    float bias = 0.00008 * f;

    // Blocker search sets the penumbra width (contact hardening).
    float texel = 1.0 / float(SHADOW_MAP_RES);
    float phi = dither * TAU;
    float rotationCos = cos(phi), rotationSin = sin(phi);
    float blocker = 0.0, count = 0.0;
    for (int i = 0; i < 6; i++) {
        vec2 o = rotateVogel12(i, rotationCos, rotationSin) * 1.41421356237 * texel * 6.0 / f;
        float d = texture(shadowtex0, ds.xy + o).r;
        if (d < ds.z - bias) { blocker += d; count += 1.0; }
    }
    if (count < 0.5) return vec3(1.0);
    blocker /= count;
    float penumbra = clamp((ds.z - blocker) * 320.0, 0.6, 7.0) * SHADOW_SOFTNESS;

    vec3 vis = vec3(0.0);
    for (int i = 0; i < SHADOW_SAMPLES; i++) {
        vec2 o = rotateVogel12(i, rotationCos, rotationSin) * texel * penumbra / f;
        vec3 p = vec3(ds.xy + o, ds.z - bias);
        float d0 = texture(shadowtex0, p.xy).r;
        // Fully lit taps contribute one regardless of solid/color data; water depth is zero here too.
        if (d0 >= p.z) {
            vis += vec3(1.0);
            continue;
        }
        float solid = step(p.z, texture(shadowtex1, p.xy).r);
        vec4 tint = texture(shadowcolor0, p.xy);
        vec3 through;
        if (tint.a < 0.01) {
            // Water: shadow-depth difference -> blocks of water crossed (undo the 0.2 z squash).
            float blocks = max((p.z - d0) * 10.0 / abs(shadowProjection[2][2]), 0.0);
            through = exp(-vec3(0.42, 0.075, 0.05) * blocks);
            shadowWaterDepth += blocks / float(SHADOW_SAMPLES);
        } else {
            // Stained glass and ice tint the light instead of blocking it.
            if (solid < 0.5) continue; // This tap contributes zero; skip the RGB power.
            through = toLinear(tint.rgb) * (1.0 - tint.a * 0.5);
        }
        vis += vec3(solid) * through;
    }
    vis /= float(SHADOW_SAMPLES);
    // Fade out near the edge of the shadow distance.
    return mix(vis, vec3(1.0), smoothstep(SHADOW_DIST * 0.85, SHADOW_DIST, dist));
}
#endif
