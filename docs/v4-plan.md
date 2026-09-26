# ClaudeBench V4 plan

Source: Trevor's 2026-09-24 play session (V3 integrated vs Bliss, Complementary Unbound, Solas, Noble, Photon,
Fantasy, BSL). Screenshots: `ShaderBench/minecraft/screenshots/2026-09-23_23.49` .. `2026-09-24_00.19`.

## Ownership
- **Claude** (branch `claude/v4-art`, worktree `mc-shader-bench-claude-art`): creative direction and graphics
  engineering: the lighting engine, Nether art, lava, portal, snow/ice, cloud forms.
- **Codex**: performance (target: most of the 120 -> ~50 fps shader cost back), bugs, live game control and
  captures, A/B/A timing. Straightforward defects listed under "Bugs" below.

Rule from Trevor: code may be taken from other packs, but every borrowed piece must be substantially improved
(prettier, more correct, or cheaper). Each borrowed system below states its improvement.

## 1. Lighting engine (priority one)
Verdicts: caves are fully lit; shadows are too binary and too dark; block light is a flat single colour;
lava lights nothing; the Nether is black; soul sand turned red.

Root causes found in code:
- Eye adaptation opens up to 20x with a blue scotopic shift, so unlit caves read as flat blue-grey light.
- Metering uses an arithmetic mean capped at 4, so lava pools dominate and crush every other surface to black.
- Nether ambient is a constant orange multiplier everywhere (turns grey soul sand red); fog colour ~0.01.
- Block light is `BLOCKLIGHT_COLOR * f(lm.x)`: one colour, no direction, no spatial shape.

Plan:
- **Voxel light field** (after Complementary's flood fill). The shadow pass writes blocks into a 3D image and a
  compute pass (shadowcomp) diffuses coloured light one block per frame. Improvements over the original:
  - Emission colour and strength come from the block itself (`at_midBlock.w` + a brightness-weighted read of its
    own texture), so there is no hand-maintained light-colour table and modded or new blocks just work.
  - Surfaces use the field's gradient: block light has a direction, so faces toward lava are lit and faces away
    are not, and glossy stone gets a specular glint of the lava/portal (the look Trevor liked most).
  - Area emitters accumulate: a lava sea glows harder than one lava block. Vanilla lightmap stays as occlusion
    guard and as the fallback outside the volume.
  - Fire and lava sources flicker slightly per voxel, so firelight moves on walls.
  - The same field lights Nether smoke (glowing smog above lava, portal haze).
  - Nether/End get a voxel-only shadow pass: vertices are clipped away, so there is no rasterization cost.
- **Exposure**: log-average metering with emissive highlights capped; adaptation range limited underground
  (eye sky light), much lower minimum light: unlit caves go dark, torch-lit caves stay readable.
- **Sun light diffusion**: sky fill is kept at a physical ratio to sunlight (shadowed snow reads pale blue, not
  black); wider contact-hardening penumbra.

## 2. Nether
Direction: Bliss's smoke and dread (smog you can feel in your lungs), Complementary's light, Solas's portal.
Grotesque but beautiful; lava hot enough that it hurts to look at.
- Volumetric smog (half-res march, temporal), densest over lava seas, lit from below by the lava sea and by the
  voxel light field; per-biome tint (crimson red, warped muted, soul sand valley cold grey, basalt ash).
- Lava: keep Minecraft pixels, remove the repeat (stochastic tiles), add a value hierarchy (mostly molten orange,
  sparse white-hot upwellings, darker cooling patches), hot shore rim, heat shimmer. Falls stay vanilla-like.
- Portal: Solas-style sparkling purple swirl, improved with depth layers and real purple light on surroundings.
- Soul sand and other blocks keep their own colours (no global orange ambient).

## 3. Overworld
- Snow: redo reflections/glitter (current glitter is per-texel white noise). Ice: silky, reflective, clear.
- Clouds: fewer flat high-sky clouds; stacked volumetric decks of different types you can fly through.

## Bugs (Codex)
- Cloud shadows jitter heavily.
- Ice seen from underwater is 100% reflective.
- Water reflections swim toward the camera when moving fast (history/reprojection of reflections).
- Distant water is far too transparent.
- High altitude rendering breaks down.
