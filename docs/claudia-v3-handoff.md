# ShaderBench V3 creative handoff

Trevor switched Claude accounts and the new conversation has no prior chat. This is the context for the Minecraft shader project. Codex is coordinating runtime verification and performance work; Claude should own creative direction and visual quality, with an isolated worktree for edits. The live game is shared, so coordinate before changing packs, teleporting, or reloading shaders.

## Project and current state

- Repository: `C:\Users\Trevor\codeprojects\mc-shader-bench`.
- Current combined V3 candidate: `C:\Users\Trevor\codeprojects\mc-shader-bench-v3-integration`, branch `feature/v3-visual-integration`, commit `c724ff2` at this handoff. Codex may add later commits.
- Prism instance: `ShaderBench`; Fabric Minecraft 26.2, Iris, Sodium, Distant Horizons, BenchCam. The active pack is user-controlled and may change at any time; read `minecraft/config/iris.properties` and the game log before judging an image.
- Original, detailed spoken review: `C:\Users\Trevor\.codex\attachments\6c8c4988-ff2e-43ab-a00b-6ecc15a5f3eb\Pasted text.txt`.
- Repro captures: `C:\Users\Trevor\codeprojects\mc-shader-bench\harness\out\views\`. Key captures are `v3-integrated-nether.png`, `v3-integrated-end.png`, `v3-sunset.png`, `v3-night.png`, `v3-cloud-above.png`, plus `bliss-wide.jpg`, `bsl-wide.jpg`, and `vanilla-control-wide.jpg`.
- Codex's first combined pass compiled all 176 generated vertex/fragment stages after expanding Iris includes and supplying compile-only Iris/DH symbols. Compile success alone is not visual acceptance.

## Trevor's artistic direction

Preserve Minecraft's visual identity. The rejected Nether lava was brown, stretched, hyper-realistic crust; the actual problem is obvious repetition of the stock tile across lava lakes. Pool lava should be lively, pixel-based, bright orange/yellow, with medium and broad motion/variation and no visible grid. Falls should stay recognizable. Nether mood should be hot, loud, hellish, and beautiful: dark smoke or haze visibly rising over lava, warm light on nearby stone, readable dark blocks, no blue glow. Bliss supplies a useful smoky mood but has a repetitive pattern; BSL supplies a useful hot light impression. Copying a technique is okay if you make a meaningful improvement rather than importing it wholesale. The fancy neon-marble Nether portal was rejected as disgusting; use a restrained, clearly visible purple portal that still feels like Minecraft.

The End should feel alien: violet void and islands, dramatic but tasteful, inspired by Bliss and Complementary Unbound. Avoid the Solas-like enormous black hole, excessive brightness, gimmicks, and Distant Horizons terrain carpeting the entire void. The exit/End portal can be redesigned subtly. Obsidian towers need texture/readability rather than pure black cutouts.

Overworld clouds need several forms at different heights and must work when flown through or viewed from above; no flat gray cloud carpet. They must not occlude or shadow the first-person hand. Sunset should be beautiful, not merely adequate. Night should show a striking Milky Way in a dark unpolluted sky, while terrain stays playable without unnatural moonlight. Water and looking up from underwater were liked, but the translucent hand was a defect. Dynamic held-torch lighting is implemented and should remain.

Trevor reports catastrophic Nether performance (~14 FPS in one earlier configuration) and wants extremely low GPU cost. Do not add expensive full-screen ray marches or extra texture-heavy passes without strong visual gain. Codex is measuring A/B/A frame times with PresentMon at fixed poses; coordinate performance tradeoffs with it.

## Current implementation and visual verdict

Eleven Codex Luna agents produced separate V3 slices. The integration branch includes sprite-based lava with animated macro tint, one-lookup 3D Nether smoke, warm Nether lighting, simpler portal, End violet storm sky, End LOD fade, subtle End bounce for dark towers, End portal redesign, cloud layers, sunset/night changes, and a hand-water compositing fix. After v2 revisions, **the combined pack has not yet been visually rechecked**. Do not assume those revisions are good. In the v1 integrated Nether screenshot, lava was still a nearly uniform orange lake, smoke almost invisible, and the portal too transparent. The End sky's alien purple structure worked, but towers were black; sunset looked good. The v1 night was too dark and clouds hid the Milky Way. From y=1390, mid-cloud tops formed a flat gray carpet. Those issues prompted the v2 edits now in integration.

Performance candidate work is separate from the visual baseline. Historical matched tests in `docs/perf-v3.md` found Nether dimension skips worth 3.3–3.8 ms and half-resolution bloom worth about 0.75 ms in one Overworld view. Those are scene-specific, not general FPS promises. Another isolated candidate cuts Nether SSAO from eight to four depth taps; it still needs a visual and measured A/B/A gate.

## How to collaborate

Read the original review and reference captures, then inspect the integration code and make an opinionated art pass. Own a separate branch/worktree; do not overwrite Codex's integration or agents' work. Send specific visual recommendations and the paths/commits of your edits to Codex. Codex owns the live game and will capture matched views; ask it for a camera/screenshot rather than triggering your own Iris reload. The earlier partial Windows input lock has no proven root cause, but overlapping reloads and heavy Distant Horizons generation were credible contributors. One live controller at a time is the rule.

Please focus your first pass on the still-unverified Nether lava/smoke/portal composition and the End's island/portal atmosphere. Be ambitious with composition and taste, conservative with GPU work, and reject work that merely compiles but looks wrong. Trevor asked you to take creative direction, not just follow the current implementation.
