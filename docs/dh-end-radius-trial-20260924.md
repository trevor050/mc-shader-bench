# Opt-in End DH radius trial, 2026-09-24

The Art End DH fragment path discards/fades fully by 430 blocks in `end_lod.glsl`, and the End composite reaches full haze by 450 blocks. A 64-chunk Distant Horizons radius is 1,024 blocks, leaving a conservative distance margin beyond those shader cutoffs. This supports testing a smaller End render radius without changing Art or the shaderpack. The shader evidence motivates the trial; it does not establish that 64 chunks is visually equivalent or faster.

The BenchCam adapter adds `dhend on|off|status`. The End trial is off by default, uses 64 LOD chunks, and changes only DH's in-memory public API override. Its saved TOML value remains the baseline. The existing Nether trial remains independently controlled by `dhtrial on|off|status|radius <chunks>` and keeps its startup property and radius behavior.

When the trials are both enabled, BenchCam applies only the target for the active client dimension. On Nether/End/Overworld transitions it clears its recorded API value before applying the next dimension's enabled target. `dhstatus` reports the active (`getValue`), saved (`getTrueValue`), and API (`getApiValue`) values, along with both independent enable states, the owner dimension, and `apiOwner=not_exposed`. DH provides no API ownership token: `owned` is local bookkeeping, and if another mod replaces the radius override with the same numeric value, BenchCam cannot tell and may clear that value. The cleanup check protects only against a different numeric value. Run both trials only on the pinned stack with no other DH API radius writer. Clear failures block another application and continue through the existing bounded retry/backoff path.

## Guarded runtime result

On the pinned MC 26.2 / Iris 1.11.4 / DH 3.3.2 stack with `ClaudeBenchV4Art`, a guarded 512 → 64 → 512 check used a fixed 1920×1080 central-island pose `(0.5,105,0.5)`, yaw 0, pitch 15, vanilla render distance 32. The monitors remained off. Each phase settled for 400 ticks, then recorded a full-resolution screenshot, 300 render-thread samples, and 10 process/GPU-memory samples. The verified-PID watchdog reported armed then canceled with empty stderr. `dhstatus` reported `active/api/true` as `512/null/512`, `64/64/512`, then `512/null/512`; no telemetry sample had an error.

| Phase | Render-thread median / p95 | Dedicated GPU allocation | Java private bytes |
| --- | ---: | ---: | ---: |
| 512 A1 | 2.761 / 3.888 ms | 2.365 GiB | 8.617 GiB |
| 64 B | 0.742 / 1.050 ms | 0.366 GiB | 5.003 GiB |
| 512 A2 | 2.600 / 3.598 ms | 1.696 GiB | 7.874 GiB |

These are process allocation and render-thread figures, not whole-frame GPU Busy or on-screen FPS. The return control had not fully recovered its initial memory allocation when sampled, so the exact memory delta is provisional.

**Reject the 64-chunk End setting.** Full-resolution [A1](../harness/out/dh-end-radius-trial-20260924/a1-512.png), [B](../harness/out/dh-end-radius-trial-20260924/b-64.png), and [A2](../harness/out/dh-end-radius-trial-20260924/a2-512.png) images show a continuous band of distant End islands across the horizon at 512. At 64, that band disappears, leaving a nearly empty dark horizon. The central island foreground remains, but the loss of the distant islands is a material visual regression. The Art shader's nominal DH fade thresholds therefore do not safely predict the appearance of this real End scene.

The adapter remains opt-in/off by default, and this setting is not promoted. After the trial, shaders were disabled, both radius controls were off with API override null and saved radius 512, the player was restored to the Nether portal in creative mode, Minecraft exited normally, and the original BenchCam jar, Iris properties, and options were restored byte-for-byte. Monitors were sent off again. See [the BenchCam command and safety notes](../harness/benchcam/DH_NETHER_RADIUS_TRIAL.md) for the implementation; do not enable the End trial for normal play.
