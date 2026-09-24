# Optional DH Nether and End radius trials

These BenchCam-only trials apply Distant Horizons 3.3.2 public API overrides by dimension. The Nether trial remains independently controlled with `dhtrial` and defaults to 64 LOD chunks. The new End trial is independently controlled with `dhend` and uses a fixed 64 LOD chunks (1,024 blocks). Both are off by default; neither changes the underlying DH configuration value. The trials do not change shaders, Prism files, or the game installation.

Build from `harness/benchcam` with `./gradlew build` (PowerShell: `.\gradlew.bat build`). The build needs the pinned Iris 1.11.4 and DH 3.3.2 jars as compile-only dependencies. Set `BENCHCAM_IRIS_JAR` and `BENCHCAM_DH_JAR` if they are not at the ShaderBench Prism paths in `build.gradle`. The output is `build/libs/benchcam-0.1.0.jar`; building does not install it.

For a future guarded game trial, install that candidate jar deliberately. The existing `-Dbenchcam.dhNetherRadiusTrial=true` startup property still opts into only the Nether trial; otherwise use `py bench.py raw "dhtrial on"` to enable it at runtime. The End trial has no startup property and is enabled with `py bench.py raw "dhend on"`. Each `off` command disables and clears only its own dimension's override. `py bench.py raw "dhstatus"`, `py bench.py raw "dhtrial status"`, and `py bench.py raw "dhend status"` are read-only. Status includes both controls plus `active` (DH `getValue()`), `true` (DH `getTrueValue()`), and `api` (DH `getApiValue()`). A normal 512-chunk baseline should report `active=512 true=512 api=null`; in either opted-in dimension the target is `active=64 true=512 api=64`. Treat the observed `true` value as the baseline; the code does not assume it is 512.

To switch the requested radius during a guarded Nether test, send each command separately through BenchCam. The radius command runs on the render thread. It clears and verifies BenchCam's current API override before applying the replacement, then replies with status:

```powershell
py bench.py raw "dhtrial on"
py bench.py raw "dhtrial radius 64"
py bench.py raw "dhtrial radius 48"
py bench.py raw "dhstatus"
py bench.py raw "dhtrial radius 64"
py bench.py raw "dhstatus"
```

The expected active sequence is 64 → 48 → 64, while `true` stays at the saved value (for example 512). `requested` reports the selected target even when the trial is off or the player is outside the Nether. Values below 32 or above DH's current saved `true` radius are rejected. A pending cleanup or a radius override owned by another mod blocks the switch.

The End trial has its own fixed target and switch. It can be enabled while in another dimension and applies on arrival in the End. If both trials are enabled, only the current dimension's target is applied; changing dimensions clears the old API override before applying the new target.

```powershell
py bench.py raw "dhend status"
py bench.py raw "dhend on"
py bench.py raw "dhstatus"
py bench.py raw "dhend off"
```

The End target is fixed at 64 chunks and is validated against DH's saved radius when applied. `dhend off` only clears a BenchCam override currently owned in the End; it does not disturb the Nether trial or an override currently owned in another dimension.

Suggested A/B/A check: record `dhstatus` in the Nether with the Nether trial off, send `dhtrial on`, record status and frames, send `dhtrial off`, record status and frames. Repeat in the End with `dhend on/off`. Also check Nether -> Overworld -> End -> Nether with status after each dimension settles. BenchCam clears its owned override on leaving its dimension, disconnect, client stop, or trial failure. A disconnect suspends both controls until a new connection joins; an enabled Nether JVM-property trial can therefore resume in a later world. Each runtime `off` remains off until its matching `on`; the Nether property is read only at process start.

The hook runs at `Minecraft.renderFrame` HEAD and at client tick end. It selects the requested target for the current dimension, clears an owned radius before applying a different dimension's target, and acts before that frame's DH render callback. It cannot affect frames rendered before Minecraft changes `mc.level`. The new adapter guards its own DH API class loading, but the pre-existing BenchCam DH profiler mixin/config already assumes the ShaderBench stack includes DH; this document does not claim the whole jar runs without DH. If DH rejects the override or readback is wrong, only that dimension's trial disables itself and the adapter attempts to clear its override. A failed clear stays `owned=true clearPending=true`, blocks further application, and retries at 1, 2, 4, 8, then at most 10 seconds between attempts without repeated error logs. Each retry reads the current API value before clearing. Either `on` command refuses to resume while cleanup is pending. A different mod's existing radius override is not overwritten; if another mod changes the radius to a different value during the trial, BenchCam does not clear that new override.

The shaderpack's `LOD_DISTANCE` constant may still be set for 512 chunks (8192 blocks). This trial intentionally does not edit shader art, so a 64-chunk DH radius can expose a fog or terrain transition mismatch. Use this candidate to measure DH behavior, not to judge final shader visuals.
