# mc-shader-bench (agent notes)

Iris shaderpack written from scratch as an AI benchmark + automated screenshot harness. MC 26.2 Fabric.

## Layout
- shaderpack/shaders/program/*.glsl : ALL real code. Root/world-1/world1 *.vsh/*.fsh are generated stubs: edit `shaderpack/tools/gen_stubs.py`, never the stubs.
- shaderpack/shaders/lib/ : settings, common (materials, encoding, dithers), atmosphere (sky, haze, stars), clouds (volumetric + cloud shadow + caustics), shadows, lighting, water, waving, jitter.
- Pipeline: gbuffers_solid -> G-buffer (c0 albedo, c1 normal+lm, c2 mat/emissive/ao) -> deferred (lighting+sky+clouds; writes c0 and copy c4) -> gbuffers_translucent (water/glass/hand forward, reads c4) -> composite (fog/VL/underwater) -> composite1 TAA (history c5, never cleared) -> final (bloom, glare, AgX).
- tools/gen_cloud_noise.py bakes textures/cloudnoise.dat (64^3 RGBA16, customTexture in shaders.properties). 8-bit banded visibly.
- Junctioned into instance: %APPDATA%\PrismLauncher\instances\ShaderBench\minecraft\shaderpacks\ClaudeBench
- harness/benchcam/ : Fabric client mod, TCP 127.0.0.1:25599 (ping/status/cmd/hud/closescreen/wait/waitchunks/shot/reload/shaders on|off/mouse grab|free/window x y). Forces inactivityFpsLimit=MINIMIZED (AFK limiter caps 30fps otherwise).
- harness/bench.py : `launch|reload|shots [--vanilla] [scene..]|sheet <dir>|raw "<cmd>"...`. Writes out/<ts>/ + sheet.jpg contact sheet (review the sheet, crop full-res only when needed).
- harness/merge_dh.py : merge a pregenerated DistantHorizons.sqlite into the client world (game closed).

## World
BenchWorld = Terralith + Tectonic (+Lithostitched), seed "claudebench". Frozen time/weather, no mobs, cheats on. Scenes in harness/scenes.json. Terralith cluster ~x2500-3200 z0-700; Emerald Peaks -778,-283.
DH pregen: dedicated Fabric server in %TEMP%\bench-fabric-server (same mods + DH), `py pregen.py <dir> "x z:radiusChunks"`, then merge_dh.py server->client db. Client `/dh` commands are not permitted in singleplayer.

## Versions (pinned)
MC 26.2, Fabric loader 0.19.5, Iris 1.11.4, Sodium 0.9.2, DH 3.3.2, fabric-api 0.161.0, Falling Leaves 2.0.7, Terralith 2.6.4, Tectonic 3.0.28, Java 25 Temurin. Loom 1.17-SNAPSHOT, unobfuscated Mojang names. Decompiled source via `gradlew genSources`.

## V3 systems
- lib/lava.glsl (procedural lava: MAT_LAVA from block 10007 and DH lava), MAT_PORTAL 8 (nether portal vortex, translucent), MAT_SNOW 9 (glitter, deferred), MAT_ENDPORTAL 10 (gbuffers_block via blockEntityId + PROG_BLOCK; parallax space in deferred).
- atmosphere: netherHaze, endSky (also end portal), twilightGlow. lighting: handheldLight, netherUplight. deferred: rainbow, lightning (cloudFlash), glossy dark stone. weather.glsl: grey rain lit by skyColor.
- Clouds: one volume y 175..1080; cloudColumn() picks base 185..430 per region/cloud, storm towers (w.cb) with anvils.
- Lightning must be applied after cloud temporal accumulation (in deferred) or history averages it away.
- Stars: raSun pinned (fract(day/3650+0.44)) so the Milky Way is up at midnight, not behind the full moon.

## V4 systems (claude/v4-art)
- Half-resolution transient targets are deliberately reused by pass lifetime: `colortex7` holds cloud radiance, then VL radiance, then bloom; `colortex8.r` holds cloud distance through `deferred2`, then VL/smog scene distance through `composite2`. Persistent histories `colortex9` and `colortex11` remain separate. Do not reintroduce removed `colortex10`/`colortex12` without a pass-order reason. See `docs/framebuffer-alias-colortex12-to-8.md` and the coordination notes for Iris runtime evidence.
- Overworld `cloudWeather()` is frame-uniform but expensive: `cloud_weather.glsl` defines it once; `vl_march.glsl` reuses it across ray samples and `deferred.glsl` passes seven flat weather scalars from vertex to deferred2 fragment. Keep the 3-argument `cloudShadow` API and 2-argument wrapper. Guarded pass-level Art/combined/Art timings and above-cloud control are in `docs/perf-overworld-weather-integration.md`; no whole-frame FPS gain is established.
- Light field: shadow pass voxelizes (lib/voxel.glsl; r32ui voxelImg 128x64x128, type|level|extra2|rgb8) -> shadowcomp.csh diffuses rgba16f lightFieldA/B (ping-pong by frameCounter parity; readers use B on even frames). rgb = colour ENERGY (sources stored c*c, read back with sqrt), a = extra-light energy (class 3 lava, 2 portal, 1 fire-like). Surfaces: brightness from vanilla lm.x (blockLightLevel, gentle curve), hue + direction + extra reach from the field (fieldBlockLight). Never let the field alone decide brightness (black pockets where it has not spread).
- Emitter colour: auto from sprite (l^8 * saturation weighted, 6x6 taps); lava/portal fixed colours.
- Nether/End have voxel-only shadow stubs (VOXEL_ONLY clips all vertices; map 256, dist 80). gen_stubs writes shadow/shadowcomp at #version 430. shadow.enabled=true required.
- Nether smog = vl_march (DIM_NETHER) netherSmog() -> vec2(sigma, sootFraction); glow gated by field alpha (real lava proximity). composite: heat haze (only non-lava pixels seen through y 31..38 layer), far analytic smog. Air is grey soot; orange only near lava.
- Exposure: Nether/End meter log2(min(lum,0.8)); clamp [EXPOSURE_MIN_OTHERWORLD, MAX]. final: agxHuePreserving (bright saturated colours keep hue; AgX per-channel turned lava salmon/pink).
- Lava: lib/lava.glsl. Sources (block 10007 = lava:level=0) get per-patch (Voronoi on texel grid) orientation/offset, static; flowing lava (10016 -> MAT_LAVA + lavaFlowing flag) keeps vanilla flow sprite. Trevor rejects anything non-vanilla-looking, drifting patches and painted hot spots.
- Reflections: lib/reflections.glsl traced in composite for c2.a smoothness > 0 (MAT_POLISHED 13, MAT_METAL 14, MAT_GLASSY 15 obsidian, MAT_ICE_SOLID). Smoothness written in gbuffers_solid.
- MAT_ICE 11 (translucent, gbuffers_translucent branch). Portal: lib/portal.glsl + portalFrameEdge (voxel).
- Offline gate: `py shaderpack/tools/check_compile.py [filter]` (glslang in ~/tools/glslang/bin). Compile-only.
- Coordination with Codex: docs/claude-to-codex.md. Reference notes: ../refpacks/notes-*.md (Complementary lighting, Bliss/Solas/Photon Nether, ice, perf). Licenses: ideas only for Complementary/Bliss/Solas; Photon portions OK off Modrinth/CurseForge.
- Lighting core = port of Complementary DoLighting (lighting.glsl shadeSurface: sqrt light mix in gamma space, ^2.2 at end); tonemap = Hejl 2015 + hue-preserving blend + Complementary dark lift (final.glsl).
- End: lib/end_atmosphere.glsl storm (vortex, eye wall, maelstrom; vl_march DIM_END) + island lit through storm (deferred) + camera effects only in final.glsl endStormCamera (roll/zoom, refraction, gust smear, dust fronts, dust streams, fringe). NO geometry/particles in front of the lens (Trevor rejected streaks, gust sheets, grit) and NO full-screen flares (End HDR ~0.02-0.05: +0.02 doubled the image = "pink frame").
- ClaudeBench Ambience mod (ambience/, Fabric, ./gradlew build -> mods/): End storm sound (synth ogg via ambience/tools/synth_sounds.py + AmbientSounds layers), gust events, trauma sway, shove. Talks to shader via End weather: rain = 0.2+0.8*intensity; thunder = (dir*32 + gust31 + flash)/256 (MC multiplies thunder by rain). Mod changes need a game restart; weather.glsl discards in the End.
- Motion testing: harness/rec.py <secs> <out.mp4> screen-records the game window (region hardcoded; window often on the 2nd monitor, focus it with Alt+SetForegroundWindow first) and saves .npy for brightness/flicker analysis.
- Capture helper: harness/cap_v4.py <dim> x y z yaw pitch time name [settle] (tp via execute in <dim>).

## Hazards
- Python `open(p,'w')` on Windows writes CRLF; use newline='' (string matches with 
 fail on CRLF files).
- ALWAYS confirm the active Iris pack is ClaudeBench before judging captures (Trevor switches packs; bench.py warns). A whole hour of V3 tests once ran on Bliss.
- Performance A/B results and capture caveats are in `docs/perf-v3.md`. BenchCam `chunks=true` does not mean Distant Horizons generation/loading has stopped.
- In Nether/End, `program.<dimension>/shadow.enabled=false` alone does not suppress Iris shadows. Omit dimension shadow stubs and compile out every active shadow sampler; keep Overworld shadow references.
- Iris resets frameTimeCounter on reload: captures at the same delay after a reload show identical clouds (not a bug).
- RDP session => no NVIDIA OpenGL. Game must run on the console session.
- MC grabs + ClipCursor()s the mouse; BenchCam mixin blocks it unless `mouse grab`. Stale clip after a kill: user32 ClipCursor(NULL).
- Iris fallback programs render pure fog on 26.2: every geometry type needs a program (see gen_stubs table).
- gbuffers_line must not touch gl_Vertex (link error with iris_Position); PROG_BASIC uses ftransform only.
- Iris auto-declares dhMaterialId in DH programs. dhRenderDistance is int (unclear units): use dhFarPlane.
- DH water depth-tests only vs LOD depth: dh_water must test depthtex1 itself. Vanilla terrain/water dither out at 0.84-0.94*far; DH starts at 0.78*far.
- Hand goes through the solid G-buffer as MAT_HAND (depth < 0.56); world-space effects skip it.
- Stars must be drawn in screen-space pixels (angular gaussians came out smeared). Don't march cloud empty space with bigger strides (causes horizontal banding).
- Water is in the shadow map with alpha 0 as a marker; shadows.glsl converts depth diff to blocks for absorption/caustics.
- Trevor's skin is a rainbow checker; a rainbow hand is not a bug.
- dhFarPlane is NOT the LOD extent (half of it ~1.6 km). Use LOD_DISTANCE (settings.glsl) = DH lodChunkRenderDistanceRadius*16; keep both in sync (currently 512 chunks / 8192).
- Horizon review: always inspect full-res crops, never contact sheets (downscaling hid bands and invented cloud rings). Debug by painting categories (sky mask, distance bands) with saturated HDR colors; grayscale debug gets scrambled by AgX.
- Sun: disc radiance soft-capped (~1800) so bloom doesn't flood when a sliver shows; no TAA hot-pixel bypass (caused flicker). Eye adaptation state lives in colortex5 alpha, fed by capped luminance in colortex6.
- Others commit to this repo too (commits under Trevor050). Check git log before editing sun/final code.
- Editing the same file via PowerShell and Edit tool causes stale-read failures; re-Read before Edit.
