# Overworld cloud-weather integration

This branch combines VL candidate `1122b32` and deferred2 candidate `79cdf714` on Art `b2b9ea6`. `CloudWeather`, `noise1`, and `cloudWeather()` move unchanged to `lib/cloud_weather.glsl`. Both paths share the three-argument `cloudShadow`; other callers retain the two-argument wrapper and its light-angle/altitude early returns. The VL march reuses one weather value per pixel, while deferred2 receives seven flat weather scalars from its full-screen vertex stage. Nether and End variants exclude those varyings.

Each candidate passed a separate guarded alpine RD12 per-pass A/B/A against Art, with no visible screenshot change:

| Pass | Art A1 / candidate B / Art A2 median (ms) |
| --- | --- |
| VL `composite` | 1.871 / 1.821 / 1.876 |
| `deferred2` | 0.966 / 0.948 / 0.966 |

These are per-pass observations, not whole-frame FPS results. The integrated source passes `py shaderpack/tools/check_compile.py` (183 stages, zero failures).

The combined guarded runtime gate then passed on 2026-09-24 at the same RD12 Overworld alpine pose. Art / combined / Art `composite` medians were **1.868 / 1.821 / 1.873 ms**; `deferred2` medians were **0.958 / 0.946 / 0.965 ms**. All three captures had 16 rows per frame, clean query drains, and no visible effect difference in full-resolution screenshots beyond animated clouds and terrain loading. An above-cloud y=700 Art / combined / Art control had identical `composite` medians (0.339 ms each), while `deferred2` was 0.687 / 0.675 / 0.690 ms. Full evidence and caveats are in the main repo's `harness/out/weather-combined-ab-20260924/findings.md`.

These are small pass-level gains in tested scenes. Profiler-off/on overhead, whole-frame FPS or GPU Busy, low-sun pixel comparisons, and long-run stability remain unmeasured.
