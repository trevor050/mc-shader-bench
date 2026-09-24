# DH memory-detail launch abort, 2026-09-24

The isolated `mc-shader-bench-dh-buffer-size-audit` candidate compiled with
`gradlew --offline clean build`. Its SHA256 was
`3F88ED33CDA904120266052ABC46239CFAEE3182F84D22E9B862297A8621004F`.
The separate CPU-only 24-byte DH quad codec test passed all six deterministic
test methods (576 all-face/state byte comparisons inside one method); this is
not a real DH/Iris rendering test.

Before launch, the installed BenchCam jar, `options.txt`, `iris.properties`,
`DistantHorizons.toml`, and `instance.cfg` were backed up under
`harness/out/dh-memory-detail-20260924-1914`. The candidate jar was installed
temporarily, and Prism was started with process-local
`JAVA_TOOL_OPTIONS=-Dbenchcam.memowners.trackDh=true`.

Prism stopped at a **"Low free memory"** dialog before a Minecraft Java process
started. Windows reported 7,012,624 KiB free physical memory (~6.69 GiB),
below the instance's configured 8,192 MiB maximum heap. The cause of that
memory pressure was not established. The dialog's exact title came from the
responding Prism process; no Minecraft log for this attempt was created.
Prism and the waiting launch command were stopped. No shader was enabled, no
world was loaded, and no watchdog was needed or armed.

The original BenchCam jar was restored to SHA256
`46CF10416B34BBD10D10A765B0AD59D445914FAC9DE6EBD3C99630991204D217`.
The four other backed-up files already matched their prelaunch hashes. Prism
and Minecraft were closed after cleanup. No `memowners detail` runtime result,
GPU-memory attribution, visual comparison, or frame-time conclusion follows
from this attempt.

Before retrying a live capture, recheck available physical memory and the
instance heap setting. Do not dismiss the low-memory dialog just to force the
test through, given the earlier whole-desktop stalls. Preserve the same
candidate and backups for a guarded retry when memory headroom is adequate.
