# Offline stall capture analysis

Summarize a raw PresentMon CSV and the sibling files emitted by
`passive_capture.py`:

```powershell
py .\harness\stall_analysis.py C:\Temp\shader-stall-01.csv
py .\harness\stall_analysis.py C:\Temp\shader-stall-01.csv --json-out C:\Temp\shader-stall-01.analysis.json
```

The analyzer reads `<stem>.capture.json` for the target PID and
`<stem>.telemetry.csv` for sampled GPU, VRAM, Java, and system memory values.
It reports per-target-swapchain frame timestamp gaps and available CPU/GPU busy
distributions. Empty or header-only PresentMon files still produce a report,
and telemetry can remain useful when PresentMon captured no frame rows.
The JSON also reports cumulative counts at 1, 2, 4, 8, and 12 seconds so
`campaign_review.py` can separate progressive multi-second stalls into bands.

It refuses to combine multiple target swapchains or guess which one is the
Minecraft render chain. Present-event gaps use sorted unique `TimeInMs`
timestamps when available (or `TimeInSeconds`). If only `CPUStartTimeInMs` or
PresentMon's app-only `CPUStartTime` exists, the report labels its result
`frame_start_gaps`, since CPU frame-start intervals are not the same measurement
as present-event intervals. CPU busy accepts `CPUBusy` in the app-only output;
GPU busy remains unmeasurable if PresentMon did not emit a GPU metric. The output
calls out missing columns, sparse rows, missing target PID, and other
unmeasurable fields explicitly; without a validated metadata PID it does not
aggregate either frame or telemetry rows.

All findings are descriptive. Sparse telemetry and frame gaps do not establish
whether CPU, GPU, the driver, a shader pass, or memory pressure caused a stall.
In particular, a VRAM rise or a single busy sample is not evidence of a leak.
One-second telemetry is only a trend sample and can miss short memory spikes.
