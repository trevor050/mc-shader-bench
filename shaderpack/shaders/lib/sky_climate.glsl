// Frame-uniform climate supplied by Iris custom uniforms (shaders.properties).
// These accessors contain no noise, texture reads, or time calculations: every
// atmosphere, reflection, shadow and cloud pass receives the same atmosphere.
#ifndef SKY_CLIMATE_GLSL
#define SKY_CLIMATE_GLSL

uniform vec4 skyClimate;       // cold, arid, humid, maritime; independently smoothed
uniform float skyAerosol;      // modest change to physical Mie scattering/extinction
uniform float skyConvection;   // smooth morning -> afternoon -> evening convection
uniform float skyVividEvent;   // rare, continuous clear-weather sunset enhancement

vec4 skyClimateWeights() {
#if defined DIM_NETHER || defined DIM_END
    return vec4(0.0);
#else
    return clamp(skyClimate, 0.0, 1.0) * SKY_CLIMATE;
#endif
}

float skyAerosolScale() {
#if defined DIM_NETHER || defined DIM_END
    return 1.0;
#else
    return mix(1.0, clamp(skyAerosol, 0.7, 1.65), SKY_CLIMATE);
#endif
}

float skySunsetEvent() {
#if defined DIM_NETHER || defined DIM_END
    // Preserve the legacy shared tint/grade in other dimensions; this climate pass is Overworld-only.
    return 1.0;
#else
    // Cap the artistic enhancement: the legacy full palette flattened thick decks into
    // orange ceilings and strongly saturated their shaded undersides.
    return clamp(skyVividEvent * SKY_VARIATION, 0.0, 1.0) * 0.55;
#endif
}

#endif
