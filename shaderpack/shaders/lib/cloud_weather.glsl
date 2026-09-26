// Cloud weather is derived only from frame-uniform time and weather inputs. Keep this separate from the
// volumetric cloud routines so passes can evaluate it in a cheaper stage when the result is shared.
#ifndef CLOUD_WEATHER_GLSL
#define CLOUD_WEATHER_GLSL

uniform int worldDay;
uniform int worldTime;
#ifndef THUNDER_UNIFORM
#define THUNDER_UNIFORM
uniform float thunderStrength;
#endif

float noise1(float x) {
    float i = floor(x), f = fract(x);
    float a = fract(sin(i * 127.1) * 43758.5453), b = fract(sin((i + 1.0) * 127.1) * 43758.5453);
    return mix(a, b, f * f * (3.0 - 2.0 * f));
}

struct CloudWeather {
    float cov0;    // cumulus coverage
    float tower;   // how tall cumulus grow
    float cov1;    // altocumulus coverage
    float cirrus;  // cirrus amount
    float low;     // share of the map under the low deck
    float lowCov;  // extra coverage in low-deck regions
    float cb;      // thunderstorm tower strength
};

CloudWeather cloudWeather() {
    // Weather clock in days; octaves drift at different rates so the sky never repeats on a fixed cycle.
    float t = float(worldDay) + float(worldTime) / 24000.0;
    CloudWeather w;
    float a = noise1(t * 0.9) * 0.65 + noise1(t * 2.3 + 5.0) * 0.35;
    float b = noise1(t * 0.7 + 17.0);
    float c = noise1(t * 1.1 + 41.0);
    w.cov0 = mix(0.31, 0.58, a) * CLOUD_COVERAGE / 0.34;
    w.tower = mix(0.35, 1.0, noise1(t * 1.3 + 71.0));
    // Altocumulus ranges from absent to a mackerel sky that fills the whole dome.
    // Most days have little or none; a deck over half the sky is an occasional event, a full one rare.
    w.cov1 = mix(0.0, 0.62, smoothstep(0.35, 0.95, b));
    // Cirrus is fibrous (curving strokes and tufts), so it can reach near full strength without reading as a flat sheet.
    w.cirrus = mix(0.0, 0.8, smoothstep(0.3, 0.9, c));
    // Regimes: some days bring a low grey deck over the valleys, some build afternoon thunderstorms.
    w.low = mix(0.05, 0.75, smoothstep(0.3, 0.8, noise1(t * 0.8 + 131.0)));
    w.lowCov = mix(0.0, 0.25, noise1(t * 1.2 + 157.0));
    float afternoon = smoothstep(0.1, 0.35, float(worldTime) / 24000.0) * (1.0 - smoothstep(0.45, 0.55, float(worldTime) / 24000.0));
    w.cb = smoothstep(0.45, 0.85, noise1(t * 0.6 + 97.0)) * mix(0.55, 1.0, afternoon);
    // Rain: thick, low, flat-bottomed overcast.
    w.cov0 = mix(w.cov0, 0.9, rainStrength);
    w.tower = mix(w.tower, 0.8, rainStrength);
    w.cov1 = mix(w.cov1, 0.85, rainStrength);
    w.cirrus *= 1.0 - rainStrength;
    w.low = mix(w.low, 0.9, rainStrength);
    w.cb = max(w.cb, thunderStrength);
#if SKY_PRESET == 1
    // Storm shield (the 2026-09-25 pre-nor'easter sky): altocumulus under a high veil, ragged fractus below, a little
    // cirrus, no fair-weather cumulus; the deck ends west of the observer (clouds.glsl).
    w.cov0 = 0.06; w.tower = 0.3; w.cov1 = 0.48; w.cirrus = 0.25; w.low = 0.2; w.lowCov = 0.0; w.cb = 0.0;
#elif SKY_PRESET == 2
    // Mackerel sky: a full altocumulus deck.
    w.cov0 = 0.05; w.tower = 0.3; w.cov1 = 0.6; w.cirrus = 0.1; w.low = 0.2; w.lowCov = 0.0; w.cb = 0.0;
#elif SKY_PRESET == 3
    // Cirrus: fans and mares' tails over a few small cumulus.
    w.cov0 = 0.15; w.tower = 0.4; w.cov1 = 0.0; w.cirrus = 0.95; w.low = 0.2; w.lowCov = 0.0; w.cb = 0.0;
#endif
#ifdef CLOUD_DEBUG_ALTO
    w.cov1 = 0.8; w.cirrus = 0.35; w.cov0 = 0.1;
#endif
#ifdef CLOUD_DEBUG_CIRRUS
    w.cirrus = 0.9; w.cov1 = 0.0; w.cov0 = 0.2;
#endif
#ifdef CLOUD_DEBUG_WEATHER
    w.cov0 = 0.0; w.tower = 0.8; w.cov1 = 0.0; w.cirrus = 0.0; w.low = 0.45; w.lowCov = 0.0; w.cb = 0.0;
#endif
    return w;
}

#endif
