# Nether-only Distant Horizons radius trial, 2026-09-24

The installed DH 3.3.2 configuration renders LODs to a radius of 512 chunks (8,192 blocks). The V4 Art Nether far-smog term reaches its 520-block cap well inside 64 chunks (1,024 blocks). A guarded Art-on trial tested an in-memory 64-chunk override using DH's public API; the saved TOML value remains 512. The [BenchCam adapter](../harness/benchcam/DH_NETHER_RADIUS_TRIAL.md) now applies 64 automatically only when ClaudeBenchV4Art is loaded and Iris's shader pipeline is active in the Nether. Shader source and `LOD_DISTANCE` were not changed.

## Guarded runtime check

Minecraft 26.2, Iris 1.11.4, DH 3.3.2, `ClaudeBenchV4Art`, 1920×1080 captured image, vanilla render distance 32, fixed Nether portal pose `(406.99,76,360.61)`, yaw -55.5, pitch 22. The monitors remained powered off. A verified-PID watchdog was armed before shaders were enabled. Each radius phase settled for 400 game ticks before the portal screenshot and `framestats 300`; 9–10 passive telemetry samples were recorded per phase. The Art pack was confirmed in `latest.log`.

| Portal phase | DH active / saved chunks | Median render-thread frame | p95 | Median process dedicated GPU | Median Java private |
| --- | ---: | ---: | ---: | ---: | ---: |
| A1 | 512 / 512 | 4.803 ms | 6.673 ms | 6.879 GiB | 18.539 GiB |
| B | 64 / 512 | 1.838 ms | 2.100 ms | 3.301 GiB | 10.803 GiB |
| A2 | 512 / 512 | 3.445 ms | 3.898 ms | 6.878 GiB | 18.559 GiB |

The process GPU allocation fell by about **3.58 GiB (52%)** and returned to baseline when the override cleared. Java private bytes followed the same reversible pattern, about **7.74 GiB lower** in B. All telemetry rows had empty `SampleError`. The render-thread reduction is promising but has substantial A1-to-A2 drift, so these samples do not establish a stable FPS gain. `framestats` is neither GPU Busy nor presentation interval; with the monitors off, PresentMon could not supply those metrics.

At a fixed Nether lava-sea pose `(459.07,49,247.83)`, yaw 56.3, pitch -12, the shader-on render-thread medians were 3.567 ms at 512, 1.911 ms at 64, and 3.982 ms after returning to 512. Full-resolution portal and lava images retained the same composition and visible terrain features. In a portal crop outside the animated portal, mean RGB absolute difference was 3.31/255 for A1–B, 2.97 for B–A2, and 2.98 between the two 512 controls. In a broad lava crop, those differences were 7.13, 7.76, and 12.66/255. Smog, portal, and lava animation differ between captures; these figures are consistency checks, not proof of pixel parity. The watchdog reached its deadline during the first lava return and disabled shaders, so `lava-a2-512.png` is an invalid visual control. A fresh guarded shader-on capture, `lava-a2-shader-512.png`, replaced it.

With shaders off, a Nether → Overworld → End → Nether transition reported API radius 64 → null → null → 64, while the underlying value remained 512 in every dimension. Explicit `dhtrial off` restored `active=512 api=null`. No transition exception, clear failure, or game stall was observed in this short trial. This does not rule out the earlier intermittent whole-desktop freezes.

The original BenchCam jar, Iris properties, and Minecraft options were restored byte-for-byte after normal game exit; shaders remain disabled, the player returned to the original Nether portal pose in creative mode, and monitors were sent off again. Both watchdog runs printed armed then completed without stderr or forced termination. The DH TOML still reports radius 512.

**Status:** 64 is promoted as the Art-guarded Nether default based on the reversible process-GPU allocation drop and consistent settled portal/lava imagery. The run did not measure display-on whole-frame GPU Busy, CPU Busy, or presentation tails, and continuous camera motion was not evaluated. DH quadtree rebuilds on radius changes, and its background generation bounds are separate. This does not establish an on-screen FPS gain or show that the earlier stalls are fixed. The saved DH radius remains 512.
