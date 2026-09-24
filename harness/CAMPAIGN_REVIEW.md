# Shader architecture campaign review

campaign_review.py is an offline join over existing evidence. It does not launch or query Minecraft. For each Overworld, Nether, or End scene it combines:

- The current PresentMon A/B/A gate for GPU Busy, CPU Busy, and present intervals.
- A/B/A passive captures with per-frame long-gap counts and sampled process/GPU/system memory.
- Full-resolution A1/B1/A2 screenshots, compared against both controls.
- Exact shaderpack identity recorded at the time of each capture.

Start from shader-campaign.example.json. Add one scenario per scene and dimension. Keep A1/B1/A2 order and matching pose, resolution, environment, DH state, and capture duration. Use dimension-specific portal, lava, outer-island, and representative terrain poses where those effects matter. scenes.json currently defines Overworld locations only; Nether and End scene IDs must refer to separately prepared, reproducible poses.

## Capture metadata and identity

For each PresentMon run, pass --pack, --pack-revision, --pack-artifact, and --expected-pack-sha256 to perf_capture.py. Put its .capture.json path in capture_metadata in the performance manifest, and include the same pack_sha256 in that run. The capture checks the selected Iris config and latest Using shaderpack: log line before recording.

For each passive run, add those same options to passive_capture.py. This reads config/log once before capture, fingerprints the supplied folder/archive once, and stores the result in active_pack_attestation. The capture stays passive; it sends no game or BenchCam command.

For screenshots, use bench.py shots while the intended pack is selected. Each PNG gets a sibling .image.json that records the selected config pack, latest log pack, and content SHA-256 of the selected pack folder or ZIP when it is present. The review requires each screenshot's sidecar and rejects mismatched pack names, hashes, or scene IDs.

The folder fingerprint hashes sorted relative paths and file contents; ZIP fingerprints hash the exact archive bytes. A settings change outside the shaderpack artifact must be included in pack_revision and the environment attestation.

## Review

    py .\harness\campaign_review.py .\captures\shader-campaign.json --json-out .\captures\shader-campaign.review.json

Each scenario needs its own existing perf_analysis manifest. The campaign manifest points to that manifest, three passive CSVs, and three screenshots. Paths are relative to the campaign JSON except for paths inside the performance manifest, which remain relative to that performance manifest.

The current combined performance gate only returns PASS when GPU Busy median improves by at least 5% (and CPU Busy/present interval do not regress). Treat this as acceptance for GPU-oriented shader candidates. CPU/DH-bound work may be a real improvement and still be INCONCLUSIVE here; report its CPU Busy change separately or use a gate designed for CPU-bound candidates. Do not read campaign PASS as a universal architecture verdict.

Visual tolerances are explicit per scene. max_control_mae is the allowed A1/A2 RGB mean absolute difference; candidate MAE, 95th percentile channel difference, and fraction above 8/255 are checked against both A controls. An optional [x, y, width, height] ROI is useful for stable terrain or a specific architectural effect when animated sky/water makes full-frame control drift too large. Do not use a contact sheet as visual evidence.

stall_gate.max_extra_gaps_by_band compares B1 with the worse A control for each band: 1–2, 2–4, 4–8, 8–12, and at least 12 seconds. Set all five bands to make the check a gate. memory_gate supports hard bounds for candidate VRAM used, Java private bytes, and minimum available physical bytes. Choose bounds from the current machine's measured capacity, not this example's values. These are sampled observations; 1-second telemetry can miss short pressure spikes.

Campaign PASS requires the existing steady-state perf gate, the per-scene visual gate, all configured stall bands, and at least one measurable memory limit. A capture with missing/ambiguous pack evidence fails closed as INCONCLUSIVE. App-only PresentMon mode can count CPU frame-start gaps, but those are not present-event intervals and do not establish GPU Busy. The report keeps that distinction and does not attribute stalls to shaders, DH, the driver, or a memory leak.

This workflow deliberately adds no GL query profiler or per-frame logging to the measured path. Passive capture adds a bounded PresentMon session and 1-second telemetry sampling; use standard display/GPU tracking when available, and label --app-only runs accordingly.
