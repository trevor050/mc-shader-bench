# BenchCam memory-owner snapshot

This diagnostic is built for Minecraft 26.2, Sodium 0.9.2, DH 3.3.2, and Iris 1.11.4. It passed a guarded live smoke alongside Art-only automatic DH64; see [the trial record](../../docs/auto-art-dh64-memory-owner-smoke-20260924.md). The command neither changes render settings nor reads pixels or GPU memory.

```powershell
cd harness\benchcam
.\gradlew.bat --offline clean build
```

Add `-Dbenchcam.memowners.trackDh=true` to the Minecraft JVM arguments **before launching** the optional jar if DH buffer storage is needed. The property is off by default. When enabled, BenchCam records DH `GLBuffer` storage changes at successful upload returns and removes IDs after DH's actual deletion method returns, including asynchronous deletion. This does one small map update per DH storage change, with no frame loop, GL query, readback, allocation stack, or periodic sampling. Do not turn the property on after world load: buffers already allocated would be absent from the ledger.

From the repository root, run `py harness\bench.py raw "memowners"` at settled points and record the reply with the process telemetry CSV timestamp. All sizes are decimal **bytes**; divide by 1,073,741,824 for GiB. `ts_ms` is Unix epoch milliseconds. The first `gc_delta_*` values are `-1` because there is no prior command in this process.
The first command also initializes JVM management beans, so exclude that command's frame from timing comparisons.

Fields:

| Field | Meaning |
| --- | --- |
| `dh_buffer_storage_bytes`, `dh_buffer_count` | Live DH `GLBuffer` IDs with recorded storage; `na` when property is off. |
| `dh_glbuffer_count` | DH's own total live GLBuffer object count; may exceed the recorded count because some objects have no storage or use an untracked path. |
| `sodium_arena_alloc_bytes` | Sodium geometry and index arena allocations plus its reusable cached buffers. |
| `sodium_arena_used_bytes` | Sodium geometry and index arena used bytes; this is part of the allocated total, not additional memory. |
| `sodium_cached_bytes`, `sodium_buffer_count` | Reusable cached buffers and arena plus cache object count, from Sodium's public getters. |
| `heap_used_bytes`, `heap_committed_bytes` | JVM heap state. Heap used can include DH Java arrays, but cannot assign them to DH. |
| `jvm_direct_bytes` | JVM direct-buffer pool memory, or `-1` if unsupported; native allocations outside that pool may be missed. |
| `gc_count`, `gc_time_ms`, `gc_delta_count`, `gc_delta_ms` | Cumulative JVM collection totals and changes since the previous command. |

`sodium_state=unavailable` means no Sodium world renderer/arena was present. In that case the Sodium numeric fields are omitted. The Sodium total excludes staging buffers, uniform buffers, textures, and other Minecraft buffers. DH tracking excludes DH textures and buffers not using this `GLBuffer` storage path. Iris targets, vanilla resources, driver heaps, and Java arrays are not attributed by this command. The GL storage values are **not** dedicated or resident GPU memory. Do not call `process dedicated allocation - these values` an exact residual; the gap also includes residency and driver accounting differences. Compare each field's A/B/A *change* with the separately sampled Windows process dedicated GPU allocation, private bytes, system commit, and available RAM.

The live smoke confirmed `dh_tracking=on`, `sodium_state=ready`, nonzero DH storage, pack/dimension transitions, and delayed DH buffer cleanup after an End transition. It did not turn this diagnostic into a GPU residency profiler. Keep the launch-time property off for ordinary play; repeat guarded owner captures at settled points when investigating allocations.
