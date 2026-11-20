//
//  PixelReductionService.swift
//  Tristimulator
//
//  Peak-brightness measurement: MPSImageConversion linearises the drawable
//  -> extendedLinearDisplayP3, then textureMaxReduce finds the per-channel max.
//
//  For PQ/HLG spaces Core Graphics normalises to the BT.2408 diffuse-white
//  reference (203 nit) rather than the 100-nit SDR convention used everywhere
//  else in the app.  After conversion we multiply by 2.03 to correct for this.
//
//  Result: 1.0 = SDR white (100 nit), values > 1.0 are HDR.

import Metal
import MetalPerformanceShaders
import simd

final class PixelReductionService {

    let pipeline: MTLComputePipelineState

    private static let linearDestSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// Scale factor for PQ/HLG: BT.2408 diffuse-white (203 nit) → 100-nit SDR white.
    private static let bt2408Correction: Float = 203.0 / 100.0

    init?(device: MTLDevice) {
        guard
            let library  = device.makeDefaultLibrary(),
            let function = library.makeFunction(name: "textureMaxReduce"),
            let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        self.pipeline = pipeline
    }

    func measurePeak(
        texture: MTLTexture,
        device: MTLDevice,
        commandBuffer: MTLCommandBuffer,
        sourceColorSpace: CGColorSpace,
        completion: @escaping (SIMD4<Float>) -> Void
    ) {
        let needsCorrection = Self.isAbsoluteLuminanceSpace(sourceColorSpace)

        // Convert drawable texture to extendedLinearDisplayP3 via MPS.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width:  texture.width,
            height: texture.height,
            mipmapped: false
        )
        desc.usage       = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let intermediate = device.makeTexture(descriptor: desc) else { return }

        guard
            let convInfo = CGColorConversionInfo(src: sourceColorSpace,
                                                 dst: Self.linearDestSpace),
            let converter = MPSImageConversion(
                device: device,
                srcAlpha: .alphaIsOne,
                destAlpha: .alphaIsOne,
                backgroundColor: nil,
                conversionInfo: convInfo
            ) as MPSImageConversion?
        else { return }

        converter.encode(commandBuffer: commandBuffer,
                         sourceTexture: texture,
                         destinationTexture: intermediate)

        // GPU reduction on the linearised intermediate texture.
        let numTGX     = (texture.width  + 15) / 16
        let numTGY     = (texture.height + 15) / 16
        let groupCount = numTGX * numTGY

        guard
            let resultBuffer = device.makeBuffer(
                length: groupCount * MemoryLayout<SIMD4<Float>>.stride,
                options: .storageModeShared
            ),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(intermediate, index: 0)
        encoder.setBuffer(resultBuffer, offset: 0, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: numTGX, height: numTGY, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { _ in
            let ptr = resultBuffer.contents()
                .bindMemory(to: SIMD4<Float>.self, capacity: groupCount)
            var globalMax = SIMD4<Float>(repeating: 0)
            for i in 0..<groupCount { globalMax = max(globalMax, ptr[i]) }
            // Correct PQ/HLG from BT.2408 203-nit reference to 100-nit SDR white.
            if needsCorrection {
                let k = PixelReductionService.bt2408Correction
                globalMax = SIMD4<Float>(globalMax.x * k, globalMax.y * k,
                                         globalMax.z * k, 0.0)
            }
            DispatchQueue.main.async { completion(globalMax) }
        }
    }

    private static func isAbsoluteLuminanceSpace(_ space: CGColorSpace) -> Bool {
        guard let name = space.name as String? else { return false }
        return name.contains("2100_PQ") || name.contains("2100_HLG")
    }
}
