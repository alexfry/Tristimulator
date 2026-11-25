//
//  ACES2CTLGoldenTests.swift
//  TristimulatorTests
//
//  Compares the app's ACES 2.0 display chain with golden values produced by the
//  Academy's ACES 2.0 CTL (aces-aswf/aces v2.0.0+2025.04.04, run through ctlrender).
//  Provenance, CTL commits and the regeneration command are in
//  TristimulatorTests/GoldenData/ACES2/README.md and manifest.json.
//
//  Two paths are checked for every transform:
//    - CPU: the OCIOProcessor factories in OpenColorIOBridge.mm, exactly as ImageManager
//      builds them (display/view, Dynamic ACES2 group, inverse display).
//    - GPU: OCIOGPUProcessor's combined Metal passes (the shaders the viewer draws with),
//      read back from its rgba16Float output. Skipped when there is no Metal device.
//
//  Tolerances are measured numbers plus a margin, not guesses. See the table below and
//  Scripts/measure_ocio_vs_ctl.py. A failure means the app has drifted from the CTL.
//  Do not widen a tolerance without explaining the new error in the README.
//

import Testing
import Foundation
import Metal
@testable import Tristimulator

// MARK: - Golden data

private struct GoldenManifest: Decodable {
    struct InputSet: Decodable { let file: String; let count: Int }
    struct Transform: Decodable {
        let id: String
        let kind: String          // forward | inverse | roundtrip
        let inputs: String        // scene | display
        let file: String
        let count: Int
        let app: [String: AnyJSON]
    }
    let inputs: [String: InputSet]
    let transforms: [Transform]
}

/// Minimal JSON scalar so the manifest's free-form "app" dictionary decodes.
private enum AnyJSON: Decodable {
    case string(String), number(Double)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .string(try c.decode(String.self)) }
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let d) = self { return d }; return nil }
}

private enum Golden {
    static let dir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("GoldenData/ACES2")

    static let configPath: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("OCIO/studio-config-v4.0.0_aces-v2.0_ocio-v2.5.ocio").path

    static let manifest: GoldenManifest = {
        let data = try! Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        return try! JSONDecoder().decode(GoldenManifest.self, from: data)
    }()

    /// Little-endian float32 RGB triplets.
    static func floats(_ file: String) -> [Float] {
        let data = try! Data(contentsOf: dir.appendingPathComponent(file))
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self)).map { Float(bitPattern: UInt32(littleEndian: $0.bitPattern)) }
        }
    }

    static func transform(_ id: String) -> GoldenManifest.Transform {
        manifest.transforms.first { $0.id == id }!
    }

    static func input(for t: GoldenManifest.Transform) -> [Float] {
        floats(manifest.inputs[t.inputs]!.file)
    }

    static func config() throws -> OCIOConfig {
        try OCIOConfig(path: configPath)
    }
}

// MARK: - Tolerances

/// Per-transform limits. `max` bounds the worst sample, `p99` the 99th percentile, so a
/// single hard sample cannot hide a broad shift and a broad shift cannot hide behind a
/// generous `max`. Units: display code values for forward/roundtrip; for inverse, the
/// sample's worst RGB error divided by max(|expected RGB|, 1e-3) (scene-linear, relative).
///
/// Measured against OCIO 2.5.2 (the vcpkg baseline); full table in GoldenData/ACES2/MEASUREMENTS.md.
/// CPU: max ~1.2e-3 SDR, ~3.8e-3 HDR 1000, ~4.9e-3 at 1600 nits, all from a handful of
/// very bright, highly saturated AP1-edge samples; p99 <= 4e-5.
/// The GPU writes rgba16Float, so GPU results are scored after removing one fp16 step at the
/// sample's magnitude (see `fp16Step`), then held to these same limits. Separately the GPU
/// must agree with the app's CPU result to within one fp16 step per channel.
private struct Tolerance { let max: Double; let p99: Double }

private let cpuTolerance: [String: Tolerance] = [
    "fwd_sdr100_rec709_srgb":   .init(max: 2.0e-3, p99: 1.0e-4),
    "fwd_sdr100_p3_srgb":       .init(max: 2.0e-3, p99: 1.0e-4),
    "fwd_hdr1000_p3_srgb":      .init(max: 6.0e-3, p99: 1.0e-4),
    "fwd_hdr1000_p3_rec2100pq": .init(max: 1.0e-3, p99: 2.0e-4),
    "dyn_p3_100":               .init(max: 2.0e-3, p99: 1.0e-4),
    "dyn_p3_400":               .init(max: 4.0e-3, p99: 1.0e-4),
    "dyn_p3_1000":              .init(max: 6.0e-3, p99: 1.0e-4),
    "dyn_p3_1600":              .init(max: 8.0e-3, p99: 1.0e-4),
    "dyn_p3_4000":              .init(max: 4.0e-3, p99: 1.0e-4),
    "dyn_rec709_100":           .init(max: 2.0e-3, p99: 1.0e-4),
    "inv_sdr100_rec709_srgb":   .init(max: 2.0e-3, p99: 4.0e-4),
    "inv_sdr100_p3_srgb":       .init(max: 2.0e-3, p99: 4.0e-4),
    "rt_sdr100_rec709_srgb":    .init(max: 2.0e-4, p99: 5.0e-5),
    "rt_sdr100_p3_srgb":        .init(max: 1.0e-4, p99: 5.0e-5),
    "invdyn_rec709_to_p3_100":  .init(max: 6.0e-4, p99: 5.0e-5),
    "invdyn_rec709_to_p3_1000": .init(max: 1.5e-2, p99: 3.0e-4),
]


// MARK: - Comparison

private struct ErrorStats: CustomStringConvertible {
    let max: Double, p99: Double, median: Double, worstIndex: Int
    var description: String {
        String(format: "max=%.3e p99=%.3e median=%.3e (worst sample %d)", max, p99, median, worstIndex)
    }
}

/// Per-sample error: max over RGB. Inverse transforms are scored relative to the sample's
/// brightest expected channel, because their output is unbounded scene-linear.
/// `fp16Allowance`: subtract one fp16 step per channel first (GPU output is rgba16Float).
private func compare(_ got: [Float], _ expected: [Float], kind: String,
                     fp16Allowance: Bool = false) -> ErrorStats {
    precondition(got.count == expected.count && got.count % 3 == 0)
    var errs = [Double](repeating: 0, count: got.count / 3)
    for i in 0..<errs.count {
        var e = 0.0, mag = 0.0
        for c in 0..<3 {
            let g = Double(got[i * 3 + c]), x = Double(expected[i * 3 + c])
            var d = g.isFinite ? abs(g - x) : .infinity
            if fp16Allowance { d = Swift.max(0, d - fp16Step(Swift.max(abs(g), abs(x)))) }
            e = Swift.max(e, d)
            mag = Swift.max(mag, abs(x))
        }
        errs[i] = kind == "inverse" ? e / Swift.max(mag, 1e-3) : e
    }
    let worst = errs.indices.max { errs[$0] < errs[$1] } ?? 0
    let sorted = errs.sorted()
    let p99 = sorted[Swift.min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.99).rounded(.up)))]
    return ErrorStats(max: sorted.last ?? 0, p99: p99, median: sorted[sorted.count / 2], worstIndex: worst)
}

/// Spacing of IEEE half-precision values at magnitude `v`: 2^(floor(log2 v) - 10), with the
/// subnormal floor 2^-24. One step is the most a correct float->half conversion can move a
/// value (round-to-nearest moves it at most half a step; truncation up to one step).
private func fp16Step(_ v: Double) -> Double {
    guard v >= 6.103515625e-05 else { return 5.960464477539063e-08 }   // 2^-14 normal min, 2^-24
    return pow(2.0, floor(log2(v)) - 10)
}

/// GPU/CPU parity: largest per-channel |a - b| left over after allowing one fp16 step at that
/// magnitude. Measured in absolute code values (not in steps) because near zero the fp16
/// step is tiny and harmless 1e-5 differences would count as hundreds of steps.
private func parityExcess(_ a: [Float], _ b: [Float]) -> (excess: Double, maxAbs: Double, index: Int) {
    var worst = 0.0, maxAbs = 0.0, idx = 0
    for k in a.indices {
        let x = Double(a[k]), y = Double(b[k])
        let d = abs(x - y)
        maxAbs = Swift.max(maxAbs, d)
        let e = Swift.max(0, d - fp16Step(Swift.max(abs(x), abs(y))))
        if e > worst { worst = e; idx = k / 3 }
    }
    return (worst, maxAbs, idx)
}

/// Prints a result line and, when the test runner sets ACES2_GOLDEN_SUMMARY (CI exports
/// TEST_RUNNER_ACES2_GOLDEN_SUMMARY), appends it to that file for the job summary.
@MainActor
private func report(_ line: String) {
    print(line)
    guard let path = ProcessInfo.processInfo.environment["ACES2_GOLDEN_SUMMARY"], !path.isEmpty else { return }
    let url = URL(fileURLWithPath: path)
    let data = Data((line + "\n").utf8)
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: url)
    }
}

@MainActor
private func check(_ stats: ErrorStats, _ tol: Tolerance, _ label: String,
                   got: [Float], expected: [Float], input: [Float]) {
    let w = stats.worstIndex
    let fmt = { (a: [Float]) in String(format: "(%.6g, %.6g, %.6g)", a[w * 3], a[w * 3 + 1], a[w * 3 + 2]) }
    report("ACES2 CTL golden [\(label)]: \(stats) tol(max=\(tol.max), p99=\(tol.p99))")
    #expect(stats.max <= tol.max,
            "\(label): max error \(stats.max) > \(tol.max). Worst input \(fmt(input)) app \(fmt(got)) CTL \(fmt(expected))")
    #expect(stats.p99 <= tol.p99, "\(label): p99 error \(stats.p99) > \(tol.p99)")
}

/// CTL clamps negatives before the PQ inverse EOTF (aces-core DisplayEncoding eotf_inv);
/// OCIO's "DISPLAY - CIE-XYZ-D65_to_REC.2100-PQ" builtin mirrors them instead. P3-limited
/// output in a Rec.2020 container can produce tiny negative blue for saturated reds
/// (the P3->2020 matrix has a -0.0012 term), which PQ's steep toe turns into code values
/// down to about -0.1. A display clips them, so the test clamps at 0 before comparing and
/// reports how many samples it touched. A rise in that count is a real change.
private let pqNegativeSampleLimit = 30

private func clampPQNegatives(_ v: inout [Float]) -> Int {
    var n = 0
    for i in stride(from: 0, to: v.count, by: 3) where v[i] < 0 || v[i + 1] < 0 || v[i + 2] < 0 {
        n += 1
        for c in 0..<3 { v[i + c] = Swift.max(v[i + c], 0) }
    }
    return n
}

private func isPQ(_ t: GoldenManifest.Transform) -> Bool {
    (t.app["display"]?.string ?? "").contains("PQ")
}

@MainActor
private func gamutXY(_ tag: String) -> [Double] {
    switch tag {
    case "rec709": return ACES2Gamut.rec709.xy
    case "rec2020": return ACES2Gamut.rec2020.xy
    default: return ACES2Gamut.p3d65.xy
    }
}

// MARK: - CPU path

@MainActor
private func runCPU(_ t: GoldenManifest.Transform, config: OCIOConfig, input: [Float]) throws -> [Float] {
    let n = input.count / 3
    func apply(_ p: OCIOProcessor, _ v: [Float]) throws -> [Float] {
        let d = v.withUnsafeBufferPointer { Data(buffer: $0) }
        let out = try p.processPixelData(d, width: n, height: 1, channels: 3)
        return out.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    let path = t.app["path"]!.string!
    let display = t.app["display"]?.string ?? ""
    let view = t.app["view"]?.string ?? ""
    let peak = t.app["peakNits"]?.number ?? 100
    let gamut = gamutXY(t.app["gamut"]?.string ?? "p3d65")
    guard let sceneLinear = config.sceneLinearColorSpace() else { throw OCIOGPUError.processorCreationFailed }

    switch path {
    case "displayView":
        return try apply(OCIOProcessor.makeDisplayProcessor(config: config, sourceSpace: "ACES2065-1",
                                                            display: display, view: view), input)
    case "dynamicACES2":
        // ImageManager CPU path: linearize to scene_linear, then the ACES2 group from scene_linear.
        let (lin, linSpace) = try OCIOProcessor.makeLinearizeProcessor(config: config, sourceSpace: "ACES2065-1")
        let a2 = try OCIOProcessor.makeDynamicACES2Processor(config: config, sourceSpace: linSpace,
                                                             peakNits: peak, outputGamutXY: gamut)
        return try apply(a2, apply(lin, input))
    case "inverseDisplay":
        // ImageManager: inverse display -> scene_linear. Map to ACES2065-1 to meet the CTL output.
        let inv = try OCIOProcessor.makeInverseDisplayProcessor(config: config, display: display, view: view)
        let toAP0 = try OCIOProcessor(config: config, sourceSpace: sceneLinear, destinationSpace: "ACES2065-1")
        return try apply(toAP0, apply(inv, input))
    case "inverseThenDisplay":
        let inv = try OCIOProcessor.makeInverseDisplayProcessor(config: config, display: display, view: view)
        let fwd = try OCIOProcessor.makeDisplayProcessor(config: config, sourceSpace: sceneLinear,
                                                         display: display, view: view)
        return try apply(fwd, apply(inv, input))
    case "inverseThenDynamicACES2":
        let inv = try OCIOProcessor.makeInverseDisplayProcessor(config: config, display: display, view: view)
        let a2 = try OCIOProcessor.makeDynamicACES2Processor(config: config, sourceSpace: sceneLinear,
                                                             peakNits: peak, outputGamutXY: gamut)
        return try apply(a2, apply(inv, input))
    default:
        Issue.record("unknown app path \(path)")
        return input
    }
}

private let allIDs = Golden.manifest.transforms.map(\.id)
/// Every forward and round-trip entry has a matching combined Metal pass in the app; the
/// standalone inverse has none (it only runs inside the combined passes), so it is CPU only.
private let gpuIDs = Golden.manifest.transforms.filter { $0.kind != "inverse" }.map(\.id)

@Suite("ACES 2.0 CTL golden — CPU (OCIO via OpenColorIOBridge)")
@MainActor
struct ACES2CTLGoldenCPUTests {

    @Test("Golden data is present and matches the manifest")
    func manifestIntegrity() throws {
        for (_, set) in Golden.manifest.inputs {
            #expect(Golden.floats(set.file).count == set.count * 3, "\(set.file)")
        }
        for t in Golden.manifest.transforms {
            let v = Golden.floats(t.file)
            #expect(v.count == t.count * 3, "\(t.id)")
            let finite = v.allSatisfy { $0.isFinite }
            #expect(finite, "\(t.id) has non-finite CTL output")
            #expect(cpuTolerance[t.id] != nil, "no CPU tolerance for \(t.id)")
        }
    }

    @Test("CPU matches CTL", arguments: allIDs)
    func cpuMatchesCTL(id: String) throws {
        let t = Golden.transform(id)
        let config = try Golden.config()
        let input = Golden.input(for: t)
        let expected = Golden.floats(t.file)
        var got = try runCPU(t, config: config, input: input)
        if isPQ(t) {
            let n = clampPQNegatives(&got)
            report("ACES2 CTL golden [cpu \(id)]: \(n) samples had negative PQ code values (clamped, limit \(pqNegativeSampleLimit))")
            #expect(n <= pqNegativeSampleLimit)
        }
        check(compare(got, expected, kind: t.kind), cpuTolerance[id]!, "cpu \(id)",
              got: got, expected: expected, input: input)
    }
}

// MARK: - GPU path

private let metalDevice = MTLCreateSystemDefaultDevice()

/// GPU vs CPU limit: absolute difference allowed beyond one fp16 step (code values).
/// Measured on an M-series Mac (see MEASUREMENTS.md): forward passes <= 1.1e-5; passes that
/// start with an inverse output transform <= 3.5e-4, because the inverse is ill-conditioned
/// near display white and small float differences grow before the forward pass.
private func gpuCPUParityExcess(_ kind: String) -> Double { kind == "forward" ? 1.0e-4 : 1.0e-3 }

/// Runs `input` (RGB triplets) through OCIOGPUProcessor's current pipeline and reads the
/// rgba16Float result back as Float RGB.
@MainActor
private func runGPU(_ gpu: OCIOGPUProcessor, device: MTLDevice, input: [Float]) async throws -> [Float] {
    let n = input.count / 3
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: n, height: 1, mipmapped: false)
    desc.usage = [.shaderRead]
    guard let tex = device.makeTexture(descriptor: desc) else { throw OCIOGPUError.processorCreationFailed }
    var rgba = [Float](repeating: 1, count: n * 4)
    for i in 0..<n { for c in 0..<3 { rgba[i * 4 + c] = input[i * 3 + c] } }
    tex.replace(region: MTLRegionMake2D(0, 0, n, 1), mipmapLevel: 0, withBytes: rgba, bytesPerRow: n * 16)

    guard let out = await gpu.processTexture(input: tex, exposure: 0) else {
        throw OCIOGPUError.shaderCompilationFailed("processTexture returned nil")
    }
    #expect(out.pixelFormat == .rgba16Float)
    return try readBackRGB(out, device: device, count: n)
}

/// Copies the first `count` texels of an rgba16Float texture (private storage) to a shared
/// buffer and returns them as Float RGB. Synchronous on purpose: called from async code.
private func readBackRGB(_ out: MTLTexture, device: MTLDevice, count n: Int) throws -> [Float] {
    let bytesPerRow = n * 8
    guard let queue = device.makeCommandQueue(),
          let buf = device.makeBuffer(length: bytesPerRow, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else {
        throw OCIOGPUError.processorCreationFailed
    }
    blit.copy(from: out, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: n, height: 1, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    let halfs = buf.contents().bindMemory(to: Float16.self, capacity: n * 4)
    var rgb = [Float](repeating: 0, count: n * 3)
    for i in 0..<n { for c in 0..<3 { rgb[i * 3 + c] = Float(halfs[i * 4 + c]) } }
    return rgb
}

/// Builds the same combined Metal pass ImageManager uses for each golden entry.
@MainActor
private func setupGPU(_ gpu: OCIOGPUProcessor, _ t: GoldenManifest.Transform, config: OCIOConfig) throws {
    let path = t.app["path"]!.string!
    let display = t.app["display"]?.string ?? ""
    let view = t.app["view"]?.string ?? ""
    let peak = t.app["peakNits"]?.number ?? 100
    let gamutTag = t.app["gamut"]?.string ?? "p3d65"
    guard let sceneLinear = config.sceneLinearColorSpace() else { throw OCIOGPUError.processorCreationFailed }

    switch path {
    case "displayView":
        try gpu.setupCombinedTransform(config: config, sourceSpace: "ACES2065-1", display: display, view: view)
    case "dynamicACES2":
        let a2 = try OCIOProcessor.makeDynamicACES2Processor(config: config, sourceSpace: sceneLinear,
                                                             peakNits: peak, outputGamutXY: gamutXY(gamutTag))
        try gpu.setupCombinedACES2Transform(config: config, sourceSpace: "ACES2065-1", peakNits: Float(peak),
                                            gamutTag: gamutTag, aces2Processor: a2)
    case "inverseThenDisplay":
        try gpu.setupCombinedInverseDisplayTransform(config: config, inverseDisplay: display, inverseView: view,
                                                     display: display, view: view)
    case "inverseThenDynamicACES2":
        let a2 = try OCIOProcessor.makeDynamicACES2Processor(config: config, sourceSpace: sceneLinear,
                                                             peakNits: peak, outputGamutXY: gamutXY(gamutTag))
        try gpu.setupCombinedInverseDisplayACES2Transform(config: config, inverseDisplay: display, inverseView: view,
                                                          peakNits: Float(peak), gamutTag: gamutTag,
                                                          aces2Processor: a2)
    default:
        Issue.record("no GPU path for \(path)")
    }
}

@Suite("ACES 2.0 CTL golden — GPU (OCIOGPUProcessor Metal)",
       .enabled(if: metalDevice != nil, "No Metal device; GPU golden tests skipped"))
@MainActor
struct ACES2CTLGoldenGPUTests {

    @Test("GPU matches CTL", arguments: gpuIDs)
    func gpuMatchesCTL(id: String) async throws {
        let device = try #require(metalDevice)
        let t = Golden.transform(id)
        let config = try Golden.config()
        let input = Golden.input(for: t)
        let expected = Golden.floats(t.file)
        let gpu = OCIOGPUProcessor(device: device)
        try setupGPU(gpu, t, config: config)
        var got = try await runGPU(gpu, device: device, input: input)
        if isPQ(t) {
            let n = clampPQNegatives(&got)
            report("ACES2 CTL golden [gpu \(id)]: \(n) samples had negative PQ code values (clamped, limit \(pqNegativeSampleLimit))")
            #expect(n <= pqNegativeSampleLimit)
        }
        // GPU/CPU parity: the Metal pass must reproduce the app's own CPU result to within one
        // fp16 step per channel, plus a small absolute allowance (see gpuCPUParityExcess).
        var cpu = try runCPU(t, config: config, input: input)
        if isPQ(t) { _ = clampPQNegatives(&cpu) }
        let parity = parityExcess(got, cpu)
        report(String(format: "ACES2 CTL golden [gpu-vs-cpu %@]: maxAbs=%.3e beyond-one-fp16-step=%.3e (sample %d) tol=%.1e",
                     id, parity.maxAbs, parity.excess, parity.index, gpuCPUParityExcess(t.kind)))
        #expect(parity.excess <= gpuCPUParityExcess(t.kind),
                "gpu \(id): GPU differs from CPU by \(parity.excess) beyond one fp16 step at sample \(parity.index)")

        check(compare(got, expected, kind: t.kind, fp16Allowance: true), cpuTolerance[id]!, "gpu \(id)",
              got: got, expected: expected, input: input)
    }
}
