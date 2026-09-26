# Profile performance verification

Performance remains unverified until a valid RTX 4070 console-session capture is collected. The first three launches on September 26 ran in disconnected Windows session 3, which exposed only the `WinDisc` virtual monitor and selected AMD integrated OpenGL. Their 4 FPS readings are rejected as evidence about ClaudeBench or the profile changes.

PresentMon ETW permission was separately verified with a two-second unique session targeting the benchmark shell's own PID: recording started/stopped and returned zero. The user belongs to enabled `Performance Log Users`, so same-account PID-based capture does not require an additional elevation. That shell produced no presents and no timing CSV; this permission probe makes no GPU performance claim. `tscon 3 /dest:console` did require elevation and returned error 5, Access is denied.

## Frozen artifacts

The unchanged original is `mc-shader-bench-claude-art/shaderpack` at commit `55a002eb145453b54136e7f3e97c9fbbc56851b3`, content SHA-256 `7fd1267342417e2b1fc0e9ecfec4a3a4d789ac4bea09afaed1baed3244239ea5`.

Candidate A is saved under `work/profile-bench/candidate-A/shaderpack`, content SHA-256 `8508466970919a1c306de72a534dcc3857cffedc28aae0e95a36331d61e8a2e0`. Source hashes before and after copying equal the snapshot hash. Its 260 files have read-only attributes. The adjacent `manifest.json` includes all per-file hashes, the five actual Iris profile definitions, and the original artistic options. The snapshot has not been activated.

`harness/profile_benchmark.py` controls fixed familiar camera locations and captures unique, timed PresentMon sessions. It checks the selected live Iris pack against the supplied artifact, requires the NVIDIA OpenGL renderer, saves the screenshot's real framebuffer dimensions, and rejects changes to source, profile settings, camera, or world time during a capture. Pack options are backed up before modification. Profile values are read from the frozen `shaders.properties` rather than reproduced manually.

## Matching conditions

Capture the original and shaders-off reference before evaluating candidates. Keep the same physical framebuffer resolution, render distance, simulation distance, DH state, HUD state, camera pose, world day/time, clear weather, and artistic controls. Record Java private/working-set memory, system RAM/commit availability, NVIDIA utilization, VRAM, temperature, power, and clock before and after each run. Record the actual enabled state separately: the selected pack name remains populated when shaders are off.

The saved starting options are 32 chunks, simulation distance 8, vsync off, a 260 FPS cap, view bobbing off, and DH rendering disabled with a 64-chunk configured radius. Confirm them again after returning to the console. The failed remote-session screenshot was 1920×1080; it must not be compared with a different physical-console resolution.

## Capture matrix

Use 18–20 seconds per capture, exclude the first two seconds, and settle for at least eight seconds after a shader reload. Settle a newly selected familiar scene longer, and confirm loaded chunks. No terrain, inventory, or structures are modified.

| Scene | Position | Yaw / pitch | Time | Purpose |
| --- | --- | --- | --- | --- |
| Night | -738.03, 110, -276.22 | 175 / -15 | 162000 | Visible aurora, stars, clouds, snowy terrain |
| Landscape | -778, 140, -283 | 0 / 10 | 150000 | Cloud-heavy landscape and shadows |
| Water | 1014, 72, -283 | 45 / 12 | 149000 | Water/reflection path in a familiar scene |
| Cave | 2615, -36, 615 | 180 / 0 | 150000 | Existing sealed emitter test cave |
| Above cloud | -778, 800, -283 | 0 / 10 | 150000 | Sky/cloud control without nearby terrain |

First collect `original / off / off / original` at night to quantify repeat noise, then the remaining scene matrix. Compare Rob's Vanilla Reshaded 1.0.5 and Sildur's Basic 2.7 Fast against shaders off in at least two matching views. Candidate profiles then use paired A/B and B/A ordering. Nether/End correctness and transition smoke tests follow the main Overworld matrix. Held-light tests must preserve the user's inventory.

## Provisional gates

These gates are proposed before measurement, not achieved performance claims:

- Stable brackets: repeat median GPU Busy drift at most 3%, median present-interval drift at most 5%. Larger drift requires another bracket or more settling.
- Real speed improvement: median GPU Busy gain at least the greater of 10% and twice the measured repeat noise. Present intervals must corroborate when GPU-bound; CPU-bound or capped views are labeled explicitly.
- Potato proximity to vanilla: target at most 1.0 ms added median GPU Busy, and at most 10% added median present interval, subject to the measured cap/CPU floor. Judge p95 and p99 as well as the median; a median-only win cannot conceal recurring stalls.
- Profile ordering: Ultra preserves source quality, and each lower profile should have a measurable reduction in representative GPU cost without new errors, severe visual defects, or worse tails. Adjust budgets using the measured bottlenecks rather than assuming loop-count changes improve whole-frame performance.

All speed reports include present, GPU Busy, and CPU Busy p50/p95/p99 and the artifact/options fingerprint. BenchCam's `framestats` measures render CPU work and is never treated as GPU or displayed FPS evidence.
