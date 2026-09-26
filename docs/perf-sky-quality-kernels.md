# Sky and cloud performance kernels

These source changes are candidates for the five-profile performance work. CPU
compilation and numerical gates establish the limits below; they do not establish
Minecraft frame time or visual acceptance.

## Ultra and High shared work removal

- The cloud pass computes its seven weather scalars and veil/fractus/virga amounts
  in the vertex stage and carries them flat. The existing weather equations remain
  unchanged. Other callers retain the original weather wrapper.
- Cloud scattering phase is evaluated once per view/light ray, then reused by all
  density samples and all five scattering orders. The altocumulus iridescence angle
  is also evaluated once per ray. No scattering order or density octave is removed.
- A zero daylight gate prevents cirrus fibre integration on fully dark nights.
  The previous result was computed and then blended completely to transparent.
- Atmospheric scattering returns zero before its nested integral when the light
  is provably invisible to all view samples. Sun aureole similarly returns zero
  once its existing visibility factor is exactly zero.
- Moon atmospheric tint reuses one transmittance evaluation. Star scintillation
  reuses the ray's air mass across catalogue candidates.

### Conservative atmospheric rejection

`scatter` uses a fixed camera radius of 6,360,200 metres, raises all view rays above
the horizon, and caps the integration length at 320,000 metres. Along this segment,
the change of the radial up-vector from vertical is at most
`320000 / 6360200 = 0.0503128832`. Unit light directions therefore satisfy
`dot(up, light) <= light.y + 0.0503128832`. The shader uses the slightly wider
0.05032 bound. If that upper bound is at or below -0.12, every original soft
terminator factor is zero. The same condition implies a light height below -0.15,
so the original sky-self factor is zero too. All single/multiple-scatter sums and
the self term are zero, regardless of intensity or aerosol.

At ordinary daytime the rejected source is the moon, removing six view samples
with four nested light samples each from the visible sky. On fully dark nights
the rejected source is the sun, removing twelve view samples with four light
samples each. Near dawn and dusk both sources retain the original integration.
The fixed physical camera in `scatter` makes this proof independent of the game
camera altitude. It does not alter the cloud-layer altitude lighting.

## Lower kernels

Medium/Low retain the original view-density functions, coverage, extinction,
weather, noise erosion and near-cloud 60-block division. Only illumination
quadrature and view sample locations/stride change. Adjacent light taps combine
their original weights and sample at their weighted positions, preserving the
same approximate optical integration domain rather than shortening its reach.

Medium uses three cumulus/two deck light taps; Low uses two cumulus/one deck tap.
Their adaptive cumulus segments cover the actual clipped interval and integrate
the true final segment length. Tiny intervals use a minimum representable stride
to avoid a float32 position that stops advancing. The lower cloud deck kernels
increase the existing nominal stride by their profile multiplier. Near fog keeps
its original four full-resolution samples.

Medium/Low visible sky and haze both use eight view samples; Ultra/High both retain
twelve. Equal counts at the eye-level horizon remain an invariant. Medium/Low
omit only the additional Milky Way noise grain, preserving its baked texture,
catalogue stars, dark-sky fade, cloud blocking and four aurora event modes.

Potato returns a continuous linear-light gradient with the shared dusk event and
biome aerosol. Its caller converts to the direct sRGB pipeline. Clouds are five
moving world-space height columns with the real weather and deck altitudes,
finite horizontal fade and broad horizon continuation. They run only in the
deferred sky, allowing removal of cloud march/history passes. This deliberately
trades detailed volume geometry, fly-through relief and self-shadow for a cheap
weather-dependent sky. The baked Milky Way and stars remain. Its aurora keeps
continuous sheets and all event gates, with two root refinements and one broad
emission field; no altitude-stratum or dotted noise representation is introduced.

## Baseline cumulus coverage caveat

Ultra/High deliberately preserve the established 64-step cumulus loop for an
isolated comparison. This loop already stops early on long, near-horizontal
clear rays: starting at zero over a 6000-block interval reaches 1530.896 blocks;
starting at 60 over 5940 reaches 1743.986. Increasing this bound is a separate
correctness/performance change requiring live review. Neither those old omitted
intervals nor a change of cloud radius may be reported as a new speedup.

## CPU receipts and next gates

`py shaderpack/tools/verify_sky_performance.py` parses the production stride and
quality constants. It checks 31,089 conservative terminator cases and 19,208
float32 intervals per lower tier, including spans up to 24,000 blocks. Maximum
sample counts are 84 for Medium and 61 for Low, within the 128 bound. The report
includes source hashes and the baseline coverage caveat at
`work/sky-performance-cpu.json`.

The original cloud CPU gate still passes 8400 authored deck intervals (51 maximum
steps). The integrated default compiled all 189 shader stubs with zero failures.
The independent profile matrix must also compile all five branches. Required live
gates are an identical-camera Ultra image difference, daytime/deep-night/dusk
performance, threshold views around the atmospheric early-return boundary,
near-horizontal in-cloud travel, all profile horizon transitions, and Potato
day/night/storm appearance with its direct display-space pipeline. Only the
exclusive benchmark lane may run the game or GPU timing context.

## Later numerical-only candidates

The independent LUT package under `work/lut_candidate` is not applied to the
production pack or immutable candidate A. Its 512x256 RG16F normalized optical
columns preserve the four-midpoint kernel, while aerosol/ozone remain dynamic.
The CPU propagation study covered 3,932,768 sky cases with maximum relative RGB
error 0.06976%. A separately authorized numerical OpenGL run on AMD Radeon(TM)
Graphics, GL 4.3.0 Core 26.9.1.260820, tested actual two-channel half-float linear
sampling across 112 sun/aerosol/rain cases: maximum relative sky RGB error
0.03224%, p99 0.00637%, all finite/nonnegative. Both compile variants passed all
189 stages. These are numerical receipts on AMD, not Minecraft/RTX speed claims.

`verify_aurora.py` and `verify_clouds.py` now accept `--profile 0..4` or `all`,
compile the actual profile header, and record the selected profile/source hashes.
The AMD aurora numerical run passed all four event modes in all five profiles;
its 4096-day selector produced 429 active nights and no adjacent active nights.
Separate horizon/up30/zenith/panorama renders at 0, 2 and 3600 seconds were
finite/nonnegative across every profile, with maximum wrap difference 1.56e-6.
This does not certify live dot/stripe appearance, sky/cloud compositing, or game
grading. Potato's broad constant-activity emission was brighter in a sampled
view than Ultra; a separate work-only activity calibration candidate is prepared
for a multi-night comparison instead of silently changing the frozen pack.
