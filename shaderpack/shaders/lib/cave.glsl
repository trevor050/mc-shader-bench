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

vec3 caveAirColor() {
    vec3 c = vec3(0.0011, 0.0016, 0.0025);
    c = mix(c, vec3(0.0008, 0.0024, 0.0017), inLushCave);
    c = mix(c, vec3(0.0024, 0.0017, 0.0011), inDripstone);
    c = mix(c, vec3(0.00008, 0.00022, 0.00030), inDeepDark);
    return c;
}

// Extinction of cave air per block.
float caveFogDensity() {
    return mix(0.012, 0.035, inDeepDark) * mix(1.0, 1.6, inLushCave) * mix(1.0, 1.3, inDripstone);
}

// Dust that catches block light: how much the air scatters (per block), and its tint.
float caveDustDensity() {
    return mix(0.010, 0.022, max(inLushCave, inDripstone)) * mix(1.0, 0.55, inDeepDark);
}
#endif
