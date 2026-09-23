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

## Hazards
- RDP session => no NVIDIA OpenGL. Game must run on the console session.
- MC grabs + ClipCursor()s the mouse; BenchCam mixin blocks it unless `mouse grab`. Stale clip after a kill: user32 ClipCursor(NULL).
- Iris fallback programs render pure fog on 26.2: every geometry type needs a program (see gen_stubs table).
- gbuffers_line must not touch gl_Vertex (link error with iris_Position); PROG_BASIC uses ftransform only.
- Iris auto-declares dhMaterialId in DH programs. dhRenderDistance is int (unclear units): use dhFarPlane.
- DH water depth-tests only vs LOD depth: dh_water must test depthtex1 itself. Vanilla terrain/water dither out at 0.84-0.94*far; DH starts at 0.78*far.
- Hand renders after deferred: it is forward shaded (PROG_HAND in translucent).
- Water is in the shadow map with alpha 0 as a marker; shadows.glsl converts depth diff to blocks for absorption/caustics.
- Trevor's skin is a rainbow checker; a rainbow hand is not a bug.
- dhFarPlane is NOT the LOD extent (half of it ~1.6 km). Use LOD_DISTANCE (settings.glsl) = DH lodChunkRenderDistanceRadius*16; keep both in sync (currently 512 chunks / 8192).
- Horizon review: always inspect full-res crops, never contact sheets (downscaling hid bands and invented cloud rings). Debug by painting categories (sky mask, distance bands) with saturated HDR colors; grayscale debug gets scrambled by AgX.
- Sun: disc is physically bright; final.glsl solarGlare (committed by Trevor/another agent in b97f3c3) adds halo + star. Eye adaptation state lives in colortex5 alpha, fed by capped luminance in colortex6 from composite.
- Others commit to this repo too (commits under Trevor050). Check git log before editing sun/final code.
- Editing the same file via PowerShell and Edit tool causes stale-read failures; re-Read before Edit.
