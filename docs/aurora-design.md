# Northern aurora curtains

## Event controls

`AURORA_MODE` preserves four choices: 1, snowy biomes; 2, snowy biomes under a full moon; 3, random nights in any biome; 4, every night. Mode 3 is the default. All choices retain the dark-sky and rain fades, and callers exclude the Nether and End.

`auroraNightRoll` hashes integer `worldDay`, independently of frame time, biome, and position. A random display requires today's proposal and a non-proposal yesterday. Proposal probability p=(1-sqrt(0.6))/2 gives long-run frequency p(1-p)=0.10, with no adjacent eligible nights. This is a statistical rate rather than one guaranteed display in each ten-night block. Iris exposes no world seed here, so worlds at the same day count share the sequence. Reloading does not reroll a night; `worldDay` changes at dawn.

## Continuous sheets and their ray integrals

The aurora comprises three continuous folded sheets in a north-facing magnetic frame. The ray interval lies between 94 km and 320 km spherical altitude shells above a 6371 km reference sphere. Rationalized altitude and shell intersection expressions avoid cancellation near zenith and the plane-intersection singularity at the horizon. Small magnetic shear inclines every field-aligned ray coherently. Separate curtain phases, slopes, depths, and broad curls give overlapping geometry rather than evenly spaced walls.

The rejected altitude-march implementation integrated sheet amounts but evaluated all sheets' emission at a single weighted-average crossing inside each altitude segment. When the sheets' relative weights changed, that estimated footpoint changed abruptly. Fine-ray noise consequently acquired diagonal crosshatching and comb structure even though the integrated density itself was smooth. Increasing the number of layers did not address that coupling.

A second root-search implementation used 16 intervals, safeguarded crossing roots, and stationary-point grazing volumes. It removed the live zipper artifacts but was rejected on active-path cost: the offscreen native-resolution trial had a 54.32 ms median at 3440x1369.

The current implementation uses three continuous folded sheets whose spatial derivative is bounded by construction. Their broad and secondary sinusoid amplitudes give maximum absolute slopes of 0.1887, 0.2685, and 0.3411. A conservative ray-derivative bound is evaluated over the 94-320 km spherical interval. Each curtain fades smoothly in directions where that bound approaches a tangent, so a visible sheet has a unique crossing and requires neither a march nor a stationary-point search.

The three crossings are solved simultaneously from a geometric depth estimate with four Newton refinements. Analytical first and second derivatives provide the finite optical path through each Gaussian sheet. A normal-CDF difference clips the full optical column to the lower and upper spherical altitude limits. Emission uses each sheet's own actual refined footpoint. Failed estimates fade by their geometric residual instead of extrapolating a no-hit slope into an invented bright tail. All root coordinates are global to the sheet; they do not depend on altitude strata or search-bracket boundaries.

This is a local finite-width approximation of a curved, optically thin volume, not an exact general volumetric solver. Geometrical Gaussian widths of 2.4, 3.1, and 3.8 km deliberately exaggerate physical sheet thickness enough for game rendering. The bounded geometry trades tight self-overlapping curls for a fast, resolvable family of curved curtains. Green, red, violet, activity, and broad-billow modulation remain independently evaluated at each sheet's refined footpoint.

## Emission and motion

Green emission rises around a locally varying lower lip near 110 km and fades with a locally varying vertical scale. Weaker red emission peaks near 220 km. A restrained violet fringe occupies the lower boundary. These altitude/color choices are physically motivated rather than a calibrated spectroscopic simulation.

The sheet-emission mix is `0.42 + 0.50*coarse`. A continuous luminous floor and broad uneven billows carry the ribbon. The coarse field has a 100 km base noise-cell scale, warped by a separate 270 km field with amplitude 1.6 cells, so billow widths vary substantially along the curtain. The previous fine and microdetail components were removed: even subdued high-frequency footpoint modulation projected as regular radial green pinstripes in the live graded image. The final effect has no fine-frequency comb or dotted emission texture.

Local lower-lip height and vertical decay vary with the broad field. Traveling folds, regional activity, and billows remain continuous functions of time. Integer harmonics repeat smoothly at Iris's 3600-second frame-clock wrap. Separate stable night hashes determine geometry and display strength. The emission remains stationary in compass space with very weak world-position parallax.

## Milky Way and clouds

Aurora and the Milky Way enter the same scene-linear HDR sky before cloud compositing, exposure, bloom, and grading. The aurora adds optically thin emission. The Milky Way retains its current `MILKYWAY_BRIGHTNESS=0.28`; the earlier 0.5 calibration is obsolete. Aurora uses `AURORA_BRIGHTNESS=0.09`, multiplied by a 0.45 amplitude scale and stable night strength, followed by a smooth luminance shoulder at 1.1 and atmospheric extinction. The 0.45 scale is 25% lower than the preceding 0.60 candidate; its stronger continuous floor and broad billows also redistribute emission. This is an artistic relative calibration, not an absolute luminance measurement.

Opaque cloud compositing attenuates the entire background sky, including both celestial effects. The water sky fallback receives the gated aurora before its cloud reflection composite. Cloud blocking and water behavior require live scene verification in addition to the isolated shader preview.

## Validation limits

`shaderpack/tools/check_compile.py` checks generated shader stages offline. `shaderpack/tools/verify_aurora.py` compiles the current aurora GLSL and common helpers in an offscreen OpenGL context, records finite/nonnegative radiance, event gates, motion and wrap checks, and writes linear image data plus review PNGs. The preview omits the game scene, star catalogue, temporal antialiasing, exposure adaptation, and final game grading. Its PNGs are shader previews, not in-game screenshots. GPU timing from that harness measures its offscreen draw rather than Minecraft frame time or FPS; concurrent game/context scheduling can contaminate samples.

The original live capture under `work/aurora-live-first.png` is a rejection reference. The accepted billowing-sheet revision is recorded in `work/aurora-billows-final.png`; `work/aurora-soft-live.png` is the preceding pinstripe rejection reference. The final `night.glsl` SHA256 is `5933348c9e7858ad5f95fbc0ad8add7076721b6d109f10354f14d3d305cbe878` (2026-09-26). Passing compile and offscreen checks alone does not establish live visual acceptance. Current verification receipts, the four-mode gate matrix, and remaining measurement limits belong in `docs/aurora-validation.md`.

## Physical references

- University of Alaska Fairbanks Geophysical Institute: https://www.gi.alaska.edu/monitors/aurora-forecast
- NOAA Space Weather Prediction Center: https://www.swpc.noaa.gov/sites/default/files/images/u2/Aurora.pdf
