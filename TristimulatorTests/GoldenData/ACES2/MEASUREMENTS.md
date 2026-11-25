# Measured error against the ACES 2.0 CTL

Measured on 25 Nov 2026. These numbers are the basis for every tolerance in
`ACES2CTLGoldenTests.swift`.

- **App, CPU and GPU:** DiscoVolante (Apple M4 Pro, macOS 27.2, Xcode 27.2), OCIO 2.5.2
  static build from vcpkg, Debug test build run through `Scripts/ci_xcode_test.sh`.
- **Cross-check:** PyOpenColorIO 2.5.2 on Linux x86_64, using
  `Scripts/measure_ocio_vs_ctl.py`. Its numbers agree with the Mac CPU numbers to about
  2 significant figures, so the CPU result does not depend on the architecture.

## Metric

- **Forward and round trip:** the error is the absolute difference in display code values.
  Each sample is scored by its worst channel. In HDR transforms those code values are the
  extended sRGB-curve Display P3 values the app draws, and they go above 1.0.
- **Inverse:** each sample's worst-channel error is divided by
  max(|expected RGB|, 1e-3). The output is unbounded scene-linear, so a relative score is
  used.
- **GPU vs CTL:** the GPU writes `rgba16Float`, so one fp16 step at each value's magnitude
  is subtracted per channel before scoring. The GPU is then held to the same limits as
  the CPU.
- **GPU vs CPU:** this is the absolute difference left over after allowing one fp16 step.

## CPU (app's OCIO processors) vs CTL

| id | max | p99 | median | tol max | tol p99 |
|---|---|---|---|---|---|
| fwd_sdr100_rec709_srgb | 1.21e-3 | 1.4e-5 | 1.4e-6 | 2e-3 | 1e-4 |
| fwd_sdr100_p3_srgb | 1.20e-3 | 1.9e-5 | 1.4e-6 | 2e-3 | 1e-4 |
| fwd_hdr1000_p3_srgb | 3.75e-3 | 2.9e-5 | 1.8e-6 | 6e-3 | 1e-4 |
| fwd_hdr1000_p3_rec2100pq ¹ | 4.56e-4 | 6.7e-5 | 1.5e-6 | 1e-3 | 2e-4 |
| dyn_p3_100 | 1.20e-3 | 1.9e-5 | 1.4e-6 | 2e-3 | 1e-4 |
| dyn_p3_400 | 2.18e-3 | 1.8e-5 | 1.7e-6 | 4e-3 | 1e-4 |
| dyn_p3_1000 | 3.75e-3 | 2.9e-5 | 1.8e-6 | 6e-3 | 1e-4 |
| dyn_p3_1600 | 4.88e-3 | 2.2e-5 | 1.9e-6 | 8e-3 | 1e-4 |
| dyn_p3_4000 | 2.24e-3 | 3.5e-5 | 1.8e-6 | 4e-3 | 1e-4 |
| dyn_rec709_100 | 1.07e-3 | 1.1e-5 | 1.4e-6 | 2e-3 | 1e-4 |
| inv_sdr100_rec709_srgb (rel) | 1.28e-3 | 1.6e-4 | 1.6e-5 | 2e-3 | 4e-4 |
| inv_sdr100_p3_srgb (rel) | 1.00e-3 | 1.9e-4 | 1.7e-5 | 2e-3 | 4e-4 |
| rt_sdr100_rec709_srgb | 9.3e-5 | 1.4e-5 | 5.5e-6 | 2e-4 | 5e-5 |
| rt_sdr100_p3_srgb | 1.6e-5 ² | 1.2e-5 | 5.4e-6 | 1e-4 | 5e-5 |
| invdyn_rec709_to_p3_100 | 3.0e-4 | 2.1e-5 | 5.7e-6 | 6e-4 | 5e-5 |
| invdyn_rec709_to_p3_1000 | 8.79e-3 | 1.3e-4 | 8.3e-6 | 1.5e-2 | 3e-4 |

¹ This is after clamping the app's negative PQ code values at 0. Twenty of the 1803
samples were affected (limit 30). See the README, under Known differences.
² This was 2.3e-5 with PyOpenColorIO on x86_64.

Each `max` tolerance is the measured value times about 1.6, rounded up. Each `p99`
tolerance sits well below any `max`. The `max` limit catches a single outlier getting
worse, and the `p99` limit catches a broad shift that would otherwise hide under a loose
`max`.

The large `max` values come from a handful of very bright, highly saturated samples on
the AP1 boundary. Examples are ACEScg yellow at about +6 stops and magenta/blue at about
+7 stops. The size of these errors is the same with the OCIO NONE, LOSSLESS and DEFAULT
CPU optimisation settings, so they come from OCIO's fixed-function ACES 2 code itself.
Everywhere else, the error sits around 1e-6 to 4e-5.

The inverse entries are largest where display code values reach 1.0. The inverse is
steep there, because display white maps to about 128 in ACEScg. For samples whose
largest channel is below 0.95, the Rec.709 inverse is within 2.6e-4 relative.

`invdyn_rec709_to_p3_1000` takes that ill-conditioned inverse and shows it on a
1000-nit display. That is why its `max` is the largest in the table.

## GPU (OCIOGPUProcessor Metal) vs CTL, after allowing one fp16 step

| id | max | p99 |
|---|---|---|
| fwd_sdr100_rec709_srgb | 7.1e-4 | 1.7e-7 |
| fwd_sdr100_p3_srgb | 6.8e-4 | 3.5e-7 |
| fwd_hdr1000_p3_srgb | 3.55e-3 | 2.5e-6 |
| fwd_hdr1000_p3_rec2100pq | 4.0e-4 | 6.7e-5 |
| dyn_p3_100 / 400 / 1000 / 1600 / 4000 | 6.8e-4 / 1.6e-3 / 3.55e-3 / 4.1e-3 / 6.6e-4 | ≤ 1.7e-5 |
| dyn_rec709_100 | 3.3e-4 | 0 |
| rt_sdr100_rec709_srgb / p3 | 9.5e-5 / 2.5e-5 | ≤ 1.3e-5 |
| invdyn_rec709_to_p3_100 / 1000 | 2.6e-4 / 8.76e-3 | ≤ 8.2e-6 |

Before the fp16 allowance, the raw GPU error p99 was 4.9e-4 for SDR, 1.9e-3 at 1000
nits and 3.7e-3 at 4000 nits. Those are exactly the fp16 step sizes at those magnitudes.

## GPU vs CPU

| | beyond one fp16 step (max) | tolerance |
|---|---|---|
| Forward passes (display/view, Dynamic ACES2) | ≤ 1.05e-5 | 1e-4 |
| Passes starting with an inverse (rt_, invdyn_) | ≤ 3.47e-4 (invdyn 1000) | 1e-3 |

The Metal shaders reproduce the CPU result to within one fp16 output step. No
GPU-specific drift was found.

## Sensitivity check

To confirm the tests catch real drift, the peak passed to
`FIXED_FUNCTION_ACES_OUTPUT_TRANSFORM_20` in `aces2DynamicProcessorWithConfig` was raised
by 2% in a scratch build. That change was never committed. Every `dyn_*` and `invdyn_*`
case then failed on both CPU and GPU, on both `max` and `p99`. The `fwd_*`, `inv_*` and
`rt_*` cases, which do not use that code, still passed.
