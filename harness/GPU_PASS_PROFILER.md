# BenchCam Iris GPU pass profiler prototype

This client-only BenchCam build times Iris 1.11.4+mc26.2 composite passes with OpenGL `GL_TIME_ELAPSED` queries. It does not change shader files, framebuffers, or the rendered image. It measures each Iris `begin`, `prepare`, `deferred`, and `composite` pass (compute, mipmap setup, and draw together), plus `final` when present. It does not time geometry, shadows, Distant Horizons, buffer clears, post-Iris UI, or presentation.

The hook is pinned to the installed Iris jar's `CompositeRenderer.renderAll` debug groups: one outer group, then one group per pass, including a separate pop for compute-only passes. `FinalPassRenderer.renderFinalPass` has a group around its shader-based final pass. These call sites were checked against the installed `iris-fabric-1.11.4+mc26.2.jar` bytecode and Iris's `26.2` source. Any Iris upgrade requires another bytecode check before using the numbers.

## Build and install gate

Build only in this worktree:

```powershell
cd C:\Users\Trevor\codeprojects\mc-shader-bench-gpu-pass-profiler\harness\benchcam
.\gradlew.bat build
```

The build reads the installed Iris jar from the ShaderBench Prism instance for compilation. Set `BENCHCAM_IRIS_JAR` to its path if it has moved. The output is `build\libs\benchcam-0.1.0.jar`. **The prototype is not installed in Prism.** The lead controls the live game, shader selection, and monitors; installation and a guarded runtime smoke test are the next gate.

## Capture protocol (after the runtime gate)

Use the existing BenchCam socket, for example from `harness`:

```powershell
py bench.py raw "gpuprof start gpu-pass-001.csv"
py bench.py raw "gpuprof status"
py bench.py raw "gpuprof stop"
py bench.py raw "gpuprof status"
```

`start` accepts a CSV basename only and creates a **new** file under `%USERPROFILE%\BenchCamGpuProfiles`. Directory components and UNC paths are rejected, and the output root is checked for link/junction redirection. It is off by default. `stop` stops issuing queries immediately but reports `draining` until old GPU results have arrived and the writer has closed. Continue rendering and poll `status` until `state=closed`, `pending=0`, `written=received`, `failed_reason=none`, `restart_required=false`, `writer_error=none`, and both dropped counters are zero. Keep the CSV with the exact pack revision, scene/camera, render/DH distance, resolution, and the paired control/candidate run order. Drop warmup frames in analysis. Never interpret pass sums as whole-frame GPU Busy or FPS.

`frame,stage,pass,gpu_ns` is the CSV schema. `frame` is BenchCam's render-frame ordinal within the client session. Pass names come from Iris. Results are polled at least four frames later, and `GL_QUERY_RESULT` is read only after `GL_QUERY_RESULT_AVAILABLE` is true. Query objects are reused with a 512-object ceiling and deleted after the capture drains. BenchCam checks `GL_CURRENT_QUERY` before beginning and before ending or aborting a timer, so it never ends another mod's elapsed query. If a capture fails, ended pending queries are deleted without waiting for results, and the file is closed. If deletion cannot be confirmed, `restart_required=true` rejects another capture until the client and GL context restart; `unreleased_queries` reports how many query IDs were left for context destruction. If the GPU falls behind, `dropped_queries` rises rather than blocking rendering. A separate bounded writer queue keeps file I/O off the render thread; `dropped_rows` and `writer_error` expose output loss. A method wrapper closes an active query and marks `failed_reason` when Iris exits a pass abnormally; a pass token prevents a later pass from ending another pass's query. GL errors from query creation, begin/end, polling, retrieval, and deletion are reported in `failed_reason`. Treat any failure reason, dropped query or row, incomplete drain, mixin injection failure, or GL error as a failed capture.

The timer measures elapsed GPU execution for submitted commands in each group, including their dependencies, not isolated shader ALU time. It cannot explain a full desktop stall by itself. The first live test should confirm that `deferred`, `composite`, and `final` rows arrive while the monitors are off, compare profile-off versus profile-on frame time for overhead, and verify that screenshots stay identical at a fixed scene. No such runtime test has been performed in this worktree.
