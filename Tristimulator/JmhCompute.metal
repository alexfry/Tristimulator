//
//  JmhCompute.metal
//  Tristimulator
//
//  GPU compute kernels for the JMh (Hellwig 2022) polar scope.
//  Converts scene-linear RGB → XYZ → LMS → compressed response → Aab → JMh,
//  using the simplified Hellwig CAM from the ACES 2.0 display transform.
//
//  The histogram is laid out in Cartesian coordinates derived from the
//  polar (M, h) mapping:  x = M·cos(h),  y = M·sin(h),  centred in the
//  texture so (histSize/2, histSize/2) corresponds to M = 0.
//

#include <metal_stdlib>
using namespace metal;

// Parameters passed from CPU.
struct JmhParams {
    float3x3 rgbToXYZ;    // Working-space RGB → XYZ
    uint2    histSize;     // Histogram dimensions (e.g. 512×512)
    uint     stride;       // Downsample stride
    float    maxM;         // Maximum colourfulness radius (e.g. 50)
};

// Matrices copied verbatim from the ACES 2.0 output transform shader.
// AP1 RGB → sharpened LMS (line 212)
constant float3x3 ap1_to_lms = float3x3(
    0.445181042, 0.123734146, 0.0117007261,
    0.34964928, 0.613643706, 0.0280607939,
    -0.00112973328, 0.0563228093, 0.753939092
);

// AP1 RGB → XYZ
constant float3x3 ap1_to_xyz = float3x3(
    0.6624542, 0.2722287, -0.0055746,
    0.1340042, 0.6740818,  0.0040607,
    0.1561877, 0.0536895,  1.0103391
);

// Panluminance-response matrix: compressed LMS → [A, a, b] (line 215)
constant float3x3 panlrcm = float3x3(
    20.2588081, 15480., 1720.,
    10.1294041, -16887.2734, 1720.,
    0.506470203, 1407.27271, -3440.
);

// Per-bin layout in the accumulation buffer:
//   [idx*4 + 0] = sum of R (as fixed-point uint: float * 65536)
//   [idx*4 + 1] = sum of G
//   [idx*4 + 2] = sum of B
//   [idx*4 + 3] = count

// ---------------------------------------------------------------------------
// Pass 1: Accumulate JMh histogram with colour
// ---------------------------------------------------------------------------

kernel void jmhHistogram(
    texture2d<float, access::read>  srcTexture  [[texture(0)]],
    device atomic_uint*             histogram   [[buffer(0)]],
    constant JmhParams&             params      [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 pixelCoord = gid * params.stride;
    uint  texW = srcTexture.get_width();
    uint  texH = srcTexture.get_height();

    if (pixelCoord.x >= texW || pixelCoord.y >= texH) return;

    float4 color = srcTexture.read(pixelCoord);

    // Skip black / non-positive pixels
    if (color.r <= 0.0 && color.g <= 0.0 && color.b <= 0.0) return;

    // --- RGB → LMS (assumes AP1/ACEScg source for now) ---
    // Verbatim from ACES 2.0 shader line 212.
    float3 lms = ap1_to_lms * color.rgb;

    // --- Non-linear post-adaptation compression (verbatim from ACES shader) ---
    float3 F_L_v = pow(abs(lms), float3(0.419999987, 0.419999987, 0.419999987));
    float3 rgb_a = (sign(lms) * F_L_v) / (27.1299992 + F_L_v);

    // --- Opponent channels via panluminance-response matrix ---
    float3 Aab = panlrcm * rgb_a;

    // A (achromatic) must be positive for a valid lightness
    if (Aab.x <= 0.0) return;

    // --- JMh from Aab (verbatim from ACES shader) ---
    float J = 100.0 * pow(Aab.x, 1.13705599);
    float a = Aab.y;
    float b = Aab.z;
    float M = (J == 0.0) ? 0.0 : sqrt(a * a + b * b);
    float h = (a == 0.0) ? 0.0 : atan2(b, a) * 57.29577951308238;
    h = h - floor(h / 360.0) * 360.0;
    if (h < 0.0) h += 360.0;

    // Skip if M is beyond our display range
    if (M > params.maxM) return;

    // --- Polar → Cartesian histogram bin ---
    float h_rad = h * 0.0174532924;   // deg → rad
    float nx = (M * cos(h_rad)) / params.maxM * 0.5 + 0.5;
    float ny = (M * sin(h_rad)) / params.maxM * 0.5 + 0.5;

    if (nx < 0.0 || nx > 1.0 || ny < 0.0 || ny > 1.0) return;

    uint bx = uint(nx * float(params.histSize.x - 1));
    uint by = uint(ny * float(params.histSize.y - 1));

    // Flip y so bin 0 is bottom, top of texture (row 0)
    by = (params.histSize.y - 1) - by;

    uint base = (by * params.histSize.x + bx) * 4;

    // Store scene-linear RGB (no tonemapping, no clamp to 1.0).
    // Fixed-point encoding with scale 512: supports [0, 128) per channel.
    // Worst case per bin: 250k samples * 128 * 512 ≈ 16B — but typical images
    // average much lower, and bins are spread across 512×512 grid.
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
// Pass 2: Normalize → average colour per bin, boosted for visibility
// (Shared with the chromaticity scopes — identical logic.)
// ---------------------------------------------------------------------------

struct JmhNormalizeParams {
    float logMaxCount;
    float maxEDR;       // e.g. 1.0 for SDR, or display's EDR headroom
};

kernel void jmhNormalize(
    device uint*                     histogram  [[buffer(0)]],
    texture2d<float, access::write>  output     [[texture(0)]],
    constant JmhNormalizeParams&     params     [[buffer(1)]],
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
        // Compress (1, ∞) into (1, maxEDR] with Reinhard on the excess
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
