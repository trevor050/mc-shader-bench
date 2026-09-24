# Guarded Minecraft shader test

`guarded_game_watchdog.ps1` is a short-lived, opt-in safety guard for a known
Minecraft Java process. Start it **before** enabling an experimental shader.
It waits until its UTC deadline unless a cancel file appears or the game exits.
At the deadline it asks BenchCam to turn shaders off. If that command is not
acknowledged, it asks the render thread for `status`. It forcibly stops the
game only when both render-thread requests fail to reply, then releases a
stale Windows cursor clip after confirming that process exited.

The guard refuses to arm unless all of these match: PID, exact process creation
FILETIME, Java process name, Prism instance path in the command line, a recognized
Prism or Minecraft entry point, and BenchCam loopback listener owner. It holds an OS process
handle through the whole run and stops via that handle, so PID reuse cannot
redirect a termination to another process. It never records or prints the Java
command line, which may contain a Minecraft session token. If the listener's
ownership changes, it fails closed without sending commands or stopping Java.

From PowerShell, with the intended game already running and BenchCam listening:

```powershell
$gameProcessId = 12345 # obtain and verify the current Minecraft javaw.exe PID
$game = Get-Process -Id $gameProcessId
$startFileTimeUtc = $game.StartTime.ToUniversalTime().ToFileTimeUtc()
$instance = Join-Path $env:APPDATA 'PrismLauncher\instances\ShaderBench'
$cancel = Join-Path $env:TEMP ('shader-guard-cancel-' + [guid]::NewGuid().ToString('N'))
$deadline = [DateTimeOffset]::UtcNow.AddSeconds(90).ToString('o')
& .\harness\guarded_game_watchdog.ps1 -TargetProcessId $gameProcessId `
  -InstancePath $instance -ExpectedStartFileTimeUtc $startFileTimeUtc `
  -DeadlineUtc $deadline -CancelSignalPath $cancel
```

Run that command in a separate PowerShell process if the test controller needs
to continue while the guard waits. Use the same fresh cancel path to disarm
it: `New-Item -ItemType File -Path $cancel | Out-Null`. A cancel file present
before launch is rejected. Maximum deadline is 15 minutes away. The guard
uses 250 ms polling and two bounded 1.5 second BenchCam requests; it never
starts Minecraft, changes Prism settings, or captures the desktop.

Before enabling a risky shader, verify the separate process printed `guard armed`
and its stderr is empty. A launch PID alone does not establish that the
guard compiled, validated the game, or survived startup. A fresh PowerShell
process caught an ambiguous `FILETIME` type that an in-process syntax check
missed; the current script uses a fully qualified type and has passed both
arm/cancel and deadline-disable probes.

Exit codes: `0` means canceled, target exited, or shader disable acknowledged;
`2` means validation failed or the game answered `status` but did not confirm
shader disable; `3` means the stalled, verified game was forcibly stopped.

This protects only an intentionally guarded run. A complete OS stall can delay
the guard itself, and a render-thread reply does not prove acceptable frame
rate. Keep external telemetry and a reversible test setup for visual and
performance decisions.
