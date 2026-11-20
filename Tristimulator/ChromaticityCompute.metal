//
//  ChromaticityCompute.metal
//  Tristimulator
//
//  GPU compute kernels for chromaticity histograms:
//    - CIE 1931 Yxy: chromaticityHistogram (RGB→XYZ→xy)
//    - CIE 1976 UCS: ucsHistogram (RGB→XYZ→u'v')
//  Both share the same normalize pass (chromaticityNormalize).
//

#include <metal_stdlib>
using namespace metal;

// Histogram parameters passed from CPU.
struct ChromaticityParams {
    float3x3 rgbToXYZ;     // Working-space RGB → CIE XYZ matrix
    uint2    histSize;      // Histogram dimensions (e.g. 256×256)
    uint     stride;        // Downsample stride (sample every Nth pixel)
    uint     _pad;
};

// Per-bin layout in the accumulation buffer:
//   [idx*4 + 0] = sum of R (as fixed-point uint: float * 65536)
//   [idx*4 + 1] = sum of G
//   [idx*4 + 2] = sum of B
//   [idx*4 + 3] = count

// ---------------------------------------------------------------------------
// Pass 1: Accumulate chromaticity histogram with color
// ---------------------------------------------------------------------------

kernel void chromaticityHistogram(
    texture2d<float, access::read>  srcTexture  [[texture(0)]],
    device atomic_uint*             histogram   [[buffer(0)]],
    constant ChromaticityParams&    params      [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 pixelCoord = gid * params.stride;
    uint  texW = srcTexture.get_width();
    uint  texH = srcTexture.get_height();

    if (pixelCoord.x >= texW || pixelCoord.y >= texH) return;

    float4 color = srcTexture.read(pixelCoord);

    // Skip black / non-positive pixels
    if (color.r <= 0.0 && color.g <= 0.0 && color.b <= 0.0) return;

    // RGB → XYZ
    float3 xyz = params.rgbToXYZ * color.rgb;
    float  sum = xyz.x + xyz.y + xyz.z;
    if (sum <= 1e-7) return;

    // XYZ → CIE xy chromaticity
    float cx = xyz.x / sum;
    float cy = xyz.y / sum;

    // Clamp to diagram bounds: x ∈ [0, 0.8], y ∈ [0, 0.9]
    if (cx < 0.0 || cx > 0.8 || cy < 0.0 || cy > 0.9) return;

    // Quantize to bin coordinates
    uint bx = uint(cx / 0.8 * float(params.histSize.x - 1));
    uint by = uint(cy / 0.9 * float(params.histSize.y - 1));

    // Flip y so bin 0 is bottom of diagram (low y), top of texture (row 0)
    by = (params.histSize.y - 1) - by;

    uint base = (by * params.histSize.x + bx) * 4;

    // Store scene-linear RGB (no tonemapping, no clamp to 1.0).
    // Fixed-point encoding with scale 512: supports [0, 128) per channel.
    float3 rgb = clamp(color.rgb, 0.0, 128.0);
    uint rFixed = uint(rgb.r * 512.0);
    uint gFixed = uint(rgb.g * 512.0);
    uint bFixed = uint(rgb.b * 512.0);

    atomic_fetch_add_explicit(&histogram[base + 0], rFixed, memory_order_relaxed);
    atomic_fetch_add_explicit(&histogram[base + 1], gFixed, memory_order_relaxed);
    atomic_fetch_add_explicit(&histogram[base + 2], bFixed, memory_order_relaxed);
    atomic_fetch_add_explicit(&histogram[base + 3], 1,      memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// Pass 1b: CIE 1976 UCS u'v' histogram
// Same structure as chromaticityHistogram but projects to u'v' instead of xy.
//   u' = 4X / (X + 15Y + 3Z)
//   v' = 9Y / (X + 15Y + 3Z)
// Diagram bounds: u' ∈ [0, 0.7], v' ∈ [0, 0.65]
// ---------------------------------------------------------------------------

kernel void ucsHistogram(
    texture2d<float, access::read>  srcTexture  [[texture(0)]],
    device atomic_uint*             histogram   [[buffer(0)]],
    constant ChromaticityParams&    params      [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 pixelCoord = gid * params.stride;
    uint  texW = srcTexture.get_width();
    uint  texH = srcTexture.get_height();

    if (pixelCoord.x >= texW || pixelCoord.y >= texH) return;

    float4 color = srcTexture.read(pixelCoord);

    // Skip black / non-positive pixels
    if (color.r <= 0.0 && color.g <= 0.0 && color.b <= 0.0) return;

    // RGB → XYZ
    float3 xyz = params.rgbToXYZ * color.rgb;
    float  denom = xyz.x + 15.0 * xyz.y + 3.0 * xyz.z;
    if (denom <= 1e-7) return;

    // XYZ → CIE 1976 u'v'
    float u_prime = 4.0 * xyz.x / denom;
    float v_prime = 9.0 * xyz.y / denom;

    // Clamp to diagram bounds: u' ∈ [0, 0.7], v' ∈ [0, 0.65]
    if (u_prime < 0.0 || u_prime > 0.7 || v_prime < 0.0 || v_prime > 0.65) return;

    // Quantize to bin coordinates
    uint bx = uint(u_prime / 0.7 * float(params.histSize.x - 1));
    uint by = uint(v_prime / 0.65 * float(params.histSize.y - 1));

    // Flip y so bin 0 is bottom of diagram (low v'), top of texture (row 0)
    by = (params.histSize.y - 1) - by;

    uint base = (by * params.histSize.x + bx) * 4;

    // Store scene-linear RGB with HDR range
    float3 rgb = clamp(color.rgb, 0.0, 128.0);
    uint rFixed = uint(rgb.r * 512.0);
    uint gFixed = uint(rgb.g * 512.0);
    uint bFixed = uint(rgb.b * 512.0);

    atomic_fetch_add_explicit(&histogram[base + 0], rFixed, memory_order_relaxed);
    atomic_fetch_add_explicit(&histogram[base + 1], gFixed, memory_order_relaxed);
    atomic_fetch_add_explicit(&histogram[base + 2], bFixed, memory_order_relaxed);
    atomic_fetch_add_explicit(&histogram[base + 3], 1,      memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// Pass 2: Normalize → average color per bin, with EDR brightness
// ---------------------------------------------------------------------------

struct ChromaticityNormalizeParams {
    float logMaxCount;
    float maxEDR;       // e.g. 1.0 for SDR, or display's EDR headroom
};

kernel void chromaticityNormalize(
    device uint*                          histogram  [[buffer(0)]],
    texture2d<float, access::write>       output     [[texture(0)]],
    constant ChromaticityNormalizeParams&  params     [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = output.get_width();
    uint h = output.get_height();
    if (gid.x >= w || gid.y >= h) return;

    uint base  = (gid.y * w + gid.x) * 4;
    uint count = histogram[base + 3];

    if (count == 0) {
        output.write(float4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    // Decode fixed-point (scale 512) accumulated scene-linear colour and average
    float3 avgLinear = float3(
        float(histogram[base + 0]) / (512.0 * float(count)),
        float(histogram[base + 1]) / (512.0 * float(count)),
        float(histogram[base + 2]) / (512.0 * float(count))
    );

    // Normalize chromaticity: scale to unit peak, preserving hue/saturation
    float peak = max(max(avgLinear.r, avgLinear.g), max(avgLinear.b, 0.001));
    float3 chroma = avgLinear / peak;

    // Map scene-linear peak into EDR display range.
    // Linear up to 1.0 (SDR white), then compress above into EDR headroom.
    float displayPeak;
    if (peak <= 1.0) {
        displayPeak = peak;
    } else {
        float excess = peak - 1.0;
        float maxExcess = params.maxEDR - 1.0;
        displayPeak = 1.0 + maxExcess * excess / (excess + maxExcess);
    }

    float3 outColor = chroma * displayPeak;

    // Log-scale density → alpha/brightness boost
    float density = log2(float(count) + 1.0) / params.logMaxCount;
    density = saturate(density);

    float brightness = mix(0.6, 1.0, density);
    outColor *= brightness;

    // Ensure very dark source pixels are still visible
    float maxC = max(max(outColor.r, outColor.g), outColor.b);
    if (maxC < 0.08) {
        outColor = outColor / max(maxC, 0.001) * 0.08;
    }

    float alpha = mix(0.5, 1.0, density);

    output.write(float4(outColor, alpha), gid);
}
