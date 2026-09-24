# Reuse `colortex8` for volumetric scene distance

## Change

The half-resolution scene-distance output from `composite` now writes to `colortex8.r`, and the volumetric temporal and bilateral-upsample passes read that channel. The separate half-resolution `R32F` `colortex12` target, its explicit size, and its format declaration are removed. `colortex8` remains `RG32F`; no value is quantized or recomputed differently.

## Pass-order proof

| Pass | `colortex8` lifetime | Other relevant targets |
| --- | --- | --- |
| `deferred` cloud march | Writes cloud distance to `.r` and scene distance to `.g` on every pixel | Writes cloud radiance to `colortex7` |
| `deferred1` cloud temporal | Reads `.r` for cloud reprojection | Reads `colortex7`, writes persistent history `colortex9` |
| `deferred2` cloud upsample | Reads `.g` for edge-aware upsampling and `.r` for lightning position | Reads `colortex9` |
| translucent geometry | No `colortex8` access | Reads persistent cloud history `colortex9` |
| `composite` volumetric march | Overwrites `.r` with scene distance on every pixel | Writes volumetric radiance to `colortex7` |
| `composite1` volumetric temporal | Reads `.r` for reprojection | Reads `colortex7`, writes persistent history `colortex11` |
| `composite2` fog | Reads `.r` for bilateral upsampling | Reads persistent volumetric history `colortex11` |
| later passes / next frame | No old cloud-distance value is needed; next `deferred` cloud march rewrites both `.r` and `.g` | Histories `colortex9` and `colortex11` stay separate and persistent |

The Overworld follows the complete sequence. In the Nether, `deferred` is disabled, while the `DIM_NETHER` `composite` and `composite1` stubs run the smog march and temporal accumulation; they use only the newly written `.r` scene distance. In the End, `composite` is disabled and the `DIM_END` temporal shader writes its invalid-history sentinel before reading any distance; End fog excludes the volumetric upsample path. The End's cloud march may still write its sentinel to `colortex8`, which is harmless because no later pass consumes it.

Both cloud march and volumetric march cover the full half-resolution viewport and assign every MRT output on all paths. The volumetric march assigns its distance before its underwater, End, or disabled-effect returns. Reuse therefore does not depend on a clear value or stale contents. `colortex8` keeps its existing `RG32F` precision, dimensions, and clear policy; the `.r` value is the same float previously written to `colortex12.r`. The removed `colortex12` used the default per-frame clear policy, so its redundant clear and attachment go away.

## Estimated allocation saved

Iris allocates main and alternate textures for a referenced colortex target. Removing `colortex12` saves its `R32F` storage twice at the configured half resolution, excluding driver alignment:

| Output size | Half-resolution pixels | Saved bytes | Saved MiB |
| --- | ---: | ---: | ---: |
| 3440×1369 | 1720×684 = 1,176,480 | 9,411,840 | 8.98 |
| 3840×2160 (4K UHD) | 1920×1080 = 2,073,600 | 16,588,800 | 15.82 |

This is a source-derived allocation estimate, not a runtime VRAM measurement or FPS claim.
