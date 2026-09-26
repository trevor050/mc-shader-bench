# Biome and time climate

Climate is evaluated by Iris custom uniforms on the CPU. Independent cold,
arid, humid and maritime axes combine biome precipitation, temperature,
rainfall and category. Temperature/rainfall keep modded biomes meaningful even
when their categories fall back to plains. Ocean/beach/river classification
uses Iris biome tags. Temperate weather is the unmodified baseline.

Biome crossings use a 30 second half-life. Installed Iris 1.11.4's
`SmoothFloat.updateAndGet` scales its supplied fade argument by 0.1 before
using a seconds-based frame delta, so the property argument is 300, not 30.
Initial load establishes the local climate immediately; movement eases it.

The same aerosol multiplier changes Mie scattering and extinction in the
shared atmosphere. Haze, water reflections, sunlight and sky inherit it.
Bounds stay close to the original physical coefficients, avoiding tinted sky
filters or an independently painted horizon. Cold air is a little clearer;
humid/coastal air softly hazier; dry air supports restrained dust haze.

Existing volumetric decks retain their density/marching algorithms. Their
existing weather scalars choose fewer, flatter cumulus in cold/dry air, more
afternoon convection in humid air, and broken low/mid-level decks along coasts.
Rain and thunder still establish the global storm state. Climate changes
coverage and deck balance gradually, without new cloud noise per ray sample.

Ordinary dusk is gold, peach and a restrained belt of Venus. A deterministic,
continuous daily event allows occasional broad rose/violet afterglow. The
same event gates cloud fill and final dusk vibrance, so the terrain and water
agree with the sky. Its visual influence is capped at 0.55 after the first live
vivid-sunset review rejected the full legacy palette's orange ceiling and
magenta band. At peak, the effective extra dusk vibrance is approximately 1.39
(the legacy full event used 2.2). The event fades during global rain. It never replaces the
accepted star map, Milky Way or aurora.

With zero biome influence, cloud weather/deck balance and aerosol retain the
pre-climate baseline. The sunset event control is independent. Nether/End
return neutral climate/aerosol inputs and preserve their legacy tint and final
grade, rather than depending on fixed celestial time to hide a difference.

Reference: Dramatic Skys' photographed cloud structure and timed fades inspire
the differing cloud scale, altitude illumination and clear-weather afterglow.
Its cubemap assets are not imported. Their source credits do not establish a
reuse license, and static backdrops would contradict fly-through volumes.

Validation must include offline shader compilation, actual installed Iris
expression parsing, bounded climate/time/weather sweeps, and in-game visual
checks. Compilation alone does not establish visual acceptance or performance.

Iris syntax/constants were checked against the installed 1.11.4 jar and the
matching 26.2 source checkout (`BiomeCategories`, `IrisDefines`, `IrisFunctions`,
`CustomUniforms`, `SmoothFloat`, `SystemTimeUniforms`). Official reference:
https://shaders.properties/current/reference/shadersproperties/custom_uniforms/

## Numerical receipt

`py shaderpack/tools/verify_sky_climate.py` resolves and evaluates the actual
properties with the installed Iris jar's parser and function resolver. The
proposed values passed 51,840 climate/time/weather combinations. All axes,
aerosol, convection and event values stayed finite and bounded. Across 2,000
days at dusk, event strength exceeded 0.2 on 7.8% and 0.75 on 2.3%. Full rain
disabled the event. Maximum event discontinuity over a day boundary was zero
at the checked precision. Installed smoothing reached 0.5000 after 30 seconds.

At the sampled warm afternoon, aerosol was 1.014 temperate, 0.816 cold,
1.302 arid, 1.337 humid, 1.219 maritime and 0.956 frozen maritime. These are
coefficient changes, not measured visual contrast or performance claims.

The integrated default passed all 189 generated program stubs with
`py shaderpack/tools/check_compile.py` (zero failures). For comparable clear
sunset captures, day 0 at time 12500 is a quiet event (`/time set 12500`),
and day 131 at time 12500 is fully vivid (`/time set 3156500`). Use the same
biome/view and wait for the cloud history to settle after changing time.
The two days also have different ordinary cloud weather, so these captures
are a visual survey rather than an isolated event-amplitude A/B.

`py shaderpack/tools/verify_clouds.py` separately executes the actual GLSL
weather implementation. Its climate probe passed finite/bounded seven-field
outputs, arid coverage/low-deck reduction, maritime low/mid-deck increase,
humid convection response and full-thunder tower strength. At its fixed
weather time, fair cumulus coverage was 0.3600 temperate and 0.1146 arid;
humid supplied convection 0 to 1 raised coverage from 0.3240 to 0.4752.
These scalar probes do not establish live-biome visual acceptance.

## Live acceptance

The integrated pack was inspected in Minecraft 26.2 with Iris 1.11.4 on an RTX
4070. Command-side biome assertions confirmed desert, jungle, snowy plains,
deep ocean and swamp at the camera. Captures cover clear noon, humid afternoon,
thunderstorm, ordinary sunset and rare sunset. Climate transitions settle
gradually; reloading initializes the local climate immediately.

The rare event was also compared at the same camera, day 131 and time 12500
with SKY_VARIATION=0 and 1, reloading between captures. The dense warm cloud
ceiling remains in both images because it belongs to that day's ordinary
weather; the final capped event adds a modest color/afterglow increase.
The setting was restored to 1.0 after this control.

High-altitude day/night captures after matching haze and sky sample counts
show continuous sky brightness across the horizon. The final aurora was
inspected from ground level and above the clouds, with its narrow repeating
stripes removed. The live settings screen confirms all six controls and the
default Random (10%) occurrence mode. Unedited captures accompany the release.
These checks establish sampled visual behavior, not a whole-game performance
benchmark or exhaustive coverage of all modded biomes.
