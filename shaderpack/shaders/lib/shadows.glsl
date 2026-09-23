// Shadow-space distortion and filtered lookups.
// Requires uniforms shadowModelView, shadowProjection, shadowtex0, shadowtex1, shadowcolor0.

const float SHADOW_DISTORT = 0.86;

vec3 distortShadow(vec3 p) {
    float f = length(p.xy) * SHADOW_DISTORT + (1.0 - SHADOW_DISTORT);
    return vec3(p.xy / f, p.z * 0.2);
}

#ifndef SHADOW_PASS
// Vogel disk for well-spread PCF taps.
vec2 vogel(int i, int n, float phi) {
    float r = sqrt((float(i) + 0.5) / float(n));
    float theta = float(i) * 2.39996323 + phi;
    return r * vec2(cos(theta), sin(theta));
}

// Returns colored shadow visibility. playerPos is relative to the camera; normal is world space.
vec3 sampleShadow(vec3 playerPos, vec3 normal, float NdotL, float dither) {
    float dist = length(playerPos);
    if (dist > SHADOW_DIST) return vec3(1.0);

    // Normal offset scaled by distance keeps acne away on far, low-res texels.
    vec3 offsetPos = playerPos + normal * (0.035 + dist * 0.0018) * (1.0 + 2.0 * (1.0 - NdotL));
    vec3 sp = (shadowProjection * (shadowModelView * vec4(offsetPos, 1.0))).xyz;
    float f = length(sp.xy) * SHADOW_DISTORT + (1.0 - SHADOW_DISTORT);
    vec3 ds = distortShadow(sp) * 0.5 + 0.5;
    float bias = 0.00008 * f;

    // Blocker search sets the penumbra width (contact hardening).
    float texel = 1.0 / float(SHADOW_MAP_RES);
    float phi = dither * TAU;
    float blocker = 0.0, count = 0.0;
    for (int i = 0; i < 6; i++) {
        vec2 o = vogel(i, 6, phi) * texel * 6.0 / f;
        float d = texture(shadowtex0, ds.xy + o).r;
        if (d < ds.z - bias) { blocker += d; count += 1.0; }
    }
    if (count < 0.5) return vec3(1.0);
    blocker /= count;
    float penumbra = clamp((ds.z - blocker) * 320.0, 0.6, 7.0) * SHADOW_SOFTNESS;

    vec3 vis = vec3(0.0);
    for (int i = 0; i < SHADOW_SAMPLES; i++) {
        vec2 o = vogel(i, SHADOW_SAMPLES, phi) * texel * penumbra / f;
        vec3 p = vec3(ds.xy + o, ds.z - bias);
        float solid = step(p.z, texture(shadowtex1, p.xy).r);
        float all = step(p.z, texture(shadowtex0, p.xy).r);
        // Translucent casters (stained glass) tint the light instead of blocking it.
        vec4 tint = texture(shadowcolor0, p.xy);
        vis += mix(vec3(solid) * toLinear(tint.rgb) * (1.0 - tint.a * 0.5), vec3(1.0), all);
    }
    vis /= float(SHADOW_SAMPLES);
    // Fade out near the edge of the shadow distance.
    return mix(vis, vec3(1.0), smoothstep(SHADOW_DIST * 0.85, SHADOW_DIST, dist));
}
#endif
