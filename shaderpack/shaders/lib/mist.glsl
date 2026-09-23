// Ground mist: patchy fog that pools in low valleys, thickest around sunrise, lifting by midday.
// Requires clouds.glsl (cloudTex, noise1, cloudWind) and uniforms worldDay, worldTime, rainStrength.

#define MIST_BASE 66.0      // world height where mist is densest
#define MIST_FALLOFF 36.0   // e-folding height above the base (blocks)
#define MIST_DENSITY 0.011  // peak extinction per block

// How much mist the current time of day and weather allow (0..1). Computed per frame, not per sample.
float mistAmount(vec3 sunDir) {
    float elev = sunDir.y;
    // Morning (sun in the east, +x) is the classic valley-fog hour; evenings get a lighter haze.
    float morning = sunDir.x > 0.0 ? 1.0 : 0.45;
    float dayCurve = 1.0 - smoothstep(0.05, 0.55, elev);        // burns off as the sun climbs
    float night = smoothstep(0.0, -0.2, elev) * 0.55;             // settles again at night
    float amount = max(dayCurve * morning, night);
    // Some days are foggy, some are clear.
    float t = float(worldDay) + float(worldTime) / 24000.0;
    amount *= mix(0.25, 1.0, noise1(t * 1.7 + 93.0));
#ifdef MIST_DEBUG
    return 1.0;
#endif
    return saturate(amount + rainStrength * 0.6);
}

float mistDensity(vec3 wp, float amount) {
    float h = wp.y - MIST_BASE;
    float falloff = exp(-max(h, 0.0) / MIST_FALLOFF) * smoothstep(-40.0, 0.0, h);
    if (falloff * amount < 0.01) return 0.0;
    vec3 wind = cloudWind() * 0.25;
    // Two noise scales: banks of fog a few hundred blocks across, torn into wisps.
    float big = cloudTex(vec3((wp.xz + wind.xz) / 900.0, wp.y / 400.0 + 0.1)).r;
    float wisp = cloudTex(vec3((wp.xz + wind.xz * 2.0) / 160.0, wp.y / 90.0 + 0.5)).g;
    float n = smoothstep(0.47, 0.74, big * 0.75 + wisp * 0.25);
    // Low-lying fog stays continuous near the ground; its top edge gets the breakup.
    n = mix(n, 1.0, exp(-max(h, 0.0) / 5.0) * 0.35);
    return MIST_DENSITY * amount * falloff * n;
}
