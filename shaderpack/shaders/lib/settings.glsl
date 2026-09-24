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

// Voxel light field (lib/voxel.glsl): coloured, directional block light diffused through a grid around the
// camera. Must match the image sizes in shaders.properties.
#define LIGHT_FIELD
#define VOXEL_EXTENT 128          // horizontal blocks (multiple of 8)
#define VOXEL_EXTENT_Y 64         // vertical blocks (multiple of 8)
#define LIGHT_FIELD_SOURCE 24.0   // radiance injected by a level-15 emitter
#define LIGHT_FIELD_KEEP 0.992    // per-step energy kept while diffusing; lower = shorter reach
//#define LIGHT_FIELD_SELFTEST   // with LIGHT_FIELD_DEBUG: constant green field and unfiltered voxel writes
//#define LIGHT_FIELD_DEBUG      // paint the raw field and voxel occupancy instead of shading
#define LIGHT_FIELD_GAIN 0.9      // field amplitude -> radiance for glints and smoke
#define LIGHT_FIELD_EXTRA_GAIN 2.2 // extra-light channel -> light level (lava seas, portals)

#define CLOUDS
#define CLOUD_HEIGHT 820.0
#define CLOUD_COVERAGE 0.34
//#define CLOUD_DEBUG_WEATHER
//#define MIST_DEBUG

// Distant Horizons render radius in blocks (lodChunkRenderDistanceRadius * 16). Keep in sync with the DH config.
#define LOD_DISTANCE 8192.0

// In the End, fade DH geometry into the void before the renderer's full-distance edge. The existing End
// aerial haze begins at 150 blocks and reaches full strength at 450, so this dissolve finishes just inside it.
#ifdef DIM_END
#define END_DH_FADE_START 220.0
#define END_DH_FADE_END 430.0
#endif

#define VOLUMETRIC_LIGHT
#define VL_STEPS 20
#define NETHER_SMOG_STEPS 12      // half-resolution march steps for Nether smoke
#define NETHER_SMOG_RANGE 160.0   // marched distance; beyond it the smog continues analytically
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
#define EXPOSURE_MAX_CAVE 5.0       // exposure ceiling underground and in the Nether/End
#define EXPOSURE_MIN_OTHERWORLD 1.4 // Nether/End: lava and lit smoke cannot darken the scene below this
#define EXPOSURE_MAX_OTHERWORLD 3.0 // Nether/End: dark biomes stay dark instead of opening up to grey
#define EXPOSURE_KEY_OTHERWORLD 0.55 // Nether/End key (log-average metering there)
//#define EXPOSURE_DEBUG
#define SATURATION 1.08
#define GRADE_CONTRAST 0.28
#define GRADE_VIBRANCE 0.3

#define TAA
