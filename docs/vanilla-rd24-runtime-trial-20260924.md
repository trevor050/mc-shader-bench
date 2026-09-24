# Same-session vanilla render-distance 24 trial, 2026-09-24

The opt-in BenchCam `rdtrial` adapter (`7f7af4e`) passed offline build and independent code review, then a guarded live 32 → 24 → 32 comparison. The active pack was `ClaudeBenchV4Art` (confirmed in `latest.log`), Iris was enabled for captures, DH's saved and effective radius stayed 512 chunks, and the game rendered at 1920×1080. Minecraft 26.2 / Iris 1.11.4 / DH 3.3.2 ran in the same process throughout. `rdtrial status` confirmed selected/effective/server radius 32/32/32, then 24/24/24, then 32/32/32 after each phase settled. No Video Settings screen was opened.

At the alpine pose `(2486.5,160,5.5)`, yaw -60/pitch 12, Overworld time 6000, each phase had at least 400 ticks of settled rendering after the distance change, with `waitchunks` before capture. At the sakura pose `(2678.5,110,677.5)`, yaw 0/pitch 15, time 7000, the same phase sequence followed. All figures below are BenchCam **render-thread** frame samples, not GPU Busy, whole-frame times, or displayed FPS.

| Pose | RD32 A1 median/p95 ms | RD24 B median/p95 ms | RD32 A2 median/p95 ms |
| --- | ---: | ---: | ---: |
| Alpine | 7.089 / 8.670 | 6.645 / 7.881 | 7.029 / 8.177 |
| Sakura | 5.880 / 6.350 | 5.558 / 5.937 | 5.741 / 6.158 |

Ten 1-second process telemetry samples were collected at the alpine pose in each phase. Medians:

| Metric | RD32 A1 | RD24 B | RD32 A2 |
| --- | ---: | ---: | ---: |
| Java process private bytes | 17.001 GiB | 15.261 GiB | 16.177 GiB |
| Process dedicated GPU allocation | 5.924 GiB | 4.629 GiB | 5.004 GiB |

The GPU allocation and private-byte controls did not fully return to A1 after 400 ticks, so their differences are evidence of a smaller observed footprint, not a stable savings estimate. System available physical memory was only about 2.2–2.3 GiB during these samples; a separate collector or additional high-pressure game experiment is not justified from this run.

Full-resolution [alpine A1](../harness/out/vanilla-rd24-runtime-trial-20260924/a1-rd32-alpine.png), [B](../harness/out/vanilla-rd24-runtime-trial-20260924/b-rd24-alpine.png), and [A2](../harness/out/vanilla-rd24-runtime-trial-20260924/a2-rd32-alpine.png) retained the snowy slope and terrain silhouettes. The fixed `(0,360)-(600,680)` snow crop had RGB mean absolute difference 1.88/255 for A1–B and 2.40/255 for A1–A2. Full-resolution [sakura A1](../harness/out/vanilla-rd24-runtime-trial-20260924/a1-rd32-sakura.png), [B](../harness/out/vanilla-rd24-runtime-trial-20260924/b-rd24-sakura.png), and [A2](../harness/out/vanilla-rd24-runtime-trial-20260924/a2-rd32-sakura.png) kept cliff, water, and tree silhouettes; its center crop `(450,350)-(1450,650)` differed 5.21/255 A1–B versus 5.45/255 A1–A2. A camera yaw sweep at 35 and 70 degrees, with 60 ticks at each angle in all three phases, showed no obvious terrain pop or missing geometry in the captured frames. The [70-degree crop triptych](../harness/out/vanilla-rd24-runtime-trial-20260924/sweep-y70-triptych.png) differed 2.29/255 A1–B versus 2.55/255 A1–A2 in `(350,300)-(1450,650)`. These are fixed-frame checks, not continuous-flight proof; clouds, lighting, and temporal history can affect pixel differences.

**Decision: retain RD24 as an opt-in candidate, leave saved RD32.** It repeatedly lowered render-thread medians and did not show RD16's visual failure in these scenes. Whole-frame display/GPU measurement and longer flight through different terrain remain open; the monitors were off, so PresentMon GPU Busy/present intervals were unavailable. The watchdog armed with empty stderr and later reported normal target exit. `rdtrial restore` returned 32, shaders were turned off, the player returned to the Nether portal in creative mode with mouse free and HUD on, and Minecraft closed normally. The original jar, `options.txt`, and Iris properties were restored byte-for-byte; all three hashes matched their pretrial copies, and the monitors were sent off again.
