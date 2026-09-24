# Vanilla render distance 16 trial, 2026-09-24

The pinned ShaderBench setup uses vanilla render distance 32, DH render radius 512 chunks, and the Art shader's 8,192-block LOD distance. A guarded 32 → 16 → 32 check asked whether the expensive full-detail vanilla radius could shrink without losing the Overworld view. Each phase ran in a separate Minecraft process with the same Art pack, 1920×1080 capture, fixed alpine pose `(2486.5,160,5.5)`, yaw -60, pitch 12, time 6000, clear weather, 400 settling ticks, 300 render-thread samples, and 10 passive process/GPU-memory samples. Each verified-PID watchdog armed and canceled normally with empty stderr. The monitors stayed off.

| Phase | Render-thread median / p95 | Dedicated GPU allocation | Java private bytes |
| --- | ---: | ---: | ---: |
| RD32 A1 | 6.719 / 7.874 ms | 4.980 GiB | 14.780 GiB |
| RD16 B | 5.698 / 6.146 ms | 4.420 GiB | 12.820 GiB |
| RD32 A2 | 6.479 / 8.552 ms | 5.300 GiB | 15.210 GiB |

The render-thread and memory reductions are plausible but **RD16 fails the visual gate**. At full resolution, the snowy middle-distance slope and trees at the left of [A1](../harness/out/vanilla-rd16-trial-20260924/a1-rd32-alpine.png) flatten into a coarse, patterned DH-looking surface in [B](../harness/out/vanilla-rd16-trial-20260924/b-rd16-alpine.png), and the detail returns in [A2](../harness/out/vanilla-rd16-trial-20260924/a2-rd32-alpine.png). The fixed `(0,360)-(600,680)` snowy crop has mean RGB absolute difference 14.65/255 for A1–B and 1.09/255 for A1–A2. The far mountain skyline survives, but that does not compensate for the obvious middle-distance change. The village crop varied through the A controls, so it is not used as the rejection criterion.

The figures above are process allocations and render-thread durations, not whole-frame GPU Busy, presentation intervals, or on-screen FPS. A 10-sample phase cannot rule out loading or thermal drift. No additional RD12 cut is warranted after RD16 fails. The player was returned to the Nether portal in creative mode, shaders were disabled, Minecraft exited normally, and the original options/Iris files were restored byte-for-byte with render distance 32. Monitors were sent off again. No live setting was promoted.
