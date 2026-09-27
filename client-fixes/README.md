# Afterglow Client Fixes preview

Optional Fabric client mod for **Minecraft 26.2, Java 25**. Install the built JAR in the same instance's `mods` directory with Fabric API. The End ambience mod is independent and is not required.

This preview adds a GUI latency mitigation while an in-world screen is open and Iris has one of these exact active pack names, compared without regard to case:

- `Afterglow-preview-2026-09-26.zip` or its extracted folder `Afterglow-preview-2026-09-26`.
- `Afterglow-preview-2026-09-26.2.zip` or its extracted folder `Afterglow-preview-2026-09-26.2`.
- Development identities `ClaudeBenchRCMenuV2`, `AfterglowGUIProbe`, or `AfterglowGUIStress`.

Generic names such as `Afterglow Lite`, other releases, and renamed packs skip the guard. It waits for the just-submitted frame's existing OpenGL GPU fence, with a finite 30 ms timeout. This reduces queued GPU work when the fence completes. Gameplay with no screen, title screens, disabled shaders, and other shader packs skip the additional wait. Shader resolution and visual settings are unchanged.

The tradeoff is less CPU/GPU overlap while a GUI is open, so GUI frame throughput can decrease. This is a compatibility mitigation, not a proven fix for the reported RTX 2060 Super issue. A timeout bounds this mod's requested wait only: Minecraft can still wait for the same unfinished fence on the next frame. The mod does not repair GPU hangs, driver stalls, or insufficient VRAM.

Client commands work without server permissions:

- `/afterglowfix off`: disable the extra wait and save the opt-out.
- `/afterglowfix on`: enable it and save the setting.
- `/afterglowfix status`: print the current gate, pack, engaged/completed/timed-out frame counts, and mean/maximum wait, then reset the counters.

`on` and `off` also reset counters. Settings are stored in `config/afterglow-client-fixes.json`; `enabled` defaults to `true`, and `maxWaitMillis` defaults to `30` with a supported range of 1–100. Edit the wait budget while Minecraft is closed. Status has no automatic telemetry or network endpoint.

Verify the identity policy on Windows with `./tools/verify_policy.ps1`, then build with `./gradlew.bat build` (`./gradlew build` on other platforms). Output: `build/libs/afterglow-client-fixes-0.1.0-preview.1.jar`. Live acceptance requires matched on/off captures, command/counter checks, and confirmation that closed-screen world rendering does not engage the guard. See `../docs/gui-stall-diagnosis.md` for source evidence and affected-host capture instructions.
