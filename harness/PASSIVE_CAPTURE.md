# Passive stall capture

`passive_capture.py` runs a bounded PresentMon v2 capture and the existing
`telemetry.ps1` sampler at the same time. It is intended for a Minecraft render
stall where BenchCam status or a normal pack attestation can hang or fail.

The helper checks that the supplied PID is a running `java.exe` or `javaw.exe`
whose command line contains the selected Prism instance path. It then starts a
new uniquely named PresentMon session filtered to that PID and starts telemetry
with the same PID. It does not query BenchCam, read Iris state, issue game
commands, or change game settings.

Example from the repository root, after the game is running and the PID has
been checked in Task Manager:

```powershell
py .\harness\passive_capture.py `
  --presentmon $((Get-Command presentmon.exe).Source) `
  --pid 12345 `
  --output C:\Temp\shader-stall-01.csv `
  --seconds 90
```

If the monitors are powered off and standard PresentMon writes no CSV, add
`--app-only`. This uses PresentMon's `--no_track_gpu --no_track_display` mode to
record application frame starts. It cannot provide GPU Busy or true display
present timing; use the concurrent NVIDIA utilization and memory samples only
as supporting observations.

Outputs use the requested path for the raw PresentMon CSV, plus sibling
`<stem>.telemetry.csv`, `<stem>.capture.json`, and four stdout/stderr log files.
Existing outputs are never overwritten. A lock file prevents another run with
the same output stem from starting concurrently and is removed at completion.
The metadata records UTC start/end times, validated Java PID, executable path,
start time, session name, exit codes, timeouts, cleanup attempts, and whether
each CSV exists and its size. It never saves the command line, which may contain a
session token.

The helper deliberately does not reject an empty or header-only PresentMon CSV.
That file and the metadata are the evidence when a stall yields no frame rows.
Inspect the raw CSV and logs after capture; zero bytes or no target rows means
PresentMon did not produce usable frame samples, but the surrounding telemetry
can still be useful.

Duration is limited to 1–900 seconds, telemetry interval to 1–60 seconds, and
shutdown grace to 0–120 seconds. Both child processes are supervised. If a
process exceeds the shared duration-plus-grace deadline, the helper terminates
that child process. If PresentMon had started, the helper always asks it to stop
only the capture's unique session name, including after a clean CLI exit. On an unexpected interruption it
attempts the same cleanup and writes metadata before exiting.

This is best-effort process/session cleanup: Windows termination or a broken
PresentMon ETW session can still defeat cleanup. In that case, inspect the
metadata's cleanup result and PresentMon logs before another capture. PID
validation is repeated by `telemetry.ps1` when its sampler starts, but the
PresentMon launch necessarily has a small interval after the initial PID check.
