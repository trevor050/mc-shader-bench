# Windows memory pressure during shader work (2026-09-24)

## Captured state

Trevor approved a read-only elevated Microsoft RAMMap 1.63 snapshot while
Minecraft and the Art shader were running. The full snapshot is local at
`C:\Users\Trevor\AppData\Local\Temp\codex-ram-diagnosis\live-20260924.rmp`
(441,408,970 bytes). It was captured after 17-18 hours of Windows uptime.
No RAMMap Empty command was used.

RAMMap Use Counts, decoded from the snapshot (GiB, 1024-based):

| Use | Total | Active | Standby |
| --- | ---: | ---: | ---: |
| Process Private | 16.157 | 15.123 | 0.936 |
| Mapped File | 3.097 | 2.084 | 1.012 |
| Shareable | 0.448 | 0.410 | 0.006 |
| Page Table | 3.522 | 3.522 | 0 |
| Paged Pool | 1.159 | 1.134 | 0 |
| Nonpaged Pool | 1.897 | 1.897 | 0 |
| System PTE | 0.549 | 0.549 | 0 |
| Driver Locked | 0.387 | 0.387 | 0 |
| Unused | 3.661 | 3.512 | 0 |

Usable physical RAM was 31.157 GiB. Total active pages were 28.849 GiB;
standby pages were 2.001 GiB, and free plus zeroed only 0.149 GiB at snapshot
time. Standby is already included in Windows Available memory, so the low
available count was genuine pressure, not a misleading cache display.

The Minecraft `javaw.exe` resident working set was around 9-9.6 GiB while
sampling. The snapshot also contains 106,195 ProcessList records, of which
only 374 have a nonempty resident PFN list. The most frequent historical image
names were `glslang.exe` (29,815), `python.exe` (14,578), `conda.exe` (13,128),
and `git.exe` (12,885). The 3.522-GiB Page Table and 3.512-GiB active Unused
buckets each work out to roughly 35 KiB per historical process record. This
closely matches the retained-exited-process pattern reported on Windows, but
one RAMMap snapshot does not prove which process or driver owns those pages.

A second read-only snapshot at
`C:\Users\Trevor\AppData\Local\Temp\codex-ram-diagnosis\live-20260924-b.rmp`
was captured 664.7 seconds later with Minecraft still running. It contained
2,269 additional process records (2,283 additional empty-PFN records), while
active Page Table grew by 20,825 pages / 81.35 MiB and active Unused by
17,638 pages / 68.90 MiB. That is 36.71 KiB of new page-table memory and
31.09 KiB of new active/unused memory per new process record. This repeated
near-linear relationship strongly supports retained process-exit resources,
although the snapshot format does not attribute page-table pages to individual
PIDs or a driver. In the same interval, active Process Private rose only
42.07 MiB and active Mapped File fell 459.55 MiB. The growing page-table and
unused buckets are therefore a more direct explanation of the apparently
missing RAM than Minecraft Java heap growth.

The 7700X integrated AMD Radeon GPU drives the 2560x1440 second monitor. Its
driver is `31.0.24033.1003`, dated May 2024. Similar Ryzen 7000/Radeon
reports have linked active Unused growth to the integrated driver, but that is
a lead rather than local causal proof. **Do not disable this adapter:** the
second monitor depends on it. Any driver update or reboot must wait until the
game and other interactive work are clear, and needs a before/after memory
capture.

## Immediate operating implications

- Keep wide shader compile/build matrices paused while physical available RAM
  is low. Tens of thousands of short-lived compilers and shell processes can
  amplify a process-lifecycle leak if one exists.
- Do not interpret a shader-off test alone as clearing system memory pressure;
  the Page Table and active Unused buckets are outside the Java process.
- Reboot likely clears accumulated pages temporarily, but it is not evidence
  of a permanent fix. A controlled post-reboot baseline and process-churn
  comparison are still needed.
- This snapshot does not rule out separate GPU or shader stalls during camera
  movement. Keep those investigations distinct.

Sources: [Microsoft RAMMap documentation](https://learn.microsoft.com/en-us/sysinternals/downloads/rammap),
[AMD 7700X driver page](https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen/ryzen-7000-series/amd-ryzen-7-7700x.html),
[Windows report of retained exited processes](https://learn.microsoft.com/zh-cn/answers/questions/4062688/windows-11-23h2-1-page-table-8g),
[Codex Windows process-churn report](https://github.com/openai/codex/issues/26812).
