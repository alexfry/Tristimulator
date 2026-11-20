import Foundation
import simd

// Returns a 3×3 matrix that converts source scene-linear RGB → AP0 (ACES2065-1),
// which is what the pre-baked ACES 2 compute shader expects as input.
func inputToAP0Matrix(header: EXRHeaderInfo) -> simd_float3x3 {
    if let cs = header.colorSpace?.trimmingCharacters(in: .whitespaces), !cs.isEmpty {
        if let m = namedMatrix(cs) { return m }
    }
    if let chroma = header.chromaticities {
        if let m = matrixFromChromaticities(chroma) { return m }
    }
    // Default: assume Linear Rec.709 — the most common non-tagged floating point content.
    return rec709_to_AP0
}

// MARK: - Named colour space lookup

private func namedMatrix(_ cs: String) -> simd_float3x3? {
    switch cs.lowercased() {
    case "aces2065-1", "lin_ap0", "linear aces", "aces":
        return matrix_identity_float3x3

    case "acescg", "lin_ap1", "linear acescg", "lin_ap1_scene":
        return ap1_to_AP0

    case "linear rec.709", "linear rec709", "linear srgb", "lin_rec709",
         "lin_srgb", "srgb - linear", "linear", "scene_linear":
        return rec709_to_AP0

    // P3-D65 and Display P3 share the same primaries
    case "linear p3-d65", "lin_p3d65",
         "linear display p3", "lin_displayp3", "apple display p3 linear":
        return p3d65_to_AP0

    default:
        return nil
    }
}

// MARK: - Hardcoded matrices (published ACES values)

// AP1 → AP0  (ACES S-2014-004 / SMPTE ST 2065-1)
private let ap1_to_AP0 = simd_float3x3(columns: (
    simd_float3( 0.6954522414,  0.0447945634, -0.0055258826),
    simd_float3( 0.1406786965,  0.8596711177,  0.0040252103),
    simd_float3( 0.1638690622,  0.0955343189,  1.0015006723)
))

// Rec.709 → AP0  (derived from published primaries via XYZ bridging)
// Rec.709: R(0.640,0.330) G(0.300,0.600) B(0.150,0.060) W D65
// AP0:     R(0.73470,0.26530) G(0.00000,1.00000) B(0.00010,-0.07700) W ACES~D60
private let rec709_to_AP0 = simd_float3x3(columns: (
    simd_float3( 0.4397010,  0.0897923,  0.0175440),
    simd_float3( 0.3829780,  0.8134230,  0.1115440),
    simd_float3( 0.1773350,  0.0967616,  0.8707040)
))

// P3-D65 → AP0  (derived from P3 primaries R(0.680,0.320) G(0.265,0.690) B(0.150,0.060) W D65)
private let p3d65_to_AP0 = simd_float3x3(columns: (
    simd_float3( 0.4868992,  0.0885786,  0.0174416),
    simd_float3( 0.3495517,  0.8148415,  0.1064070),
    simd_float3( 0.1635491,  0.0965799,  0.8761514)
))

// MARK: - Chromaticity-derived matrix

// Given any set of RGB primaries + white point, computes RGB → AP0.
// Returns nil if the chromaticity data is degenerate.
func matrixFromChromaticities(_ c: EXRChromaticities) -> simd_float3x3? {
    guard let srcToXYZ = rgbToXYZ(rx: c.rx, ry: c.ry,
                                   gx: c.gx, gy: c.gy,
                                   bx: c.bx, by: c.by,
                                   wx: c.wx, wy: c.wy),
          let ap0ToXYZ = rgbToXYZ(rx: 0.73470, ry: 0.26530,
                                   gx: 0.00000, gy: 1.00000,
                                   bx: 0.00010, by: -0.07700,
                                   wx: 0.32168, wy: 0.33767),
          let xyzToAP0 = inverse3x3(ap0ToXYZ)
    else { return nil }

    return xyzToAP0 * srcToXYZ
}

// Builds the RGB → XYZ matrix for a set of primaries and white point.
// Returns nil if the primary matrix is singular.
private func rgbToXYZ(rx: Float, ry: Float,
                      gx: Float, gy: Float,
                      bx: Float, by: Float,
                      wx: Float, wy: Float) -> simd_float3x3? {
    // Convert xy chromaticities to XYZ (with Y=1)
    let Xr = rx / ry;  let Zr = (1 - rx - ry) / ry
    let Xg = gx / gy;  let Zg = (1 - gx - gy) / gy
    let Xb = bx / by;  let Zb = (1 - bx - by) / by

    let M = simd_float3x3(columns: (
        simd_float3(Xr, 1.0, Zr),
        simd_float3(Xg, 1.0, Zg),
        simd_float3(Xb, 1.0, Zb)
    ))

    guard let Minv = inverse3x3(M) else { return nil }

    let W = simd_float3(wx / wy, 1.0, (1 - wx - wy) / wy)
    let S = Minv * W

    // Scale columns by S so that white maps to white
    return simd_float3x3(columns: (
        simd_float3(Xr * S.x, 1.0 * S.x, Zr * S.x),
        simd_float3(Xg * S.y, 1.0 * S.y, Zg * S.y),
        simd_float3(Xb * S.z, 1.0 * S.z, Zb * S.z)
    ))
}

// 3×3 matrix inverse via cofactor expansion.
private func inverse3x3(_ m: simd_float3x3) -> simd_float3x3? {
    let c = m.columns
    let (a, b, c2) = (c.0, c.1, c.2)

    let det =  a.x * (b.y * c2.z - b.z * c2.y)
             - a.y * (b.x * c2.z - b.z * c2.x)
             + a.z * (b.x * c2.y - b.y * c2.x)

    guard abs(det) > 1e-10 else { return nil }
    let inv = 1 / det

    return simd_float3x3(columns: (
        simd_float3(
             (b.y * c2.z - b.z * c2.y) * inv,
            -(a.y * c2.z - a.z * c2.y) * inv,
             (a.y * b.z  - a.z * b.y)  * inv
        ),
        simd_float3(
            -(b.x * c2.z - b.z * c2.x) * inv,
             (a.x * c2.z - a.z * c2.x) * inv,
            -(a.x * b.z  - a.z * b.x)  * inv
        ),
        simd_float3(
             (b.x * c2.y - b.y * c2.x) * inv,
            -(a.x * c2.y - a.y * c2.x) * inv,
             (a.x * b.y  - a.y * b.x)  * inv
        )
    ))
}
