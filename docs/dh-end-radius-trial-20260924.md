# Opt-in End DH radius trial, 2026-09-24

The Art End DH fragment path discards/fades fully by 430 blocks in `end_lod.glsl`, and the End composite reaches full haze by 450 blocks. A 64-chunk Distant Horizons radius is 1,024 blocks, leaving a conservative distance margin beyond those shader cutoffs. This supports testing a smaller End render radius without changing Art or the shaderpack. The shader evidence motivates the trial; it does not establish that 64 chunks is visually equivalent or faster.

The BenchCam adapter adds `dhend on|off|status`. The End trial is off by default, uses 64 LOD chunks, and changes only DH's in-memory public API override. Its saved TOML value remains the baseline. The existing Nether trial remains independently controlled by `dhtrial on|off|status|radius <chunks>` and keeps its startup property and radius behavior.

When the trials are both enabled, BenchCam applies only the target for the active client dimension. On Nether/End/Overworld transitions it clears its currently owned API value before applying the next dimension's enabled target. `dhstatus` reports the active (`getValue`), saved (`getTrueValue`), and API (`getApiValue`) values, along with both independent enable states and the owner dimension. Foreign API values are not cleared. Clear failures block another application and continue through the existing bounded retry/backoff path.

This is an implementation record, not a runtime result. The trial remains opt-in. See [the BenchCam command and safety notes](../harness/benchcam/DH_NETHER_RADIUS_TRIAL.md) before a guarded End A/B/A check. Do not infer a performance or image-quality result from the Art distance thresholds alone.
