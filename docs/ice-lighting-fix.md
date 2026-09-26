# Held light on clear ice

## Report and cause

The reported failure is a held light-emitting item on isolated reflective ice. Placed lights already work. Baseline: `3035b5eae7870772abcf37ab5988d378925bde12`.

`block.properties` routes ice and frosted ice to `MAT_ICE` (11), a special forward branch in `program/gbuffers_translucent.glsl`. That branch calls `shadeSurface`, builds the refracted ice body and reflection, then returns. The generic translucent branch adds `albedo * handheldLight(...)` below that return. Clear ice therefore never evaluates the held-light term. A nearby opaque surface can contain held illumination in `colortex4`, but that is incidental refracted/reflected scene light, not illumination of the ice itself. This explains why isolated ice exposes the missing term.

`git blame` attributes the initial clear-ice early-return branch to `29f9392d`, with the milky body and underside changes in `c5591bd2` and `a4a3547a`. None adds held lighting.

Packed and blue ice route to `MAT_ICE_SOLID` (12), the opaque deferred path. Deferred already adds `albedo * handheldLight(playerPos, n, ao)` after its material shading. No opaque-ice lighting change is needed for this report.

## Scoped correction

Add the existing shared held-light response to `iceLit` after its underside sky-light override and before the body/reflection mix:

```glsl
iceLit += iceAlbedo * handheldLight(playerPos, n0, 1.0);
```

Use the unperturbed face normal, matching ordinary surface illumination. The existing helper chooses the brighter hand, item colour, distance falloff, and wrapped diffuse response. Applying it after the underside override avoids discarding it below a sheet. Applying it to the ice body once lets the existing frost/transmission and Fresnel weights attenuate it; it does not add an unconditional glow to the final reflection. Existing placed-light and opaque-ice paths stay as they are.

## Validation

- Source routing: clear/frosted ice uses the special forward branch; packed/blue ice uses deferred; `dynamicHandLight=true` is present.
- Numerical transfer check over frost 0/0.5/1 and view cosine 0/0.25/0.5/0.75/1: the direct body coefficient is 0.137500–0.887844 for top/side faces and 0.510000–0.598379 below, including the strongest allowed Fresnel attenuation. Reflections cannot erase the entire newly lit body.
- The existing helper still returns zero for a level-0 item and for a distance beyond the held item's level. At a 1.32-block source-to-surface distance, its scalar before colour/normal response is 0.802592 for level 14 and 1.062729 for level 15. No new brightness or colour scale is introduced.
- Independent source review confirms the held-light call is inside the `MAT_ICE` branch, after the complete underside override, before both body/reflection mixes and the branch return. There is one local held-light call in that branch. No global lighting or placed-light code was changed for the fix.
- `py shaderpack/tools/check_compile.py gbuffers_water gbuffers_hand_water gbuffers_entities_translucent deferred`: 36 stages checked, 0 failed (all three dimensions, including current shared cloud/aurora edits).

The running game was left untouched. Offline checks establish source routing and compilation, not live Iris linking or visual quality. Live acceptance should hold a torch or lantern over isolated normal/frosted ice at night, swap to an unlit item, compare packed/blue ice, and check an underside view. Keep placed-light controls unchanged.
