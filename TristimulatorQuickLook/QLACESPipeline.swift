import Foundation
import Metal
import simd

// Loads the ACES 2 shader + LUT textures from bundle resources,
// compiles the Metal source at init, and encodes per-frame dispatches.
// ACES2Params uniforms are recomputed when peakNits changes, making the
// tone curve and gamut compression adapt to the display's EDR headroom.
class QLACESPipeline {
    private let pso:    MTLComputePipelineState
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var orderedTextures: [MTLTexture] = []

    private var paramsBuffer: MTLBuffer
    private var cachedPeakNits: Float = 0
    private var reachMTexture: MTLTexture?
    private var gamutCuspTexture: MTLTexture?

    init(device: MTLDevice, commandQueue: MTLCommandQueue) throws {
        self.device = device
        self.commandQueue = commandQueue

        let bundle = Bundle(for: QLACESPipeline.self)

        guard let manifestURL = bundle.url(forResource: "aces2_manifest", withExtension: "json") else {
            throw PipelineError.missingShader
        }
        let manifestData = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let shaderSource = manifest["shader"] as? String else {
            throw PipelineError.missingShader
        }

        let opts = MTLCompileOptions()
        opts.fastMathEnabled = false
        let library = try device.makeLibrary(source: shaderSource, options: opts)
        guard let fn = library.makeFunction(name: "ocioColorTransform") else {
            throw PipelineError.missingKernel
        }
        pso = try device.makeComputePipelineState(function: fn)

        guard let buf = device.makeBuffer(
            length: MemoryLayout<ACES2Uniforms>.stride,
            options: .storageModeShared
        ) else {
            throw PipelineError.missingKernel
        }
        paramsBuffer = buf

        if let entries = manifest["textures"] as? [[String: Any]] {
            orderedTextures = try loadTextures(entries: entries, bundle: bundle)
        }
    }

    func encode(source: MTLTexture,
                output: MTLTexture,
                peakNits: Float,
                inputMatrix: simd_float3x3,
                exposure: Float = 0.0,
                channelMask: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0),
                into commandBuffer: MTLCommandBuffer) {

        updateParamsIfNeeded(peakNits: peakNits)

        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pso)

        enc.setTexture(source, index: 0)
        enc.setTexture(output, index: 1)
        for (i, tex) in orderedTextures.enumerated() {
            enc.setTexture(tex, index: 2 + i)
        }
        if let reach = reachMTexture { enc.setTexture(reach, index: 2) }
        if let cusp = gamutCuspTexture { enc.setTexture(cusp, index: 3) }

        var exp = exposure
        enc.setBytes(&exp,         length: MemoryLayout<Float>.size,           index: 0)
        var mask = channelMask
        enc.setBytes(&mask,        length: MemoryLayout<SIMD4<Float>>.size,    index: 1)
        var nits = peakNits
        enc.setBytes(&nits,        length: MemoryLayout<Float>.size,           index: 2)
        var mat = inputMatrix
        enc.setBytes(&mat,         length: MemoryLayout<simd_float3x3>.size,   index: 3)
        enc.setBuffer(paramsBuffer, offset: 0, index: 4)

        let tgs = MTLSize(width: 16, height: 16, depth: 1)
        let tg  = MTLSize(
            width:  (source.width  + 15) / 16,
            height: (source.height + 15) / 16,
            depth:  1
        )
        enc.dispatchThreadgroups(tg, threadsPerThreadgroup: tgs)
        enc.endEncoding()
    }

    // MARK: - Dynamic ACES 2 params

    private func updateParamsIfNeeded(peakNits: Float) {
        let quantized = quantizePeakNits(peakNits)
        guard quantized != cachedPeakNits else { return }
        cachedPeakNits = quantized

        let nits = Double(quantized)
        var uniforms = makeACES2Uniforms(peakNits: nits)
        paramsBuffer.contents().copyMemory(
            from: &uniforms,
            byteCount: MemoryLayout<ACES2Uniforms>.size
        )

        let reachData = makeReachMTable(peakNits: nits)
        reachMTexture = upload1DTexture(data: reachData, width: reachData.count, channels: 1)

        let (cuspData, _) = makeGamutCuspTable(peakNits: nits)
        gamutCuspTexture = upload1DTexture(data: cuspData, width: cuspData.count / 3, channels: 3)
    }

    private func upload1DTexture(data: [Float], width: Int, channels: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type1D
        desc.pixelFormat = .rgba32Float
        desc.width = width
        desc.usage = .shaderRead
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        var rgba = [Float]()
        rgba.reserveCapacity(width * 4)
        if channels == 1 {
            for i in 0..<width {
                rgba.append(data[i])
                rgba.append(0); rgba.append(0); rgba.append(0)
            }
        } else {
            for i in 0..<width {
                let base = i * channels
                rgba.append(data[base])
                rgba.append(channels > 1 ? data[base + 1] : 0)
                rgba.append(channels > 2 ? data[base + 2] : 0)
                rgba.append(1.0)
            }
        }

        let byteCount = width * 4 * MemoryLayout<Float>.size
        guard let staging = device.makeBuffer(
            bytes: rgba, length: byteCount, options: .storageModeShared
        ) else { return nil }

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: staging, sourceOffset: 0,
            sourceBytesPerRow: byteCount,
            sourceBytesPerImage: byteCount,
            sourceSize: MTLSize(width: width, height: 1, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return texture
    }

    private func quantizePeakNits(_ nits: Float) -> Float {
        if nits < 500 {
            return (nits / 10).rounded() * 10
        } else {
            return (nits / 25).rounded() * 25
        }
    }

    func makeOutputTexture(matching source: MTLTexture) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width:       source.width,
            height:      source.height,
            mipmapped:   false
        )
        desc.usage       = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    // MARK: - Texture loading

    private func loadTextures(entries: [[String: Any]], bundle: Bundle) throws -> [MTLTexture] {
        var textures: [MTLTexture] = []
        for entry in entries {
            guard let name = entry["name"] as? String,
                  let type = entry["type"] as? String,
                  let file = entry["file"] as? String else { continue }

            let fileBase = (file as NSString).deletingPathExtension
            let fileExt  = (file as NSString).pathExtension
            guard let dataURL = bundle.url(forResource: fileBase, withExtension: fileExt),
                  let data = try? Data(contentsOf: dataURL) else {
                print("⚠️ QLACESPipeline: missing texture file \(file)")
                continue
            }

            let channels = entry["channels"] as? Int ?? 3

            if type == "3D", let edge = entry["edgeLength"] as? Int {
                if let tex = create3DTexture(data: data, edgeLength: edge) {
                    textures.append(tex)
                }
            } else if type == "2D", let w = entry["width"] as? Int, let h = entry["height"] as? Int {
                if let tex = create2DTexture(data: data, width: w, height: h, channels: channels) {
                    textures.append(tex)
                }
            } else if type == "1D", let w = entry["width"] as? Int {
                let shaderUsesRGB = entry["channelType"] as? String == "RGB"
                let effectiveChannels = shaderUsesRGB ? channels : 1
                if let tex = create1DTexture(data: data, width: w, channels: effectiveChannels) {
                    textures.append(tex)
                }
            }
        }
        return textures
    }

    private func create1DTexture(data: Data, width: Int, channels: Int) -> MTLTexture? {
        let uploadData: Data
        let bytesPerTexel = 4 * MemoryLayout<Float>.size

        if channels == 1 {
            uploadData = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
                let floats = ptr.bindMemory(to: Float.self)
                var out = [Float]()
                out.reserveCapacity(width * 4)
                for i in 0..<width {
                    out.append(i < floats.count ? floats[i] : 0)
                    out.append(0); out.append(0); out.append(0)
                }
                return Data(bytes: out, count: out.count * MemoryLayout<Float>.size)
            }
        } else {
            let n = width * channels
            uploadData = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
                let floats = ptr.bindMemory(to: Float.self)
                var out = [Float]()
                out.reserveCapacity(width * 4)
                for i in stride(from: 0, to: min(n, floats.count), by: channels) {
                    out.append(floats[i])
                    out.append(channels > 1 ? floats[i + 1] : 0)
                    out.append(channels > 2 ? floats[i + 2] : 0)
                    out.append(1.0)
                }
                return Data(bytes: out, count: out.count * MemoryLayout<Float>.size)
            }
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = width
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        guard let staging = device.makeBuffer(
            bytes: uploadData.withUnsafeBytes({ $0.baseAddress! }),
            length: uploadData.count,
            options: .storageModeShared
        ) else { return nil }

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }

        blit.copy(
            from: staging, sourceOffset: 0,
            sourceBytesPerRow: width * bytesPerTexel,
            sourceBytesPerImage: width * bytesPerTexel,
            sourceSize: MTLSize(width: width, height: 1, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return texture
    }

    private func create2DTexture(data: Data, width: Int, height: Int, channels: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let componentCount = width * height * channels
        let rgbaData = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            let floats = ptr.bindMemory(to: Float.self)
            var out = [Float]()
            out.reserveCapacity(width * height * 4)
            if channels == 1 {
                for i in 0..<(width * height) {
                    let v = floats[i]
                    out.append(v); out.append(v); out.append(v); out.append(1.0)
                }
            } else {
                for i in stride(from: 0, to: componentCount, by: channels) {
                    out.append(floats[i])
                    out.append(channels > 1 ? floats[i + 1] : 0)
                    out.append(channels > 2 ? floats[i + 2] : 0)
                    out.append(1.0)
                }
            }
            return Data(bytes: out, count: out.count * MemoryLayout<Float>.size)
        }

        rgbaData.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: width * 4 * MemoryLayout<Float>.size
            )
        }
        return texture
    }

    private func create3DTexture(data: Data, edgeLength: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = edgeLength; descriptor.height = edgeLength; descriptor.depth = edgeLength
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let n = edgeLength * edgeLength * edgeLength * 3
        let rgbaData = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            let floats = ptr.bindMemory(to: Float.self)
            var out = [Float]()
            out.reserveCapacity(edgeLength * edgeLength * edgeLength * 4)
            for i in stride(from: 0, to: n, by: 3) {
                out.append(floats[i]); out.append(floats[i+1]); out.append(floats[i+2]); out.append(1.0)
            }
            return Data(bytes: out, count: out.count * MemoryLayout<Float>.size)
        }

        let bytesPerRow = edgeLength * 4 * MemoryLayout<Float>.size
        rgbaData.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: edgeLength, height: edgeLength, depth: edgeLength)),
                mipmapLevel: 0, slice: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerRow * edgeLength
            )
        }
        return texture
    }

    enum PipelineError: LocalizedError {
        case missingShader
        case missingKernel
        var errorDescription: String? {
            switch self {
            case .missingShader: return "aces2_manifest.json not found in bundle — run Bake QuickLook Shader from the main app first"
            case .missingKernel: return "ocioColorTransform kernel not found in compiled shader"
            }
        }
    }
}
