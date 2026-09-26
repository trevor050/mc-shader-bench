# Smooth emitter halos

## Cause and scope

The supplied soul-torch screenshot shows the glow around the emitter retaining coarse rectangular footprints. `sun_rays.glsl` previously reconstructed nine increasingly coarse scene mips with bilinear reads. A sparse bright source occupies only a few texels in those mips, so their piecewise linear tent shapes survive the 1:2:1 blur. The half-resolution glow targets were then linearly upsampled again in `final.glsl`.

The correction applies positive, normalized cubic B-spline reconstruction to the bloom kernel and to the half-resolution glow targets. The scene, held-item geometry, emitter texture, lighting model, bloom strengths, colour grading, and exposure settings are unchanged.

## Implementation

`lib/bloom_filter.glsl` implements the separable cubic basis and pairs adjacent positive weights into hardware bilinear taps, following the filtering principle described by Sigg and Hadwiger in [GPU Gems 2, chapter 20](https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-20-fast-third-order-texture-filtering).

These taps require linear sampling. The affected pack targets are `RGBA16F`; [Iris's upstream RenderTarget implementation](https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/targets/RenderTarget.java) selects linear/mipped-linear samplers and edge clamping for non-integer targets. The fixture uses that same filtering policy. Exact live sampler bindings remain uninspected.

For each bloom mip, the existing 1:2:1 blur at -0.75/0/+0.75 mip texels is folded into the cubic basis. Six weights on each axis become three bilinear pairs, so the 3x3 blur retains **nine texture reads per mip, 81 total**, rather than 36 reads per mip for a naive cubic implementation. Actual texture dimensions preserve the old screen-space blur radius for non-power-of-two frame sizes. Iris's [viewport uniforms](https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/uniforms/ViewportUniforms.java) refer to the full main render target even in a half-resolution pass; the fixture uses that same convention. Sampling clamps to the last available mip for small windows, and the pair weights retain unit gain.

`final.glsl` reconstructs the glow and bloom targets with four bilinear taps each. The sharp scene read remains unchanged. The direct source contribution remains `(1 - BLOOM_STRENGTH) * scene`, so the filter does not blur the world or the emitter core. The current buffer reuse and pass order are preserved.

The normalized linear bloom kernel is mathematically equivalent to evaluating the original nine blur taps with cubic reconstruction. Emitter/glare thresholding occurs on the complete reconstructed blur, with a convex quartic knee that has a continuous slope and retains the bright-core response. Applying a nonlinear threshold to the individual paired reads exposes their shifting grouping boundaries as rectangular seams, so that approach was rejected. Thresholded halo energy differs slightly from the old per-tap threshold; it is verified rather than claimed to be exactly conserved.

## Verification

The reproducible GPU harness uses the actual production bloom function and helper, compares against baseline `3035b5e`, and renders a rotated cyan emitter over a sharp checker background. It also checks uniform and black frames, isolates halo energy from the background, verifies the direct scene term, and compares the grouped kernel against a direct 36-fetch cubic reference with full-precision bilinear interpolation.

```powershell
py shaderpack/tools/verify_torch_halo.py
py shaderpack/tools/verify_torch_halo.py --size 1024x512 --source-size 80x160 --output work/torch-halo/large-source
py shaderpack/tools/verify_torch_halo.py --controls-only --size 320x180 --output work/torch-halo/small-window
py shaderpack/tools/verify_torch_halo.py --timing-only --size 3440x1369 --source-size 80x160 --output work/torch-halo/native-timing
py shaderpack/tools/check_compile.py composite4 final
```

RTX 4070, 1024x512 GPU fixtures, relative to the same source and unchanged bloom settings:

| Fixture | Halo energy retained | Outer-halo curvature p99 | Direct scene/core error |
| --- | ---: | ---: | ---: |
| 10x24 emitter | 90.82% | 35.09% lower | 1.26e-6 |
| 80x160 emitter | 93.03% | 19.81% lower | 2.21e-6 |

Energy isolates the extra halo by subtracting the source-free background. Curvature is the 99th percentile sum of absolute second differences, measured 24–180 pixels outside the rotated emitter boundary. Both fixtures pass the same retained-energy (90–110%), reduced-curvature, finite/nonnegative-output, and unchanged-core gates. Uniform and black frames produce identical before/after HDR output.

The float64 basis-pairing and normalization check has maximum error 1.78e-15. GPU full-precision bilinear comparison against the direct 36-fetch cubic reference has peak-relative errors 5.31e-6 and 3.03e-6; native hardware interpolation has larger small differences. This checks that the nine-read fold implements the intended linear filter, separately from the threshold response.

Receipts and synthetic paired previews are under `work/torch-halo/` and `work/torch-halo/large-source/`. At 320x180, uniform/black controls also pass with zero before/after HDR difference, exercising the last-mip clamp.

3440x1369 GPU-only timing on the final source uses a GPU-generated 80x160 emitter, `RGBA16F` HDR targets, three warmups, and eight alternating before/after samples. Median synthetic bloom cost is **0.202 → 0.507 ms**; halo reconstruction plus the common tonemap is **0.051 → 0.152 ms**, a combined increase of about **0.406 ms**. The naive 36-read cubic variant was rejected before this implementation. These isolate the affected work, omit sun rays/veil/weather and the rest of the game, and are not a whole-frame FPS result. Raw samples are in `work/torch-halo/native-timing/metrics.json`.

Final scoped offline compilation: 12 stages checked, 0 failed. `git diff --check` passes. The soft-knee scalar check is nonnegative, monotonic, bounded by source luminance, and exactly retains the original response above the knee.

The screenshot establishes the reported appearance, and the isolated GPU fixture establishes filter behaviour. The running game has not been reloaded, moved, or otherwise controlled. Live Iris linking, temporal motion, and the appearance in the user's full scene remain a separate acceptance gate. Synthetic timing is not a whole-game FPS result.
