# ClaudeBench V3 plan

Source: Trevor's adversarial review of V2 (overworld, Nether, End; compared against Complementary Unbound,
Photon, Fantasy, Bliss, BSL, Solas).

## Ownership
- **Claude (visuals):** everything in the list below. Files: lib/clouds.glsl, lib/atmosphere.glsl, lib/stars.glsl,
  lib/lighting.glsl, lib/mist.glsl, program/deferred.glsl, program/clouds_march.glsl, program/composite.glsl,
  program/final.glsl, program/gbuffers_solid.glsl, program/gbuffers_translucent.glsl, sky.glsl, new Nether/End libs.
- **Codex (performance):** overworld fps (Trevor measured ~44), Nether fps (Trevor measured 14), VRAM. Please ping
  before touching the files above; Claude will keep new effects cheap and flag anything expensive here.

## Overworld
1. Hand: clouds are composited over the hand (it counts as sky in the cloud pass), which reads as a cloud
   shadow / see-through arm, especially underwater. Exclude the hand from clouds everywhere.
2. Cloud variety: several cumulus decks at different heights (a low deck you can walk into on mountains,
   a mid deck, towering cumulonimbus), stratocumulus/altocumulus fields, cirrus; weather regimes choose mixes.
3. Clouds from above look "funky": fix top lighting and far-field look.
4. Sunset: from pretty to beautiful. Clouds must not smother it; stronger colour drama (belt of Venus, earth
   shadow, golden rim light, rays through cloud gaps).
5. Night: moonlight too strong on terrain; a vivid dark-sky Milky Way (not strictly accurate); stars richer.
6. Handheld dynamic light (torch in hand lights the world).
7. Dark blocks (obsidian) crush to pure black: add specular sheen and a sane ambient floor.
8. Nether portal redesign (glowing, swirling, emissive).

## Nether
- Hellish but beautiful: dark ashen smoke, heat haze, light rising from lava seas (Bliss vibe), no teal glow
  from biome fog; per-biome tint kept subtle.
- Lava redesign: bright, hot, animated flowing surface instead of the repeating texture; lights its surroundings.

## End
- Alien, island feel (fade out LOD terrain), own take on Bliss's swirling sky storm with Complementary's
  purple mood; no gimmicks (no black holes). End portal redesign.
