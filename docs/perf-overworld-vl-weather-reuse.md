# Overworld volumetric-light cloud-shadow candidate

`program/vl_march.glsl` evaluates up to 16 near and 10 far samples for each half-resolution pixel. Each sunlit sample may call `cloudShadow`, which takes up to five cumulus-density taps. Before this candidate, every call also computed `cloudWeather()`, although that function depends only on frame uniforms and has the same result at every point on the ray.

`lib/clouds.glsl` now offers a `cloudShadow` overload that accepts a precomputed `CloudWeather`. The original two-argument entry point remains for other passes, including its altitude and light-angle short circuits. The Overworld VL pass computes weather once per pixel when direct cloud shading is enabled and shares it across near and far samples. Its near loop also skips cloud shading when `shadowVisibility` returns zero: multiplication by that zero would erase the cloud result. Mist ambient and extinction are still evaluated for these samples.

The sample positions, shadow-depth reads, cloud-density reads for contributing samples, scattering equations, target formats, and target dimensions are unchanged. Floating-point results should match except for possible compiler evaluation-order differences. This candidate is compile-checked, but GPU timer and visual A/B validation are still required; the driver may already hoist some uniform weather work.

## Guarded A/B

Compare Art commit `fe4da1b` with this commit at the same settled alpine RD12 pose, time, weather, resolution, render distance, and shader settings. Capture the `composite,composite` GPU timer over repeated settled frames; also compare full-resolution screenshots at that pose and a low-sun scene with visible terrain shadows and valley mist. Try a high-altitude view, underwater view, and night to check the fast paths. Report medians and spread, not a single FPS observation. Revert the candidate if the timer does not improve outside run-to-run noise or the image shows a visible change.
