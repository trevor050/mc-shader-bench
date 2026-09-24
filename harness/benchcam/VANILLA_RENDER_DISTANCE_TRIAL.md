# Vanilla render-distance trial

BenchCam exposes an opt-in, in-memory vanilla render-distance switch for a same-process 24/32 comparison. It changes only Minecraft's vanilla render-distance option; it does not edit the shader pack or Distant Horizons settings.

Send commands through the existing BenchCam socket (default `127.0.0.1:25599`), one command per line:

```text
rdtrial status
rdtrial 24
wait 60
waitchunks 600
rdtrial status
rdtrial 32
wait 60
waitchunks 600
rdtrial restore
```

The first actual change captures the current vanilla render distance and Graphics preset. It refuses to start unless the saved Graphics preset is `custom`, because restoring a named preset can reapply other managed options. Repeating the current trial target is idempotent. Switching between 24 and 32 keeps the original snapshot. `restore` returns both the render distance and Graphics preset to their captured values, saves those originals, and ends the trial. Only 24 and 32 are accepted as targets. `status` reports `active`, `original`, `target`, selected `current`, effective distance, server cap, and whether the cap is currently limiting the selection.

The change runs on Minecraft's client thread and uses the pinned 26.2 APIs. It calls `Options.renderDistance().set(...)`, explicitly calls `Minecraft.levelExtractor.allChanged()` to invalidate/rebuild local view-distance data, then calls `Options.broadcastOptions()` to send the updated `ClientInformation` to the connection without saving the temporary target. This follows the same value and client-information path used by the Video Settings option while avoiding an immediate `options.txt` write. The server stores the requested view distance and applies its clamp to chunk tracking; it does not send a per-request acknowledgment. After each target command, allow at least 60 ticks, wait for `waitchunks` to finish, then inspect `status` and ensure `effective` is the intended distance before capturing. Let DH background LOD updates settle separately for the visual comparison.

BenchCam restores and saves the snapshot on explicit `restore`, world disconnect, and normal client shutdown. Do not open and close Video Settings while the trial is active: 26.2's options screen calls `Options.save()` when removed, which can write the temporary target to `options.txt`. Normal restore/disconnect/shutdown repairs that value. If the process is forcibly killed while active, cleanup cannot run; the target is ordinarily still memory-only, but any earlier settings-screen save can leave it persisted. Check `options.txt` after an interrupted trial if Video Settings was opened.

The command is global to the running client and does not change the DH radius. A configured/server effective-distance cap may limit the actual vanilla chunk view even when the requested option is 24 or 32. This command has not been exercised in a live game as part of the implementation build.
