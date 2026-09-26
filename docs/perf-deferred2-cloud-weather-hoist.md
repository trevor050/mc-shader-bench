# Deferred2 cloud weather hoist candidate

This candidate moves Overworld `cloudWeather()` evaluation from every eligible deferred fragment to the full-screen vertex stage. The inputs (`worldDay`, `worldTime`, `rainStrength`, and `thunderStrength`) are uniform for the draw. The seven resulting scalars travel through `flat` varyings, then feed the same `cloudShadow` implementation. The cloud shadow field and all weather equations are unchanged.

`cloudWeather()` used eight `noise1()` evaluations, each using two sine operations, plus weather remapping per eligible fragment. The vertex stage evaluates it once for each full-screen vertex. Nether and End variants do not carry the added varyings. Other cloud-shadow callers retain the two-argument wrapper, with its existing early returns.

## Compile evidence

`py shaderpack/tools/check_compile.py` checked all 183 generated shader stages across Overworld, Nether, and End with zero failures.

## Paired runtime plan

Use the current guarded Overworld alpine RD12 pose and identical pack, camera, game time, weather, resolution, DH state, and profiler build for Art A1, candidate B, and Art A2. Warm each reload consistently before capture, collect complete per-pass GL timer rows, and compare the `deferred2` median and p95 against the A bracket. Capture a same-pose screenshot with weather and animation held stable for image comparison. Repeat at a high alpine camera position above the 560-block cloud-shadow cutoff as a scene-sensitive control; its cloud-shadow work should remain an early return. Attribute any result only to the `deferred2` pass timing, not total frame time or FPS.

## Integration note

VL candidate `1122b32` adds the same `cloudShadow(vec3, vec3, CloudWeather)` overload and two-argument wrapper in `clouds.glsl`. The API is compatible. Its edit overlaps this candidate's `clouds.glsl` hunk, so combine the file changes during integration rather than expecting both commits to cherry-pick cleanly. Keep the new `cloud_weather.glsl` include in place so both vertex and fragment stages share one definition.
