# V3 performance measurements

These are local, scene-specific measurements on the ShaderBench instance (MC 26.2, 1920×1080, RTX 4070, render distance 32, Distant Horizons radius 512 chunks). PresentMon 2.4.1 captured `javaw.exe` presentations with the camera fixed. Each pack switch was followed by 200 game ticks before recording. Frame time is the median `MsBetweenPresents`; lower is better. A/B/A restores the original pack to check for drift.

| Experiment and scene | A | B | A again | Result |
| --- | ---: | ---: | ---: | --- |
| Nether dimension skips, lavafalls at `(0.5, 80, 0.5)`, yaw 180°, pitch 15° | 16.566 ms | 12.742 ms | 16.043 ms | 3.3–3.8 ms lower with dimension skips |
| Half-resolution bloom, Overworld vista at `(2486.5, 175, 5.5)`, yaw −135°, pitch 12°, time 6500 | 14.521 ms | 13.782 ms | 14.560 ms | About 0.75 ms lower with half-resolution bloom |
| Shaders off control, Nether portal/lava at `(0.5, 80, 0.5)`, yaw 0°, pitch 15° | 15.904 ms | 11.464 ms | 15.993 ms | About 4.5 ms of shader-pack cost in this view |

The dimension-skip branch omits Nether/End shadow programs and shadow references, skips their identity cloud and volumetric marches, and writes invalid temporal histories. Its Nether screenshot showed no obvious change beyond animation. The End compiled and rendered after the merge. The bloom branch moves the full-resolution 81-sample bloom/glare work to an existing half-resolution buffer. Matched sun screenshots were visually indistinguishable at normal size; the image-wide mean absolute channel difference was 0.45/255 and the 99th percentile difference was 5/255. Dynamic effects and reload timing can also contribute to those pixel differences.

The Nether initially showed 19 fps immediately after teleport, then recovered. A 40-second Java Flight Recorder profile in the same area found 8 Distant Horizons World Gen threads and 8 Render Loader threads heavily active even after BenchCam reported `chunks=true`. The render thread had 320 execution samples while each of those workers had roughly 900–1,080; those are statistical samples, not frame-time percentages. Distant Horizons generation was left enabled. This background work and its changing queue limit how far one scene's FPS can be generalized.

Do not treat BenchCam's instantaneous HUD FPS or captures immediately after a shader reload as stable benchmarks. Confirm `Using shaderpack: ClaudeBench` in `latest.log`, keep pose and options fixed, wait for chunks and temporal history, and alternate A/B/A when possible. Iris resets `frameTimeCounter` on reload, so animated clouds and lava should be compared at similar delays after each reload.
