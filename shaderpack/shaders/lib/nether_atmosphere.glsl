// Low-cost Nether smoke and lava-lit distance haze. Requires clouds.glsl's cloudTex().

float netherSmokeDensity(vec3 p) {
    float altitude = max(p.y - 34.0, 0.0);

    // Oblique world axes stretch the tile far beyond a normal view and shear the field with height,
    // so the billows rise as columns instead of reading as a flat cloud deck.
    vec3 q = vec3(
        p.x * 0.00113 + p.z * 0.00027 + altitude * 0.00024,
        p.z * 0.00107 - p.x * 0.00031 - altitude * 0.00018,
        altitude * 0.00175 + p.x * 0.00019 - p.z * 0.00041 - frameTimeCounter * 0.00036
    );
    vec4 noise = cloudTex(q);
    float shape = noise.r * 0.68 + noise.g * 0.19 + noise.b * 0.09 + noise.a * 0.04;
    float billow = smoothstep(0.42, 0.64, shape);
    float height = smoothstep(35.0, 49.0, p.y) * (1.0 - smoothstep(126.0, 158.0, p.y));
    return billow * height;
}

vec3 netherFogColor(vec3 rd, float y) {
    // Ember lift belongs near lava and along the horizon. Steep views stay ashen, avoiding an orange wash.
    float nearLava = exp(-max(y - 31.0, 0.0) / 37.0);
    float horizon = exp(-abs(rd.y) * 3.2);
    float glow = nearLava * (0.11 + horizon * 0.38);
    return vec3(0.010, 0.008, 0.007) + vec3(0.105, 0.023, 0.0035) * glow;
}

vec4 sampleNetherSmoke(vec3 origin, vec3 rd, float rayLimit) {
    const float SMOKE_BOTTOM = 36.0;
    const float SMOKE_TOP = 151.0;
    float t0 = 0.0;
    float t1 = rayLimit;

    if (abs(rd.y) < 0.001) {
        if (origin.y < SMOKE_BOTTOM || origin.y > SMOKE_TOP) return vec4(0.0);
    } else {
        float a = (SMOKE_BOTTOM - origin.y) / rd.y;
        float b = (SMOKE_TOP - origin.y) / rd.y;
        t0 = max(t0, min(a, b));
        t1 = min(t1, max(a, b));
    }

    float segment = t1 - t0;
    if (segment < 4.0) return vec4(0.0);

    vec3 p = origin + rd * (t0 + segment * 0.52);
    float density = netherSmokeDensity(p);
    float opacity = 1.0 - exp(-min(density * segment * 0.008, 0.60));
    float heat = exp(-max(p.y - 34.0, 0.0) / 60.0);
    float viewLift = mix(0.38, 1.0, saturate(-rd.y * 0.65 + 0.5));

    // Soot dominates overhead; lower billows catch a restrained red-orange lift from the lava seas.
    vec3 soot = vec3(0.025, 0.019, 0.016);
    vec3 ember = vec3(0.120, 0.029, 0.007) * heat * viewLift;
    return vec4(soot + ember, opacity);
}
