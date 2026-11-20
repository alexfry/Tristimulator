//
//  CLFOCIOTransformTests.swift
//  TristimulatorTests
//
//  Verifies that OCIOProcessor correctly applies CLF files by comparing pixel output
//  against the ACES CLF reference test suite (CLF_ApplyTestImages_v01).
//
//  Source image:   CLF_ApplyTestImages_v01/FinishingTier/CLF_testImage.exr
//  References:     CLF_ApplyTestImages_v01/FinishingTier/Processed_Reference_Images/<name>.exr
//
//  Tolerance:  ACES Finishing Tier — |actual − aim| / max(|aim|, 0.1) ≤ 0.002
//
//  Result EXRs are written to /tmp/clf_results/ for external comparison.
//

import Testing
import Foundation
@testable import Tristimulator

// MARK: - Paths

private var clfFixturesDir: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CLF")
}

private var referenceBaseDir: URL {
    URL(fileURLWithPath: "/Users/alex/GitHub/Tristimulator/CLF_ApplyTestImages_v01/FinishingTier")
}

private var sourcePath: String {
    referenceBaseDir.appendingPathComponent("CLF_testImagePrototype_v006.exr").path
}

private func referencePath(for name: String) -> String {
    referenceBaseDir
        .appendingPathComponent("Processed_Reference_Images")
        .appendingPathComponent(name + ".exr")
        .path
}

// MARK: - Suite

@Suite("CLF OCIO Transform — Finishing Tier Reference", .serialized)
struct CLFOCIOTransformTests {

    private let outputDir = URL(fileURLWithPath: "/tmp/clf_results")

    // MARK: Helpers

    private func referenceAvailable() -> Bool {
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            print("⚠️  Skipping: reference suite not found at \(referenceBaseDir.path)")
            return false
        }
        return true
    }

    private func assertCLFMatchesReference(clf clfName: String, reference refName: String) throws {
        guard referenceAvailable() else { return }

        let clfPath = clfFixturesDir.appendingPathComponent(clfName + ".clf").path
        let refPath  = referencePath(for: refName)

        guard FileManager.default.fileExists(atPath: clfPath) else {
            Issue.record("CLF fixture not found: \(clfPath)")
            return
        }
        guard FileManager.default.fileExists(atPath: refPath) else {
            Issue.record("Reference image not found: \(refPath)")
            return
        }

        // ── Load source image ────────────────────────────────────────────────────
        guard let source = try? OpenImageIOBridge.readImageUncached(sourcePath) else {
            Issue.record("Failed to load source image at \(sourcePath)")
            return
        }
        let width  = source.spec.width
        let height = source.spec.height

        // ── Build processor: raw config + CLF file step ─────────────────────────
        guard let config = OCIOConfig.rawConfig() else {
            Issue.record("Failed to create raw OCIO config")
            return
        }
        let steps: [[String: String]] = [["type": "file", "path": clfPath]]
        let processor = try OCIOProcessor.makeGroupTransformProcessor(config: config, steps: steps)

        // ── Apply transform ──────────────────────────────────────────────────────
        let result = try processor.processPixelData(
            source.pixelData, width: width, height: height, channels: 4
        )

        // ── Write EXRs for external comparison ──────────────────────────────────
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let srcOut = outputDir.appendingPathComponent(clfName + "_source.exr").path
        let resOut = outputDir.appendingPathComponent(clfName + "_result.exr").path
        if (try? OpenImageIOBridge.writeFloatPixelData(source.pixelData as Data,
                                                       width: width, height: height, channels: 4,
                                                       toPath: srcOut)) == nil {
            print("⚠️  \(clfName): could not write source EXR to \(srcOut)")
        }
        if (try? OpenImageIOBridge.writeFloatPixelData(result as Data,
                                                       width: width, height: height, channels: 4,
                                                       toPath: resOut)) == nil {
            print("⚠️  \(clfName): could not write result EXR to \(resOut)")
        }
        print("\(clfName): source=\(srcOut)  result=\(resOut)  reference=\(refPath)")

        // ── Load reference image ─────────────────────────────────────────────────
        guard let reference = try? OpenImageIOBridge.readImageUncached(refPath) else {
            Issue.record("Failed to load reference image at \(refPath)")
            return
        }

        #expect(reference.spec.width  == width,  "Width mismatch vs reference")
        #expect(reference.spec.height == height, "Height mismatch vs reference")

        // ── Pixel comparison — ACES Finishing Tier tolerance ─────────────────────
        finishingTierCompare(actual: result as Data, expected: reference.pixelData as Data,
                             pixelCount: Int(width * height), label: clfName)
    }

    /// ACES Finishing Tier: |actual − aim| / max(|aim|, 0.1) ≤ 0.002 per channel.
    private func finishingTierCompare(actual: Data, expected: Data,
                                      pixelCount: Int, label: String) {
        let tolerance: Float = 0.002
        let relFloor: Float  = 0.1

        actual.withUnsafeBytes { aRaw in
            expected.withUnsafeBytes { eRaw in
                let a = aRaw.bindMemory(to: Float.self)
                let e = eRaw.bindMemory(to: Float.self)

                var maxErr: Float = 0
                var worstIdx = 0
                var failCount = 0

                let count = min(a.count, e.count)
                for i in 0..<count {
                    if i % 4 == 3 { continue }   // skip alpha
                    let relBase = max(abs(e[i]), relFloor)
                    let err     = abs(a[i] - e[i]) / relBase
                    if err > maxErr { maxErr = err; worstIdx = i }
                    if err > tolerance { failCount += 1 }
                }

                let worstPixel = worstIdx / 4
                let worstCh    = ["R", "G", "B", "A"][worstIdx % 4]
                let actualVal  = a.count > worstIdx ? a[worstIdx] : Float(-999)
                let expectedVal = e.count > worstIdx ? e[worstIdx] : Float(-999)
                let totalChecked = (count / 4) * 3
                let msg = "\(label): err=\(String(format: "%.5f", maxErr)) pixel=\(worstPixel) ch=\(worstCh) actual=\(String(format: "%.6f", actualVal)) expected=\(String(format: "%.6f", expectedVal)) failCount=\(failCount)/\(totalChecked)"
                #expect(maxErr <= tolerance, "\(msg)")
            }
        }
    }

    // MARK: Tests — one per CLF operator category

    @Test func cdlAllStyles() throws {
        try assertCLFMatchesReference(clf: "cdl_all_styles", reference: "cdl_all_styles")
    }

    @Test func lut1dExample() throws {
        try assertCLFMatchesReference(clf: "lut1d_example", reference: "lut1d_example")
    }

    @Test func logAllStyles() throws {
        try assertCLFMatchesReference(clf: "log_all_styles", reference: "log_all_styles")
    }

    @Test func exponentAllStyles() throws {
        try assertCLFMatchesReference(clf: "exponent_all_styles", reference: "exponent_all_styles")
    }

    @Test func range() throws {
        try assertCLFMatchesReference(clf: "range", reference: "range")
    }

    @Test func matrix3x4() throws {
        try assertCLFMatchesReference(clf: "matrix_3x4_example", reference: "matrix_3x4_example")
    }

    @Test func matrixUtf8() throws {
        try assertCLFMatchesReference(clf: "matrix_example_utf8", reference: "matrix_example_utf8")
    }

    @Test func multipleOps() throws {
        try assertCLFMatchesReference(clf: "multiple_ops", reference: "multiple_ops")
    }

    // ── Visual comparison generator ──────────────────────────────────────────
    // For each CLF, writes a side-by-side strip [source | ours | reference | diff]
    // to /tmp/clf_view/ as both an 8-bit PNG (quick viewing) and a float EXR (raw
    // inspection in Tristimulator). The diff panel shows the ACES Finishing-Tier
    // RELATIVE error |ours−ref| / max(|ref|, 0.1) scaled by 500, so the 0.002
    // pass threshold maps to white: any non-black pixel is at or beyond tolerance.

    @Test func generateVisualComparison() throws {
        guard referenceAvailable() else { return }
        let viewDir = URL(fileURLWithPath: "/tmp/clf_view")
        try? FileManager.default.createDirectory(at: viewDir, withIntermediateDirectories: true)

        guard let source = try? OpenImageIOBridge.readImageUncached(sourcePath) else {
            Issue.record("Failed to load source"); return
        }
        let w = Int(source.spec.width), h = Int(source.spec.height)
        guard let config = OCIOConfig.rawConfig() else { Issue.record("rawConfig failed"); return }

        // Tonemap a linear value for display: clamp [0,1] then gamma 2.2.
        func tm(_ v: Float) -> Float {
            let c = min(max(v, 0), 1)
            return pow(c, 1.0 / 2.2)
        }

        let pairs = [
            ("matrix_example_utf8", "matrix_example_utf8"),
            ("lut1d_example", "lut1d_example"),
            ("cdl_all_styles", "cdl_all_styles"),
            ("range", "range"),
            ("log_all_styles", "log_all_styles"),
            ("exponent_all_styles", "exponent_all_styles"),
            ("matrix_3x4_example", "matrix_3x4_example"),
            ("multiple_ops", "multiple_ops"),
        ]

        // Relative-error scale: 0.002 tolerance → 1.0 (white).
        let relScale: Float = 500.0
        let relFloor: Float = 0.1
        let panels = 4
        let stripW = w * panels

        for (clfName, refName) in pairs {
            let clfPath = clfFixturesDir.appendingPathComponent(clfName + ".clf").path
            guard FileManager.default.fileExists(atPath: clfPath) else { continue }
            let proc = try OCIOProcessor.makeGroupTransformProcessor(
                config: config, steps: [["type": "file", "path": clfPath]])
            let result = try proc.processPixelData(source.pixelData, width: w, height: h, channels: 4)
            guard let ref = try? OpenImageIOBridge.readImageUncached(referencePath(for: refName)) else {
                continue
            }

            var strip   = [Float](repeating: 0, count: stripW * h * 4)   // tonemapped (PNG)
            var stripHDR = [Float](repeating: 0, count: stripW * h * 4)  // raw linear (EXR)

            source.pixelData.withUnsafeBytes { sRaw in
            result.withUnsafeBytes { rRaw in
            ref.pixelData.withUnsafeBytes { eRaw in
                let s = sRaw.bindMemory(to: Float.self)
                let r = rRaw.bindMemory(to: Float.self)
                let e = eRaw.bindMemory(to: Float.self)
                for y in 0..<h {
                    for x in 0..<w {
                        let p = (y * w + x) * 4
                        func place(_ panel: Int, _ vals: (Float,Float,Float)) {
                            let dx = panel * w + x
                            let d = (y * stripW + dx) * 4
                            stripHDR[d+0] = vals.0; stripHDR[d+1] = vals.1; stripHDR[d+2] = vals.2; stripHDR[d+3] = 1
                            strip[d+0] = tm(vals.0); strip[d+1] = tm(vals.1); strip[d+2] = tm(vals.2); strip[d+3] = 1
                        }
                        func relErr(_ a: Float, _ b: Float) -> Float {
                            abs(a - b) / max(abs(b), relFloor) * relScale
                        }
                        place(0, (s[p],   s[p+1],   s[p+2]))
                        place(1, (r[p],   r[p+1],   r[p+2]))
                        place(2, (e[p],   e[p+1],   e[p+2]))
                        place(3, (relErr(r[p],   e[p]),
                                  relErr(r[p+1], e[p+1]),
                                  relErr(r[p+2], e[p+2])))
                    }
                }
            }}}

            let pngData = Data(bytes: strip, count: strip.count * 4)
            let exrData = Data(bytes: stripHDR, count: stripHDR.count * 4)
            let pngPath = viewDir.appendingPathComponent("\(clfName).png").path
            let exrPath = viewDir.appendingPathComponent("\(clfName).exr").path
            try? OpenImageIOBridge.writeFloatPixelData(pngData, width: stripW, height: h, channels: 4, toPath: pngPath)
            try? OpenImageIOBridge.writeFloatPixelData(exrData, width: stripW, height: h, channels: 4, toPath: exrPath)
        }
        print("Wrote visual comparisons to \(viewDir.path)")
    }

    // ── OCIO application correctness (independent of reference fixtures) ───────
    // Proves the full-image OCIO matrix path produces exactly the hand-computed
    // result M×source at EVERY pixel of the real source image — including the
    // extreme out-of-range values the test image is designed to contain. This is
    // the definitive check that `processPixelData` (PackedImageDesc strides,
    // channel order, bit-depth, LOSSLESS optimization) applies the CLF correctly,
    // and it does not depend on the bundled reference EXRs being in sync.

    @Test func matrixApplicationMatchesManualMath() throws {
        guard referenceAvailable() else { return }
        // matrix_example_utf8: pure 3×3 matrix, 32f → 32f (no bit-depth scaling).
        let M: [[Float]] = [
            [0.66067963, 0.13364476, 0.15567561],
            [0.04255484, 0.81668756, 0.09075760],
            [-0.00524959, 0.00382395, 0.95142564],
        ]
        guard let src = try? OpenImageIOBridge.readImageUncached(sourcePath) else {
            Issue.record("Failed to load source image"); return
        }
        let w = Int(src.spec.width), h = Int(src.spec.height)
        guard let config = OCIOConfig.rawConfig() else {
            Issue.record("rawConfig failed"); return
        }
        let clfPath = clfFixturesDir.appendingPathComponent("matrix_example_utf8.clf").path
        let proc = try OCIOProcessor.makeGroupTransformProcessor(
            config: config, steps: [["type": "file", "path": clfPath]])
        let result = try proc.processPixelData(src.pixelData, width: w, height: h, channels: 4)

        src.pixelData.withUnsafeBytes { sRaw in
            result.withUnsafeBytes { rRaw in
                let s = sRaw.bindMemory(to: Float.self)
                let r = rRaw.bindMemory(to: Float.self)
                var maxDiff: Float = 0
                var worstPixel = -1
                for px in 0..<(w * h) {
                    let b = px * 4
                    let sr = s[b], sg = s[b+1], sb = s[b+2]
                    // Skip non-finite source pixels (the image intentionally
                    // contains inf/nan patches that don't compare meaningfully).
                    if !sr.isFinite || !sg.isFinite || !sb.isFinite { continue }
                    for ch in 0..<3 {
                        let manual = M[ch][0]*sr + M[ch][1]*sg + M[ch][2]*sb
                        let ocio   = r[b + ch]
                        guard manual.isFinite, ocio.isFinite else { continue }
                        let diff = abs(manual - ocio)
                        if diff > maxDiff { maxDiff = diff; worstPixel = px }
                    }
                }
                #expect(maxDiff < 0.01,
                        "OCIO matrix output diverged from manual M×src: maxDiff=\(maxDiff) at pixel \(worstPixel)")
            }
        }
    }

    // ── Synthetic validation ─────────────────────────────────────────────────
    // Applies known CLF ops to hand-computed inputs and checks OCIO math directly.
    // No reference images needed — catches setup errors regardless of source image.

    @Test func syntheticMatrix() throws {
        // matrix_example_utf8: 3x3, inBitDepth=32f, outBitDepth=32f
        // Row sums are all ≈ 0.95, so [0.5,0.5,0.5] → ≈ [0.475,0.475,0.475]
        let M: [[Float]] = [
            [0.66067963, 0.13364476, 0.15567561],
            [0.04255484, 0.81668756, 0.09075760],
            [-0.00524959, 0.00382395, 0.95142564],
        ]
        let src: [Float] = [0.5, 0.3, 0.7, 1.0,
                            0.0, 0.0, 0.0, 1.0,
                            1.0, 1.0, 1.0, 1.0]
        var expected: [Float] = Array(repeating: 0, count: src.count)
        for px in 0..<3 {
            for ch in 0..<3 {
                expected[px*4+ch] = M[ch][0]*src[px*4+0] + M[ch][1]*src[px*4+1] + M[ch][2]*src[px*4+2]
            }
            expected[px*4+3] = 1.0
        }

        guard let config = OCIOConfig.rawConfig() else {
            Issue.record("rawConfig failed"); return
        }
        let clfPath = clfFixturesDir.appendingPathComponent("matrix_example_utf8.clf").path
        let processor = try OCIOProcessor.makeGroupTransformProcessor(
            config: config, steps: [["type": "file", "path": clfPath]])

        var buf = src
        let data = Data(bytes: &buf, count: buf.count * MemoryLayout<Float>.size)
        let result = try processor.processPixelData(data, width: 3, height: 1, channels: 4)

        result.withUnsafeBytes { rRaw in
            let r = rRaw.bindMemory(to: Float.self)
            var log = "syntheticMatrix:\n"
            for px in 0..<3 {
                let b = px * 4
                log += "  px\(px): got [\(String(format:"%.5f",r[b])),\(String(format:"%.5f",r[b+1])),\(String(format:"%.5f",r[b+2]))]  want [\(String(format:"%.5f",expected[b])),\(String(format:"%.5f",expected[b+1])),\(String(format:"%.5f",expected[b+2]))]\n"
                for ch in 0..<3 {
                    let err = abs(r[b+ch] - expected[b+ch])
                    #expect(err < 0.001, "px\(px) ch\(ch): got \(r[b+ch]) want \(expected[b+ch])")
                }
            }
            try? log.write(toFile: "/tmp/clf_results/synthetic_matrix.txt", atomically: true, encoding: .utf8)
        }
    }

    @Test func syntheticLUT1D() throws {
        // lut1d_example: inBitDepth=8i, outBitDepth=12i, 65 entries
        // Input 0.0 (float) → 0 (8i) → LUT[0] = -1023.75 → -1023.75/4095 ≈ -0.25
        // Input 1.0 (float) → 255 (8i) → LUT[64] = 5118.75 → 5118.75/4095 ≈ 1.25
        let src: [Float] = [0.0, 0.0, 0.0, 1.0,
                            1.0, 1.0, 1.0, 1.0]
        let expectedPx0: Float = -1023.75 / 4095.0   // ≈ -0.2499
        let expectedPx1: Float =  5118.75 / 4095.0   // ≈ 1.2499

        guard let config = OCIOConfig.rawConfig() else {
            Issue.record("rawConfig failed"); return
        }
        let clfPath = clfFixturesDir.appendingPathComponent("lut1d_example.clf").path
        let processor = try OCIOProcessor.makeGroupTransformProcessor(
            config: config, steps: [["type": "file", "path": clfPath]])

        var buf = src
        let data = Data(bytes: &buf, count: buf.count * MemoryLayout<Float>.size)
        let result = try processor.processPixelData(data, width: 2, height: 1, channels: 4)

        result.withUnsafeBytes { rRaw in
            let r = rRaw.bindMemory(to: Float.self)
            var log = "syntheticLUT1D:\n"
            log += "  px0 R: got \(r[0])  want \(expectedPx0)\n"
            log += "  px1 R: got \(r[4])  want \(expectedPx1)\n"
            try? log.write(toFile: "/tmp/clf_results/synthetic_lut1d.txt", atomically: true, encoding: .utf8)
            #expect(abs(r[0] - expectedPx0) < 0.001, "px0 R: got \(r[0]) want \(expectedPx0)")
            #expect(abs(r[4] - expectedPx1) < 0.001, "px1 R: got \(r[4]) want \(expectedPx1)")
        }
    }
}
