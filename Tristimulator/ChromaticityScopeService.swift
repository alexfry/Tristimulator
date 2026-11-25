//
//  ChromaticityScopeService.swift
//  Tristimulator
//
//  Manages the GPU pipeline for the CIE 1931 Yxy chromaticity histogram.
//  Owns compute pipeline states, double-buffered histogram buffers, and the
//  density output texture.  All GPU work runs on a dedicated command queue.
//

import Metal
import simd
import Observation
import AppKit

/// Which chromaticity projection to compute.
enum ChromaticityDiagramMode {
    case yxy    // CIE 1931 xy
    case ucs    // CIE 1976 u'v'
}

@Observable
final class ChromaticityScopeService {

    // MARK: - Published state

    /// The density heatmap texture (256×256, rgba16Float).
    /// Read by ChromaticityMetalView for rendering.
    private(set) var densityTexture: MTLTexture?

    /// Bumped each time a new density texture is ready, so views can react.
    private(set) var updateCounter: UInt = 0

    /// The diagram mode this service instance computes.
    let mode: ChromaticityDiagramMode

    /// 3D point-cloud mode (Yxy only). When true, `update` writes one point per
    /// sample into `pointBuffer` instead of building the 2D density texture.
    /// 2D stays the default.
    var is3D = false

    /// Latest 3D point cloud (`Scope3DPoint` layout, see Scope3D.metal) and
    /// how many points in it are valid.
    private(set) var pointBuffer: MTLBuffer?
    private(set) var pointCount = 0
    /// Bumped each time a new point cloud is ready.
    private(set) var pointsVersion: UInt = 0

    /// Whether this service can produce a 3D point cloud.
    var supports3D: Bool { mode == .yxy }

    // MARK: - Configuration

    static let histogramWidth  = 256
    static let histogramHeight = 256
    /// Target number of pixel samples regardless of image resolution.
    var targetSampleCount = 250_000
    /// Point budget for the 3D cloud (capacity of each point buffer).
    static let maxPoints3D = 262_144
    /// Vertical axis range of the 3D Yxy scope, in stops of Y (0 = scene-linear 1.0, SDR white).
    static let stopsMin3D: Float = -8
    static let stopsMax3D: Float = 6

    // MARK: - Metal state

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var histogramPipeline: MTLComputePipelineState?
    private var normalizePipeline: MTLComputePipelineState?

    /// Double-buffered histogram: write to [writeIndex], read from [readIndex].
    private var histogramBuffers: [MTLBuffer] = []
    private var writeIndex = 0
    private var readIndex: Int { 1 - writeIndex }

    /// Persistent density output texture (backing storage for GPU writes).
    private var densityOutputTexture: MTLTexture?

    /// Cached RGB→XYZ matrix and the color space it was computed for.
    private var cachedMatrix = simd_float3x3(1)
    private var cachedColorSpace = ""

    /// Guard against overlapping GPU submissions. A request that arrives while
    /// busy is kept and run once the current one finishes (so toggling 2D/3D
    /// mid-update is not lost).
    @ObservationIgnored private var isProcessing = false {
        didSet {
            if !isProcessing, let pending = pendingRequest {
                pendingRequest = nil
                DispatchQueue.main.async { [weak self] in
                    self?.update(sourceTexture: pending.texture, sourceColorSpace: pending.colorSpace)
                }
            }
        }
    }
    @ObservationIgnored private var pendingRequest: (texture: MTLTexture, colorSpace: String)?

    /// 3D point-cloud state.
    @ObservationIgnored private var pointsPipeline: MTLComputePipelineState?
    @ObservationIgnored private var pointBuffers: [MTLBuffer] = []
    @ObservationIgnored private var counterBuffers: [MTLBuffer] = []
    @ObservationIgnored private var pointWriteIndex = 0

    // MARK: - Init

    init?(device: MTLDevice, mode: ChromaticityDiagramMode = .yxy) {
        self.device = device
        self.mode = mode
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        setupPipelines()
        setupBuffers()
    }

    // MARK: - Public API

    /// Compute the chromaticity histogram for the given source texture.
    /// Call this whenever the image changes (new load, new frame, etc.).
    /// The source texture should be in a scene-linear working space.
    func update(sourceTexture: MTLTexture, sourceColorSpace: String) {
        if isProcessing {
            pendingRequest = (sourceTexture, sourceColorSpace)
            return
        }
        guard histogramPipeline != nil,
              normalizePipeline != nil else { return }

        isProcessing = true

        // Update matrix if color space changed
        if sourceColorSpace != cachedColorSpace {
            cachedMatrix = Self.rgbToXYZMatrix(for: sourceColorSpace)
            cachedColorSpace = sourceColorSpace
        }

        if is3D && supports3D {
            updatePoints(sourceTexture: sourceTexture)
            return
        }

        // Calculate downsample stride
        let totalPixels = sourceTexture.width * sourceTexture.height
        let stride = max(1, Int(sqrt(Double(totalPixels) / Double(targetSampleCount))))

        // Swap buffers
        writeIndex = 1 - writeIndex

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            isProcessing = false
            return
        }

        let histW = Self.histogramWidth
        let histH = Self.histogramHeight
        let writeBuffer = histogramBuffers[writeIndex]

        // --- Clear the write buffer ---
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            isProcessing = false
            return
        }
        blitEncoder.fill(buffer: writeBuffer, range: 0..<writeBuffer.length, value: 0)
        blitEncoder.endEncoding()

        // --- Pass 1: Histogram accumulation ---
        guard let histEncoder = commandBuffer.makeComputeCommandEncoder() else {
            isProcessing = false
            return
        }

        histEncoder.setComputePipelineState(histogramPipeline!)
        histEncoder.setTexture(sourceTexture, index: 0)
        histEncoder.setBuffer(writeBuffer, offset: 0, index: 0)

        var params = ChromaticityParams(
            rgbToXYZ: cachedMatrix,
            histSize: SIMD2<UInt32>(UInt32(histW), UInt32(histH)),
            stride: UInt32(stride),
            _pad: 0
        )
        histEncoder.setBytes(&params, length: MemoryLayout<ChromaticityParams>.stride, index: 1)

        let dispatchW = (sourceTexture.width  + stride - 1) / stride
        let dispatchH = (sourceTexture.height + stride - 1) / stride
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width:  (dispatchW + 15) / 16,
            height: (dispatchH + 15) / 16,
            depth: 1
        )
        histEncoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        histEncoder.endEncoding()

        // --- Find max count on CPU from the write buffer (after GPU completes) ---
        // We encode the normalize pass in a completed handler to get the max.
        // This adds one frame of latency but avoids a GPU reduction pass.

        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            self.normalizeAndPublish(buffer: writeBuffer)
        }

        commandBuffer.commit()
    }

    // MARK: - 3D point cloud

    /// Writes one `Scope3DPoint` per (strided) sample via an atomic counter.
    private func updatePoints(sourceTexture: MTLTexture) {
        ensurePointBuffers()
        guard let pointsPipeline,
              pointBuffers.count == 2, counterBuffers.count == 2,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            isProcessing = false
            return
        }

        pointWriteIndex = 1 - pointWriteIndex
        let points = pointBuffers[pointWriteIndex]
        let counter = counterBuffers[pointWriteIndex]
        let maxPoints = Self.maxPoints3D

        blit.fill(buffer: counter, range: 0..<counter.length, value: 0)
        blit.endEncoding()

        // Stride rounds up so the sample count stays within the point budget.
        let totalPixels = Double(sourceTexture.width * sourceTexture.height)
        let stride = max(1, Int(ceil(sqrt(totalPixels / Double(maxPoints)))))

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            isProcessing = false
            return
        }
        encoder.setComputePipelineState(pointsPipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setBuffer(points, offset: 0, index: 0)
        encoder.setBuffer(counter, offset: 0, index: 1)
        var params = ChromaticityPointParams(
            rgbToXYZ: cachedMatrix,
            stride: UInt32(stride),
            maxPoints: UInt32(maxPoints),
            maxEDR: Float(NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0),
            stopsMin: Self.stopsMin3D,
            stopsMax: Self.stopsMax3D
        )
        encoder.setBytes(&params, length: MemoryLayout<ChromaticityPointParams>.stride, index: 2)
        let dispatchW = (sourceTexture.width  + stride - 1) / stride
        let dispatchH = (sourceTexture.height + stride - 1) / stride
        encoder.dispatchThreadgroups(
            MTLSize(width: (dispatchW + 15) / 16, height: (dispatchH + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] _ in
            let written = Int(counter.contents().load(as: UInt32.self))
            let count = min(written, maxPoints)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pointBuffer = points
                self.pointCount = count
                self.pointsVersion &+= 1
                self.isProcessing = false
            }
        }
        commandBuffer.commit()
    }

    private func ensurePointBuffers() {
        guard pointBuffers.isEmpty else { return }
        let length = Self.maxPoints3D * Scope3DGPU.pointStride
        for _ in 0..<2 {
            guard let p = device.makeBuffer(length: length, options: .storageModePrivate),
                  let c = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
            else { pointBuffers = []; counterBuffers = []; return }
            p.label = "Yxy 3D points"
            pointBuffers.append(p)
            counterBuffers.append(c)
        }
    }

    // MARK: - Private

    private func normalizeAndPublish(buffer: MTLBuffer) {
        let histW = Self.histogramWidth
        let histH = Self.histogramHeight
        let binCount = histW * histH

        // Scan for max hit count on CPU.
        // Buffer layout: [R, G, B, count] per bin, so count is at offset +3.
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: binCount * 4)
        var maxCount: UInt32 = 0
        for i in 0..<binCount {
            maxCount = max(maxCount, ptr[i * 4 + 3])
        }

        if maxCount == 0 {
            DispatchQueue.main.async {
                self.isProcessing = false
            }
            return
        }

        // --- Pass 2: Normalize on GPU ---
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            DispatchQueue.main.async { self.isProcessing = false }
            return
        }

        ensureDensityTexture()
        guard let outTex = densityOutputTexture else {
            DispatchQueue.main.async { self.isProcessing = false }
            return
        }

        encoder.setComputePipelineState(normalizePipeline!)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setTexture(outTex, index: 0)

        let maxEDR = Float(NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0)
        var normParams = ChromaticityNormalizeParams(
            logMaxCount: log2(Float(maxCount) + 1.0),
            maxEDR: maxEDR
        )
        encoder.setBytes(&normParams, length: MemoryLayout<ChromaticityNormalizeParams>.stride, index: 1)

        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width:  (histW + 15) / 16,
            height: (histH + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.densityTexture = outTex
                self.updateCounter += 1
                self.isProcessing = false
            }
        }

        commandBuffer.commit()
    }

    private func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else { return }

        let histKernelName: String
        switch mode {
        case .yxy: histKernelName = "chromaticityHistogram"
        case .ucs: histKernelName = "ucsHistogram"
        }

        if let histFunc = library.makeFunction(name: histKernelName) {
            histogramPipeline = try? device.makeComputePipelineState(function: histFunc)
        }
        if let normFunc = library.makeFunction(name: "chromaticityNormalize") {
            normalizePipeline = try? device.makeComputePipelineState(function: normFunc)
        }
        if mode == .yxy, let pointsFunc = library.makeFunction(name: "chromaticityPoints") {
            pointsPipeline = try? device.makeComputePipelineState(function: pointsFunc)
        }
    }

    private func setupBuffers() {
        // 4 uint32s per bin: R_sum, G_sum, B_sum, count (fixed-point color accumulation)
        let bufferSize = Self.histogramWidth * Self.histogramHeight * 4 * MemoryLayout<UInt32>.stride
        for _ in 0..<2 {
            if let buf = device.makeBuffer(length: bufferSize, options: .storageModeShared) {
                histogramBuffers.append(buf)
            }
        }
    }

    private func ensureDensityTexture() {
        if densityOutputTexture != nil { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Self.histogramWidth,
            height: Self.histogramHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        densityOutputTexture = device.makeTexture(descriptor: desc)
    }

    // MARK: - RGB → XYZ matrices

    /// Returns the 3×3 matrix converting from the named color space's linear RGB
    /// to CIE XYZ. ACES spaces use the native ACES white (~D60); others use D65.
    static func rgbToXYZMatrix(for colorSpace: String) -> simd_float3x3 {
        let lower = colorSpace.lowercased()

        // ACEScg (AP1) — most common ACES working space
        if lower.contains("acescg") || lower.contains("ap1") ||
           lower.contains("ace") && lower.contains("cg") {
            return acescgToXYZ
        }

        // ACES2065-1 (AP0)
        if lower.contains("aces2065") || lower.contains("ap0") {
            return aces2065ToXYZ
        }

        // sRGB / Rec.709
        if lower.contains("srgb") || lower.contains("rec709") || lower.contains("rec.709") ||
           lower.contains("bt.709") || lower.contains("bt709") {
            return srgbToXYZ
        }

        // Display P3
        if lower.contains("p3") && (lower.contains("d65") || lower.contains("display")) {
            return displayP3ToXYZ
        }

        // Rec.2020
        if lower.contains("rec2020") || lower.contains("rec.2020") ||
           lower.contains("bt.2020") || lower.contains("bt2020") {
            return rec2020ToXYZ
        }

        // Default: ACEScg (AP1) — safest default for ACES-based workflows
        return acescgToXYZ
    }

    // --- Standard matrices (column-major) ---

    /// ACEScg AP1 primaries → CIE XYZ (ACES ~D60 white, per S-2014-004)
    static let acescgToXYZ = simd_float3x3(columns: (
        SIMD3<Float>( 0.6624542,  0.2722287,  -0.0055746),
        SIMD3<Float>( 0.1340042,  0.6740818,   0.0040607),
        SIMD3<Float>( 0.1561877,  0.0536895,   1.0103391)
    ))

    /// ACES2065-1 AP0 primaries → CIE XYZ (ACES ~D60 white)
    static let aces2065ToXYZ = simd_float3x3(columns: (
        SIMD3<Float>( 0.9525524,  0.3439664,   0.0),
        SIMD3<Float>( 0.0,        0.7281661,   0.0),
        SIMD3<Float>( 0.0000937,  -0.0721325,  1.0088251)
    ))

    /// sRGB / Rec.709 → CIE XYZ (D65)
    static let srgbToXYZ = simd_float3x3(columns: (
        SIMD3<Float>( 0.4123908,  0.2126390,  0.0193308),
        SIMD3<Float>( 0.3575843,  0.7151687,  0.1191950),
        SIMD3<Float>( 0.1804808,  0.0721923,  0.9505322)
    ))

    /// Display P3 (D65) → CIE XYZ
    static let displayP3ToXYZ = simd_float3x3(columns: (
        SIMD3<Float>( 0.4865709,  0.2289746,  0.0),
        SIMD3<Float>( 0.2656677,  0.6917385,  0.0451134),
        SIMD3<Float>( 0.1982173,  0.0792869,  1.0439444)
    ))

    /// Rec.2020 → CIE XYZ (D65)
    static let rec2020ToXYZ = simd_float3x3(columns: (
        SIMD3<Float>( 0.6369580,  0.2627002,  0.0),
        SIMD3<Float>( 0.1446169,  0.6779981,  0.0280727),
        SIMD3<Float>( 0.1688810,  0.0593017,  1.0609851)
    ))
}

// MARK: - Shader interop struct (must match ChromaticityCompute.metal)

struct ChromaticityParams {
    var rgbToXYZ: simd_float3x3
    var histSize: SIMD2<UInt32>
    var stride: UInt32
    var _pad: UInt32
}

struct ChromaticityNormalizeParams {
    var logMaxCount: Float
    var maxEDR: Float
}

struct ChromaticityPointParams {
    var rgbToXYZ: simd_float3x3
    var stride: UInt32
    var maxPoints: UInt32
    var maxEDR: Float
    var stopsMin: Float
    var stopsMax: Float
}
