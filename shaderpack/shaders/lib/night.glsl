// Night-time sky and air effects: aurora curtains and fireflies.
// Requires common.glsl (hash12, valueNoise) and settings.glsl.

// Aurora: folded curtains of light hanging from a layer high above the ground. Each of the stacked layers is the
// same sheet pattern seen at a greater height, so a fold reads as a tall curtain with vertical rays; green at the
// base, fading through teal into a violet-pink crown. rd is the world-space view direction; t is time in seconds.
vec3 aurora(vec3 rd, float t) {
    if (rd.y < 0.02) return vec3(0.0);
    const int LAYERS = 14;
    vec3 acc = vec3(0.0);
    float dither = hash12(rd.xz * 811.0 + rd.y * 97.0);
    for (int i = 0; i < LAYERS; i++) {
        float h = (float(i) + dither) / float(LAYERS);
        // Position on a flat layer at altitude 1 + 1.4 h (arbitrary units; only the ratio matters).
        vec2 p = rd.xz / rd.y * (1.0 + h * 1.4) * 0.35;
        // A slowly writhing fold line: a warped stripe field whose crests are the curtains.
        vec2 q = p + vec2(t * 0.006, t * 0.002);
        float warp = valueNoise(q * 0.9 + vec2(t * 0.015, 0.0)) * 2.4 + valueNoise(q * 2.3 - vec2(0.0, t * 0.02)) * 0.7;
        float phase = q.x * 1.3 + q.y * 0.45 + warp;
        float sheet = pow(1.0 - abs(sin(phase * 1.6)), 10.0);
        // Rays: brightness varies along the curtain but not with height.
        float rays = 0.35 + 0.65 * valueNoise(vec2(phase * 18.0, t * 0.12));
        // Broad patches of activity so the curtains come and go across the sky.
        float activity = smoothstep(0.35, 0.75, valueNoise(q * 0.45 + vec2(-t * 0.004, t * 0.003)));
        // Brightest near the lower edge, fading up the curtain.
        float fall = exp(-h * 2.6) * smoothstep(0.0, 0.08, h + 0.02);
        vec3 c = mix(vec3(0.15, 1.0, 0.45), vec3(0.1, 0.75, 0.8), smoothstep(0.1, 0.45, h));
        c = mix(c, vec3(0.75, 0.25, 0.9), smoothstep(0.45, 0.95, h));
        acc += c * sheet * rays * activity * fall;
    }
    float horizon = smoothstep(0.02, 0.22, rd.y);
    return acc / float(LAYERS) * horizon * AURORA_BRIGHTNESS * 6.0;
}

// Fireflies: soft yellow-green points drifting a block or two above the ground near the camera, blinking on and off.
// An exact 3D DDA over 3-block cells along the view ray; a few cells hold one firefly each. Cells are limited to a
// band around the camera's feet (there is no height map to put them over the ground elsewhere).
vec3 fireflies(vec3 camPos, vec3 rd, float maxDist, float t) {
    const float CELL = 3.0;
    const int STEPS = 28;
    vec3 ro = camPos / CELL;
    vec3 cell = floor(ro);
    vec3 stepDir = sign(rd);
    vec3 tDelta = abs(1.0 / max(abs(rd), vec3(1e-4)));
    vec3 tMax = (stepDir * (cell - ro) + stepDir * 0.5 + 0.5) * tDelta;
    vec3 acc = vec3(0.0);
    float limit = min(maxDist, 42.0) / CELL;
    float yLo = floor((camPos.y - 5.0) / CELL), yHi = floor((camPos.y + 1.5) / CELL);
    for (int i = 0; i < STEPS; i++) {
        float tCell = min(tMax.x, min(tMax.y, tMax.z));
        if (cell.y >= yLo && cell.y <= yHi) {
            float h = hash12(cell.xz * 0.917 + cell.y * 2.131 + 5.3);
            if (h > 0.72) {
                float h2 = hash12(cell.zy * 1.73 + 8.1), h3 = hash12(cell.xy * 2.57 + 1.9);
                vec3 m = cell + vec3(h2, fract(h * 5.7), h3) * 0.7 + 0.15;
                // Lazy looping flight.
                m += vec3(sin(t * 0.31 + h * 30.0), 0.6 * sin(t * 0.47 + h2 * 30.0), cos(t * 0.27 + h3 * 30.0)) * 0.22;
                vec3 d = m - ro;
                float along = dot(d, rd);
                if (along > 0.05 && along < limit) {
                    float perp2 = max(dot(d, d) - along * along, 0.0);
                    // Blink: on for about a second and a half, dark for a few seconds.
                    float cycle = fract(t / (3.5 + 2.0 * h3) + h2);
                    float blink = smoothstep(0.0, 0.12, cycle) * smoothstep(0.42, 0.25, cycle);
                    // A tight core and a faint soft halo (the halo keeps distant ones from aliasing to nothing).
                    const float r = 0.014;
                    float glow = exp(-perp2 / (r * r)) + 0.06 * exp(-perp2 / (r * r * 30.0));
                    acc += vec3(0.75, 1.0, 0.22) * glow * blink * smoothstep(limit, limit * 0.55, along);
                }
            }
        }
        if (tCell > limit) break;
        if (tMax.x < tMax.y && tMax.x < tMax.z) { cell.x += stepDir.x; tMax.x += tDelta.x; }
        else if (tMax.y < tMax.z) { cell.y += stepDir.y; tMax.y += tDelta.y; }
        else { cell.z += stepDir.z; tMax.z += tDelta.z; }
    }
    return acc;
}
