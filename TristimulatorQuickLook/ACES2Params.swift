import Foundation
import simd

// Values stored in OCIO-shader-compatible form: each field maps 1:1 to a
// baked literal in the generated Metal source, so string-replacement is trivial.
struct ACES2Uniforms {
    var m_2: Float
    var s_2: Float              // CTL s_2 * F_L (OCIO's tonescale denominator)
    var t_1: Float
    var g: Float
    var limit_J_max: Float
    var model_gamma_inv: Float
    var sat: Float
    var sat_thr: Float
    var compr: Float
    var chroma_compress_scale: Float
    var mid_J: Float
    var focus_dist: Float       // CTL limit_J_max * focus_dist (OCIO pre-multiplies)
    var lower_hull_gamma_inv: Float
}

func makeACES2Uniforms(peakNits: Double) -> ACES2Uniforms {
    let ts = initTSParams(peakLuminance: peakNits)
    let limit_J_max = Y_to_J_ap0(Y: peakNits)

    let sat = max(0.2, 1.3 - (1.3 * 0.69) * ts.log_peak)
    let sat_thr = 0.5 / peakNits
    let compr = 2.4 + (2.4 * 3.3) * ts.log_peak
    let chroma_compress_scale = pow(0.03379 * peakNits, 0.30596) - 0.45135

    let mid_J = Y_to_J_ap0(Y: ts.c_t * 100.0)
    let focus_dist_raw = 1.35 + 1.35 * 1.75 * ts.log_peak
    let lower_hull_gamma_inv = 1.0 / (1.14 + 0.07 * ts.log_peak)
    let model_gamma_inv = 1.0 / kModelGamma

    return ACES2Uniforms(
        m_2:                    Float(ts.m_2),
        s_2:                    Float(ts.s_2 * kF_L),
        t_1:                    Float(ts.t_1),
        g:                      Float(ts.g),
        limit_J_max:            Float(limit_J_max),
        model_gamma_inv:        Float(model_gamma_inv),
        sat:                    Float(sat),
        sat_thr:                Float(sat_thr),
        compr:                  Float(compr),
        chroma_compress_scale:  Float(chroma_compress_scale),
        mid_J:                  Float(mid_J),
        focus_dist:             Float(limit_J_max * focus_dist_raw),
        lower_hull_gamma_inv:   Float(lower_hull_gamma_inv)
    )
}

// MARK: - Fixed viewing-condition constants (L_A=100, Y_b=20, dim surround)

private let kL_A: Double = 100.0
private let kRefLuminance: Double = 100.0
private let kCamNLOffset: Double = 0.2713 * 100.0  // 27.13

private let kModelGamma: Double = {
    let Y_b: Double = 20.0
    return 0.59 * (1.48 + sqrt(Y_b / 100.0))
}()

private let kF_L: Double = {
    let k = 1.0 / (5.0 * kL_A + 1.0)
    let k4 = k * k * k * k
    return 0.2 * k4 * (5.0 * kL_A) + 0.1 * pow(1.0 - k4, 2.0) * pow(5.0 * kL_A, 1.0 / 3.0)
}()

private let kF_L_n: Double = kF_L / kRefLuminance

private let kA_w_J: Double = {
    let F_L_Y = pow(kF_L, 0.42)
    return F_L_Y / (kCamNLOffset + F_L_Y)
}()

// MARK: - Tonescale (Lib.Academy.Tonescale.ctl)

private struct TSParams {
    var g, t_1, c_t, s_2, m_2, log_peak: Double
}

private func initTSParams(peakLuminance n: Double) -> TSParams {
    let n_r = 100.0, g = 1.15, c = 0.18, c_d = 10.013, w_g = 0.14
    let t_1 = 0.04, r_hit_min = 128.0, r_hit_max = 896.0

    let r_hit = r_hit_min + (r_hit_max - r_hit_min) * (log(n / n_r) / log(10000.0 / 100.0))
    let m_0 = n / n_r
    let m_1 = 0.5 * (m_0 + sqrt(m_0 * (m_0 + 4.0 * t_1)))
    let u = pow((r_hit / m_1) / ((r_hit / m_1) + 1.0), g)
    let m = m_1 / u
    let w_i = log(n / 100.0) / log(2.0)
    let c_t = c_d / n_r * (1.0 + w_i * w_g)
    let g_ip = 0.5 * (c_t + sqrt(c_t * (c_t + 4.0 * t_1)))
    let g_ipp2 = -(m_1 * pow(g_ip / m, 1.0 / g)) / (pow(g_ip / m, 1.0 / g) - 1.0)
    let w_2 = c / g_ipp2
    let s_2 = w_2 * m_1
    let u_2 = pow((r_hit / m_1) / ((r_hit / m_1) + w_2), g)
    let m_2 = m_1 / u_2

    return TSParams(g: g, t_1: t_1, c_t: c_t, s_2: s_2, m_2: m_2, log_peak: log10(n / n_r))
}

// MARK: - Y_to_J for AP0 (fixed viewing conditions)

private func Y_to_J_ap0(Y: Double) -> Double {
    let Ra_num = pow(abs(Y) * kF_L_n, 0.42)
    let Ra = Ra_num / (kCamNLOffset + Ra_num)
    let J = 100.0 * pow(Ra / kA_w_J, kModelGamma)
    return Y >= 0 ? J : -J
}

// MARK: - CAM16 JMh Model (for runtime LUT generation)

private struct JMhParams {
    let matRGBToCAM16c: simd_double3x3
    let matCAM16cToRGB: simd_double3x3
    let matConeRespToAab: simd_double3x3
    let matAabToConeResp: simd_double3x3
}

private let kInvCz = 1.0 / kModelGamma
private let kCamNLScale = 4.0 * 100.0
private let kAbScale = 43.0 * 0.9

private func rgbToXYZMatrix(
    rx: Double, ry: Double, gx: Double, gy: Double,
    bx: Double, by: Double, wx: Double, wy: Double
) -> simd_double3x3 {
    let r = simd_double3(rx / ry, 1.0, (1.0 - rx - ry) / ry)
    let g = simd_double3(gx / gy, 1.0, (1.0 - gx - gy) / gy)
    let b = simd_double3(bx / by, 1.0, (1.0 - bx - by) / by)
    let w = simd_double3(wx / wy, 1.0, (1.0 - wx - wy) / wy)
    let M = simd_double3x3(columns: (r, g, b))
    let S = M.inverse * w
    return simd_double3x3(columns: (S[0] * r, S[1] * g, S[2] * b)).transpose
}

private func coneResponseCompressFwd(_ v: Double) -> Double {
    let absV = abs(v)
    let p = pow(absV, 0.42)
    return copysign(p / (kCamNLOffset + p), v)
}

private func coneResponseCompressInv(_ v: Double) -> Double {
    let absV = abs(v)
    let Ra = min(absV, 0.99)
    return copysign(pow(kCamNLOffset * Ra / (1.0 - Ra), 1.0 / 0.42), v)
}

private func initJMhParams(
    rx: Double, ry: Double, gx: Double, gy: Double,
    bx: Double, by: Double, wx: Double, wy: Double
) -> JMhParams {
    let rgbToXYZ = rgbToXYZMatrix(rx: rx, ry: ry, gx: gx, gy: gy,
                                   bx: bx, by: by, wx: wx, wy: wy)
    let cam16 = rgbToXYZMatrix(
        rx: 0.8336, ry: 0.1735, gx: 2.3854, gy: -1.4659,
        bx: 0.087, by: -0.125, wx: 0.333, wy: 0.333
    ).inverse

    let xyzW = simd_mul(simd_double3(repeating: kRefLuminance), rgbToXYZ)
    let Y_w = xyzW[1]
    let rgbW = simd_mul(xyzW, cam16)

    let D_RGB = simd_double3(
        kF_L_n * Y_w / rgbW[0],
        kF_L_n * Y_w / rgbW[1],
        kF_L_n * Y_w / rgbW[2]
    )

    let matRGBToCAM16c = simd_mul(
        kRefLuminance * simd_mul(rgbToXYZ, cam16),
        simd_double3x3(diagonal: D_RGB)
    )

    let baseCRA = simd_double3x3(rows: [
        simd_double3(2.0, 1.0, 1.0 / 9.0),
        simd_double3(1.0, -12.0 / 11.0, 1.0 / 9.0),
        simd_double3(1.0 / 20.0, 1.0 / 11.0, -2.0 / 9.0)
    ])
    let cra = kCamNLScale * baseCRA

    let rgbWc = D_RGB * rgbW
    let rgbAw = simd_double3(
        coneResponseCompressFwd(rgbWc[0]),
        coneResponseCompressFwd(rgbWc[1]),
        coneResponseCompressFwd(rgbWc[2])
    )
    let A_w = simd_dot(cra[0], rgbAw)

    let matConeRespToAab = simd_double3x3(columns: (
        cra[0] / A_w,
        cra[1] * kAbScale,
        cra[2] * kAbScale
    ))

    return JMhParams(
        matRGBToCAM16c: matRGBToCAM16c,
        matCAM16cToRGB: matRGBToCAM16c.inverse,
        matConeRespToAab: matConeRespToAab,
        matAabToConeResp: matConeRespToAab.inverse
    )
}

private func JMhToRGB(J: Double, M: Double, h: Double, params: JMhParams) -> simd_double3 {
    let hRad = h * .pi / 180.0
    let A = pow(J / 100.0, kInvCz)
    let Aab = simd_double3(A, M * cos(hRad), M * sin(hRad))

    let rgbA = simd_mul(Aab, params.matAabToConeResp)
    let rgbM = simd_double3(
        coneResponseCompressInv(rgbA[0]),
        coneResponseCompressInv(rgbA[1]),
        coneResponseCompressInv(rgbA[2])
    )
    return simd_mul(rgbM, params.matCAM16cToRGB)
}

private let kReachParams: JMhParams = {
    initJMhParams(
        rx: 0.713, ry: 0.293, gx: 0.165, gy: 0.830,
        bx: 0.128, by: 0.044, wx: 0.32168, wy: 0.33767
    )
}()

func makeReachMTable(peakNits: Double) -> [Float] {
    let limitJMax = Y_to_J_ap0(Y: peakNits)
    let tableSize = 360
    var table = [Float](repeating: 0, count: tableSize + 2)

    for i in 0..<tableSize {
        let hue = Double(i)
        var low = 0.0
        var high = 50.0

        while high < 1300.0 {
            let rgb = JMhToRGB(J: limitJMax, M: high, h: hue, params: kReachParams)
            if rgb.x < 0 || rgb.y < 0 || rgb.z < 0 { break }
            low = high
            high += 50.0
        }

        while high - low > 0.01 {
            let mid = (high + low) / 2.0
            let rgb = JMhToRGB(J: limitJMax, M: mid, h: hue, params: kReachParams)
            if rgb.x < 0 || rgb.y < 0 || rgb.z < 0 {
                high = mid
            } else {
                low = mid
            }
        }

        table[i + 1] = Float(high)
    }

    table[0] = table[tableSize]
    table[tableSize + 1] = table[1]
    return table
}

// MARK: - Forward CAM16 (RGB → JMh)

private func RGBToAab(_ rgb: simd_double3, params: JMhParams) -> simd_double3 {
    let rgbM = simd_mul(rgb, params.matRGBToCAM16c)
    let rgbA = simd_double3(
        coneResponseCompressFwd(rgbM[0]),
        coneResponseCompressFwd(rgbM[1]),
        coneResponseCompressFwd(rgbM[2])
    )
    return simd_mul(rgbA, params.matConeRespToAab)
}

private func RGBToJMh(_ rgb: simd_double3, params: JMhParams) -> simd_double3 {
    let Aab = RGBToAab(rgb, params: params)
    if Aab[0] <= 0 { return simd_double3(0, 0, 0) }
    let J = 100.0 * pow(Aab[0], kModelGamma)
    let M = sqrt(Aab[1] * Aab[1] + Aab[2] * Aab[2])
    var h = atan2(Aab[2], Aab[1]) * 180.0 / .pi
    if h < 0 { h += 360.0 }
    return simd_double3(J, M, h)
}

// MARK: - P3-D65 limiting primaries

private let kLimitParams: JMhParams = {
    initJMhParams(
        rx: 0.680, ry: 0.320, gx: 0.265, gy: 0.690,
        bx: 0.150, by: 0.060, wx: 0.3127, wy: 0.3290
    )
}()

// MARK: - Gamut cusp table generation

private let kCuspCornerCount = 6
private let kTotalCornerCount = kCuspCornerCount + 2
private let kTableSize = 360
private let kTotalTableSize = kTableSize + 2
private let kBaseIndex = 1
private let kHueLimit = 360.0
private let kMaxSortedCorners = 2 * kCuspCornerCount
private let kSmoothM = 0.27
private let kSmoothCusps = 0.12

private func generateUnitCubeCuspCorner(_ corner: Int) -> simd_double3 {
    let r: Double = ((corner + 1) % kCuspCornerCount) < 3 ? 1 : 0
    let g: Double = ((corner + 5) % kCuspCornerCount) < 3 ? 1 : 0
    let b: Double = ((corner + 3) % kCuspCornerCount) < 3 ? 1 : 0
    return simd_double3(r, g, b)
}

private func buildLimitingCuspCorners(
    params: JMhParams, peakLuminance: Double
) -> (rgb: [simd_double3], jmh: [simd_double3]) {
    var tempRGB = [simd_double3](repeating: .zero, count: kCuspCornerCount)
    var tempJMh = [simd_double3](repeating: .zero, count: kCuspCornerCount)
    var minIndex = 0

    for i in 0..<kCuspCornerCount {
        tempRGB[i] = (peakLuminance / kRefLuminance) * generateUnitCubeCuspCorner(i)
        tempJMh[i] = RGBToJMh(tempRGB[i], params: params)
        if tempJMh[i][2] < tempJMh[minIndex][2] { minIndex = i }
    }

    var rgbCorners = [simd_double3](repeating: .zero, count: kTotalCornerCount)
    var jmhCorners = [simd_double3](repeating: .zero, count: kTotalCornerCount)
    for i in 0..<kCuspCornerCount {
        rgbCorners[i + 1] = tempRGB[(i + minIndex) % kCuspCornerCount]
        jmhCorners[i + 1] = tempJMh[(i + minIndex) % kCuspCornerCount]
    }
    rgbCorners[0] = rgbCorners[kCuspCornerCount]
    rgbCorners[kCuspCornerCount + 1] = rgbCorners[1]
    jmhCorners[0] = jmhCorners[kCuspCornerCount]
    jmhCorners[kCuspCornerCount + 1] = jmhCorners[1]
    jmhCorners[0][2] -= kHueLimit
    jmhCorners[kCuspCornerCount + 1][2] += kHueLimit

    return (rgbCorners, jmhCorners)
}

private func findReachCornersTable(
    reachParams: JMhParams, limitJMax: Double, forwardLimit: Double
) -> [simd_double3] {
    var tempJMh = [simd_double3](repeating: .zero, count: kCuspCornerCount)
    let limitA = pow(limitJMax / 100.0, kInvCz)
    var minIndex = 0

    for i in 0..<kCuspCornerCount {
        let rgbVec = generateUnitCubeCuspCorner(i)
        var lower = 0.0
        var upper = forwardLimit
        while upper - lower > 1e-3 {
            let test = (lower + upper) / 2.0
            let A = RGBToAab(test * rgbVec, params: reachParams)[0]
            if A < limitA { lower = test } else { upper = test }
        }
        tempJMh[i] = RGBToJMh(upper * rgbVec, params: reachParams)
        if tempJMh[i][2] < tempJMh[minIndex][2] { minIndex = i }
    }

    var corners = [simd_double3](repeating: .zero, count: kTotalCornerCount)
    for i in 0..<kCuspCornerCount {
        corners[i + 1] = tempJMh[(i + minIndex) % kCuspCornerCount]
    }
    corners[0] = corners[kCuspCornerCount]
    corners[kCuspCornerCount + 1] = corners[1]
    corners[0][2] -= kHueLimit
    corners[kCuspCornerCount + 1][2] += kHueLimit

    return corners
}

private func extractSortedCubeHues(
    reach: [simd_double3], limit: [simd_double3]
) -> [Double] {
    var sorted = [Double](repeating: 0, count: kMaxSortedCorners)
    var idx = 0, ri = 1, li = 1
    while ri < kCuspCornerCount + 1 || li < kCuspCornerCount + 1 {
        let rh = ri < kCuspCornerCount + 1 ? reach[ri][2] : Double.greatestFiniteMagnitude
        let lh = li < kCuspCornerCount + 1 ? limit[li][2] : Double.greatestFiniteMagnitude
        if rh == lh {
            sorted[idx] = rh; ri += 1; li += 1
        } else if rh < lh {
            sorted[idx] = rh; ri += 1
        } else {
            sorted[idx] = lh; li += 1
        }
        idx += 1
    }
    return Array(sorted[0..<idx])
}

private func buildHueTable(_ sortedHues: [Double]) -> [Double] {
    var hueTable = [Double](repeating: 0, count: kTotalTableSize)
    let idealSpacing = Double(kTableSize) / kHueLimit

    var samplesCount = [Int](repeating: 0, count: sortedHues.count + 2)
    var minIndex = sortedHues[0] == 0.0 ? 0 : 1
    var lastIdx = 0

    for hi in 0..<sortedHues.count {
        var nominalIdx = min(max(Int(round(sortedHues[hi] * idealSpacing)), minIndex), kTableSize - 1)
        if lastIdx == nominalIdx {
            if hi > 1 && samplesCount[hi - 2] != samplesCount[hi - 1] - 1 {
                samplesCount[hi - 1] -= 1
            } else {
                nominalIdx += 1
            }
        }
        samplesCount[hi] = min(nominalIdx, kTableSize - 1)
        minIndex = nominalIdx
        lastIdx = minIndex
    }

    var totalSamples = 0
    func fillInterval(samples: Int, lower: Double, upper: Double, base: Int) {
        let delta = samples > 0 ? (upper - lower) / Double(samples) : 0
        for j in 0..<samples {
            hueTable[base + j] = lower + Double(j) * delta
        }
    }

    fillInterval(samples: samplesCount[0], lower: 0, upper: sortedHues[0], base: totalSamples + 1)
    totalSamples += samplesCount[0]

    for i in 1..<sortedHues.count {
        let samples = samplesCount[i] - samplesCount[i - 1]
        fillInterval(samples: samples, lower: sortedHues[i - 1], upper: sortedHues[i],
                     base: totalSamples + 1)
        totalSamples += samples
    }

    let remaining = kTableSize - totalSamples
    fillInterval(samples: remaining, lower: sortedHues.last!, upper: kHueLimit,
                 base: totalSamples + 1)

    hueTable[0] = hueTable[kBaseIndex + kTableSize - 1] - kHueLimit
    hueTable[kBaseIndex + kTableSize] = hueTable[kBaseIndex] + kHueLimit

    return hueTable
}

private func findDisplayCuspForHue(
    hue: Double,
    rgbCorners: [simd_double3], jmhCorners: [simd_double3],
    params: JMhParams
) -> (J: Double, M: Double) {
    var upperCorner = 1
    for i in 1..<kTotalCornerCount {
        if jmhCorners[i][2] > hue { upperCorner = i; break }
    }
    let lowerCorner = upperCorner - 1

    if jmhCorners[lowerCorner][2] == hue {
        return (jmhCorners[lowerCorner][0], jmhCorners[lowerCorner][1])
    }

    let cuspLower = rgbCorners[lowerCorner]
    let cuspUpper = rgbCorners[upperCorner]
    var lowerT = 0.0, upperT = 1.0

    while upperT - lowerT > 1e-7 {
        let sampleT = (lowerT + upperT) / 2.0
        let sample = mix(cuspLower, cuspUpper, t: sampleT)
        let jmh = RGBToJMh(sample, params: params)
        if jmh[2] < jmhCorners[lowerCorner][2] {
            upperT = sampleT
        } else if jmh[2] >= jmhCorners[upperCorner][2] {
            lowerT = sampleT
        } else if jmh[2] > hue {
            upperT = sampleT
        } else {
            lowerT = sampleT
        }
    }

    let finalT = (lowerT + upperT) / 2.0
    let sample = mix(cuspLower, cuspUpper, t: finalT)
    let jmh = RGBToJMh(sample, params: params)
    return (jmh[0], jmh[1])
}

// Gamut compression helpers needed for upper hull gamma
private func computeFocusJ(cuspJ: Double, midJ: Double, limitJMax: Double) -> Double {
    let cuspMidBlend = 1.3
    return cuspJ + (midJ - cuspJ) * min(1, cuspMidBlend - cuspJ / limitJMax)
}

private func getFocusGain(J: Double, threshold: Double, limitJMax: Double, focusDist: Double) -> Double {
    var gain = limitJMax * focusDist
    if J > threshold {
        let adj = log10((limitJMax - threshold) / max(0.0001, limitJMax - J))
        gain *= (adj * adj + 1.0)
    }
    return gain
}

private func solveJIntersect(J: Double, M: Double, focusJ: Double, maxJ: Double, slopeGain: Double) -> Double {
    let ms = M / slopeGain
    let a = ms / focusJ
    if J < focusJ {
        let b = 1.0 - ms
        let c = -J
        let det = b * b - 4.0 * a * c
        return -2.0 * c / (b + sqrt(det))
    } else {
        let b = -(1.0 + ms + maxJ * a)
        let c = maxJ * ms + J
        let det = b * b - 4.0 * a * c
        return -2.0 * c / (b - sqrt(det))
    }
}

private func computeCompressionSlope(intersectJ: Double, focusJ: Double, limitJMax: Double, slopeGain: Double) -> Double {
    let dir = intersectJ < focusJ ? intersectJ : limitJMax - intersectJ
    return dir * (intersectJ - focusJ) / (focusJ * slopeGain)
}

private func sminScaled(_ a: Double, _ b: Double, scaleRef: Double) -> Double {
    let s = kSmoothCusps * scaleRef
    let h = max(s - abs(a - b), 0.0) / s
    return min(a, b) - h * h * h * s / 6.0
}

private func estimateLineBoundaryIntersectionM(
    jAxisIntersect: Double, slope: Double, invGamma: Double,
    jMax: Double, mMax: Double, jRef: Double
) -> Double {
    let nJ = jAxisIntersect / jRef
    let shifted = jRef * pow(nJ, invGamma)
    return shifted * mMax / (jMax - slope * mMax)
}

private func findGamutBoundaryIntersection(
    jmCusp: (Double, Double), jMax: Double,
    gammaTopInv: Double, gammaBotInv: Double,
    jIntSrc: Double, slope: Double, jIntCusp: Double
) -> Double {
    let mLower = estimateLineBoundaryIntersectionM(
        jAxisIntersect: jIntSrc, slope: slope, invGamma: gammaBotInv,
        jMax: jmCusp.0, mMax: jmCusp.1, jRef: jIntCusp)
    let fJIntCusp = jMax - jIntCusp
    let fJIntSrc = jMax - jIntSrc
    let fCuspJ = jMax - jmCusp.0
    let mUpper = estimateLineBoundaryIntersectionM(
        jAxisIntersect: fJIntSrc, slope: -slope, invGamma: gammaTopInv,
        jMax: fCuspJ, mMax: jmCusp.1, jRef: fJIntCusp)
    return sminScaled(mLower, mUpper, scaleRef: jmCusp.1)
}

private func evaluateGammaFit(
    jmCusp: (Double, Double), hue: Double,
    limitJMax: Double, midJ: Double, focusDist: Double,
    topGammaInv: Double, lowerHullGammaInv: Double,
    peakLuminance: Double, limitParams: JMhParams
) -> Bool {
    let focusGainBlend = 0.3
    let testPositions: [Double] = [0.01, 0.1, 0.5, 0.8, 0.99]
    let focusJ = computeFocusJ(cuspJ: jmCusp.0, midJ: midJ, limitJMax: limitJMax)
    let threshold = jmCusp.0 + (limitJMax - jmCusp.0) * focusGainBlend
    let lumLimit = peakLuminance / kRefLuminance

    for pos in testPositions {
        let testJ = jmCusp.0 + (limitJMax - jmCusp.0) * pos
        let gain = getFocusGain(J: testJ, threshold: threshold, limitJMax: limitJMax, focusDist: focusDist)
        let jInt = solveJIntersect(J: testJ, M: jmCusp.1, focusJ: focusJ, maxJ: limitJMax, slopeGain: gain)
        let slope = computeCompressionSlope(intersectJ: jInt, focusJ: focusJ, limitJMax: limitJMax, slopeGain: gain)
        let jIntCusp = solveJIntersect(J: jmCusp.0, M: jmCusp.1, focusJ: focusJ, maxJ: limitJMax, slopeGain: gain)

        let approxM = findGamutBoundaryIntersection(
            jmCusp: jmCusp, jMax: limitJMax,
            gammaTopInv: topGammaInv, gammaBotInv: lowerHullGammaInv,
            jIntSrc: jInt, slope: slope, jIntCusp: jIntCusp)
        let approxJ = jInt + slope * approxM
        let rgb = JMhToRGB(J: approxJ, M: approxM, h: hue, params: limitParams)
        if rgb.x <= lumLimit && rgb.y <= lumLimit && rgb.z <= lumLimit { return false }
    }
    return true
}

func makeGamutCuspTable(peakNits: Double) -> (table: [Float], hues: [Double]) {
    let ts = initTSParams(peakLuminance: peakNits)
    let limitJMax = Y_to_J_ap0(Y: peakNits)
    let midJ = Y_to_J_ap0(Y: ts.c_t * 100.0)
    let focusDistRaw = 1.35 + 1.35 * 1.75 * ts.log_peak
    let focusDist = limitJMax * focusDistRaw
    let lowerHullGammaInv = 1.0 / (1.14 + 0.07 * ts.log_peak)
    let forwardLimit = 8.0 * (128.0 + (896.0 - 128.0) * (log(peakNits / 100.0) / log(10000.0 / 100.0)))

    let limiting = buildLimitingCuspCorners(params: kLimitParams, peakLuminance: peakNits)
    let reachCorners = findReachCornersTable(
        reachParams: kReachParams, limitJMax: limitJMax, forwardLimit: forwardLimit)
    let sortedHues = extractSortedCubeHues(reach: reachCorners, limit: limiting.jmh)
    let hueTable = buildHueTable(sortedHues)

    // Build cusp table
    var cuspTable = [simd_double3](repeating: .zero, count: kTotalTableSize)
    for i in kBaseIndex..<kTotalTableSize {
        let hue = hueTable[i]
        let (J, M) = findDisplayCuspForHue(
            hue: hue, rgbCorners: limiting.rgb, jmhCorners: limiting.jmh,
            params: kLimitParams)
        cuspTable[i] = simd_double3(J, M * (1.0 + kSmoothM * kSmoothCusps), hue)
    }
    cuspTable[0] = simd_double3(cuspTable[kTableSize][0], cuspTable[kTableSize][1], hueTable[0])
    cuspTable[kBaseIndex + kTableSize] = simd_double3(
        cuspTable[kBaseIndex][0], cuspTable[kBaseIndex][1], hueTable[kBaseIndex + kTableSize])

    // Build upper hull gamma table
    var gammaTable = [Double](repeating: 0, count: kTotalTableSize)
    for i in kBaseIndex..<(kBaseIndex + kTableSize) {
        let hue = cuspTable[i][2]
        let jmCusp = (cuspTable[i][0], cuspTable[i][1])

        var low = 0.0, high = 0.4
        var outside = false
        while !outside && high < 5.0 {
            if evaluateGammaFit(
                jmCusp: jmCusp, hue: hue, limitJMax: limitJMax, midJ: midJ, focusDist: focusDist,
                topGammaInv: 1.0 / high, lowerHullGammaInv: lowerHullGammaInv,
                peakLuminance: peakNits, limitParams: kLimitParams
            ) {
                outside = true
            } else {
                low = high; high += 0.4
            }
        }
        while high - low > 1e-5 {
            let mid = (high + low) / 2.0
            if evaluateGammaFit(
                jmCusp: jmCusp, hue: hue, limitJMax: limitJMax, midJ: midJ, focusDist: focusDist,
                topGammaInv: 1.0 / mid, lowerHullGammaInv: lowerHullGammaInv,
                peakLuminance: peakNits, limitParams: kLimitParams
            ) {
                high = mid
            } else {
                low = mid
            }
        }
        gammaTable[i] = 1.0 / high
    }
    gammaTable[0] = gammaTable[kTableSize]
    gammaTable[kBaseIndex + kTableSize] = gammaTable[kBaseIndex]

    // Pack into interleaved Float array: [J, M, gamma_inv] × 362 entries
    var result = [Float](repeating: 0, count: kTotalTableSize * 3)
    for i in 0..<kTotalTableSize {
        result[i * 3 + 0] = Float(cuspTable[i][0])
        result[i * 3 + 1] = Float(cuspTable[i][1])
        result[i * 3 + 2] = Float(gammaTable[i])
    }

    return (result, hueTable)
}
