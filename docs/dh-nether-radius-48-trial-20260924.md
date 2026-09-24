# Nether radius 48 versus 64, 2026-09-24

The opt-in BenchCam trial gained a validated `dhtrial radius <chunks>` command so a radius could change without restarting Minecraft. The saved DH config stayed at 512. The selectable-radius code passed an independent static review and a clean offline Gradle build.

A guarded Minecraft 26.2 / Iris 1.11.4 / DH 3.3.2 test used V4 Art at the fixed Nether portal pose `(406.99,76,360.61)`, yaw -55.5, pitch 22, 1920×1080 capture, vanilla render distance 32, monitors off. The radius order was 64 → 48 → 64. Each phase settled for 400 game ticks before a screenshot and `framestats 300`; separate 10-second passive telemetry windows followed. `dhstatus` readbacks were `active=64/48/64`, `true=512`, and `api=64/48/64` with no failure or pending cleanup. All telemetry samples had empty errors.

| Phase | Render-thread median / p95 | Process dedicated GPU | Java private |
| --- | ---: | ---: | ---: |
| 64 A1 | 1.898 / 2.187 ms | 3.452 GiB | 12.035 GiB |
| 48 B | 1.834 / 2.117 ms | 3.331 GiB | 11.945 GiB |
| 64 A2 | 1.792 / 2.030 ms | 3.293 GiB | 11.833 GiB |

Both memory and render-thread time drifted downward through the return to 64. The 48 result sits between the two 64 controls and does **not** demonstrate a repeatable footprint or frame-time improvement. These measurements are render-thread timing, not on-screen FPS, GPU Busy, or presentation interval. The three full-resolution portal images looked consistent. In the non-portal right-side crop, mean RGB absolute differences were 3.33/255 for A1–B, 2.97 for B–A2, and 3.27 between the two 64 controls; animation and smog make this a limited visual check.

The verified-PID watchdog armed and was canceled before its deadline, with empty stderr. Shaders were disabled, the API override cleared to `active=512 api=null`, the player remained at the original Nether portal pose in creative mode with mouse free, and Minecraft closed normally. The original BenchCam jar, Iris properties, and options were restored byte-for-byte by SHA256. Monitors were sent off again.

**Decision:** keep 64 as the trial target. Do not promote 48 on these measurements. The radius selector remains available for future diagnostic work; it is off by default and not installed in the live instance.
