// Tunable settings. Values here are the pack defaults; option screens are intentionally omitted.

#define SHADOW_MAP_RES 3072       // [1024 2048 3072 4096]
#define SHADOW_DIST 192.0         // blocks
#define SHADOW_SOFTNESS 1.0
#define SHADOW_SAMPLES 12

#define WAVING_FOLIAGE
#define WAVE_STRENGTH 1.0

#define SUN_ILLUMINANCE 16.0
#define SUNSET_VIVIDNESS 1.25    // strength of the sunset sky palette (red band, gold, pinks, magenta)
#define SUN_LOW_RADIANCE 3000.0   // low sun's disc radiance once above the horizon (blinding)
#define SUN_DISC_RADIUS 0.0125    // angular radius (radians) of the low sun's visible disc
#define MOON_ILLUMINANCE 0.02
#define BLOCKLIGHT_COLOR vec3(1.0, 0.62, 0.32)
#define BLOCKLIGHT_STRENGTH 2.2
#define MIN_LIGHT 0.006
#define CU_EXPOSURE_SCALE 1.0 // Complementary-port lighting output scale (linear)
#define LAVA_EMISSION 22.0
#define BLOCK_EMISSION 17.0     // glowstone, lanterns, froglights, glow berries: bright enough to bloom     // lava emission strength (squared emissive channel times this)

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
#define EMITTER_SATURATION 2.2    // chroma expansion of emitter colours read from their sprites
#define BLOCKLIGHT_SATURATION 1.35 // extra chroma of the field's hue on lit surfaces
#define FIELD_BRIGHTNESS 3.5      // light-field luminance -> block light brightness floor
#define CAVE_WETNESS 1.0         // damp, glossy cave rock where no sky reaches
#define ORE_SPARKLE 0.07          // strength of ore glints under nearby block light
#define CAVE_SUNBEAM 1.0          // daylight beams through cave openings (dust lit by the sun)
#define SCULK_GLOW 0.07           // brightness of sculk's bioluminescent specks (times the heartbeat)
#define SOUL_MOTES 0.15           // soul motes drifting through Deep Dark air
#define CAVE_DEPTH_FOG 2.4         // how much denser cave air gets deep in the deepslate
#define CAVE_AIR_GLOW 0.4        // dust in cave air lit by block lights (coloured halos)

#define CLOUDS
#define CLOUD_HEIGHT 820.0
#define CLOUD_COVERAGE 0.34
#define CLOUD_SHADOW_FLOOR 0.33 // share of direct light that survives under the thickest cloud
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

#define WATER_TURBIDITY 0.18      // grey extinction per block of water (sediment); higher = murkier
#define WATER_SURFACE_VEIL 1.0   // blocks of extra path: in-scattering right under the surface
#define WATER_SSR
#define SSR_STEPS 24

#define BLOOM_STRENGTH 0.13
#define GLARE_STRENGTH 0.08
#define LOW_SUN_GLARE 0.25
#define SUN_VEIL 6.0              // analytic veiling glare around a visible sun (final.glsl), strongest when low       // extra wide glare for a low (sunrise/sunset) sun
#define SUN_RAYS_STRENGTH 0.006
#define SUN_STREAK_STRENGTH 0.0 // starburst streaks: Trevor rejected them twice as tacky; the low sun blinds through glare instead
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

// ---- Overworld V6: clouds, weather, night, water, bloom ----
#define CLOUD_RENDER_DISTANCE 6000.0 // [3000.0 4500.0 6000.0 8192.0 12000.0] cloud range in blocks, with a soft horizon fade
#define CLOUD_SPEED 1.8           // multiplier on cloud drift (and so on how fast cloud shadows sweep the land)
#define CLOUD_INSIDE_FOG 1.0      // wet grey-white mist when the camera is inside a cloud
#define CLOUD_MOON_SILVER 1.5     // moonlit clouds: boost of the bright forward-scattered rim toward the moon
#define RAIN_RIPPLES 1.0          // expanding raindrop rings on puddles and water
#define LIGHTNING_GROUND 1.0      // how strongly a lightning flash lights the landscape
#define STORM_DARKNESS 0.45       // how much a thunderstorm darkens the sky and the light under it
#define FIREFLIES 0.0             // fireflies over warm, humid land at night (0 disables)
#define AURORA 1.0                // rare northern aurora, all Overworld biomes (0 disables)
#define AURORA_BRIGHTNESS 0.09     // [0.0 0.03 0.06 0.09 0.12 0.18]
#define AURORA_MODE 3             // [1 2 3 4] snow / snow + full moon / random 10% / every night
#define CAUSTIC_STRENGTH 1.4      // caustics on shallow water floors
#define SHORE_FOAM 1.0            // foam where water laps at the shore
#define STORM_WAVES 1.5           // extra wave height in rain and thunder
#define EMITTER_BLOOM 0.35        // thresholded glow around lava, glowstone and other bright emitters
#define EMITTER_BLOOM_THRESHOLD 3.0 // relative to the average scene brightness
#define LAVA_HEAT 1.0             // close to a lava sea: rising embers and a burning red vignette
#define DUSK_EXPOSURE 1.15       // extra exposure around sunset and dusk (eye/phone adaptation to the fading light)
#define CLOUD_IRIDESCENCE 1.0     // pastel diffraction colours on thin altocumulus near the sun
#define CLOUD_DUSK_SKYLIGHT 1.3   // skylight on clouds around sunset (lavender fill in shade, pink away from the sun)
#define DUSK_VIBRANCE 2.2         // extra vibrance through the sunset window
#define CLOUD_DOME_ALBEDO 0.05     // share of the cloud-level sunlight a lit deck sends down as sky light
#define CLOUD_DOME_STRENGTH 1.0
#define SKY_PRESET 0              // [0 1 2 3] 0 = weather clock, 1 = storm shield (pre-nor'easter), 2 = mackerel, 3 = cirrus
