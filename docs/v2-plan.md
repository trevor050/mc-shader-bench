# ClaudeBench V2 plan

Source: Trevor's play-test of Bliss, BSL, Complementary Reimagined/Unbound, Fantasy, Noble, Photon and ClaudeBench v1.
From V2 on, reference packs' code may be read and borrowed (credit it; Photon's license allows personal
modification and non-monetized redistribution).

## Feedback to address
| Area | Liked (reference) | v1 problem |
| --- | --- | --- |
| Clouds | Fly-through volumetric clouds (Unbound close-up, Bliss), Photon's layered clouds seen from above, per-day variety | v1 clouds blurry, unreachable, one layer |
| Sun | v1 sun judged best; slightly bigger is fine | flickers when turning, grainy noise near the sun, a glow blob pops in when a sliver of sun appears |
| Air | Bliss "standing in the beams" glow, Photon valley mist and overcast fog | light-shaft noise and flicker at edges |
| Color | Bliss "color processing" (big difference) | colors look vanilla |
| Water | calm, still water (Photon); no random-direction ripples | colorless, lighting mid, see-through hand underwater, no mirror-like surface from below |
| Night | Photon's moon with a haze glow | every pack's night is grey and the stars are fake; moon near horizon looked like a second sun |
| Gimmicks | none | avoid lens flares, shooting stars, yellow wash |

## Work order
1. Sun: wider, smoother core (no sub-pixel spike), temporally stable glare, denoised light shafts.
2. Color grading pass: filmic contrast, split toning, vibrance, per-hue tweaks; whole image, never per block.
3. Clouds rewrite: low cumulus layer reachable by flying, mid altostratus/altocumulus layer, high cirrus;
   rendered for every pixel (in front of terrain when inside/above), half-res with temporal accumulation;
   daily weather variation.
4. Fog: ground mist pooling in valleys, morning/evening; stronger in-beam glow.
5. Water: tinted body color, calm directional waves, better sun path, Snell's window underwater, hand fix.
6. Night: real star catalog baked to a texture, Milky Way band, white moon without a sun-like glow, darker
   and bluer (not grey) nights.
7. Review all scenes at full resolution, tune, commit.
