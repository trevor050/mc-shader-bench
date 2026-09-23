# mc-shader-bench (agent notes)

Iris shaderpack benchmark + automated screenshot harness. MC 26.2 Fabric.

## Layout
- shaderpack/ : the pack. Junctioned into instance: %APPDATA%\PrismLauncher\instances\ShaderBench\minecraft\shaderpacks\ClaudeBench
- harness/benchcam/ : Fabric client mod, TCP 127.0.0.1:25599 line protocol (ping/status/cmd/hud/closescreen/wait/waitchunks/shot/reload/shaders on|off/mouse grab|free/window x y). Reply always "ok..." or "err...".
- harness/bench.py : client. `py -3.12 bench.py launch|reload|shots [scene..]|raw "<cmd>"...`. Scenes in harness/scenes.json. Output harness/out/<ts>/.
- harness/world-template/ : pristine BenchWorld (gitignored). Seed "claudebench", spawn ~(-100,77,-650) = iceberg field. Time/weather frozen, no mobs, random ticks 0, cheats on.

## Versions (pinned)
MC 26.2, Fabric loader 0.19.5, Iris 1.11.4+mc26.2, Sodium 0.9.2+mc26.2, DH 3.3.2-26.2, fabric-api 0.161.0+26.2. Java 25 (Temurin, C:\Program Files\Eclipse Adoptium\jdk-25.0.4.101-hotspot). Loom 1.17-SNAPSHOT, unobfuscated (Mojang names). Build: JAVA_HOME=jdk25, `gradlew build` in harness/benchcam, copy jar to instance mods.
Decompiled MC source: `gradlew genSources`, jar under .gradle/loom-cache/minecraftMaven/.../*-sources.jar.

## Hazards
- RDP session => no NVIDIA OpenGL ("Driver does not support OpenGL"). Game must run on console session.
- MC grabs + ClipCursor()s the OS mouse in-game. BenchCam mixin blocks grabMouse unless `mouse grab`. Stale clip after crash: user32 ClipCursor(NULL).
- Window parked on left monitor (DISPLAY2 at x=-2560, 2048x1152). Main monitor 3440x1440 has the Claude app.
- Iris fallback (no gbuffers program) on 26.2 renders pure fog. Every geometry type needs its own gbuffers program.
- 26.2 API renames: screens on mc.gui (screen()/setScreen), Hud is mc.gui.hud, Window.handle(), Level.getOverworldClockTime().
- Gamerules are snake_case (advance_time, random_tick_speed...).
- Creative player falls after /tp; harness uses spectator.
- Vanilla 26.x has a Vulkan backend; options.txt preferredGraphicsBackend:"opengl" must stay (Iris is GL-only).
- Prism accounts: use Trevor050 (pinned per-instance). Other MSA entries don't own the game.
