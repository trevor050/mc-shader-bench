# Overworld shadow entity/depth interval investigation

Scope: Art `b2b9ea6`, MC 26.2, Iris 1.11.4, Sodium 0.9.2. The reported `shadow,entities_depth_copy` query interval is about 1.3–1.5 ms at the guarded Overworld pose. This work did not run the game, so the split below is source/bytecode analysis and an offline-built measurement candidate, not a measured attribution.

## What the old interval contains

The old query starts at the first `_viewport` call in `ShadowRenderer.renderShadows` (Iris bytecode offset 814) and ends just before its second `ChunkSectionsToRender.renderGroup` call (offset 1280). Inside that span the installed Iris jar executes:

| Offset | Work |
| --- | --- |
| 814–932 | Shadow viewport, entity frustum setup, `LevelRenderState.reset()` |
| 939–1079 | Conditional `extractVisibleEntities` or player/vehicle extraction |
| 1111 | `renderEntities` submits entity render nodes; it does not itself draw them |
| 1170 | Conditional `extractVisibleBlockEntities` via Sodium |
| 1187 | `renderBlockEntities` submits block-entity render nodes |
| 1211 | `FeatureRenderDispatcher.renderAllFeatures` renders submitted nodes |
| 1218 | `RenderBuffers.endFrame` |
| 1223 | `copyPreTranslucentDepth` |
| 1280 | Translucent terrain draw starts; old query ends here |

`ShadowRenderTargets.copyPreTranslucentDepth` uses a framebuffer depth blit when `translucentDepthDirty` is true, otherwise it uses `DepthCopyStrategy.fastest(false)`. The call is unconditional in `renderShadows`; the chosen copy path is dynamic. Art samples both `shadowtex0` and `shadowtex1` for translucent shadow handling, so blindly removing this copy is not justified.

The CPU builds render state and enqueues GL work inside a `GL_TIME_ELAPSED` interval. GPU timer results can include idle time while CPU extraction/submission runs. The reported 1.3–1.5 ms therefore cannot be assigned to entity fragment shading, a depth blit, or GPU Busy from the existing rows.

## Light-field relationship

Art `program/shadow.glsl` returns from `voxelize` unless `renderStage` is terrain solid, cutout, cutout mipped, or translucent (lines 66–67). Its `imageStore(voxelImg, ...)` occurs in the vertex shader before shadow projection and uses world block coordinates, independent of shadow-map pixel resolution. The pack enables entity and block-entity shadow drawing in `shaders.properties` (lines 19–20), but those render stages do not directly populate the voxel light field. Entity and block-entity *shadows* can still affect the image, so disabling them is a diagnostic toggle or a quality tradeoff, not an equivalent final change.

Art declares a 3072-pixel Overworld shadow map and 192-block shadow distance in `program/deferred.glsl` (lines 450–451). Reducing the map to 2048 pixels would reduce a full 32-bit depth copy from 36 MiB to 16 MiB, while leaving the 128×64×128 voxel image dimensions and vertex image writes unchanged. Shadow-map edge quality and translucent shadow detail require visual review. This is a candidate only if the finer profiler shows `depth_copy` or shadow rasterization contributes materially.

## Measurement extension

The isolated BenchCam patch divides the old interval into `entity_setup_extract`, `entity_submit`, `block_entity_extract`, `block_entity_submit`, `feature_render`, `buffer_end_frame`, `depth_copy`, and `translucent_setup`. Each existing GPU query row also gains `cpu_wall_ns`, measured on the render thread between query begin and end. The patch compiles with the pinned Iris jar; Mixin injection and profiler overhead still need a guarded runtime smoke. Mixin selectors use exact method descriptors and `require=1`, so a changed Iris callsite fails startup instead of silently producing mislabeled data.

The new `cpu_wall_ns` is wall time, not CPU Busy. A long extraction/submission CPU interval indicates a render-thread delay; a long `depth_copy` GPU interval with a short CPU interval suggests GPU copy cost or queued GPU work. Neither paired number alone proves that the GPU was idle. Use per-frame PresentMon GPU Busy when available or a GPU timeline capture for that distinction.

## Test plan for the game owner

1. Guarded profiler smoke at the same fixed Art Overworld pose. Expect 14 shadow rows per complete frame when translucent terrain renders. Require zero drops/errors, exact phase order, and a profile-off/profile-on frame-time comparison to bound the added query overhead.
2. Compare medians and tails for all eight new subphases, paired `gpu_ns` and `cpu_wall_ns`. Record shadow entity/block-entity counts if available. Do not sum pass medians as whole-frame GPU Busy.
3. If `depth_copy` dominates, test an isolated Art 3072→2048 shadow-map resolution candidate in Art/candidate/Art order. Keep shadow distance, voxel size, camera, time, and render/DH distances fixed; check hard/soft shadow edges, water/ice tint and absorption, and voxel-light spread visually. Measure whole-frame GPU Busy and frame intervals, not just query deltas.
4. If `entity_setup_extract` or node submission dominates, use `shadowEntities=false` and `shadowBlockEntities=false` separately as diagnostic controls. Do not promote either without checking entity/block-entity shadow quality. If `feature_render` or `buffer_end_frame` dominates, inspect render-node and draw-call counts before altering the shader.
