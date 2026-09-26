# V4 framebuffer lifetime reuse

## Change

Before this change, the half-resolution `RGBA16F` target `colortex10` held transient volumetric-light / smog radiance in `composite`, then bloom in `composite4`. The Overworld first writes cloud radiance to `colortex7` in `deferred`, then consumes it in `deferred1` to update persistent cloud history `colortex9`. `composite` runs later and writes VL / smog radiance; `composite1` consumes it to update persistent history `colortex11`. `composite4` runs after that history update, and `final` is the only later bloom consumer. This change uses `colortex7` for the later VL / smog radiance and bloom outputs. No shader reads cloud-march contents after `deferred1`, and no shader reads VL / smog radiance after `composite1`, so the target is reused across these ordered lifetimes. Each producer writes every output pixel.

Before removal, both targets had the same effective dimensions (`0.5 x 0.5`) and format (`RGBA16F`), so redirecting the later images preserves storage precision, texel grid, sample coordinates, and values. The persistent history targets `colortex9` and `colortex11` remain separate and untouched. `colortex10` used the default per-frame clear policy even though both `vl_march` and `sun_rays` write every output pixel, including all early-return branches; removing the target also removes those redundant clears.

## Pass / lifetime proof

| Pass | `colortex7` | Other relevant targets |
| --- | --- | --- |
| `deferred` | cloud march writes it | cloud distance to `colortex8.r` |
| `deferred1` | cloud temporal pass reads it | writes persistent cloud history `colortex9` |
| `deferred2` | not referenced | reads `colortex8.g` and `colortex9` for cloud upsample |
| translucent geometry | not referenced | reads cloud history `colortex9` |
| `composite` | later VL/smog march overwrites it | writes scene distance to `colortex12.r` |
| `composite1` | reads the new VL/smog radiance | reads `colortex12.r`, writes persistent history `colortex11` |
| `composite2` / `composite3` | not referenced | fog then TAA; history and scene-distance targets are unchanged |
| `composite4` | bloom output overwrites it after VL history is updated | glare/rays remain in `colortex3` |
| `final` | reads bloom | final color composition |

Iris runs `deferred` programs in numeric order before translucent geometry, then `composite` programs in numeric order after the world render. The End disables `composite` and `composite1`, but its later `composite4` bloom write and `final` read remain paired. In the Nether cloud `deferred` / `deferred1` are disabled; smog `composite` / `composite1` remain enabled and complete before bloom `composite4`. Overworld uses the full cloud -> VL -> bloom sequence. A repository-wide shader scan on this candidate found only the described `colortex7` consumers. `vl_march` assigns both MRT outputs on every control-flow path, including the eye-in-water early return (distance is assigned first). `sun_rays` assigns both outputs at the end of `main`; its early returns are in helper functions and return values, not fragment exits.

This is an attachment lifetime optimization only. It does not reduce shader instructions or establish an FPS improvement. Iris runtime visual and memory confirmation is still required before promotion.

## Estimated storage saved

At 3840x2160 output, a half-resolution target is 1920x1080 pixels. `RGBA16F` is 8 bytes per pixel. Iris maintains a main and alternate texture for each colortex target, so removing `colortex10` saves `1920 * 1080 * 8 * 2 = 33,177,600` bytes, or about **31.64 MiB**, excluding driver allocation/alignment overhead. Neither transient target enables mipmaps. This estimate follows Iris's lazy `getOrCreate` allocation, paired main/alternate textures, and clear-pass builder skipping a render target that has never been created. All shader declarations, samplers, size directives, and MRT writes for index 10 are removed here. It is a source-derived estimate, not a runtime VRAM measurement.
