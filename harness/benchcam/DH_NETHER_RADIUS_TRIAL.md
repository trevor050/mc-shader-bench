# Art-guarded DH Nether and End radius defaults

These BenchCam controls apply Distant Horizons 3.3.2 public API overrides by dimension. In Nether and End, the default target is 64 LOD chunks (1,024 blocks), promoted from the guarded Art-on trials. Each override applies only while Iris reports an active shader pipeline and the successfully loaded pack name is exactly `ClaudeBenchV4Art`; shaders off or a different pack clears it before the next DH draw. `dhtrial on|off` and `dhend on|off` set per-process session overrides: `on` enables that dimension when the Art guard passes, and `off` suppresses its automatic default across dimension transitions until `on` is sent. Set `-Dbenchcam.disableArtDhRadiusAuto=true` to opt out of the automatic defaults; explicit `on` still requires the Art guard. The legacy `-Dbenchcam.dhNetherRadiusTrial=true` startup property acts as a Nether session `on`. Neither control changes the underlying DH configuration value, shaders, Prism files, or game installation.

Build from `harness/benchcam` with `./gradlew build` (PowerShell: `.\gradlew.bat build`). The build needs the pinned Iris 1.11.4 and DH 3.3.2 jars as compile-only dependencies. Set `BENCHCAM_IRIS_JAR` and `BENCHCAM_DH_JAR` if they are not at the ShaderBench Prism paths in `build.gradle`. The output is `build/libs/benchcam-0.1.0.jar`; building does not install it.

`py bench.py raw "dhstatus"`, `py bench.py raw "dhtrial status"`, and `py bench.py raw "dhend status"` are read-only. Status reports each control's `source` (`auto`, `auto_disabled`, `session_on`, or `session_off`), its suppression reason (`art_guard`, `auto_disabled`, `session_off`, `failed`, `suspended`, or `none`), the shared `artPackActive` guard, and DH `active` (`getValue()`), `true` (`getTrueValue()`), and `api` (`getApiValue()`) values. `owned` means BenchCam recorded setting the current value; it is not proof that BenchCam is still the API value's owner. DH exposes no ownership token, so a different mod can replace BenchCam's override with the same number and BenchCam cannot distinguish the two. Its cleanup check only avoids clearing an API value that differs from the value BenchCam recorded. For this reason, run both controls only on the pinned stack with no other DH API radius writer. A normal 512-chunk baseline should report `active=512 true=512 api=null`; with ClaudeBenchV4Art active in Nether or End the target is `active=64 true=512 api=64`. Treat the observed `true` value as the baseline; the code does not assume it is 512.

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

The End trial has its own target and switch. It can be enabled while in another dimension and applies on arrival in the End. If both trials are enabled, only the current dimension's target is applied; changing dimensions clears the old API override before applying the new target.

```powershell
py bench.py raw "dhend status"
py bench.py raw "dhend on"
py bench.py raw "dhstatus"
py bench.py raw "dhend radius 128"
py bench.py raw "dhend radius 256"
py bench.py raw "dhend radius 512"
py bench.py raw "dhend radius 64"
py bench.py raw "dhend off"
```

`dhend radius <chunks>` selects the End target without changing the Nether target or enabling the End trial. Values below 64 or above DH's saved `true` radius are rejected. Repeating the currently selected and active target is a no-op. Use 128, 256, and 512 as guarded comparison points when the saved radius permits them. A preliminary capture appeared to lose a distant End island horizon at 64 chunks, but shaders were off during that capture, so it is not valid evidence of the Art-on result. `dhend off` disables the End control and asks the adapter to clear its recorded End override; it does not change the Nether control.

Suggested A/B/A check: record `dhstatus` in the Nether with the Nether trial off, send `dhtrial on`, record status and frames, send `dhtrial off`, record status and frames. Repeat in the End with `dhend on/off`. Also check Nether -> Overworld -> End -> Nether with status after each dimension settles. BenchCam clears its owned override on leaving its dimension, disconnect, client stop, or trial failure. A disconnect suspends both controls until a new connection joins; an enabled Nether JVM-property trial can therefore resume in a later world. Each runtime `off` remains off until its matching `on`; the Nether property is read only at process start.

The hook runs at `Minecraft.renderFrame` HEAD and at client tick end. It selects the requested target for the current dimension, clears an owned radius when the Art guard stops passing or when changing dimensions, then acts before that frame's DH render callback. It cannot affect frames rendered before Minecraft changes `mc.level`. On the pinned Iris 1.11.4 build, the shared guard combines `IrisApi.isShaderPackInUse()` with `Iris.getCurrentPackName()`; Iris sets the latter after successful pack loading and resets it to `(off)` when shaders are disabled. This avoids relying on the persisted Iris config selection. `artPackActive` in status reports the combined check. The new adapter guards its own DH API class loading, but the pre-existing BenchCam DH profiler mixin/config already assumes the ShaderBench stack includes DH; this document does not claim the whole jar runs without DH. If DH rejects the override or readback is wrong, only that dimension is marked failed and the adapter attempts to clear its override; a manual `on` retries after cleanup succeeds. A failed clear stays `owned=true clearPending=true`, blocks further application, and retries at 1, 2, 4, 8, then at most 10 seconds between attempts without repeated error logs. Each retry reads the current API value before clearing. Either `on` command refuses to resume while cleanup is pending. A different-valued pre-existing API override is not overwritten, and a different value observed at cleanup is not cleared. The value check cannot detect another mod replacing the current value with the same number. The adapter's `owned` status is local bookkeeping, not verified API ownership; `apiOwner=not_exposed` makes that API limitation explicit.

The shaderpack's `LOD_DISTANCE` constant may still be set for 512 chunks (8192 blocks). The guarded Art tests found no material terrain silhouette loss in settled portal/lava Nether and central/outer-island End views; continuous camera motion and display-on whole-frame performance remain unmeasured. This promotion targets DH memory/render work and does not claim a whole-frame FPS gain or resolve the earlier intermittent desktop stalls.
