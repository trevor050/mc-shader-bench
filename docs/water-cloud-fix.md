# Water cloud reflections and DH water depth

## Cloud reflection root cause

Water SSR reads `colortex4`, which is copied before clouds are composited. A confident SSR hit therefore contains no clouds. The old sky fallback sampled only one fixed point in the cumulus volume, so it returned clear sky when the visible cloud was an upper deck. Its altocumulus, fractus, and veil taps also used heights centered around each base even though `DeckStyle.alt` is the bottom of the layer; most of those taps landed below the modeled volume.

The fallback now samples representative points inside every layer (`DeckStyle.alt + DeckStyle.thick * f` for the styled decks), applies the shared horizontal render-distance fade, and includes the resolved cloud aerial perspective and horizon haze. It uses the same cirrus daylight gate as the sky renderer and anchors camera-relative deck masks to `cameraPosition`. Cloud history is added to SSR hits only when the cloud lies before the hit point. Aurora is limited to the natural-night sky fallback, is attenuated by reflected cloud coverage, and is not added over an SSR hit.

## Player cloud bands root cause

The third-person rainbow skin bands came from distant-horizon water drawing over the player. The DH water pass rejected against `depthtex1` only, a snapshot taken before late translucent entity layers. A self-activating magenta diagnostic placed immediately after that rejection colored the same leg bands magenta, proving the water pass was overwriting the player. The fix rejects DH water against the nearer valid depth from current `depthtex0` and the `depthtex1` snapshot. The parent’s live capture, `work/player-depth-fixed.png`, shows the rainbow body crisp again under the same clouds. The forward entity path also bypasses cloud-history overlay and writes an entity material tag for deferred cloud guards.

## Verification

`py shaderpack/tools/check_compile.py water gbuffers_entities_translucent` passed: 24 variants checked, 0 failed.

Run `py shaderpack/tools/verify_water_clouds.py` for a standalone NVIDIA OpenGL check using the pack’s baked cloud noise and extracted GLSL helpers. Current high-layer-only results have `l0=0`; altocumulus density is `0.05235` at `y=1280` with a reflected RGB delta length of `0.01908`, and veil density is `0.05699` at `y=2040` with a delta length of `0.01923`. Each selected altitude is inside its declared deck. The same harness confirms foreground cloud composition, skips clouds behind a surface, and bypasses cloud composition for `MAT_ENTITY`.

The helper’s measured GPU time on an RTX 4070 with NVIDIA driver 616.56 was 0.739 ms per 256×256 upward-ray frame and 0.168 ms for a horizon-ray frame, six measured runs after warmup. These synthetic standalone timings exclude Iris, the rest of the shader, and live water coverage. The checks do not emulate Iris cloud temporal history; the in-game capture remains the visual proof for DH depth ordering.
