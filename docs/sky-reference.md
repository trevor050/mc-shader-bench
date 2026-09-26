# Dramatic Skys visual reference

Read-only review of `C:\Users\Trevor\Downloads\Dramatic Skys Demo 1.5.3.36.6.zip` (pack metadata names the demo as by thebaum64). The zip has OptiFine and FabricSkyBoxes/Celestial registrations for the same small set of skybox textures. Its OptiFine layers are clear-weather-only and time-faded; the asset metadata shows no biome-specific skies.

The archive's `credit.txt` says: “Credit to Hipshot for base legacy textures (Created in 2005 by Hipshot, reformatted/edited for MC by me in 2012-2014).” No reuse license is included in the archive. Treat the images as private visual references, do not ship or derive textures from them without permission. Representative originals are kept locally under `work/sky-reference/`: `day.png`, `night.png`, `sun.png`, `mask.png`, `stars.png`, `sunflare.png`.

## Useful visual cues

- **Day (`day.png`):** varied cumulus scales, broken cloud gaps, and a few taller buildups keep the sky from reading as a repeated flat layer. Borrow the variation and lighting hierarchy, not the texture or its cubemap layout.
- **Night (`night.png`):** cloud forms remain faintly legible from cool rim and underside light while most of the sky stays dark. This is a good target for moonlit volumetric clouds; keep the existing cloud field and its depth cues.
- **Dawn/dusk (`sun.png`):** a shared cloud shape is strongly warmed near the horizon, which sells time-of-day. Use a restrained, smoothly changing warm direct-light tint on the existing clouds, sky, sun, haze and reflections rather than an orange skybox.
- **Reject (`stars.png`, `sunflare.png`, `mask.png`):** the star layer is dense and conspicuously blue; the flare is a crisp starburst; the mask/skybox layering can read as a pasted dome. Keep the shader's own stars and low-sun treatment, avoid sharp lens streaks, and preserve the recently repaired natural horizon.

## Timing observed in the pack

The OptiFine `assets/minecraft/optifine/sky/world0/sky*.properties` files specify clear weather and these fade windows:

| Layer | Fade-in | Fade-out | Blend |
| --- | --- | --- | --- |
| Day clouds (`day.png`) | 05:40–06:20 | 17:40–18:20 | screen |
| Night clouds (`night.png`) | 19:20–19:40 | 04:20–04:40 | add |
| Warm sun/cloud layer (`sun.png`) | sunrise 04:20–04:40 | sunrise 05:40–06:20 | add |
| Warm sun/cloud layer (`sun.png`) | sunset 17:40–18:20 | sunset 19:20–19:40 | add |
| Sun flare (`sunflare.png`) | same dawn/dusk windows | same dawn/dusk windows | add |

These windows overlap, so transitions are layered rather than hard switches. For the shader, use continuous solar elevation with a broad golden-hour weighting rather than copying the pack's cube faces or adding new hard time bands.

## Portable direction for the shader

Keep the six existing volumetric cloud decks and the recently repaired natural horizon. Preserve their depth, shadows and weather controls; add only small, shared climate/time inputs to the existing volumetric lighting and atmosphere. A restrained mapping to explore:

| Climate family (temperature/rainfall/category) | Sky and cloud bias |
| --- | --- |
| Cold or snowy | Slightly cooler ambient fill; preserve warm low-sun light and snow horizon continuity. |
| Temperate | Neutral baseline and greatest palette/shape variety. |
| Warm, dry | A little more low-angle aerosol warmth and less frequent broad coverage, without permanent orange haze. |
| Humid, lush | Slightly softer horizon contrast and more broken low/mid cloud presence, while keeping cloud bodies volumetric. |
| Rainy/stormy weather | Let current weather scalars drive coverage, darkness and cloud light; biome only nudges the palette/morphology. |

Smooth climate axes on the CPU/uniform side if already available, and smooth the resulting parameters in shader time to prevent biome-border pops. Share any aerosol/twilight tint across sky, sun, cloud lighting, haze and reflection so each surface agrees. Keep rare saturated dusk events subtle and uncommon. This is a direction for a later implementation phase, not a claim that the pack uses these biome mappings.
