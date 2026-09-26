# Cloud interior and horizon distance correction

## Source regression

The previous `cloudMistAt()` sampled only `l0Density()` and composite enabled it only in the y132–1080 cumulus slab. The authored altocumulus (y1150–1410), veil (y1850–2230), and cirrus volumes therefore had no near-camera mist. The distant deck march could make an interior optically opaque while retaining its deeply self-shadowed surface lighting. Its fourteen uniform samples covered up to1200 blocks, leaving up to85 blocks between samples even beside the camera.

The previous mist also attenuated the first60 blocks on top of a cloud march that already included those blocks. This counted extinction twice, and averaged density from points unrelated to the actual visible surface depth.

## Implementation

- `makeCloudLightEnv()` shares the original authored cloud lighting between the cloud march and composite. Sunset altitude colors are preserved. Every deck now receives the same moonlight calibration; the previous tint was applied only to the low deck.
- The first60 blocks of cumulus, authored decks, and cirrus are integrated in composite with their own actual density and extinction. The half-resolution march excludes that segment. Near samples stop at the closest scene surface. Opaque entity pixels skip this mist consistently with deferred cloud composition, and the hand returns before world effects.
- Cheap ray/slab intersections skip all density calls where no cloud can exist in the near segment. This includes clear air on the ground and the gaps between decks. Fractus lies inside the cumulus slab but contributes its own extinction. Cirrus retains its existing daylight visibility.
- Four jittered samples resolve the near segment. Camera-local light depth is evaluated once in composite's vertex stage and passed flat to every pixel, since its three taps never depended on the view ray. The near source preserves the wet, broadly scattered illumination of the earlier mist.
- Authored deck steps grow from a four-block close stride toward their original distant stride, with a bounded 56-iteration loop. Starting at zero needs at most 51 strides over the 1200-block maximum span; this also covers the full march when inside fog is disabled. A float32 sweep of 8400 intervals, spanning 1–1200 blocks at starts from 0–6000 blocks, covered every interval in at most 51 strides. Horizontal slab rays avoid division by zero. The final segment integrates its actual length.
- `cloudRenderDistance()`, `cloudRayLimit()`, and `cloudDistanceFade()` enforce one horizontal radius across cumulus, alto, veil, fractus, cirrus, virga, and rainbow virga sampling. The radius is `min(CLOUD_RENDER_DISTANCE, LOD_DISTANCE)`, default6000 blocks. Density fades smoothly from65% of that radius to zero, rather than ending in an opaque ring. A horizontal radius preserves high cirrus overhead. Reflected clouds use these same helpers.
- Each integrated layer additionally fades its premultiplied radiance and opacity using its own extinction-weighted horizontal distance. This matters for thick bodies, which otherwise remain opaque until very close to the radius despite lower density. Cloud aerial perspective strengthens across the same transition before the cap, reducing resolved contrast into the broad horizon bank.
- Beyond the resolved detail, a broad atmospheric bank follows the same cloud-deck heights and weather. Four growing regions integrate smooth height profiles analytically, modulated by a48km regional field and an exponential visibility tail. This continues the distant blue-gray atmosphere seen in the supplied high-altitude reference instead of fading clouds into an empty dark disc. It is scene-depth clipped and contains no repeated distant puffs.
- Diffuse horizon scatter increases continuously after the sun falls below y=-0.1, retaining the existing moon/sky hue. Its aerosol height profile widens at night; daylight and authored sunset lighting retain their prior calibration.
- Terrain/snow/cave fog now fogs only the background behind foreground clouds. Cloud radiance and transmittance are preserved by premultiplied algebra, including fully opaque clouds, instead of fading the already-composited cloud into terrain-distance fog. Sky snow-whiteout uses the same background-only treatment; leaving that path on the clouded color caused a residual moonlit color rectangle at the DH boundary.

`colortex8.r` still stores the transmittance-weighted cloud distance; `.g` still stores the scene distance during deferred. Their later VL lifetime is unchanged. `colortex3` additionally holds these distances divided by65536 from deferred through composite2, using its existing half-resolution RGBA16F allocation. This permits surface-depth guards after VL has reused colortex8. Composite4 then overwrites colortex3 with glare/rays as before; do not reuse or clear it earlier.

## Offline verification

`work/cloud-interior/verify_cloud_interior.py` renders the actual GLSL with the pack's RGBA16 baked cloud-noise volume in a standalone NVIDIA OpenGL context. It retains the pre-change sources under `work/cloud-interior/baseline/` and writes paired linear arrays, fixed-exposure review PNGs, and `metrics.json`. Synthetic cameras select dense cloud positions in four decks. This exercises the real density/scattering code, but does not reproduce the user's camera, world/time, Iris temporal accumulation, deferred upsampling, or Minecraft geometry.

At a synthetic dense alto interior, y1280, with night sun direction normalized from(0.6,-0.65,0.45), day80/time18000, clear weather, and shader time60 seconds:

| Linear luminance percentile | Before | After |
| --- | ---: | ---: |
| 10th | 0.002929 | 0.005139 |
| 50th | 0.008910 | 0.015572 |
| 90th | 0.042486 | 0.053217 |

Night, day, and dusk probes in cumulus, fractus, alto, and veil produced finite, nonnegative radiance. Horizontal rays at slab boundaries also remained finite. Depth probes at0,0.25,2,10, and60 blocks showed no far-cloud radiance in front of surfaces inside the near segment. At distance zero the near result was transparent.

An eight-frame comparison against a twelve-sample near reference measured mean absolute transmittance differences of0.60% for cumulus and0.82% for alto with four samples. Six samples lowered these to0.48% and0.42% but were slower. These are numerical sampling comparisons, not an in-game visual quality certification.

Standalone GPU queries at3440×1369, with illumination and camera light depth computed in the vertex stage as in the actual pass, measured median near-pass times of0.059ms for clear ground,2.39ms for dense cumulus, and3.78ms for dense alto. The initial twelve-sample candidate measured14.63ms for dense alto and was rejected. Baseline cumulus timings drifted from about6.9ms to22ms while Minecraft remained active, so relative performance and whole-frame FPS are unverified. The alto pass does not meet a two-millisecond budget on this synthetic workload; its added runtime cost remains a live validation risk.

Compile/link checks:

```powershell
py shaderpack/tools/check_compile.py
py work/cloud-interior/check_link.py
```

The linker check expands the real Overworld `deferred` and `composite2` vertex/fragment pairs and links them with glslang. This validates the new flat light-environment varyings in addition to per-stage syntax checks. The coordinator also successfully reloaded and captured this candidate in Iris.

After the cloud and forward-water sources were frozen, the full compile gate checked 189 stages with zero failures. Both Overworld pass links returned zero, the 30000-case fog algebra check passed again, and `git diff --check` was clean. The candidate shader source contains no active player or DH magenta diagnostic hooks.

## Live evidence and remaining checks

The implementing agent performed no game controls. The coordinating agent later received explicit user authorization and owns live reloads, teleports, and captures. The candidate was checked in live day and night interiors, at high-altitude horizons, and on the third-person player. Full-frame performance and an exhaustive transition check across every deck, weather regime, and dusk remain unmeasured. The earlier synthetic timing numbers predate the broad haze and extra distance MRT additions.

The coordinator isolated the straight-edged dark quadrilateral in ClaudeBench screenshots03.16.36 and03.25.48/.54. `work/quad-depth-kind.png` marks its exact boundary as DH depth coverage (green), surrounded by sky depth (blue). `work/quad-cloud-trans.png` shows continuous cloud transmittance across that boundary. The cloud field was present; subsequent composite terrain fog faded it only over DH terrain, revealing the rectangle. The fix preserves foreground cloud radiance when applying background fog, rather than hiding an actual occluding surface or changing DH geometry.

The coordinator's `work/quad-fixed-day.png` and `work/cloud-horizon-fixed-day.png` confirmed that foreground clouds remain visible over DH terrain after the fog correction. `work/cloud-horizon-fixed-night.png` exposed the remaining sky-only snowy whiteout recoloring clouds at the same boundary. After giving sky whiteout the same treatment, the coordinator reported that `work/cloud-horizon-night-v3.png` had no DH lighting rectangle and a visible blue haze. Resolved-cloud opacity/contrast fading was then strengthened for a smoother transition. The final `work/horizon-night-final.png` shows the cloud bank continuing into blue-gray atmosphere, with no straight DH lighting boundary or empty dark disc at the detail radius.

The player's white leg bands are a separate forward-stage issue. Temporary composite diagnostics in `work/cloud-interior/player-debug/` were deployed and captured by the coordinator, then removed from the candidate source. `work/player-debug1.png` showed entity material on the cape/held item but other material on the skin body; `work/player-debug2.png` already showed the white band in colortex0 before composite fog; `work/player-debug3.png` showed the cloud-free deferred colortex4 without the skin body. Therefore opaque material and composite near-fog guards do not solve that band. A first DH magenta capture lacked an active diagnostic define and was inconclusive. With that define activated, `work/player-dh-magenta-active.png` colored the leg band magenta, proving DH water overwrote the late forward skin body. Installed Iris 1.11.4 bytecode confirms depthtex1 is copied once at `beginTranslucents()`, omitting later forward entity geometry. The forward shader owner added an exact body material marker and changed DH rejection to use `min(depthtex0, depthtex1)`. The coordinator's `work/player-depth-fixed.png` shows the full rainbow skin body without the white band in heavy cloud mist. Those forward changes are documented in `docs/water-cloud-fix.md`.

`work/cloud-interior/find_live_density.py` and `live-density-positions.json` provide exact-GLSL positions for targeted interior tests at day 0/time 6000, clear weather, frame time 5. Alto at camera/eye (308.875, 1320, 52.125) had density approximately 1.0. The nominal test positions previously used by the coordinator fell into gaps; entering a deck's altitude alone does not prove an interior. The first low-altitude cumulus/edge nighttime captures contained actual dark block textures or possible terrain overhangs and were excluded from acceptance. Veil density was zero for that weather, so it needs another weather regime.

The separate `live-density-positions-time18000.json` uses day 0/time 18000 and frame time 5. Its upper-cumulus camera/eye point (3246.375, 650, 3239.625) has exact-GLSL density 1.5 and sits above the terrain used in the earlier inconclusive captures. The coordinator's `work/dense-night-final.png` at this point shows smooth dark blue mist with visible cloud/terrain shapes and no black slab or straight-edged artifact. The daytime upper-cumulus and alto captures (`work/dense-upper-day.png`, `work/dense-alto-day.png`) show the corresponding illuminated mist. These captures establish the tested interiors; cloud weather and moving noise mean a density coordinate must always be paired with its day/time and reload delay.

`work/cloud-interior/check_fog_algebra.py` verifies the new formula against independently fogging the background then compositing the cloud, including zero/unit cloud transmittance:30000 cases passed. The exact expression is `color*(1-fogAmount) + (fogColor*cloudT + cloudRGB)*fogAmount`, with no division by cloudT. Live confirmation of the repaired rectangle belongs to the coordinator's captures.

`work/cloud-interior/check_horizon.py` exercised the actual horizon GLSL at45 rays across256 distances each: day/dusk/night, camera y240/1280/2040, and horizontal/near-horizontal/up/down directions. All radiance remained finite and nonnegative and all transmittance stayed in[0,1]. A surface before the transition receives no distant haze. An initially opaque resolved layer keeps its original premultiplied color nearby and reaches the transparent identity beyond the horizontal radius. The small offscreen draws provide numerical/depth evidence, not a performance measurement or replacement for the coordinator's horizon review.
