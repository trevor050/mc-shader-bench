# Chat and GUI stall investigation

Status, 2026-09-26: the severe frame drop is reported specifically **while typing in chat** on a friend's RTX 2060 Super PC, using Minecraft 26.2 and current Iris/Sodium/Distant Horizons plus world-generation mods. It was not reproduced on Trevor's RTX 4070 test host, including a subsequent dynamic typing capture. The optional `client-fixes/` preview implements a targeted GUI queue mitigation; it has not established a fix on the affected host. No shader quality settings have been changed for this investigation.

## Local controls

Minecraft 26.2, Iris 1.11.4, Sodium 0.9.2, 2402 × 1313 framebuffer, VSync off, configured maximum FPS 260. Each PresentMon 2.4.1 capture lasted 10 seconds, at the same position and view. The End companion mod was disabled during these controls.

| Profile and state | Samples | Median frame, ms | p95 frame, ms | Median GPU busy, ms |
| --- | ---: | ---: | ---: | ---: |
| Ultra, HUD hidden | 540 | 18.2934 | 19.7449 | 15.2526 |
| Ultra, HUD visible | 542 | 18.2944 | 19.6090 | 15.1131 |
| Ultra, empty chat | 540 | 18.2953 | 19.8620 | 15.1671 |
| Ultra, command suggestions | 537 | 18.4173 | 20.0037 | 15.3398 |
| Ultra, inventory | 537 | 18.4238 | 19.9012 | 15.2467 |
| Potato, world | 1668 | 5.9645 | 6.9697 | 4.2323 |
| Potato, chat | 1675 | 5.9585 | 6.8921 | 4.3033 |

The roughly 166 FPS Potato control also showed no chat-induced frame collapse. A snapshot showed `/time set` displaying normally, but continuous keystroke-to-display latency was **not measured**. These controls do not establish that the affected friend's system is fixed.

Raw JSON/CSV pairs are in Trevor's projectless output directory `outputs/gui-lag-diagnosis/`, with labels matching the table. The active local pack was `ClaudeBenchRCMenuV2`. The capture receipts attest Ultra artifact SHA-256 `eee9112d3462092b93430dfeb4a3f942460c7c26f69edbc38c2446c5271a8bae` and Potato diagnostic artifact SHA-256 `23f2ddaf7da59b25d7396ce8ff65eb043a0f29fa1566e6e4551f9bc910873efe`. These are host controls, not qualification of a new release artifact.

## Installed-source findings

Selected classes were decompiled locally with Vineflower 1.12.0. The installed Minecraft client matched the Gradle client cache byte-for-byte: SHA-1 `2dc72797acbc1b63fc16a11c4ac393605f453754`. Installed and cached Iris also matched: SHA-256 `f1f7ab57c974d193ba33aa285864a0ded949216f402116fceaf4dc7739b4dd7c`. Scratch evidence is under `work/gui-diagnosis/`; it is not release content.

- `GameRenderer.render` renders the world once, then `GuiRenderer.render`. Opening chat does not repeat the shader's world render graph.
- `ChatScreen.extractBackground` is empty. Minecraft's menu background blur is therefore insufficient to explain chat and all-GUI stalls together.
- `GuiRenderer` prepares text, uploads vertices through `StagedVertexBuffer`, then draws. Its staging mapping is write-only. Buffer reuse polls fences with a zero timeout and allocates another buffer when needed; no framebuffer readback was found in this path.
- `Minecraft.run` polls input events before the frame. `Minecraft.renderFrame` records `frameTimeNs` before command submission and presentation. Input polling cannot proceed during those subsequent waits; a render-only CPU meter can miss the relevant stall.
- Minecraft 26.2's `GlCommandEncoder` hardcodes two submissions in flight. `submit` inserts a GPU fence and waits for the preceding submission before rotating transient memory. Sodium 0.9.2 has no CPU Render-Ahead Limit setting. Historical advice to set that option to zero is not applicable to this local stack.
- Iris 1.11.4 invalidates its cached program at draw setup while a pack is active. This is a possible source of extra draw setup work, but it has not been shown to cause this report and is not grounds for an Iris patch.

## Typing path and dynamic capture

The attested Minecraft 26.2 sources distinguish typing from stationary chat:

- GLFW character callbacks dispatch through `KeyboardHandler` and the client task loop. `EditBox.charTyped` inserts text and invokes the `ChatScreen.onEdited` responder, which calls `CommandSuggestions.updateCommandInfo` on each edit.
- Plain chat filters player/custom-name suggestions. Slash commands additionally parse with Brigadier and request local or asynchronous server completions. A new server-completion request cancels the previous pending future; no blocking future wait was found in this path. Turning off automatic suggestions hides the popup but does **not** skip the per-edit parsing/completion work.
- `FontSet` caches glyphs by code point and their baked output. A newly encountered glyph may upload a small atlas region or allocate another 256 × 256 atlas when full. Repeated, warmed ASCII input should reuse those glyphs; no per-character cache clear was found.

A 90-second local JFR with the preview guard disabled included native `a`/Backspace input, `/locate biome` completion edits, and a plain-text burst. No severe slowdown was observed. The recording contains 1,500 render-thread native samples and 791 Java execution samples. Of the native samples, 1,239 (82.6%) were in `glfwSwapBuffers`; none showed `awaitSubmit`/`glClientWaitSync`. The leading Java leaf was Sodium's terrain `TaskCollectingTree.visit` (145 samples). Four Java samples included command-suggestion **rendering**, one included `KeyboardHandler.keyPress`, and 22 included font/glyph work. None sampled `charTyped`, `updateCommandInfo`, `ClientSuggestionProvider`, Brigadier parsing, or glyph upload. These are sampled stack counts, not exact execution durations.

The initial JSON export displayed only five frames per stack. Aggregation was therefore checked against the raw JFR using `RecordingFile`, retaining the recorded stacks up to 64 frames; 27 Java render samples were still marked truncated. Raw evidence is `outputs/gui-lag-diagnosis/typing-off.jfr`; compact full-depth aggregates are in the projectless `work/typing-off-full-summary.json`. Short input callbacks can fall between samples, and this run has no synchronized keypress-to-presentation markers. Neither the earlier static controls nor this non-reproducing local capture identify the affected host's cause or demonstrate a typing-latency improvement from the preview guard. Compare plain text versus slash commands, warmed versus new glyphs, and shader-off versus shader-on captures on that host before attributing the report to a particular path.

## Optional preview mitigation

`client-fixes/` is separate from the End ambience mod. Its `GlCommandEncoder.submit` tail hook waits for `currentSubmitIndex - 1`, the just-submitted frame's existing fence, only while an in-world GUI is open and an exact supported pack identity is active. The case-insensitive allowlist covers the two public preview ZIPs `Afterglow-preview-2026-09-26.zip` / `Afterglow-preview-2026-09-26.2.zip`, their same-named extracted folders without `.zip`, and development identities `ClaudeBenchRCMenuV2`, `AfterglowGUIProbe`, and `AfterglowGUIStress`. Generic prefixes and other releases are rejected. The default added wait requests a finite 30 ms GPU timeout. On success the fence is deleted and its slot cleared; a timeout leaves the fence intact for Minecraft's next submission. Vanilla still has an unbounded wait on that next submission, so this does not guarantee a maximum frame delay or resolve a stalled driver.

The source-level rationale is to remove one queued GPU frame during GUI interaction, using the modern queue mechanism corresponding to historical render-ahead advice. It introduces no global FPS cap and no visual-quality reduction. Less CPU/GPU overlap may reduce GUI throughput. The closed-screen world path performs no additional wait. `/afterglowfix on|off|status` permits live A/B checks and records engagement/completion/timeout counts and elapsed wait without automatic telemetry; settings and the opt-out persist in the instance's config directory. Build and local runtime acceptance must remain separate from proof of the friend's reported stall.

## Upstream reports and affected-host capture

[Iris issue 2617](https://github.com/IrisShaders/Iris/issues/2617) describes a similar chat/GUI symptom on Minecraft 1.21.4. Users reported improvement from [a lower FPS limit](https://github.com/IrisShaders/Iris/issues/2617#issuecomment-2833874375) or the [older CPU Render-Ahead Limit control](https://github.com/IrisShaders/Iris/issues/2617#issuecomment-3329758131). These are user reports, not an established cause or guaranteed remedy. [Iris issue 3274](https://github.com/IrisShaders/Iris/issues/3274) separately reports a 26.2 performance regression; [one report improves with the HUD hidden](https://github.com/IrisShaders/Iris/issues/3274#issuecomment-5198912534). Trevor's local controls did not reproduce that behavior either.

[Architectury issue 726](https://github.com/architectury/architectury-api/issues/726) reports a separate typing-specific Minecraft 26.2/Fabric conflict: an uninitialized `ScreenInputDelegate$DelegateScreen` causes a `charTyped event handler` exception for each character. Check for that dependency and matching repeated `fabric-screen-api-v1` errors in the affected log. Architectury has not been confirmed in the friend's mod list, and this issue is not evidence that their frame drop has the same cause.

Collect the affected GPU, driver, Minecraft/Iris/Sodium versions, mod list, `logs/latest.log`, selected shader/profile, FPS limit, and VSync state. Compare the same stationary scene with shaders enabled and disabled. As a reversible diagnostic, compare the current FPS limit against 120 or a limit below sustained world FPS. A successful cap test would identify a workaround to document, not justify silently imposing a universal cap.

Minecraft 26.2 still defaults to **F3+L** for its 10-second client performance capture. This was verified in the installed `Options.keyDebugModifier` / `keyDebugProfiling` bindings and `KeyboardHandler` handler; rebound keys may differ. Start one capture while standing still, then another immediately before opening chat and typing enough to trigger the symptom, without submitting a command. The completion message links to the resulting ZIP under the game's `debug/profiling/` directory. Supply both ZIPs and the corresponding log. The useful profiling branches include `frame`, `render/gui` and its `prepare/upload/draw` children, `swapBuffers`, and `frameLimiter`; command parsing and input callbacks may require a stack sample if the capture does not isolate the stall. Preserve profiler reports privately because they can contain system, options, world, and server details.
