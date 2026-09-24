# DH 64 stability setup and Voxy trial, 2026-09-24

## Why the live setting changed

The previous game session ended after progressive freezes that made Windows
nearly unusable. The selected pack at that exit was Bliss
(`Bliss_v2.1.2_(Chocapic13_Shaders_edit).zip`), not ClaudeBenchV4Art. With
Bliss active, BenchCam's exact Art guard did not apply and DH returned to its
saved 512-chunk radius. Earlier Art runs also stalled near a Nether portal, so
Bliss/DH 512 is not a proven sole cause of the problem.

The live `ShaderBench` Prism instance was backed up under
`harness/out/dh-stability-20260924/` and then changed:

| Setting | Before | Current |
| --- | ---: | ---: |
| DH `lodChunkRenderDistanceRadius` | 512 | 64 |
| DH `numberOfThreads` | 8 | 4 |
| DH `generationRequestRateLimit` | 20 | 10 |
| DH `surfaceRegenMaxDistancePercent` | -1.0 | 1.0 |
| Iris `enableShaders` | true | false |
| Iris selected pack | Bliss | ClaudeBenchV4Art |

The saved DH radius applies to every pack and dimension. The current Art-only
Nether/End auto64 override becomes redundant while the saved radius is 64.
`generationMaxChunkRadius` stayed 0 because that cap is centered at world
origin, not the moving player.

## Guarded live check

Minecraft relaunched into BenchWorld in the Nether with shaders off. BenchCam
confirmed `active=64 true=64 api=null`, world chunks loaded, and a responsive
client. A 30-second passive PresentMon capture while stationary produced
7,250 app rows; median GPU Busy was 3.10 ms, p95 4.26 ms. DisplayedTime rows
are limited by presentation behavior and do not establish in-game FPS.

An identity-verified, timed watchdog was armed before briefly enabling
ClaudeBenchV4Art. BenchCam confirmed `active=64 true=64 api=64` and Art active.
The user/game was on the pause screen for the 35-second passive capture, so
these figures are only a paused-view smoke test: 2,909 frames, GPU Busy median
9.24 ms, p95 12.02 ms, p99 14.11 ms, worst 24.09 ms. Minecraft dedicated GPU
allocation stayed at 3.93 GiB; Java private bytes were 11.74–11.84 GiB and
available physical RAM was 6.11–6.65 GiB. No long stall appeared in this
brief check. The prior movement-triggered freeze remains unverified at DH 64.

Shaders were turned off, the watchdog canceled, and Minecraft exited through
`CloseMainWindow`. The log confirmed saving all three dimensions and closing
DH databases. Raw captures and watchdog output are in
`harness/out/dh64-shaders-off-20260924/` and
`harness/out/dh64-art-guard-20260924/`.

## Voxy migration boundary

A separate `ShaderBench-Voxy-Trial` Prism instance is being used for Voxy.
The live instance and its world remain unchanged beyond the DH/Iris settings
above. Voxy 0.2.19-beta targets MC 26.2/Fabric; an upstream compatibility
report says Iris 1.11.4 plus Sodium 0.9.2 makes Voxy LODs disappear, while
Iris 1.11.2 plus Sodium 0.9.1 works. The trial pins that reported working
pair. Voxy also needs its own terrain database and a shaderpack port using
`voxy.json` and Voxy terrain patches; the existing DH-specific Art programs
cannot be treated as Voxy support. The trial starts shader-off at modest
distance, with an independent copy of BenchWorld that excludes DH databases.

Upstream references: [Voxy issue #675](https://github.com/MCRcortex/voxy/issues/675),
[Voxy project](https://modrinth.com/mod/voxy),
[Iris DH shader contract](https://github.com/IrisShaders/ShaderDoc/blob/master/dh-support.md),
[example Voxy shader contract](https://github.com/sixthsurge/photon/blob/main/shaders/program/voxy.json).

## Trial outcome and return to DH

The isolated instance was created with Voxy 0.2.19-beta, Iris 1.11.2 and
Sodium 0.9.1. Its initial launch exposed BenchCam's hard dependency on the
live Iris/Sodium/DH versions; BenchCam was disabled **only in the trial**.
The second launch reached the copied BenchWorld and initialized Voxy's normal
render pipeline. Art was unexpectedly active in that trial despite the
shader-off setup, and its sky and lighting were visibly broken according to
Trevor. That is consistent with Art lacking the Voxy-specific shader hooks.
No LOD import, paired FPS run, or validated Art port was completed. Trevor
chose to stop the Voxy route. The trial Java process exited and all Voxy port
agents were stopped; the isolated trial files remain for possible later work.

Three newly downloaded shader archives, `Horizon Unbound.zip`,
`DreamersFantasy_r1.2.zip`, and `Pegasus (v 0.4).zip`, were copied from Downloads
to both Prism shaderpacks folders with source/destination SHA-256 equality.
The first two archives contain a Voxy JSON shader contract; Pegasus does not.
Copying these archives did not select a pack or change its code.

The original `ShaderBench` DH instance relaunched into BenchWorld. BenchCam
confirmed Art active, DH saved/effective radius 64, and loaded chunks. A
45-second **moving Overworld** passive capture from 16:15:19 to 16:16:04
(before Trevor selected another pack) produced 2,635 displayed frames:

| Measure | Median | p95 | p99 | Worst |
| --- | ---: | ---: | ---: | ---: |
| DisplayedTime | 16.42 ms | 22.78 ms | 26.70 ms | 70.28 ms |
| GPUBusy | 12.01 ms | 13.94 ms | 15.26 ms | 17.06 ms |
| CPUBusy | 16.38 ms | 22.22 ms | 25.75 ms | 70.32 ms |

DisplayedTime median is roughly 61 FPS in this moving interval. Minecraft
dedicated GPU allocation ranged 4.24–5.29 GiB, Java private bytes
12.14–14.61 GiB, and Windows available physical RAM 5.07–5.43 GiB. No
multi-second stall appeared during the sample. The exact-game watchdog was
canceled after the capture, leaving Minecraft running. At 16:16:28 the user
selected `Pegasus (v 0.4).zip`; DH remained active at 64. The 45-second Art
result says nothing about Pegasus' frame rate or long-session stability.
Raw evidence: `harness/out/dh64-return-guard-20260924/`.
