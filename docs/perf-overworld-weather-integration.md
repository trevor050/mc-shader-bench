# Overworld cloud-weather integration

This branch combines VL candidate `1122b32` and deferred2 candidate `79cdf714` on Art `b2b9ea6`. `CloudWeather`, `noise1`, and `cloudWeather()` move unchanged to `lib/cloud_weather.glsl`. Both paths share the three-argument `cloudShadow`; other callers retain the two-argument wrapper and its light-angle/altitude early returns. The VL march reuses one weather value per pixel, while deferred2 receives seven flat weather scalars from its full-screen vertex stage. Nether and End variants exclude those varyings.

Each candidate passed a separate guarded alpine RD12 per-pass A/B/A against Art, with no visible screenshot change:

| Pass | Art A1 / candidate B / Art A2 median (ms) |
| --- | --- |
| VL `composite` | 1.871 / 1.821 / 1.876 |
| `deferred2` | 0.966 / 0.948 / 0.966 |

These are per-pass observations, not whole-frame FPS results. The integrated source passes `py shaderpack/tools/check_compile.py` (183 stages, zero failures). Its combined runtime result remains unmeasured.

For the combined gate, compare Art A1, this integrated branch B, and Art A2 at the same guarded RD12 alpine pose, game time, weather, resolution, DH state, profiler build, and reload settling interval. Capture complete GL timer rows for both `composite` and `deferred2`, plus same-pose full-resolution screenshots. Check both pass medians and p95 against the Art bracket and inspect the screenshots before promoting the combined branch.
