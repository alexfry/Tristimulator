//
//  JmhScopeService.swift
//  Tristimulator
//
//  Manages the GPU pipeline for the JMh (Hellwig 2022) polar scope.
//  Owns compute pipeline states, double-buffered histogram buffers, and the
//  density output texture.  All GPU work runs on a dedicated command queue.
//
//  The JMh transform matches the simplified Hellwig CAM used inside the
//  ACES 2.0 display transform: RGB → LMS → non-linear compression →
//  panluminance opponent channels → J (lightness), M (colourfulness), h (hue).
//

import Metal
import simd
import AppKit
import Observation

@Observable
final class JmhScopeService {

    // MARK: - Published state

    /// The density heatmap texture (512×512, rgba16Float).
    private(set) var densityTexture: MTLTexture?

    /// Bumped each time a new density texture is ready, so views can react.
    private(set) var updateCounter: UInt = 0

    /// 3D point-cloud mode. When true, `update` writes one point per sample
    /// (M·cos h, J, M·sin h) into `pointBuffer` instead of building the 2D
    /// density texture. 2D stays the default.
    var is3D = false

    /// Latest 3D point cloud (`Scope3DPoint` layout, see Scope3D.metal).
    private(set) var pointBuffer: MTLBuffer?
    private(set) var pointCount = 0
    /// Bumped each time a new point cloud is ready.
    private(set) var pointsVersion: UInt = 0
    /// Largest J in the latest point cloud (drives the 3D vertical axis top,
    /// since HDR content pushes J past 100).
    private(set) var observedMaxJ: Float = 100

    // MARK: - Configuration

    static let histogramSize = 512
    /// Target number of pixel samples regardless of image resolution.
    var targetSampleCount = 250_000
    /// Maximum colourfulness radius displayed in the scope.
    var maxM: Float = 100.0
    /// Point budget for the 3D cloud (capacity of each point buffer).
    static let maxPoints3D = 262_144

    // MARK: - Metal state

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var histogramPipeline: MTLComputePipelineState?
    private var normalizePipeline: MTLComputePipelineState?

    /// Double-buffered histogram: write to [writeIndex], read from [readIndex].
    private var histogramBuffers: [MTLBuffer] = []
    private var writeIndex = 0

    /// Persistent density output texture.
    private var densityOutputTexture: MTLTexture?

    /// Cached rgbToLMS matrix and the colour space it was computed for.
    private var cachedMatrix = simd_float3x3(1)
    private var cachedColorSpace = ""

    /// Guard against overlapping GPU submissions. A request that arrives while
    /// busy is kept and run once the current one finishes (so toggling 2D/3D
    /// or moving the M slider mid-update is not lost).
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

    /// 3D point-cloud state. Each stats buffer holds [point count, max J × 100].
    @ObservationIgnored private var pointsPipeline: MTLComputePipelineState?
    @ObservationIgnored private var pointBuffers: [MTLBuffer] = []
    @ObservationIgnored private var statsBuffers: [MTLBuffer] = []
    @ObservationIgnored private var pointWriteIndex = 0

    // MARK: - Init

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        setupPipelines()
        setupBuffers()
    }

    // MARK: - Public API

    /// Compute the JMh histogram for the given source texture.
    func update(sourceTexture: MTLTexture, sourceColorSpace: String) {
        if isProcessing {
            pendingRequest = (sourceTexture, sourceColorSpace)
            return
        }
        guard histogramPipeline != nil,
              normalizePipeline != nil else { return }

        isProcessing = true

        // Update matrix if colour space changed
        if sourceColorSpace != cachedColorSpace {
            cachedMatrix = Self.rgbToLMSMatrix(for: sourceColorSpace)
            cachedColorSpace = sourceColorSpace
        }

        if is3D {
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

        let histSz = Self.histogramSize
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

        var params = JmhParams(
            rgbToXYZ: cachedMatrix,
            histSize: SIMD2<UInt32>(UInt32(histSz), UInt32(histSz)),
            stride: UInt32(stride),
            maxM: maxM
        )
        histEncoder.setBytes(&params, length: MemoryLayout<JmhParams>.stride, index: 1)

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

        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            self.normalizeAndPublish(buffer: writeBuffer)
        }

        commandBuffer.commit()
    }

    // MARK: - 3D point cloud

    /// Writes one `Scope3DPoint` per (strided) sample via an atomic counter,
    /// and tracks the largest J with an atomic max.
    private func updatePoints(sourceTexture: MTLTexture) {
        ensurePointBuffers()
        guard let pointsPipeline,
              pointBuffers.count == 2, statsBuffers.count == 2,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            isProcessing = false
            return
        }

        pointWriteIndex = 1 - pointWriteIndex
        let points = pointBuffers[pointWriteIndex]
        let stats = statsBuffers[pointWriteIndex]
        let maxPoints = Self.maxPoints3D

        blit.fill(buffer: stats, range: 0..<stats.length, value: 0)
        blit.endEncoding()

        let totalPixels = Double(sourceTexture.width * sourceTexture.height)
        let stride = max(1, Int(ceil(sqrt(totalPixels / Double(maxPoints)))))

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            isProcessing = false
            return
        }
        encoder.setComputePipelineState(pointsPipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setBuffer(points, offset: 0, index: 0)
        encoder.setBuffer(stats, offset: 0, index: 1)
        var params = JmhPointParams(
            rgbToXYZ: cachedMatrix,
            stride: UInt32(stride),
            maxPoints: UInt32(maxPoints),
            maxEDR: Float(NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0),
            maxM: maxM
        )
        encoder.setBytes(&params, length: MemoryLayout<JmhPointParams>.stride, index: 2)
        let dispatchW = (sourceTexture.width  + stride - 1) / stride
        let dispatchH = (sourceTexture.height + stride - 1) / stride
        encoder.dispatchThreadgroups(
            MTLSize(width: (dispatchW + 15) / 16, height: (dispatchH + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] _ in
            let raw = stats.contents().bindMemory(to: UInt32.self, capacity: 2)
            let count = min(Int(raw[0]), maxPoints)
            let maxJ = Float(raw[1]) / 100.0
            DispatchQueue.main.async {
                guard let self else { return }
                self.pointBuffer = points
                self.pointCount = count
                if count > 0 { self.observedMaxJ = maxJ }
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
                  let c = device.makeBuffer(length: 2 * MemoryLayout<UInt32>.stride, options: .storageModeShared)
            else { pointBuffers = []; statsBuffers = []; return }
            p.label = "JMh 3D points"
            pointBuffers.append(p)
            statsBuffers.append(c)
        }
    }

    // MARK: - Private

    private func normalizeAndPublish(buffer: MTLBuffer) {
        let histSz = Self.histogramSize
        let binCount = histSz * histSz

        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: binCount * 4)
        var maxCount: UInt32 = 0
        for i in 0..<binCount {
            maxCount = max(maxCount, ptr[i * 4 + 3])
        }

        if maxCount == 0 {
            DispatchQueue.main.async { self.isProcessing = false }
            return
        }

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
        var normParams = JmhNormalizeParams(logMaxCount: log2(Float(maxCount) + 1.0), maxEDR: maxEDR)
        encoder.setBytes(&normParams, length: MemoryLayout<JmhNormalizeParams>.stride, index: 1)

        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width:  (histSz + 15) / 16,
            height: (histSz + 15) / 16,
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
        if let histFunc = library.makeFunction(name: "jmhHistogram") {
            histogramPipeline = try? device.makeComputePipelineState(function: histFunc)
        }
        if let normFunc = library.makeFunction(name: "jmhNormalize") {
            normalizePipeline = try? device.makeComputePipelineState(function: normFunc)
        }
        if let pointsFunc = library.makeFunction(name: "jmhPoints") {
            pointsPipeline = try? device.makeComputePipelineState(function: pointsFunc)
        }
    }

    private func setupBuffers() {
        let bufferSize = Self.histogramSize * Self.histogramSize * 4 * MemoryLayout<UInt32>.stride
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
            width: Self.histogramSize,
            height: Self.histogramSize,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        densityOutputTexture = device.makeTexture(descriptor: desc)
    }

    // MARK: - RGB → LMS matrix computation

    /// The Hellwig sharpened-cone LMS matrix used by the ACES 2.0 output transform,
    /// expressed as a transform from ACEScg (AP1) linear RGB.
    /// Extracted from the OCIO-generated Metal shader.
    /// Metal float3x3 is column-major.
    private static let ap1ToLMS = simd_float3x3(columns: (
        SIMD3<Float>( 0.445181042,  0.123734146,  0.0117007261),
        SIMD3<Float>( 0.34964928,   0.613643706,  0.0280607939),
        SIMD3<Float>(-0.00112973328, 0.0563228093, 0.753939092)
    ))

    /// ACEScg (AP1) → XYZ (same as ChromaticityScopeService.acescgToXYZ).
    private static let ap1ToXYZ = simd_float3x3(columns: (
        SIMD3<Float>( 0.6624542,  0.2722287, -0.0055746),
        SIMD3<Float>( 0.1340042,  0.6740818,  0.0040607),
        SIMD3<Float>( 0.1561877,  0.0536895,  1.0103391)
    ))

    /// XYZ → Hellwig LMS, derived as: AP1_to_LMS × inv(AP1_to_XYZ).
    private static let xyzToLMS: simd_float3x3 = {
        return ap1ToLMS * ap1ToXYZ.inverse
    }()

    /// Returns the combined 3×3 matrix converting from the named colour space's
    /// linear RGB to the Hellwig sharpened LMS cone space.
    static func rgbToLMSMatrix(for colorSpace: String) -> simd_float3x3 {
        let rgbToXYZ = ChromaticityScopeService.rgbToXYZMatrix(for: colorSpace)
        return xyzToLMS * rgbToXYZ
    }
}

// MARK: - Shader interop struct (must match JmhCompute.metal)

struct JmhParams {
    var rgbToXYZ: simd_float3x3  // Unused for now — shader uses hardcoded AP1→LMS
    var histSize: SIMD2<UInt32>
    var stride: UInt32
    var maxM: Float
}

struct JmhNormalizeParams {
    var logMaxCount: Float
    var maxEDR: Float
}

struct JmhPointParams {
    var rgbToXYZ: simd_float3x3  // Unused, as in JmhParams
    var stride: UInt32
    var maxPoints: UInt32
    var maxEDR: Float
    var maxM: Float
}
