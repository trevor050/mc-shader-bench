# Dynamic route capture adapter

`dynamic_capture.py` runs a project-specific moving-camera and changing-light capture against BenchCam's asynchronous route protocol. Routes are selected by unique `id` from `dynamic_routes.json`. Before using a route, verify its landmarks are pregenerated in the active world; unknown chunks may generate normally during traversal. The route mod changes player camera and visual weather/time state, and never places or removes blocks. These route timings are project measurements, not a standard benchmark claim.

The adapter canonicalizes the exact selected route JSON using UTF-8, sorted object keys, and compact separators, then SHA-256 hashes those bytes and sends their unpadded base64url form in `route load`. The returned route id/hash must match. Each start carries a fresh UUID `request_id`; the start receipt and all subsequent status polls must echo it. Recovery issues `route cancel request_id=<uuid>`, which is scoped to this run, and leaves any run with another request id untouched. It requires `gpuprof status` to report a healthy, fully drained idle/closed profiler immediately before route start and after restoration, and records both exact replies. It starts PresentMon before route start, starts the asynchronous route, and polls only `route status` and `route clock` while Java owns all motion and timing. Python does not teleport, sleep the camera through a path, or stretch the timeline to accommodate slow frames.

PresentMon 2.4.1 is started with `--qpc_time`. Its help defines this as CPU start time in performance-counter units. The adapter pairs Windows QPC readings around BenchCam `route clock` replies, rejects excessive RTT or a poor affine fit to Java `System.nanoTime()`, and trims on the route's scheduled `measured_start_ns` inclusive and `measured_end_ns` exclusive boundaries. The reported fit, frequency, and clock pairs are retained in capture metadata. It never guesses timestamp units from `CPUStartTime` values.

The original PresentMon CSV is preserved, including all target PID rows. Measured metrics retain slow frames and report percentiles, maxima, present-start gaps, `DisplayedTime=NA` counts, and present mode/runtime counts separately. A measured control desync is recorded while the route continues to its scheduled end, preserving the remaining frame tail, then the capture is rejected with its complete raw CSV. World/context loss can stop the route immediately. A nonzero PresentMon exit, ETW lost-event warning, missing or malformed target data, route hash mismatch, measured control desynchronization, lost world, failed restoration, changed pack/options, renderer/session change, or framebuffer mismatch invalidates the capture and writes a `.rejected.json` receipt without deleting the CSV.

Route validation mirrors the Java protocol bounds: route ids match `[a-z0-9_-]{1,64}`, duration is 5..180 seconds, there are 5..65 closed path points and 2..64 environment keys, pitch stays within -90..90 degrees, adjacent unwrapped yaw changes are at most 180 degrees, and world time is 0..2,000,000,000 ticks. The global camera/server maximum is retained as a diagnostic because it includes initial traversal and warmup; only `camera_server_measured_max_distance` or the measured desync reason invalidates the measured interval. Optional Iris timer values are copied into the receipt as observed. Freezing world time does not imply that shader animation timers stop.

Example invocation (use the actual active console PID and explicit framebuffer dimensions):

```powershell
py harness/dynamic_capture.py `
  --routes harness/dynamic_routes.json --route landscape_cycle `
  --presentmon "$env:LOCALAPPDATA\Microsoft\WinGet\Links\presentmon.exe" `
  --pid 1234 --output harness/out/dynamic/landscape-cycle-A.csv `
  --capture-id landscape-cycle-01 --variant A `
  --pack ClaudeBench --pack-artifact shaderpack `
  --width 2560 --height 1351 --warmup 1 --measure 3
```

`--warmup` and `--measure` must each be 1..10 traversals; `--arm-ms` must be 2000..60000, matching BenchCam's accepted request bounds. `--dry-run` is preflight-only: it validates the route, active physical-console `javaw.exe` session, renderer log, and live pack fingerprint without opening BenchCam or PresentMon, so it does not verify the live framebuffer dimensions. A real capture always takes pre/post screenshots and requires both to match the explicit `--width` and `--height`. Offline protocol and phase-trim fixtures run with:

```powershell
py -m unittest harness.test_dynamic_capture
```
