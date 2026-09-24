# Vanilla render distance 24 trial, 2026-09-24

RD16 failed the snowy middle-distance visual gate in the alpine scene. A guarded intermediate RD24 run used the same MC 26.2 / Iris 1.11.4 / DH 3.3.2 stack, `ClaudeBenchV4Art`, 1920×1080, fixed alpine pose `(2486.5,160,5.5)` yaw -60 pitch 12, time 6000, and clear weather. The RD24 game settled 400 ticks, captured a full-resolution image, 300 render-thread samples, and 10 process/GPU-memory samples. The RD32 controls came from two separate guarded launches in the preceding RD16 trial at the same pose and settings. All watchdogs armed/canceled with empty stderr; monitors stayed off.

| Phase | Render-thread median / p95 | Dedicated GPU allocation | Java private bytes |
| --- | ---: | ---: | ---: |
| RD32 A1 | 6.719 / 7.874 ms | 4.980 GiB | 14.780 GiB |
| RD24 B | 6.010 / 7.805 ms | 4.669 GiB | 13.736 GiB |
| RD32 A2 | 6.479 / 8.552 ms | 5.300 GiB | 15.210 GiB |

The fixed snowy-left `(0,360)-(600,680)` crop of [RD24](../harness/out/vanilla-rd24-trial-20260924/b-rd24-alpine.png) differs from [RD32 A1](../harness/out/vanilla-rd16-trial-20260924/a1-rd32-alpine.png) by 2.63/255 mean RGB absolute value; the two RD32 controls differ by 1.09/255, while RD16 differed by 14.65/255. The RD24 difference is small at full resolution and does not show RD16's obvious coarse snow slope. The central horizon remains continuous. This is a preliminary still-image pass, not proof of invisible transitions during movement.

A second RD24 image at the fixed [sakura valley](../harness/out/vanilla-rd24-trial-20260924/b-rd24-sakura.png) pose `(2678.5,110,677.5)` yaw 0 pitch 15, time 7000, was compared with a subsequent [RD32 control](../harness/out/vanilla-rd24-trial-20260924/a-rd32-sakura.png). The cliff, water, and tree silhouettes appear consistent in full-resolution crops. Cloud and lighting changes are substantial between the two launches, and there was no return RD24 control at this pose; do not use that pair to claim pixel parity.

**Status: RD24 is a candidate, not promoted.** Its resource and render-thread samples are lower than both RD32 controls, but separate launches and short windows allow loading/thermal drift. These measurements are not whole-frame GPU Busy, presentation intervals, or on-screen FPS. A continuous camera/flight check, a second settled scene A/B/A, and display-on whole-frame measurements are needed before changing the saved RD32 setting. The player was restored to the Nether portal in creative mode, Overworld time reset to 6000, shaders disabled, and Minecraft exited normally. The original options/Iris files were restored byte-for-byte; monitors were sent off again.
