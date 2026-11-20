# OCIO GPU / MSL: `TEXTURE_RGB_CHANNEL` Reported for Single-Channel 1D LUTs

## Summary

When using OCIO's GPU shader path with `GPU_LANGUAGE_MSL_2_0`, the
`GpuShaderDesc::getTexture()` API reports `TEXTURE_RGB_CHANNEL` for **some 1D
LUTs that are actually single-channel**.  The generated MSL shader code
contradicts this — it declares those textures as `texture1d<float>` and only
ever reads the `.r` component via a `float`-returning helper function.
Allocating a buffer based on the reported channel count causes a **3× buffer
over-read**, uploading two extra pages of uninitialised heap memory as LUT data,
and producing completely wrong (or effectively black) rendered output.

Confirmed with:

- OCIO **2.5.0**
- `GPU_LANGUAGE_MSL_2_0`
- ACES studio config v4.0.0 / ACES v2.0 / OCIO v2.5
- Display transform: ACES 2.0 (ACES Output Transform v2.0)
- Platform: Apple Silicon / Metal


---

## Background

The ACES 2.0 Output Transform uses two 1D LUTs generated at shader-compilation
time:

| Texture name | OCIO-reported channels | Shader type | Shader accessor |
|---|---|---|---|
| `ocio_reach_m_table_0` | `TEXTURE_RGB_CHANNEL` (3) | `texture1d<float>` | `.r` only |
| `ocio_gamut_cusp_table_0` | `TEXTURE_RGB_CHANNEL` (3) | `texture1d<float>` | `.r` only (per axis, via a loop) |

Both textures are reported as 3-channel by the API.  Both are only
single-channel in reality (and in the generated shader).


---

## The Bug

When a Metal (or any GPU) application queries LUT metadata and allocates upload
buffers using the reported channel count, it does:

```cpp
// Reported by GpuShaderDesc::getTexture():
//   width  = 362
//   height = 1
//   channel = TEXTURE_RGB_CHANNEL  →  channelCount = 3
size_t dataSize = width * height * channelCount * sizeof(float);
//             = 362   * 1      * 3             * 4
//             = 4344 bytes

// But OCIO only writes 362 * 1 * sizeof(float) = 1448 bytes into `values`
NSData *data = [NSData dataWithBytes:values length:dataSize];
//                                            ^^^^ reads 2896 extra bytes
```

The `values` pointer returned by `getTexture()` only contains
`width × 1 × sizeof(float) = 1448 bytes` of valid data.  Reading 4344 bytes
past it yields garbage values from uninitialised heap memory.  In our case,
LUT texels past index ~120 contained values such as `2.88e32`, causing the
ACES 2.0 gamut-compression path to fail silently and produce `(0, 0, 0)` for
essentially every pixel.


---

## Diagnosis

### Step 1 — CPU / GPU comparison

Running the same transform on the CPU reference path
(`OCIO::CPUProcessor::applyRGB`) gave correct output immediately.  The GPU path
produced near-black.  This pointed to the LUT data, not the shader math.

### Step 2 — Raw buffer inspection

Dumping the raw floats that were being uploaded to the `reach_m_table_0`
texture:

```
texel[119] = 394.51   ✅ valid
texel[120] = 393.89   ✅ valid
texel[121] = 2.88e32  ❌ garbage
texel[122] = 7.56e28  ❌ garbage
```

The corruption boundary at ~texel 120 corresponds exactly to the valid
1-channel length (`1448 / 4 = 362 / 3 ≈ 120`).

### Step 3 — Shader inspection

The OCIO-generated MSL for both textures:

```metal
// Texture declaration — note: texture1d<float>, not texture1d<float3>
void ocio_reach_m_table_0_sample(float index,
                                  texture1d<float> lut,
                                  sampler samp,
                                  thread float & outValue)
{
    float fi = (index + 0.5) / 362.0;
    outValue = lut.sample(samp, fi).r;   // ← only .r
}
```

The return type is `float`, not `float3`.  This is the definitive indicator that
only one channel of data is present, regardless of what `getTexture()` reports.


---

## Root Cause

`GpuShaderDesc::getTexture()` returns `TEXTURE_RGB_CHANNEL` for these textures,
but:

1. OCIO's internal buffer for `reach_m_table_0` and `gamut_cusp_table_0`
   contains only `width × 1 × sizeof(float)` bytes of valid data.
2. The generated MSL shader accesses only the `.r` channel.
3. The channel enum value does not accurately describe the data layout for these
   particular LUTs.

It is unclear whether this is an intentional convention (the enum reflects the
GPU texture *format* that should be created, which for `texture1d<float>` has an
implicit R-only format), or a straightforward bug in how OCIO populates the enum
for scalar 1D LUTs.  Either way, blindly allocating `width * channelCount * 4`
bytes and passing that to `dataWithBytes:length:` is unsafe.


---

## Fix

The reliable discriminator is the **return type of the OCIO-generated helper
function**:

- `float  <textureName>_sample(...)` → single-channel, allocate `width * 1 * 4` bytes
- `float3 <textureName>_sample(...)` → three-channel, allocate `width * 3 * 4` bytes

```swift
/// Returns true if the generated shader treats this texture as multi-channel.
/// OCIO always emits `float3 <name>_sample(...)` for RGB textures and
/// `float <name>_sample(...)` for R-only textures.
private func shaderSamplesRGB(textureName: String, shaderCode: String) -> Bool {
    if shaderCode.contains("float3 \(textureName)_sample") { return true  }
    if shaderCode.contains("float \(textureName)_sample")  { return false }
    return false  // safe default: treat as single-channel
}
```

Applied during LUT buffer allocation:

```swift
var channels = textureInfo["channels"] as? Int ?? 1  // from getTexture()
if channels == 3 && !shaderSamplesRGB(textureName: name, shaderCode: metalShaderCode) {
    // OCIO reports 3ch but shader only reads .r — override to avoid over-read
    channels = 1
}
let validFloatCount = width * channels
// allocate / copy only `validFloatCount * sizeof(float)` bytes
```

This check is zero-cost (a single string scan of the already-retrieved shader
source) and correctly handles both cases:

| Texture | `getTexture()` reports | Helper fn return type | Effective channels |
|---|---|---|---|
| `ocio_reach_m_table_0` | `TEXTURE_RGB_CHANNEL` | `float` | **1** (corrected) |
| `ocio_gamut_cusp_table_0` | `TEXTURE_RGB_CHANNEL` | `float` | **1** (corrected) |

> **Note:** in theory a future OCIO build might produce a different transform
> with a genuinely 3-channel `float3`-returning 1D LUT.  The helper-function
> approach handles that correctly too, because it reads the actual generated code
> rather than relying on the metadata enum.


---

## Recommendations for the OCIO Project

1. **Documentation**: Clarify whether `TEXTURE_RGB_CHANNEL` on a 1D LUT means
   "the data buffer contains RGB interleaved floats" or "you should create an
   RGB-format GPU texture" (which for 1D textures is ambiguous).

2. **API alignment**: If `TEXTURE_RGB_CHANNEL` is returned, the `values` pointer
   should point to `width * 3 * sizeof(float)` bytes of valid data, or the enum
   value should be `TEXTURE_RED_CHANNEL` when the data is scalar.

3. **Test coverage**: Add a Metal/MSL integration test that round-trips the ACES
   2.0 Output Transform through the GPU path and compares output against
   `CPUProcessor` for at least one known pixel value.


---

## Reproduction

- Open any ACES 2065-1 scene-linear EXR in an application using OCIO's MSL GPU
  path with the ACES studio config v4.0.0.
- Apply the display transform "Display P3 HDR - Display / ACES 2.0 - HDR 1000 nits".
- Allocate LUT upload buffers using `width * channelCount * sizeof(float)` where
  `channelCount` is derived from `getTexture()`'s `channels` parameter.
- Compare GPU output to CPU reference — GPU will be effectively black for all
  pixels that pass through the ACES 2.0 gamut-compression path (i.e. nearly
  every pixel in a typical scene).


---

*Discovered and fixed in Tristimulator (formerly ImageScope),
a Metal-based HDR/ACES image viewer.  March 2026.*
