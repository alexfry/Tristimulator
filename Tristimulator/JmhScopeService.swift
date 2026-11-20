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

    // MARK: - Configuration

    static let histogramSize = 512
    /// Target number of pixel samples regardless of image resolution.
    var targetSampleCount = 250_000
    /// Maximum colourfulness radius displayed in the scope.
    var maxM: Float = 100.0

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

    /// Guard against overlapping GPU submissions.
    private var isProcessing = false

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
        guard !isProcessing,
              histogramPipeline != nil,
              normalizePipeline != nil else { return }

        isProcessing = true

        // Update matrix if colour space changed
        if sourceColorSpace != cachedColorSpace {
            cachedMatrix = Self.rgbToLMSMatrix(for: sourceColorSpace)
            cachedColorSpace = sourceColorSpace
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
