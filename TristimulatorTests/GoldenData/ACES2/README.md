# ACES 2.0 CTL golden data

Reference values for `TristimulatorTests/ACES2CTLGoldenTests.swift`. They come from the
Academy's ACES 2.0 CTL run through `ctlrender`. OpenColorIO plays no part in making them.
The tests run the same inputs through the app's own CPU (OCIO via `OpenColorIOBridge.mm`)
and GPU (`OCIOGPUProcessor` Metal) paths and fail if either drifts from the CTL.

## Provenance

| Source | Repository | Commit |
|---|---|---|
| ACES 2.0 release | https://github.com/aces-aswf/aces, tag `v2.0.0+2025.04.04` | `35e1e6ac2c26ec75433547d5d0a3a881f39bd9f5` |
| `aces-core` (CTL library, submodule at that tag) | https://github.com/aces-aswf/aces-core | `2d7af39344725aaa8ac3bf1746693c9a1d6c4792` |
| `aces-output` (Output/InvOutput CTL, submodule at that tag) | https://github.com/aces-aswf/aces-output | `aab74723f76728c37345ed01e51ebb24fb1f2f1f` |
| `ctlrender` | https://github.com/aces-aswf/CTL, tag `ctl-1.5.5` | `294609eacc61687c9b8e7509608bbf6d4ca68344` |

`aces-core` and `aces-output` carry no v2 tags of their own. The release is tagged in the
umbrella `aces-aswf/aces` repo, which pins them as submodules.

`ctlrender` was built on Debian 13 (x86_64, g++ 14.2, OpenEXR 3.x from apt) with
`cmake -DCMAKE_BUILD_TYPE=Release`.

Since the release, `aces-core` main gained one CTL fix (`9e33676`, "fix min_index
assignment in corner calculations", Aug 2026). Regenerating with that fix gives
byte-identical files for every transform here, so the golden data is unaffected.
OCIO 2.5.2 already has the corrected logic.

`manifest.json` records the commits, a SHA-256 for each CTL used and each data file,
and how each entry maps onto the app.

## Files

All `.f32` files are raw little-endian float32 RGB triplets, `[count][3]`, with no header.

- `input_scene_ap0.f32`: 1803 ACES2065-1 (AP0) scene-linear samples.
  - Neutral ramp from 0 and from −14 to +12 stops around 0.18, in 1/3-stop steps, plus 0.18 and 1.0.
  - AP1 primaries and secondaries from −6 to +8 stops.
  - AP0 primaries.
  - A 36-hue ACEScg sweep at 3 saturations and 5 exposures.
  - ACEScg values just outside AP1.
  - Very large values up to 65504, around the AP1 clamp at 8 × r_hit.
  - 1000 seeded random samples (seed 20261125).
- `input_display_cv.f32`: 1485 display code values for the inverse transforms: a 9³ cube,
  a 256-step grey ramp and 500 seeded random samples.
- `expected/<id>.f32`: the CTL output for each transform, in the same order as its inputs.

## What maps to what

The default config is `OCIO/studio-config-v4.0.0_aces-v2.0_ocio-v2.5.ocio`. The OCIO
version is 2.5.2, from the vcpkg baseline `32305df7`.

| id | App path (real code under test) | CTL |
|---|---|---|
| `fwd_sdr100_rec709_srgb` | Config mode, `sRGB - Display` / `ACES 2.0 - SDR 100 nits (Rec.709)` | `d65/srgb/Output.Academy.Rec709-D65_100nit_in_Rec709-D65_sRGB-Piecewise` |
| `fwd_sdr100_p3_srgb` | Config mode, `Display P3 - Display` / `ACES 2.0 - SDR 100 nits (P3 D65)` (SDR default) | `d65/displayP3/Output.Academy.P3-D65_100nit_in_P3-D65_sRGB-Piecewise` |
| `fwd_hdr1000_p3_srgb` | Config mode, `Display P3 HDR - Display` / `ACES 2.0 - HDR 1000 nits (P3 D65)` (HDR default) | `d65/displayP3/Output.Academy.P3-D65_1000nit_in_P3-D65_sRGB-Piecewise` |
| `fwd_hdr1000_p3_rec2100pq` | Config mode, `Rec.2100-PQ - Display` / `ACES 2.0 - HDR 1000 nits (P3 D65)` | `d65/rec2100/Output.Academy.P3-D65_1000nit_in_Rec2100-D65_ST2084` |
| `dyn_p3_{100,1000}` | Dynamic ACES2 (`aces2DynamicProcessorWithConfig`, P3-D65 limit, Display P3 HDR encoding) | P3-D65 100 / 1000 nit `in_P3-D65_sRGB-Piecewise` |
| `dyn_p3_{400,1600,4000}` | Dynamic ACES2 at auto-nits peaks | **Derived**: the 1000-nit P3 CTL with only `peakLuminance` changed (see below) |
| `dyn_rec709_100` | Dynamic ACES2, Rec.709 limit | `d65/displayP3/Output.Academy.Rec709-D65_100nit_in_P3-D65_sRGB-Piecewise` |
| `inv_sdr100_rec709_srgb` | Inverse display `sRGB - Display` / SDR 100 Rec.709 → scene_linear, mapped to AP0 | `d65/srgb/InvOutput.Academy.Rec709-D65_100nit_in_Rec709-D65_sRGB-Piecewise` |
| `inv_sdr100_p3_srgb` | Inverse display `Display P3 - Display` / SDR 100 P3 | `d65/displayP3/InvOutput.Academy.P3-D65_100nit_in_P3-D65_sRGB-Piecewise` |
| `rt_*` | Inverse display, then the same display/view (`setupCombinedInverseDisplayTransform` on the GPU) | CTL Output applied to the CTL InvOutput result |
| `invdyn_rec709_to_p3_{100,1000}` | Inverse sRGB SDR, then Dynamic ACES2 P3 (`setupCombinedInverseDisplayACES2Transform`) | CTL P3 100 / 1000 Output applied to the CTL Rec.709 InvOutput result |

Dynamic ACES2 auto-nits uses peak = max(100, round(EDR headroom × 100)), so any peak can
occur. The CTL cannot take the peak as a runtime parameter, because `init_ODTParams()`
runs at global scope. The generator therefore writes a copy of the official 1000-nit P3
CTL that differs only in `const float peakLuminance`. Those entries are flagged
`derived` in the manifest.

Inputs go into the app as ACES2065-1. In Dynamic mode, the app first linearises to
scene_linear (ACEScg) and then runs the ACES2 group from there, as `ImageManager` does.

## Regenerating

```sh
git clone --recurse-submodules --branch v2.0.0+2025.04.04 https://github.com/aces-aswf/aces
git clone --branch ctl-1.5.5 https://github.com/aces-aswf/CTL
(cd CTL && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j)
pip install numpy OpenEXR
python3 Scripts/generate_ctl_golden.py --aces ./aces --ctlrender CTL/build/ctlrender/ctlrender --ctl-repo ./CTL
```

The output is deterministic. Running it twice gives identical files.

To re-measure OCIO against the CTL without Xcode, run
`pip install opencolorio==2.5.2 && python3 Scripts/measure_ocio_vs_ctl.py`.

## Running the tests

They run with the rest of the suite:

- In Xcode, use ⌘U on the `Tristimulator` scheme.
- In CI, `Scripts/ci_xcode_test.sh` runs them in the `Build and test` job. The
  per-transform error lines are also written to `TestResults/aces2-ctl-golden.txt`, and
  the `ACES 2.0 CTL golden summary` step prints them to the job summary.
- On the command line:
  ```sh
  xcodebuild test -project Tristimulator.xcodeproj -scheme Tristimulator \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TristimulatorTests/ACES2CTLGoldenCPUTests \
    -only-testing:TristimulatorTests/ACES2CTLGoldenGPUTests
  ```

Each case prints a line like
`ACES2 CTL golden [cpu dyn_p3_1000]: max=… p99=… median=… tol(max=…, p99=…)`.
The GPU suite is skipped when `MTLCreateSystemDefaultDevice()` returns nil.

## Measured error and tolerances

See `MEASUREMENTS.md` for the measured numbers behind each tolerance in the test file.

## Known differences

1. **Rec.2100-PQ negatives.** CTL clamps negative linear values to 0 before the PQ inverse
   EOTF (`eotf_inv` in `Lib.Academy.DisplayEncoding.ctl`). OCIO's
   `DISPLAY - CIE-XYZ-D65_to_REC.2100-PQ` builtin preserves their sign. A P3-limited
   output in a Rec.2020 container gives a slightly negative blue for saturated reds,
   because the P3→2020 matrix has a −0.0012 term. PQ's steep toe turns that into code
   values down to about −0.1. In this set, 20 of 1803 samples are affected. The test
   clamps at 0 before comparing and fails if more than 30 samples are affected. After
   clamping, the maximum error is 4.6e-4. This is not the app default path.
2. **Bright saturated AP1 edges.** At most 5 samples per transform differ by
   1e-3 to 5e-3 code values. Examples are pure ACEScg yellow at +6 to +7.6 stops, where
   the blue channel reads 0.8101 in OCIO and 0.8089 in CTL. Every other sample is within
   about 4e-5, with medians around 1e-6. The size is the same with the
   OPTIMIZATION_NONE, LOSSLESS and DEFAULT CPU settings, so it comes from OCIO's
   fixed-function ACES 2 implementation itself, not from its fast-math approximations.
3. **Clamped white.** OCIO encodes a clamped 1.0 as 1.0000067 because of its sRGB curve
   evaluation. CTL gives 0.99999994. The difference is 6.7e-6, well inside the tolerance.
