# Lossless DH terrain quad storage trial

Status: source plan only. No patched DH or Iris jar has been built or installed. The isolated
CPU codec at `C:\Users\Trevor\codeprojects\mc-shader-bench-dh-quad-codec-poc` has written but
unrun tests. Its descriptor models a 64-byte expanded quad as 24 bytes; the possible 62.5%
saving applies to **terrain vertex storage only**, not total DH storage or resident VRAM.

## First attribution gate

Build and briefly run the isolated `mc-shader-bench-dh-buffer-size-audit` BenchCam candidate
after the quiet window. Save the complete raw `memowners detail` reply at settled Nether and
Overworld poses, along with process GPU allocation, private bytes, JVM heap/direct pool, and
frame tails. The new GLVertexBuffer bucket is an upper bound on terrain bytes because DH also
uses vertex buffers for other geometry. The latest-upload fields cannot establish active
geometry or unused capacity. Measure pending delete bytes and age across dimension changes
before changing DH cleanup behavior.

Proceed with packed terrain integration only if vertex storage is a material part of the
footprint. Run the CPU codec tests and compare decoded bytes against real legacy DH output
before claiming losslessness.

## Coordinated patch seams

Source basis: official DH and DH Core 3.3.2 tags, Iris 26.2 branch, and the exact installed
DH 3.3.2 / Iris 1.11.4 jars. Iris has no confirmed 1.11.4 source tag, so check the installed
jar's transform and bindings before packaging.

1. `LodQuadBuilder.makeVertexBuffers/putQuad`: encode one 24-byte record per quad. Resolve
   grass-side dirt shade into the alternate RGBA field at build time. Preserve the current
   split at **32,768 quads per VBO**; packed full VBOs become 786,432 bytes. This preserves
   VBO boundaries, quad order, transparent grouping, and draw-call count.
2. `LodBufferContainer` and `GLVertexBuffer`: validate byte counts divisible by 24, retain
   semantic expanded `vertexCount = (bytes / 24) * 4` for existing consumers, and use one
   six-index `(0,1,2,2,3,0)` quad per instanced draw. Keep legacy and Blaze paths gated.
3. `GlDhTerrainShaderProgram` and both pre/post GL4.3 VAO paths: bind the 24-byte descriptor
   with divisor 1 and draw `glDrawElementsInstanced(GL_TRIANGLES, 6, ..., quadCount)` once per
   existing VBO. Do not use DH's short-pointer convenience helpers without checking offsets:
   they round a three-short field from 6 to 8 bytes and a one-short field from 2 to 4.
4. Decode the record in DH's default terrain vertex shader, preserving raw coordinates for
   atlas UVs and its existing micro-offset, curvature, and TAA order. Update Iris
   `IrisLodRenderProgram` attribute bindings and `DHTerrainTransformer.injectVertInit` so
   `dh_terrain`, `dh_water`, and `dh_shadow` see the same virtual legacy inputs.
5. Negotiate packed mode before buffer construction; fall back to legacy if the matched Iris
   patch or renderer support is missing. Format changes require a rebuild or per-VBO format
   tag. Arbitrary third-party DH shader overrides need their own compatibility decision.

The six-index path preserves primitive order and provoking corners for flat varyings.
Instancing may change vertex shader cost; no FPS gain follows from the byte reduction alone.

## Acceptance gate

Compile both mod paths and all DH shader variants. Compare exact decoded attributes with
legacy output, then matched full-resolution stills and moving views across dimensions,
grass modes, transparency, textured LODs, and shadows. Use guarded A/B/A runs to compare
DH GL buffer storage, process GPU allocation, GPU Busy, presented frame timing and tails,
and interaction stability. Reject or revise if the rendered scene or motion degrades.
