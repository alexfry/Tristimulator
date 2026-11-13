//
//  ImageClipboardHelper.swift
//  Tristimulator
//
//  Copies the OCIO-processed image to the system clipboard at full resolution,
//  tagged with the Metal display surface's colorspace to preserve HDR fidelity.
//

import Metal
import AppKit
import CoreGraphics
import CoreImage
import ImageIO

/// Result of File > Export Gain Map Image.
enum GainMapExportOutcome: Equatable {
    case saved
    /// Saved as an ISO 21496-1 gain-map JPEG, but the UltraHDR XMP couldn't be added.
    case savedWithoutUltraHDR(reason: String)
    case failed
}

enum ImageClipboardHelper {

    // MARK: - Public: Clipboard (Gain Map)

    static func copyToClipboard(
        device: MTLDevice,
        gpuProcessor: OCIOGPUProcessor,
        sourceTexture: MTLTexture,
        exposure: Float,
        channelMask: SIMD4<Float>,
        colorSpace: CGColorSpace,
        sdrProcessor: OCIOGPUProcessor? = nil,
        sdrColorSpace: CGColorSpace? = nil
    ) async -> Bool {
        guard let hdrTexture = await gpuProcessor.processTexture(
            input: sourceTexture, exposure: exposure, channelMask: channelMask
        ) else {
            print("❌ Clipboard: OCIO HDR transform failed")
            return false
        }

        guard let hdrImage = readbackAsCGImage(
            texture: hdrTexture, device: device, colorSpace: colorSpace
        ) else {
            print("❌ Clipboard: HDR CGImage creation failed")
            return false
        }

        var sdrImage: CGImage?
        if let sdrProc = sdrProcessor {
            if let sdrTex = await sdrProc.processTexture(
                input: sourceTexture, exposure: exposure, channelMask: channelMask
            ) {
                let sdrCS = sdrColorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
                sdrImage = readbackAsCGImage(texture: sdrTex, device: device, colorSpace: sdrCS)
            }
            if sdrImage == nil {
                print("⚠️ Clipboard: OCIO SDR pass failed, falling back to CIToneMapHeadroom")
            }
        }

        let success = await MainActor.run {
            writeToPasteboard(hdrImage: hdrImage, hdrColorSpace: colorSpace, sdrImage: sdrImage)
        }

        if success {
            let csName = colorSpace.name as String? ?? "unknown"
            let mode = sdrImage != nil ? "OCIO SDR base" : "CIToneMap SDR base"
            print("✅ Clipboard: copied \(hdrTexture.width)×\(hdrTexture.height) (\(csName), \(mode))")
        }
        return success
    }

    // MARK: - Public: Clipboard (Native Colorspace)

    static func copyNativeToClipboard(
        device: MTLDevice,
        gpuProcessor: OCIOGPUProcessor,
        sourceTexture: MTLTexture,
        exposure: Float,
        channelMask: SIMD4<Float>,
        colorSpace: CGColorSpace
    ) async -> Bool {
        guard let processedTexture = await gpuProcessor.processTexture(
            input: sourceTexture, exposure: exposure, channelMask: channelMask
        ) else {
            print("❌ Clipboard (native): OCIO transform failed")
            return false
        }

        guard let cgImage = readbackAsCGImage(
            texture: processedTexture, device: device, colorSpace: colorSpace
        ) else {
            print("❌ Clipboard (native): CGImage creation failed")
            return false
        }

        let success = await MainActor.run {
            writeNativeToPasteboard(cgImage: cgImage, colorSpace: colorSpace)
        }

        if success {
            let csName = colorSpace.name as String? ?? "unknown"
            print("✅ Clipboard (native): copied \(processedTexture.width)×\(processedTexture.height) (\(csName))")
        }
        return success
    }

    // MARK: - Public: File Export (Gain Map)

    static func exportGainMapImage(
        device: MTLDevice,
        gpuProcessor: OCIOGPUProcessor,
        sourceTexture: MTLTexture,
        exposure: Float,
        channelMask: SIMD4<Float>,
        colorSpace: CGColorSpace,
        url: URL,
        sdrProcessor: OCIOGPUProcessor? = nil,
        sdrColorSpace: CGColorSpace? = nil,
        ultraHDRCompatible: Bool = false
    ) async -> GainMapExportOutcome {
        guard let hdrTexture = await gpuProcessor.processTexture(
            input: sourceTexture, exposure: exposure, channelMask: channelMask
        ) else {
            print("❌ Export: OCIO HDR transform failed")
            return .failed
        }

        guard let hdrImage = readbackAsCGImage(
            texture: hdrTexture, device: device, colorSpace: colorSpace
        ) else {
            print("❌ Export: HDR CGImage creation failed")
            return .failed
        }

        var sdrImage: CGImage?
        if let sdrProc = sdrProcessor {
            if let sdrTex = await sdrProc.processTexture(
                input: sourceTexture, exposure: exposure, channelMask: channelMask
            ) {
                let sdrCS = sdrColorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
                sdrImage = readbackAsCGImage(texture: sdrTex, device: device, colorSpace: sdrCS)
            }
            if sdrImage == nil {
                print("⚠️ Export: OCIO SDR pass failed, falling back to CIToneMapHeadroom")
            }
        }

        return writeGainMapToFile(
            hdrImage: hdrImage, hdrColorSpace: colorSpace,
            sdrImage: sdrImage, url: url,
            ultraHDRCompatible: ultraHDRCompatible
        )
    }

    // MARK: - Gain Map Pipeline

    private static func buildGainMapImages(
        hdrCGImage: CGImage,
        hdrColorSpace: CGColorSpace,
        sdrCGImage: CGImage?,
        context: CIContext
    ) -> (sdr: CIImage, hdr: CIImage, headroom: Float, p3: CGColorSpace)? {
        let csName = hdrColorSpace.name as String? ?? "unknown"
        let isPQorHLG = hdrColorSpace.name == CGColorSpace.itur_2100_PQ
            || hdrColorSpace.name == CGColorSpace.itur_2100_HLG

        // Prepare HDR CIImage in extended-linear Display P3
        let hdrCIImage: CIImage
        if isPQorHLG {
            let extLinP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
            let pqCI = CIImage(cgImage: hdrCGImage)
            guard let linearCG = context.createCGImage(
                pqCI, from: pqCI.extent, format: .RGBAh, colorSpace: extLinP3
            ) else {
                print("❌ GainMap: PQ→linear conversion failed")
                return nil
            }

            let scale: CGFloat = 203.0 / 100.0
            var linearCI = CIImage(cgImage: linearCG)
            let scaleFilter = CIFilter(name: "CIColorMatrix")!
            scaleFilter.setValue(linearCI, forKey: kCIInputImageKey)
            scaleFilter.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputRVector")
            scaleFilter.setValue(CIVector(x: 0, y: scale, z: 0, w: 0), forKey: "inputGVector")
            scaleFilter.setValue(CIVector(x: 0, y: 0, z: scale, w: 0), forKey: "inputBVector")
            scaleFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            linearCI = scaleFilter.outputImage ?? linearCI

            guard let scaledCG = context.createCGImage(
                linearCI, from: linearCI.extent, format: .RGBAh, colorSpace: extLinP3
            ) else {
                print("❌ GainMap: scaled linear render failed")
                return nil
            }
            hdrCIImage = CIImage(cgImage: scaledCG)
            print("📊 GainMap: converted \(csName) → extendedLinearDisplayP3, ×\(scale) (100 nit ref white)")
        } else {
            hdrCIImage = CIImage(cgImage: hdrCGImage)
        }

        // Measure headroom from HDR pixel data
        let headroom: Float
        if isPQorHLG {
            headroom = 10.0
        } else {
            let measured = measurePeakHeadroom(cgImage: hdrCGImage)
            headroom = max(measured, Self.estimatedHeadroom(for: hdrColorSpace))
        }
        print("📊 GainMap: headroom=\(headroom)")

        guard headroom > 1.0 else {
            print("📊 GainMap: SDR content (headroom ≤ 1.0)")
            return nil
        }

        // Annotate HDR image with headroom
        let hdrWithHeadroom: CIImage
        if let cg = hdrCIImage.cgImage {
            hdrWithHeadroom = CIImage(cgImage: cg, options: [.contentHeadroom: headroom])
        } else {
            hdrWithHeadroom = hdrCIImage
        }

        // SDR base: prefer OCIO-tone-mapped version, fall back to CIToneMapHeadroom
        let sdrCIImage: CIImage
        if let sdr = sdrCGImage {
            sdrCIImage = CIImage(cgImage: sdr)
            print("📊 GainMap: using OCIO SDR base image")
        } else if #available(macOS 15.0, *) {
            let toneMap = CIFilter(name: "CIToneMapHeadroom")!
            toneMap.setValue(hdrWithHeadroom, forKey: kCIInputImageKey)
            toneMap.setValue(headroom, forKey: "inputSourceHeadroom")
            toneMap.setValue(1.0, forKey: "inputTargetHeadroom")
            sdrCIImage = toneMap.outputImage ?? hdrWithHeadroom
            print("📊 GainMap: using CIToneMapHeadroom (\(headroom) → 1.0)")
        } else {
            sdrCIImage = hdrWithHeadroom
        }

        guard let p3ColorSpace = CGColorSpace(name: CGColorSpace.displayP3) else {
            print("❌ GainMap: failed to create Display P3 colorspace")
            return nil
        }

        return (sdrCIImage, hdrWithHeadroom, headroom, p3ColorSpace)
    }

    // MARK: - Pasteboard (Gain Map)

    private static func writeToPasteboard(
        hdrImage: CGImage, hdrColorSpace: CGColorSpace, sdrImage: CGImage?
    ) -> Bool {
        let context = CIContext()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard let (sdr, hdr, headroom, p3) =
                buildGainMapImages(hdrCGImage: hdrImage, hdrColorSpace: hdrColorSpace,
                                   sdrCGImage: sdrImage, context: context) else {
            return fallbackToNSImage(hdrImage, pasteboard)
        }

        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr,
            .hdrGainMapAsRGB: true
        ]

        if let heicData = context.heifRepresentation(
            of: sdr, format: .RGBA16, colorSpace: p3, options: options
        ) {
            let tempURL = createTemporaryHEICURL()
            do {
                try heicData.write(to: tempURL)
                print("✅ Clipboard: SDR+GainMap HEIC (\(heicData.count) bytes, headroom \(headroom)) → \(tempURL.path)")
                if pasteboard.writeObjects([tempURL as NSURL]) {
                    return true
                }
                print("❌ Clipboard: pasteboard.writeObjects failed")
            } catch {
                print("❌ Clipboard: temp file error: \(error)")
                try? FileManager.default.removeItem(at: tempURL)
            }
        } else {
            print("❌ Clipboard: heifRepresentation returned nil — gain map generation failed")
        }

        print("⚠️ Clipboard: falling back to NSImage (no gain map)")
        return fallbackToNSImage(hdrImage, pasteboard)
    }

    // MARK: - File Export (Gain Map)

    private static func writeGainMapToFile(
        hdrImage: CGImage, hdrColorSpace: CGColorSpace,
        sdrImage: CGImage?, url: URL,
        ultraHDRCompatible: Bool = false
    ) -> GainMapExportOutcome {
        let context = CIContext()
        let isJPEG = url.pathExtension.lowercased() == "jpg"
            || url.pathExtension.lowercased() == "jpeg"

        guard let (sdr, hdr, headroom, p3) =
                buildGainMapImages(hdrCGImage: hdrImage, hdrColorSpace: hdrColorSpace,
                                   sdrCGImage: sdrImage, context: context) else {
            print("❌ Export: gain map image build failed")
            return .failed
        }

        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr,
            .hdrGainMapAsRGB: true
        ]

        let data: Data?
        if isJPEG {
            data = context.jpegRepresentation(of: sdr, colorSpace: p3, options: options)
        } else {
            data = context.heifRepresentation(of: sdr, format: .RGBA16, colorSpace: p3, options: options)
        }

        guard var imageData = data else {
            print("❌ Export: \(isJPEG ? "JPEG" : "HEIC") representation failed")
            return .failed
        }

        // UltraHDR (Google/Adobe hdrgm XMP) applies to JPEG only. If it can't be added, the
        // file is still a valid ISO 21496-1 gain-map JPEG, so save it and report the reason.
        var ultraHDRProblem: String?
        if isJPEG && ultraHDRCompatible {
            do {
                let result = try UltraHDRMetadata.inject(into: imageData)
                imageData = result.data
                print("✅ UltraHDR: \(result.injected ? "added hdrgm XMP" : "already present") from \(result.source.rawValue) "
                      + "(capacity \(result.params.hdrCapacityMin)…\(result.params.hdrCapacityMax) log2, "
                      + "\(result.params.channels.count) channel(s))")
            } catch {
                ultraHDRProblem = "\(error)"
                print("❌ UltraHDR: couldn't add UltraHDR metadata: \(error)")
            }
        }

        do {
            try imageData.write(to: url)
            let fmt = isJPEG ? "JPEG" : "HEIC"
            print("✅ Export: \(fmt) gain map (\(imageData.count) bytes, headroom \(headroom)) → \(url.path)")
            return ultraHDRProblem.map { .savedWithoutUltraHDR(reason: $0) } ?? .saved
        } catch {
            print("❌ Export: file write error: \(error)")
            return .failed
        }
    }

    // MARK: - Pasteboard (Native)

    private static func writeNativeToPasteboard(cgImage: CGImage, colorSpace: CGColorSpace) -> Bool {
        let tiffData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            tiffData as CFMutableData, "public.tiff" as CFString, 1, nil
        ) else { return false }

        let isPQorHLG = colorSpace.name == CGColorSpace.itur_2100_PQ
            || colorSpace.name == CGColorSpace.itur_2100_HLG
        let metadata = isPQorHLG ? makeHDRMetadata(maxCLL: 1000, maxFALL: 1000) : nil

        CGImageDestinationAddImageAndMetadata(dest, cgImage, metadata, nil)
        guard CGImageDestinationFinalize(dest) else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let csName = colorSpace.name as String? ?? "unknown"
        print("📊 Clipboard (native): Float16 TIFF, colorSpace=\(csName), \(tiffData.length) bytes")
        return pasteboard.setData(tiffData as Data, forType: .tiff)
    }

    // MARK: - Helpers

    private static func createTemporaryHEICURL() -> URL {
        let tempDir = URL.temporaryDirectory.appendingPathComponent("TristimulatorHDR", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let filename = "hdr_clipboard_\(UUID().uuidString.prefix(8)).heic"
        return tempDir.appendingPathComponent(filename)
    }

    private static func fallbackToNSImage(_ cgImage: CGImage, _ pasteboard: NSPasteboard) -> Bool {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize.zero)
        return pasteboard.writeObjects([nsImage])
    }

    private static func measurePeakHeadroom(cgImage: CGImage) -> Float {
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data as Data? else { return 1.0 }

        let bytesPerRow = cgImage.bytesPerRow
        let width = cgImage.width
        let height = cgImage.height
        let componentsPerPixel = 4

        var maxVal: Float = 0.0
        data.withUnsafeBytes { rawBuffer in
            let basePtr = rawBuffer.baseAddress!
            for y in 0..<height {
                let rowPtr = basePtr.advanced(by: y * bytesPerRow)
                    .assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    let pixelOffset = x * componentsPerPixel
                    for c in 0..<3 {
                        let halfBits = rowPtr[pixelOffset + c]
                        let val = Float(Float16(bitPattern: halfBits))
                        if val > maxVal { maxVal = val }
                    }
                }
            }
        }
        print("📊 GainMap: measured peak pixel value = \(maxVal)")
        return max(maxVal, 1.0)
    }

    private static func estimatedHeadroom(for colorSpace: CGColorSpace) -> Float {
        let name = colorSpace.name
        if name == CGColorSpace.itur_2100_PQ || name == CGColorSpace.itur_2100_HLG {
            return 10.0
        }
        if name == CGColorSpace.extendedLinearDisplayP3
            || name == CGColorSpace.extendedLinearSRGB
            || name == CGColorSpace.extendedLinearITUR_2020
            || name == CGColorSpace.extendedDisplayP3
            || name == CGColorSpace.extendedSRGB {
            return 10.0
        }
        return 1.0
    }

    // MARK: - HDR Metadata

    private static func makeHDRMetadata(maxCLL: Int, maxFALL: Int) -> CGImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        let ns = "http://ns.apple.com/hdrContent/1.0/" as CFString
        let prefix = "hdrContent" as CFString
        CGImageMetadataRegisterNamespaceForPrefix(metadata, ns, prefix, nil)

        if let tag = CGImageMetadataTagCreate(
            ns, prefix, "MaxContentLightLevel" as CFString,
            .string, "\(maxCLL)" as CFTypeRef
        ) {
            CGImageMetadataSetTagWithPath(metadata, nil,
                "hdrContent:MaxContentLightLevel" as CFString, tag)
        }
        if let tag = CGImageMetadataTagCreate(
            ns, prefix, "MaxFrameAverageLightLevel" as CFString,
            .string, "\(maxFALL)" as CFTypeRef
        ) {
            CGImageMetadataSetTagWithPath(metadata, nil,
                "hdrContent:MaxFrameAverageLightLevel" as CFString, tag)
        }

        print("📎 HDR metadata: MaxCLL=\(maxCLL), MaxFALL=\(maxFALL)")
        return metadata
    }

    // MARK: - GPU Readback → CGImage

    private static func readbackAsCGImage(
        texture: MTLTexture,
        device: MTLDevice,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        let width = texture.width
        let height = texture.height

        let bytesPerPixel = 8
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        guard let commandQueue = device.makeCommandQueue(),
              let readbackBuffer = device.makeBuffer(length: totalBytes, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else { return nil }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readbackBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: totalBytes
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let data = Data(bytes: readbackBuffer.contents(), count: totalBytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.floatComponents.rawValue |
            CGBitmapInfo.byteOrder16Little.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue
        )

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
