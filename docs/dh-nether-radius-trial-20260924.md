# Nether-only Distant Horizons radius trial, 2026-09-24

The installed DH 3.3.2 configuration renders LODs to a radius of 512 chunks (8,192 blocks). The V4 Art Nether far-smog term reaches its 520-block cap well inside 64 chunks (1,024 blocks). This made a Nether-only, in-memory 64-chunk override worth testing. The override uses DH's public API; the saved TOML value remains 512. The [trial adapter](../harness/benchcam/DH_NETHER_RADIUS_TRIAL.md) is opt-in and off by default. Shader source and `LOD_DISTANCE` were not changed.

## Guarded runtime check

Minecraft 26.2, Iris 1.11.4, DH 3.3.2, `ClaudeBenchV4Art`, 2402×1313, vanilla render distance 32, fixed Nether portal pose `(406.99,76,360.61)`, yaw -55.5, pitch 22. The monitors remained powered off. A verified-PID watchdog was armed before shaders were enabled. Each radius phase settled for 400 game ticks before the portal screenshot and `framestats 300`; 9–10 passive telemetry samples were recorded per phase. The Art pack was confirmed in `latest.log`.

| Portal phase | DH active / saved chunks | Median render-thread frame | p95 | Median process dedicated GPU | Median Java private |
| --- | ---: | ---: | ---: | ---: | ---: |
| A1 | 512 / 512 | 4.803 ms | 6.673 ms | 6.879 GiB | 18.539 GiB |
| B | 64 / 512 | 1.838 ms | 2.100 ms | 3.301 GiB | 10.803 GiB |
| A2 | 512 / 512 | 3.445 ms | 3.898 ms | 6.878 GiB | 18.559 GiB |

The process GPU allocation fell by about **3.58 GiB (52%)** and returned to baseline when the override cleared. Java private bytes followed the same reversible pattern, about **7.74 GiB lower** in B. All telemetry rows had empty `SampleError`. The render-thread reduction is promising but has substantial A1-to-A2 drift, so these samples do not establish a stable FPS gain. `framestats` is neither GPU Busy nor presentation interval; with the monitors off, PresentMon could not supply those metrics.

At a fixed Nether lava-sea pose `(459.07,49,247.83)`, yaw 56.3, pitch -12, the shader-on render-thread medians were 3.567 ms at 512, 1.911 ms at 64, and 3.982 ms after returning to 512. Full-resolution portal and lava images retained the same composition and visible terrain features. Smog, portal, and lava animation differ between captures; this is a qualitative check, not pixel parity. The watchdog reached its deadline during the first lava return and disabled shaders, so `lava-a2-512.png` is an invalid visual control. A fresh guarded shader-on capture, `lava-a2-shader-512.png`, replaced it.

With shaders off, a Nether → Overworld → End → Nether transition reported API radius 64 → null → null → 64, while the underlying value remained 512 in every dimension. Explicit `dhtrial off` restored `active=512 api=null`. No transition exception, clear failure, or game stall was observed in this short trial. This does not rule out the earlier intermittent whole-desktop freezes.

The original BenchCam jar, Iris properties, and Minecraft options were restored byte-for-byte after normal game exit; shaders remain disabled, the player returned to the original Nether portal pose in creative mode, and monitors were sent off again. Both watchdog runs printed armed then completed without stderr or forced termination. The DH TOML still reports radius 512.

**Status:** keep the adapter opt-in and uninstalled. Before enabling it for normal play, run display-on PresentMon GPU Busy, CPU Busy, and presentation-tail A/B/A; inspect more Nether views and moving-camera behavior at full resolution; verify dimension transitions with shaders on. DH quadtree rebuilds on radius changes, and its background generation bounds are separate. No claim that this fixes the prior stalls or improves on-screen FPS yet.
