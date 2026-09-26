# Performance profiles

The visual reference is commit `55a002e`. Ultra is the default and keeps its accepted sample budgets. The candidate removes repeated work in Ultra and uses progressively cheaper compiled kernels for High, Medium, and Low. Potato uses Minecraft's lightmap with a short sRGB pipeline and analytical sky/cloud alternatives.

These are implementation choices and acceptance targets, not measured performance claims. Final profile selection requires immutable source snapshots, the actual Iris-selected pack, controlled GPU frame measurements, and matched visual captures.

## Public quality settings

Named Iris profiles set `PERFORMANCE_PROFILE` and the following real controls. Artistic settings remain independent.

| Control | Ultra | High | Medium | Low | Potato |
|---|---:|---:|---:|---:|---:|
| `PERFORMANCE_PROFILE` | 4 | 3 | 2 | 1 | 0 |
| Shadow resolution | 3072 | 2048 | 2048 | 1024 | 1024, unused |
| Shadow distance | 192 | 160 | 128 | 96 | 80, unused |
| Shadow filter samples | 12 | 8 | 6 | 4 | 0 |
| Water reflection steps | 24 | 18 | 12 | 0 | 0 |
| Volumetric budget | 20 | 14 | 10 | 6 | 0 |
| Nether smog steps | 12 | 9 | 6 | 4 | 0 |

Potato explicitly turns off temporal anti-aliasing, voxel light, volumetric lighting, and screen-space water reflections in the stored profile options, matching its compiled pipeline. Low turns off screen-space water reflections. Higher profiles restore the supported features. Clouds remain functional through the analytical Potato sky path; their toggle still controls that layer.

`PERFORMANCE_PROFILE` is internal to the named preset selector. Potato cannot allocate the disabled expensive features by manually changing their numeric budgets or toggles; choose Low or higher to use them. The menu describes this restriction. The named selector reports Custom when a profile-owned setting is changed.

`SHADOW_MAP_RES` and `SHADOW_DIST` now also drive Iris's `shadowMapResolution` and `shadowDistance` directives. They previously changed shader calculations while the real Overworld shadow map/range remained hardcoded at 3072/192.

## Compiled kernels

`lib/performance_quality.glsl` supplies internal constants through concrete preprocessor branches. They have no Iris allowed-value annotations and are not independent user options. GLSL's preprocessor does not accept a C-style ternary expression in a `#if`, so these values must remain concrete definitions.

| Kernel | Ultra | High | Medium | Low | Potato |
|---|---:|---:|---:|---:|---:|
| SSAO samples | 8 | 6 | 4 | 2 | 0 |
| Shadow blocker taps | 6 | 4 | 3 | 0 | 0 |
| Glossy reflection steps/refinement | 28/6 | 20/5 | 14/4 | 0/0 | 0/0 |
| Water wave octaves | 4 | 3 | 2 | 1 | 0 |
| Cloud light quality | 3 | 3 | 2 | 1 | 0 |
| Cloud march stride multiplier | 1.0 | 1.0 | 1.35 | 1.8 | analytical |
| Cloud detail quality | 2 | 2 | 1 | 1 | analytical |
| Sky view and horizon samples | 12 | 12 | 8 | 8 | analytical |
| Near/far volumetric samples | 16/10 | 12/8 | 8/5 | 4/3 | 0/0 |
| End storm samples | 16 | 12 | 8 | 4 | 0 |
| Sun-ray samples | 48 | 32 | 20 | 0 | 0 |

Manual `VL_STEPS` changes scale the tier's actual near/far/storm sample budget relative to its named default. A zero budget has no history consumer. Lower reflection tiers keep inexpensive environment/Fresnel alternatives instead of tracing zero steps and pretending they hit the scene.

The first candidate keeps the voxel grid at 128x64x128 for all field-enabled tiers. A smaller grid is a separate measured candidate because it changes the spatial support of colored light.

## Render and color contracts

Ultra through Low retain the HDR render graph and its buffer lifetimes. Cloud radiance/history remains separate from volumetric history; c3 preserves normalized cloud depths until composite2. Do not use c8's previous cloud distances after the volumetric pass has reused it.

Potato disables cloud march/history, volumetric march/history, TAA, glare/bloom, shadow rendering, and shadow compute in all dimensions. It has no voxel/light-field image declarations. The remaining surface, forward-water, deferred2, composite2, weather, and final paths carry sRGB:

- Opaque and forward geometry sample the actual Minecraft lightmap.
- Deferred2 copies opaque sRGB to c4 for forward refraction. Sky pixels combine the cheap linear sky/cloud/night model once and convert once to sRGB.
- Composite2 evaluates one analytical depth/fog expression. It reads no c3/c7/c8/c9/c11 history and keeps the hand depth guard.
- Final directly handles sRGB scene/weather and its mild grade. It must not read c5 exposure state or c3/c7 glare/bloom data, whose producers are disabled.

The Potato clouds draw only on sky pixels. Geometry therefore occludes them directly; there is no half-resolution layer across players or held items. Advanced foreground cloud volumes are a deliberate Potato simplification.

Ultra exact work removal includes vertex-stage cloud weather/deck-state reuse, an early angular rejection for rainbows, shared sky scattering density integration, and uniform phase/angle hoists. These hypotheses still require live timing.

## Installed Iris evidence

The integration was checked against installed Iris 1.11.4, `iris-fabric-1.11.4+mc26.2.jar`, SHA256 `f1f7ab57c974d193ba33aa285864a0ded949216f402116fceaf4dc7739b4dd7c`.

Local `javap -c -p` inspection established:

- `ShaderPack.lambda$new$8` checks the disabled-program basename before includes and `JcppProcessor.glslPreprocessSource`. This applies to `.csh` as well as graphics stages.
- `ProgramSet.readComputeSource` returns null for a disabled/missing compute source; it does not create a compute program from an empty feature toggle.
- `PropertiesPreprocessor` receives numeric option values, allowing the profile-specific `#if` property branches.
- GLSL macro expansion occurs before directive collection, so the real shadow resolution/distance aliases resolve to numeric constants.

Iris parses menu screens, slider lists, profiles, and required feature flags from the raw property file. Those declarations cannot depend on a profile `#if`. The menu therefore stays static, with explicit Low-or-higher restrictions for Potato's disabled effects. Required compute/custom-image capabilities remain pack-wide even when Potato allocates no images and dispatches no compute work.

This proves source routing, not live draw/dispatch counts. The benchmark must still confirm no shadow/compute/pass cost remains in Potato and validate profile switches and dimension transitions.

## Acceptance gates

Initial targets are at least 15% lower GPU frame time for Ultra versus `55a002e`, then at least 25% lower GPU time per step through High, Medium, and Low. Potato aims for frame-time overhead within 10-15% of shaders off where the CPU floor permits. Targets may require additional measured candidates; the first matrix is not success certification.

Keep the repaired cloudy horizon, player/DH-water depth, held-ice illumination, all four aurora visibility modes, and coherent Nether/End rendering. Inspect full-resolution horizon crops and motion, not only downsampled contact sheets. Profile compilation is a syntax/type gate and cannot establish performance, Iris-side linking, or visual acceptance.
