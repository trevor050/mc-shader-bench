// Tunable defaults. Selected user-facing controls are exposed in shaders.properties.

// Iris named profiles select this kernel tier; artistic settings stay independent.
#define PERFORMANCE_PROFILE 4    // [0 1 2 3 4] Potato / Low / Medium / High / Ultra

#define SHADOW_MAP_RES 3072 // [1024 2048 3072 4096]
#define SHADOW_DIST 192.0 // [80.0 96.0 128.0 160.0 192.0 256.0] blocks
#define SHADOW_SOFTNESS 1.0 // [0.0 0.5 0.75 1.0 1.25 1.5 2.0]
#define SHADOW_SAMPLES 12 // [0 2 4 6 8 12]

#define WAVING_FOLIAGE
#define WAVE_STRENGTH 1.0 // [0.0 0.5 0.75 1.0 1.5 2.0]

#define SUN_ILLUMINANCE 16.0 // [8.0 12.0 16.0 20.0 24.0]
#define SUNSET_VIVIDNESS 1.25 // [0.0 0.5 0.75 1.0 1.25 1.5 2.0] peak sunset palette; rose/violet afterglow is a rare weather event
#define SKY_CLIMATE 1.0 // [0.0 0.5 1.0] biome influence on cloud balance and atmospheric haze
#define SKY_VARIATION 1.0 // [0.0 0.5 1.0] rare vivid sunset enhancement (ordinary dusk remains warm)
#define SUN_LOW_RADIANCE 3000.0   // low sun's disc radiance once above the horizon (blinding)
#define SUN_DISC_RADIUS 0.0125    // angular radius (radians) of the low sun's visible disc
#define MOON_ILLUMINANCE 0.02 // [0.0 0.01 0.02 0.03 0.04 0.06]
#define BLOCKLIGHT_COLOR vec3(1.0, 0.62, 0.32)
#define BLOCKLIGHT_STRENGTH 2.2 // [1.0 1.5 2.0 2.2 2.5 3.0]
#define MIN_LIGHT 0.006
#define CU_EXPOSURE_SCALE 1.0 // Complementary-port lighting output scale (linear)
#define LAVA_EMISSION 22.0 // [8.0 14.0 22.0 30.0 40.0]
#define BLOCK_EMISSION 17.0 // [5.0 10.0 17.0 24.0 32.0] glowstone, lanterns, froglights, glow berries: bright enough to bloom     // lava emission strength (squared emissive channel times this)

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
#define EMITTER_SATURATION 2.2 // [0.5 1.0 1.5 2.2 2.8 3.5] chroma expansion of emitter colours read from their sprites
#define BLOCKLIGHT_SATURATION 1.35 // [0.0 0.5 1.0 1.35 1.7 2.0] extra chroma of the field's hue on lit surfaces
#define FIELD_BRIGHTNESS 3.5 // [0.0 1.0 2.0 3.5 5.0 7.0] light-field luminance -> block light brightness floor
#define CAVE_WETNESS 1.0 // [0.0 0.5 1.0 1.5] damp, glossy cave rock where no sky reaches
#define ORE_SPARKLE 0.07 // [0.0 0.03 0.07 0.12 0.18] strength of ore glints under nearby block light
#define CAVE_SUNBEAM 1.0 // [0.0 0.5 1.0 1.5 2.0] daylight beams through cave openings (dust lit by the sun)
#define SCULK_GLOW 0.07 // [0.0 0.03 0.07 0.12 0.18] brightness of sculk's bioluminescent specks (times the heartbeat)
#define SOUL_MOTES 0.15 // [0.0 0.05 0.15 0.25 0.4] soul motes drifting through Deep Dark air
#define CAVE_DEPTH_FOG 2.4 // [0.0 1.0 1.6 2.4 3.2] how much denser cave air gets deep in the deepslate
#define CAVE_AIR_GLOW 0.4 // [0.0 0.2 0.4 0.6 0.8] dust in cave air lit by block lights (coloured halos)

#define CLOUDS
#define CLOUD_HEIGHT 820.0
#define CLOUD_COVERAGE 0.34 // [0.17 0.25 0.34 0.42 0.5]
#define CLOUD_SHADOW_FLOOR 0.33 // [0.1 0.2 0.33 0.5 0.7 1.0] share of direct light that survives under the thickest cloud
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
#define VL_STEPS 20 // [0 6 10 14 20 28]
#define NETHER_SMOG_STEPS 12 // [0 4 6 9 12 16 20] half-resolution march steps for Nether smoke
#define NETHER_SMOG_RANGE 160.0   // marched distance; beyond it the smog continues analytically
#define FOG_DENSITY 1.0 // [0.0 0.5 0.75 1.0 1.25 1.5 2.0]

#define WATER_TURBIDITY 0.18 // [0.06 0.1 0.14 0.18 0.24 0.32] grey extinction per block of water (sediment); higher = murkier
#define WATER_SURFACE_VEIL 1.0 // [0.0 0.5 1.0 1.5 2.0] blocks of extra path: in-scattering right under the surface
#define WATER_SSR
#define SSR_STEPS 24 // [0 8 12 18 24 32]

#define BLOOM_STRENGTH 0.13 // [0.0 0.05 0.09 0.13 0.18 0.25]
#define GLARE_STRENGTH 0.08 // [0.0 0.03 0.05 0.08 0.12 0.18]
#define LOW_SUN_GLARE 0.25 // [0.0 0.1 0.25 0.4 0.6]
#define SUN_VEIL 6.0 // [0.0 1.5 3.0 6.0 9.0] analytic veiling glare around a visible sun (final.glsl), strongest when low       // extra wide glare for a low (sunrise/sunset) sun
#define SUN_RAYS_STRENGTH 0.006 // [0.0 0.003 0.006 0.009 0.012]
#define SUN_STREAK_STRENGTH 0.0 // starburst streaks: Trevor rejected them twice as tacky; the low sun blinds through glare instead
#define EXPOSURE_KEY 0.42 // [0.21 0.3 0.42 0.55 0.7]
#define EXPOSURE_MIN 0.02
#define EXPOSURE_MAX 20.0
#define EXPOSURE_MAX_CAVE 5.0 // [2.0 3.0 5.0 7.0 10.0] exposure ceiling underground and in the Nether/End
#define EXPOSURE_MIN_OTHERWORLD 1.4 // Nether/End: lava and lit smoke cannot darken the scene below this
#define EXPOSURE_MAX_OTHERWORLD 3.0 // Nether/End: dark biomes stay dark instead of opening up to grey
#define EXPOSURE_KEY_OTHERWORLD 0.55 // [0.35 0.45 0.55 0.7 0.9] Nether/End key (log-average metering there)
//#define EXPOSURE_DEBUG
#define SATURATION 1.08 // [0.0 0.5 0.75 1.0 1.08 1.2 1.4]
#define GRADE_CONTRAST 0.28 // [0.0 0.1 0.2 0.28 0.4 0.5]
#define GRADE_VIBRANCE 0.3 // [0.0 0.15 0.3 0.45 0.6]

#define TAA

// ---- Overworld V6: clouds, weather, night, water, bloom ----
#define CLOUD_RENDER_DISTANCE 6000.0 // [3000.0 4500.0 6000.0 8192.0 12000.0] cloud range in blocks, with a soft horizon fade
#define CLOUD_SPEED 1.8 // [0.0 0.5 1.0 1.8 2.5 3.5] multiplier on cloud drift (and so on how fast cloud shadows sweep the land)
#define CLOUD_INSIDE_FOG 1.0 // [0.0 0.5 1.0 1.5 2.0] wet grey-white mist when the camera is inside a cloud
#define CLOUD_MOON_SILVER 1.5 // [0.0 0.5 1.0 1.5 2.0] moonlit clouds: boost of the bright forward-scattered rim toward the moon
#define RAIN_RIPPLES 1.0 // [0.0 0.5 1.0 1.5] expanding raindrop rings on puddles and water
#define LIGHTNING_GROUND 1.0 // [0.0 0.25 0.5 0.75 1.0] how strongly a lightning flash lights the landscape
#define STORM_DARKNESS 0.45 // [0.0 0.2 0.3 0.45 0.6 0.8] how much a thunderstorm darkens the sky and the light under it
#define FIREFLIES 0.0 // [0.0 0.5 1.0 1.5] fireflies over warm, humid land at night (0 disables)
#define AURORA 1.0 // [0.0 1.0] rare northern aurora, all Overworld biomes (0 disables)
#define AURORA_BRIGHTNESS 0.09 // [0.0 0.03 0.06 0.09 0.12 0.18]
#define AURORA_MODE 3 // [1 2 3 4] snow / snow + full moon / random 10% / every night
#define CAUSTIC_STRENGTH 1.4 // [0.0 0.5 1.0 1.4 2.0] caustics on shallow water floors
#define SHORE_FOAM 1.0 // [0.0 0.5 1.0 1.5] foam where water laps at the shore
#define STORM_WAVES 1.5 // [0.0 0.5 1.0 1.5 2.0 3.0] extra wave height in rain and thunder
#define EMITTER_BLOOM 0.35 // [0.0 0.15 0.25 0.35 0.5 0.7] thresholded glow around lava, glowstone and other bright emitters
#define EMITTER_BLOOM_THRESHOLD 3.0 // [1.5 2.0 3.0 4.0 6.0] relative to the average scene brightness
#define LAVA_HEAT 1.0 // [0.0 0.5 1.0 1.5] close to a lava sea: rising embers and a burning red vignette
#define DUSK_EXPOSURE 1.15 // [0.75 1.0 1.15 1.3 1.5] extra exposure around sunset and dusk (eye/phone adaptation to the fading light)
#define CLOUD_IRIDESCENCE 1.0 // [0.0 0.5 1.0 1.5] pastel diffraction colours on thin altocumulus near the sun
#define CLOUD_DUSK_SKYLIGHT 1.3 // [0.0 0.5 1.0 1.3 1.7 2.0] skylight on clouds around sunset (lavender fill in shade, pink away from the sun)
#define DUSK_VIBRANCE 2.2 // [0.0 0.5 1.0 1.5 2.2 3.0] extra vibrance through the sunset window
#define CLOUD_DOME_ALBEDO 0.05     // share of the cloud-level sunlight a lit deck sends down as sky light
#define CLOUD_DOME_STRENGTH 1.0
#define SKY_PRESET 0 // [0 1 2 3] 0 = weather clock, 1 = storm shield (pre-nor'easter), 2 = mackerel, 3 = cirrus

#include "/lib/performance_quality.glsl"
