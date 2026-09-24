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

## PresentMon capture and matched analysis

`harness/bench.py raw "framestats [n]"` measures client render-thread CPU frame time. It is not GPU time or display cadence. PresentMon captures per-frame ETW observations for the Java process. The historical table above reports the median `MsBetweenPresents`, which is frame cadence; it does not isolate shader GPU cost. PresentMon 2.4.1 also records `MsGPUBusy` and `MsCPUBusy` in the local captures. Use GPU Busy as the primary shader-cost signal, then read Present Interval and CPU Busy as context. Keep each metric labeled; do not describe present interval as GPU time.

The local Windows installation was PresentMon 2.4.1 at `%LOCALAPPDATA%\Microsoft\WinGet\Links\presentmon.exe`. Its 2.x CSV includes `MsGPUBusy`, `MsCPUBusy`, `MsBetweenPresents`, `CPUStartTimeInMs`, `Application`, `ProcessID`, and `SwapChainAddress`. The corresponding upstream option/column reference is [PresentMon 2.4.1 console documentation](https://github.com/GameTechDev/PresentMon/blob/v2.4.1/README-ConsoleApplication.md).

### Capture one run

Use one deliberate capture per A/B/A step. Do not automate pack reload loops: shader reloads can block Iris's render thread, and a previous parallel reload coincided with a prolonged input lock. Keep Minecraft on the console session, select the intended pack and fixed scene, wait at least 200 game ticks after each pack change, confirm the pack in `latest.log`, and let the same DH scene settle before each capture. PresentMon only observes the process; it does not control Minecraft or verify its active pack, pose, resolution, or background DH work.

From PowerShell, identify Minecraft's `javaw.exe` PID, then start a timed capture while the game is already at the stable scene:

```powershell
Get-Process javaw | Select-Object Id, StartTime, Path
$gameProcessId = 12345 # replace with the Minecraft process ID shown above
$presentMon = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\presentmon.exe"
$captureDir = "harness\out\perf-YYYYMMDD"
New-Item -ItemType Directory -Force -Path $captureDir | Out-Null
& $presentMon --process_id $gameProcessId --output_file "$captureDir\A1.csv" --timed 60 --terminate_after_timed --v2_metrics --no_console_stats
```

Repeat as `B1.csv`, then restore A and record `A2.csv`. Keep the same window resolution, scene pose/time/weather, game and driver, render distance, DH radius, shader options unrelated to the experiment, VSync, and frame limit. Capture at least one minute after the 200-tick settle; repeat the B capture too for a stronger conclusion. Avoid running other GPU-heavy work during captures. Keep an eye on DH generation/loading: `chunks=true` does not prove its worker queues have gone idle.

### Analyze a bracketed comparison

Copy `harness/perf-runs.example.json` to a manifest beside the CSVs, set each run's CSV path and metadata, and use an exact `scene` object (scene id plus coordinates, yaw, pitch, time, and weather) for all captures. Record the active pack name and source revision/settings fingerprint per variant. The analyzer requires A/B/A order, identical scene/pose, resolution, and environment metadata, and consistent pack identity within each variant. It also refuses ambiguous Java processes or swap chains, rejects a CSV resolution mismatch when width/height columns are present, and removes the configured warm-up interval using the CSV timestamp column. Scene, pack, pose, and resolution are not present in standard PresentMon rows; those manifest values are operator attestations, so retain the log/config evidence with the captures.

The analyzer is offline and uses only the Python standard library:

```powershell
py harness\perf_analysis.py harness\out\perf-YYYYMMDD\perf-runs.json --metric gpu-busy --json-out harness\out\perf-YYYYMMDD\gpu-busy.json
py harness\perf_analysis.py harness\out\perf-YYYYMMDD\perf-runs.json --metric cpu-busy --json-out harness\out\perf-YYYYMMDD\cpu-busy.json
py harness\perf_analysis.py harness\out\perf-YYYYMMDD\perf-runs.json --metric present-interval --json-out harness\out\perf-YYYYMMDD\present-interval.json
```

Per capture it reports sample count, median, nearest-rank p95/p99, mean, and sample variance in ms² after warm-up. Variant summaries are the median of each capture's summary, so longer CSVs do not silently dominate by contributing more frames. It reports A1-to-A2 baseline median drift and each candidate's percentage change from the baseline. The example manifest uses a 2-second warm-up; each capture must have at least 1,000 usable samples by default. Change these only deliberately. A result with high baseline drift or active DH queue changes is inconclusive and should be recaptured. `--metric gpu-time` selects PresentMon's `MsGPUTime` span; the default `gpu-busy` is the active GPU work duration. For timing metrics, a negative candidate percentage means a lower value than the baseline.

Run the offline regression checks with:

```powershell
py -m unittest discover -s harness -p test_perf_analysis.py
```
