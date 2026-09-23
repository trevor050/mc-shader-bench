// Tunable settings. Values here are the pack defaults; option screens are intentionally omitted.

#define SHADOW_MAP_RES 3072       // [1024 2048 3072 4096]
#define SHADOW_DIST 192.0         // blocks
#define SHADOW_SOFTNESS 1.0
#define SHADOW_SAMPLES 12

#define WAVING_FOLIAGE
#define WAVE_STRENGTH 1.0

#define SUN_ILLUMINANCE 16.0
#define MOON_ILLUMINANCE 0.02
#define BLOCKLIGHT_COLOR vec3(1.0, 0.62, 0.32)
#define BLOCKLIGHT_STRENGTH 3.2
#define MIN_LIGHT 0.006

#define CLOUDS
#define CLOUD_HEIGHT 820.0
#define CLOUD_COVERAGE 0.34
#define CLOUD_DEBUG_WEATHER

// Distant Horizons render radius in blocks (lodChunkRenderDistanceRadius * 16). Keep in sync with the DH config.
#define LOD_DISTANCE 8192.0

#define VOLUMETRIC_LIGHT
#define VL_STEPS 20
#define FOG_DENSITY 1.0

#define WATER_SSR
#define SSR_STEPS 24

#define BLOOM_STRENGTH 0.1
#define GLARE_STRENGTH 0.08
#define SUN_RAYS_STRENGTH 0.006
#define SUN_STREAK_STRENGTH 0.0 // eye-style streaks; reference packs use none and they read as fake
#define EXPOSURE_KEY 0.42
#define EXPOSURE_MIN 0.02
#define EXPOSURE_MAX 20.0
//#define EXPOSURE_DEBUG
#define SATURATION 1.25

#define TAA
