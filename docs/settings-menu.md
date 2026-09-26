# Native Iris settings menu

ClaudeBench uses Iris's native two-column shader settings screen. The menu has five explicit performance profiles, three universal quick controls, and short pages organized around player choices. Artistic and comfort values are independent from the profile budgets.

The source defaults identify as **Ultra**. Profiles restore rendering feature switches as well as their sampling budgets. Changing a profile-owned budget or switch makes Iris identify the selection as Custom; changing a color or weather preference does not.

## Menu map

| Page | Player controls |
| --- | --- |
| Root | Profile, clouds, foliage animation, saturation; category links |
| Performance and Quality | Temporal anti-aliasing and colored block light; shadow resolution, distance, filtering and softness; cloud range; atmospheric and reflection samples |
| Lighting | Sunlight, moonlight, block light, light source color, emissive brightness, cloud shadow brightness, light shafts |
| Cave Atmosphere | Cave sunbeams, colored air glow, depth fog |
| Sky and Weather | Biome variation, vivid sunset events, sunset palette, atmospheric haze; cloud, night and weather pages |
| Cloud Appearance | Formation, coverage, drift, nearby mist, moonlit rims, iridescence, dusk fill light |
| Night Sky | Aurora switch, occurrence mode and brightness; Milky Way brightness; fireflies |
| Weather Effects | Rain ripples, landscape lightning illumination, storm darkness |
| Water | Terrain reflections, murkiness, surface haze, caustics, shore foam, storm waves |
| Color and Brightness | Saturation, contrast, vibrance, dusk vibrance; brightness and glow pages |
| Image Brightness | Overworld, dusk, cave, Nether and End eye adaptation |
| Bloom and Glare | Bloom, glare, emitter glow and threshold, low-sun glare, sunlight veil, ray glow |
| World Effects | Foliage animation and sway, lava heat; cave surface page |
| Cave Surfaces and Motes | Damp rock, ore glints, sculk glow, soul motes |
| Visual Comfort | Shortcuts for foliage/cloud movement, landscape lightning illumination, lava heat, sunlight veil and glare |
| Potato Settings | A focused set of 16 sky, cloud, water, color, and foliage controls that remain active on Potato |

There are 71 unique controls across 15 subpages. Comfort and Potato duplicates are deliberate shortcuts to the same option values. No screen uses `*`, so diagnostic options and implementation constants cannot leak into the menu.

Sliders are reserved for intensity, distance, and sampling budgets. Cloud formation, aurora occurrence, biome variation, sunset events, shadow resolution, and on/off switches use discrete buttons. Every visible option and category has an English label and tooltip. Tooltips describe dependencies, zero/off behavior, and qualitative performance costs without claiming measured frame-rate gains.

## Profile contract

| Budget | Ultra | High | Medium | Low | Potato |
| --- | ---: | ---: | ---: | ---: | ---: |
| Internal kernel tier | 4 | 3 | 2 | 1 | 0 |
| Shadow resolution | 3072 | 2048 | 2048 | 1024 | 1024, pass skipped |
| Shadow distance | 192 | 160 | 128 | 96 | 80, pass skipped |
| Shadow filter samples | 12 | 8 | 6 | 4 | 0 |
| Water reflection samples | 24 | 18 | 12 | 0 | 0 |
| Light shaft budget | 20 | 14 | 10 | 6 | 0 |
| Nether smoke samples | 12 | 9 | 6 | 4 | 0 |
| Temporal anti-aliasing | On | On | On | On | Off |
| Colored block light | On | On | On | On | Off |
| Volumetric light shafts | On | On | On | On | Off |
| Water terrain reflections | On | On | On | Off | Off |
| Clouds | On | On | On | On | Simplified, On |

Potato skips shadow rendering, voxel images and compute, cloud/VL temporal passes, the TAA resolve, and bloom/glare. It keeps the deferred lighting copy, analytic fog, final display resolve, the native Minecraft lightmap, a simplified layered sky, and forward water.

Iris 1.11.4 reads screen layouts, profiles, sliders, and required features from the original properties file, rather than the preprocessed file. Consequently native menus cannot hide controls by quality tier. This was verified in the installed jar's `ShaderProperties` bytecode as well as the upstream source. Conditional screen definitions would silently use the last definition on every tier, so none are present.

The root controls work on every profile. The Potato Settings page provides only controls its simplified renderer consumes. Advanced effects that Potato omits explicitly state their Low-or-higher requirement; sun ray glow requires Medium or higher. The Potato preset sets unavailable rendering switches to Off. Applying a higher preset restores the corresponding feature switches. Manually forcing an unsupported switch on while the internal Potato tier remains selected does not replace that tier's immutable renderer; select a higher named preset first.

The existing framebuffer sizes, custom textures, blending configuration, and custom weather/climate uniforms remain intact. The Potato branch removes voxel images and disables expensive source families. Compute/image capability requirements remain pack-wide because Iris parses those requirements before property preprocessing; Potato is not a claim of compatibility with older graphics hardware.

## Audited exclusions and fixes

- `MIN_LIGHT` has no renderer consumer. It is excluded.
- `CLOUD_HEIGHT` only feeds the legacy `applyClouds` helper, which the active volumetric renderer does not call. It is excluded.
- Voxel dimensions, light diffusion constants, LOD distance, debug visualizations, and exposure safety clamps remain internal invariants.
- The previously declared shadow resolution and distance affected shader math while Iris allocated hardcoded values. The profile architecture now connects Iris's actual shadow directives to the settings.
- Boolean discovery requires a real standalone `#ifdef` or `#ifndef` reference in Iris 1.11.4. Combined `#if defined(...)` guards alone made water reflections and light shafts silently disappear from the menu. Their consumers now retain recognizable guards.
- Shadow sample values cannot exceed the 12-entry Vogel table. The invalid 16-sample setting was removed.
- The original `SATURATION` reference was confined to an unused legacy tonemapper. The final display path now consumes saturation on every tier, normalized to preserve the accepted default. Potato also consumes a scaled contrast setting and both water murkiness/surface-haze settings.

## References

Installed reference metadata was inspected read-only from the ShaderBench instance: Complementary Unbound and Reimagined r5.9.3, BSL v10.1.8, Photon v1.3b, Bliss v2.1.2, and Solas v3.7b. The useful common patterns were an explicit native profile selector, separate performance and appearance pages, short subject pages, translated choice values, and dependency/impact tooltips. No reference shader code or menu copy was imported.

## Verification

Run from the repository root:

```powershell
py shaderpack/tools/verify_settings_menu.py --report work/menu-audit.json
```

The verifier discovers the reachable shader include graph and runs the installed Iris 1.11.4 `OptionAnnotatedSource`, `OptionSet`, `ProfileSet`, and `PropertiesPreprocessor` classes through the local Java runtime. It checks option domains, actual parsing, labels/tooltips, screen reachability and density, profile membership/default matching, static layout semantics, Potato program/image removal, and preservation of runtime texture/weather/framebuffer properties. It rejects conditionals around menu or capability properties because Iris does not honor them.

For another installation, pass `--iris-jar` and `--libraries`. `--source-only` runs a portable source model and clearly labels the evidence as weaker than actual Iris parsing. Java and the installed Iris dependency libraries are required for the default path. The verifier reads installed jars without editing them and writes Java intermediate files only into a temporary directory.

This gate establishes parser and static menu correctness. It does not establish in-game presentation, option efficacy, visual quality, profile transition behavior, or measured performance. The lead performs the separate native menu and renderer checks in the game.
