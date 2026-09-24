# End Art passive frame-time diagnostic, 2026-09-24

This was a 20-second read-only PresentMon 2.4.1 capture of the running
ShaderBench client (PID 480856). It did not move the camera or reload Iris.
The selected pack and latest.log both said `ClaudeBenchV4Art`; that pack is a
junction to `mc-shader-bench-claude-art/shaderpack`, whose clean shader source
was at Art commit `7b9e0c4` during this capture. Claude could move the camera,
so this is an uncontrolled scene diagnostic, not an A/B/A comparison.

The capture's `pack_artifact` argument mistakenly pointed to the main bench
repo's `shaderpack`, and its recorded SHA-256 `591fead0...` **does not attest
the live Art pack**. The Art shaderpack's hash immediately after capture was
`c4b29f9c0dfd6056c607cca16fc007f5b401ee5315297363e3214cf2e5d11fab`.
Do not use the capture metadata's pack hash for a promotion gate.

| PresentMon metric | Samples | Median | P95 | P99 |
| --- | ---: | ---: | ---: | ---: |
| FrameTime | 1,573 | 12.496 ms | 13.993 ms | 16.340 ms |
| CPUBusy | 1,573 | 12.411 ms | 13.884 ms | 16.246 ms |
| GPUBusy | 1,573 | 10.412 ms | 10.971 ms | 11.085 ms |
| DisplayedTime | 1,341 | 11.614 ms | 29.842 ms | 33.964 ms |

The sample is CPU-side limited: median CPUBusy exceeds GPUBusy by 2.0 ms.
This makes the opt-in DH/render-thread phase profiler valuable for the next
guarded session. A GPU shader optimization can still lower cost or VRAM use,
but an FPS gain cannot be assumed until the CPU bottleneck is addressed.
DisplayedTime's long tail needs a controlled motion A/B/A before attribution.

Telemetry had 19 samples: process dedicated GPU allocation stayed at
0.740 GiB, Java private bytes at 5.134 GiB, system available physical memory
10.456–10.528 GiB, and NVIDIA total VRAM use 2,398 MiB. The original
PresentMon CSV, telemetry, and capture metadata are in
`harness/out/end-art-passive-20260924.*`.
