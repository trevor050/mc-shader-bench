// Air in enclosed spaces (caves, deep interiors). Where a surface sees no sky, distance fades into the cave's
// own air instead of the daylight horizon: the sky's haze (and the sun's aureole in it) cannot reach a wall
// underground. Each cave biome gets a mood: cool stone, humid green lush caves, warm dripstone dust, and the
// near-black Deep Dark. Block lights scatter off the dust in this air (vl_march), giving coloured halos.
// Requires custom uniforms inDeepDark, inLushCave, inDripstone (shaders.properties).
#ifndef CAVE_GLSL
#define CAVE_GLSL

uniform float inDeepDark;
uniform float inLushCave;
uniform float inDripstone;

// Depth below the upper cave levels: 0 around y 48 and above, 1 deep in the deepslate (y -40 and below).
float caveDepth(float y) { return smoothstep(48.0, -40.0, y); }

vec3 caveAirColor(float y) {
    // Near the surface the air is a dim stone grey; deep down it sinks toward a cold, near-black blue.
    float deep = caveDepth(y);
    vec3 c = mix(vec3(0.0013, 0.0016, 0.0021), vec3(0.00045, 0.00065, 0.0012), deep);
    c = mix(c, vec3(0.0008, 0.0024, 0.0017), inLushCave);
    c = mix(c, vec3(0.0024, 0.0017, 0.0011), inDripstone);
    c = mix(c, vec3(0.00008, 0.00022, 0.00030), inDeepDark);
    return c;
}

// Extinction of cave air per block: denser the deeper you go, so the deepslate levels feel heavy.
float caveFogDensity(float y) {
    return mix(0.010, 0.035, inDeepDark) * mix(1.0, 1.25, inLushCave) * mix(1.0, 1.3, inDripstone) * mix(1.0, CAVE_DEPTH_FOG, caveDepth(y) * (1.0 - 0.6 * inDeepDark));
}

// Sculk heartbeat: a slow double beat (lub-dub) that travels across the sculk fields in broad, bending waves, so
// the Deep Dark breathes around you. Near zero at rest, peaks near 1.1.
float sculkPulse(vec3 wp, float t) {
    float bend = valueNoise(wp.xz * 0.045) * 1.6;
    float phase = t / 2.3 - dot(wp.xz, vec2(0.031, 0.024)) - wp.y * 0.02 - bend;
    float f = fract(phase);
    float beat = exp(-f * 13.0) + 0.65 * exp(-abs(f - 0.17) * 17.0);
    return 0.06 + beat;
}

// Soul motes: sparse cyan specks drifting upward through Deep Dark air. A 3D grid of 2-block cells is walked
// along the view ray (exact cell traversal, so motes never pop as the view turns); each cell may hold one mote
// that rises, wobbles and twinkles. Returns radiance to add.
vec3 soulMotes(vec3 camPos, vec3 rd, float maxDist, float t) {
    const float CELL = 2.0;
    const int STEPS = 22;
    vec3 ro = camPos / CELL;
    vec3 rdc = rd;
    // Motes rise: shift the grid downward over time so each mote travels up.
    ro.y -= t * 0.12;
    vec3 cell = floor(ro);
    vec3 stepDir = sign(rdc);
    vec3 tDelta = abs(1.0 / max(abs(rdc), vec3(1e-4)));
    vec3 tMax = (stepDir * (cell - ro) + stepDir * 0.5 + 0.5) * tDelta;
    vec3 acc = vec3(0.0);
    float limit = min(maxDist, 36.0) / CELL;
    for (int i = 0; i < STEPS; i++) {
        float tCell = min(tMax.x, min(tMax.y, tMax.z));
        float h = hash12(cell.xz * 0.731 + cell.y * 1.917);
        if (h > 0.86) {
            float h2 = hash12(cell.zy * 1.37 + 4.1), h3 = hash12(cell.xy * 2.11 + 9.7);
            vec3 m = cell + vec3(h2, fract(h * 7.3), h3) * 0.8 + 0.1;
            m.xz += 0.12 * vec2(sin(t * 0.7 + h * 40.0), cos(t * 0.6 + h2 * 40.0));
            vec3 d = m - ro;
            float along = dot(d, rdc);
            if (along > 0.02 && along < limit) {
                float perp2 = max(dot(d, d) - along * along, 0.0);
                float r = 0.022;
                float twinkle = 0.55 + 0.45 * sin(t * (1.5 + h3 * 2.0) + h2 * 30.0);
                acc += vec3(0.25, 0.95, 1.0) * exp(-perp2 / (r * r)) * twinkle * smoothstep(limit, limit * 0.6, along);
            }
        }
        if (tCell > limit) break;
        if (tMax.x < tMax.y && tMax.x < tMax.z) { cell.x += stepDir.x; tMax.x += tDelta.x; }
        else if (tMax.y < tMax.z) { cell.y += stepDir.y; tMax.y += tDelta.y; }
        else { cell.z += stepDir.z; tMax.z += tDelta.z; }
    }
    return acc;
}

// Dust that catches block light: how much the air scatters (per block), and its tint.
float caveDustDensity() {
    return mix(0.010, mix(0.022, 0.015, inLushCave), max(inLushCave, inDripstone)) * mix(1.0, 0.3, inDeepDark);
}
#endif
