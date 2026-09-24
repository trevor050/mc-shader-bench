# Read-only Minecraft telemetry

`telemetry.ps1` records Windows per-process GPU memory counters, Java private and working-set bytes, system committed bytes/limit, available physical memory, global NVIDIA VRAM and GPU/memory utilization, and optionally BenchCam FPS. It does not change game settings or send camera/game-control commands. The optional FPS query uses BenchCam's read-only `status` endpoint with a 500 ms client timeout; skip `-BenchCam` when you want counters only.

Run a one-minute capture at 1 Hz:

```powershell
pwsh -NoProfile -File .\harness\telemetry.ps1 -DurationSeconds 60
```

The script auto-selects only when exactly one `java.exe`/`javaw.exe` command line contains the configured Prism instance path (`%APPDATA%\PrismLauncher\instances\ShaderBench`). It rejects ambiguous/wrong processes. Pass `-ProcessId` after verifying the PID to select explicitly, `-InstancePath` for another Prism instance, `-BenchCam` to include FPS, or `-OutputPath C:\path\capture.csv` to choose the CSV path. By default it writes to `%TEMP%\mc-shader-telemetry-<timestamp>.csv` and refuses to overwrite an existing file.

GPU/process/system memory values are bytes; global NVIDIA VRAM values are MiB and utilization is percent. If counters or `nvidia-smi` are unavailable, the affected CSV fields remain empty and `SampleError` records the counter issue. A rising allocation that plateaus after returning to a settled view suggests retained residency/cache; continued growth while stationary or after repeated identical traversals is stronger leak evidence. Compare per-process counters and system commit/available memory as well as global VRAM.
