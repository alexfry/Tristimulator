# CLF OCIO Transform Test — RESOLVED (all passing)

## Outcome (2026-06-07)

All `CLFOCIOTransformTests` pass (EXIT 0): the 8 ACES reference-comparison tests, the
synthetic tests, and `matrixApplicationMatchesManualMath`.

## Root cause

The OCIO CLF application code was always correct. The tests failed because the bundled
**source image was the wrong version** of the ACES CLF test image.

The test image bakes its own creation date into the pixels (README: "a data stamp to
differentiate versions"). Rendering `[source | ours | reference | diff]` strips made it
visible:
- bundled source / `CLF_testImage.exr`: **Mon Oct 25 2021**
- `Processed_Reference_Images/*`:        **Tue Aug 25 2020**

Different versions — the patch/ramp layout was rearranged between them, so most of the
image matched but discrete patches diverged.

## Fix

Source is now `CLF_testImagePrototype_v006.exr`, extracted from the CLFTestImage repo at
commit `2eccf5b` ("updated doc images and general script tidy", 2020-08-25) — the version
matching the reference render date. With it, every reference test passes within the ACES
Finishing-Tier tolerance (|a−aim| / max(|aim|,0.1) ≤ 0.002).

Source: `~/Library/Mobile Documents/com~apple~CloudDocs/Documents/GitHub/CLFTestImage`,
`git show 2eccf5b:images/CLF_testImagePrototype_v006.exr`.

## Code change kept

`OpenColorIOBridge.mm` `groupTransformProcessorWithConfig:` builds the CPU processor with
`getOptimizedCPUProcessor(OPTIMIZATION_LOSSLESS)` instead of `getDefaultCPUProcessor()`
(= VERY_GOOD). LOSSLESS avoids `FAST_LOG_EXP_POW` (approximate log/exp/pow) and
`COMP_SEPARABLE_PREFIX` (finite-LUT baking that clips extreme values) — needed to hit the
0.002 tolerance on the extreme-value test content, and a correctness win for the
production AMF pipeline too.

## Verification tooling (in CLFOCIOTransformTests.swift)

- `matrixApplicationMatchesManualMath` — applies the matrix CLF to the source and checks
  OCIO output == hand-computed M×src at every pixel. Independent of the reference EXRs.
- `generateVisualComparison` — writes `[source | ours | reference | diff]` strips to
  /tmp/clf_view/ as PNG (8-bit) and EXR (float). The diff panel shows relative error
  scaled so the 0.002 threshold = white (black = passing).
