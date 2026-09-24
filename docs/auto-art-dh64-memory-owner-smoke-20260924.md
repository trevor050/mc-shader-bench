# Automatic Art DH64 and memory-owner smoke, 2026-09-24

BenchCam commits `b0001a7` and `e0198fb` make DH's in-memory 64-chunk radius automatic in the Nether and End only while Iris reports the exact loaded `ClaudeBenchV4Art` pack and an active shader pipeline. The saved DH radius remains 512 chunks. Commit `e837712` adds on-demand `memowners`; this smoke launched with `-Dbenchcam.memowners.trackDh=true` so it could account for DH `GLBuffer` storage by live GL ID. That JVM property was scoped to this launch and is off for ordinary future launches.

The combined jar built offline and then ran on MC 26.2 / Iris 1.11.4 / Sodium 0.9.2 / DH 3.3.2 at 1920×1080. A watchdog armed for the exact Java PID/start/instance before Art was enabled, and its stderr stayed empty. The monitors stayed off. The game log confirms Art → `ClaudeBenchBaseline` → Art, with no shader compile or mixin error beyond the existing Windows Perflib warning.

At the fixed Nether portal pose `(406.99,76,360.61)`, yaw -55.5/pitch 22:

| Settled state | DH active / saved | DH GLBuffer storage | DH buffer IDs | Sodium arena allocated |
| --- | ---: | ---: | ---: | ---: |
| Shaders off, before Art | 512 / 512 | 4.141 GiB | 3,126 | 0.922 GiB |
| Art auto-selected | 64 / 512 | 0.991 GiB | 898 | 1.676 GiB |
| Baseline pack, after 400 ticks | 512 / 512 | 4.515 GiB | 3,518 | 1.680 GiB |
| Back to Art, after 400 ticks | 64 / 512 | 0.991 GiB | 898 | 1.640 GiB |

The first shaders-off → Art transition removed **3.151 GiB of DH GLBuffer storage**. The pack-switch sequence confirms the exact Art guard releases/reapplies the override; Sodium's arena did not account for the DH contraction. These are allocated GL buffer storage estimates, not resident VRAM, and different shader states prevent treating this table as a pure radius performance A/B/A. The earlier Art-on 512 → 64 → 512 [Nether trial](dh-nether-radius-trial-20260924.md) isolated the radius and measured process dedicated GPU allocation 6.879 → 3.301 → 6.878 GiB. This smoke's settled Art-auto64 process dedicated allocation was 3.423 GiB and Java private bytes 10.812 GiB (ten 1-second samples); it is a separate run, not another A/B/A.

Shader disable and the Baseline pack both cleared the override to active/API 512/null. Returning to Art restored 64/64. Explicit `dhtrial off` held 512 for the session; `dhtrial on` restored 64. On Nether → Overworld → End, Overworld read 512/null and End auto-applied 64/64. Explicit `dhend off|on` similarly changed 512/null ↔ 64/64, and End → Nether selected the Nether target. There were no clear failures. The [Nether Art image](../harness/out/auto-art-dh64-memory-owner-smoke-20260924/nether-auto64-art.png) matches the earlier guarded 64-chunk portal view in terrain/atmosphere, and the [End Art image](../harness/out/auto-art-dh64-memory-owner-smoke-20260924/end-auto64-art.png) retains the expected central-island scene.

The End `memowners` snapshot immediately after the dimension change still showed 3.236 GiB of DH storage from buffers awaiting teardown; a later settled snapshot fell to 0.034 GiB and 180 IDs. Future owner measurements must wait for this cleanup, not rely only on `waitchunks` or a fixed tick count. The End's later process dedicated allocation median was 1.610 GiB (ten samples), which includes non-DH and cross-dimension retained resources. Do not subtract DH GL storage from Windows dedicated allocation and call the remainder another mod's resident bytes.

**Decision:** leave the new BenchCam jar installed so Art now uses the guarded 64-chunk radius automatically in the Nether and End. The original `options.txt`, Iris properties, and DH TOML were restored byte-for-byte after normal game exit; the jar SHA256 is `46CF10416B34BBD10D10A765B0AD59D445914FAC9DE6EBD3C99630991204D217`. The player is back at the Nether portal in creative mode, with shaders off, HUD on, mouse free, and Overworld time 6000. The monitor-off helper stopped and the monitors were sent off again. This establishes large storage savings and guard transitions, **not** display-on GPU Busy, presented FPS, continuous-motion visual parity, or a fix for the earlier intermittent desktop stalls.
