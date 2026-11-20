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
    ) async -> Bool {
        guard let hdrTexture = await gpuProcessor.processTexture(
            input: sourceTexture, exposure: exposure, channelMask: channelMask
        ) else {
            print("❌ Export: OCIO HDR transform failed")
            return false
        }

        guard let hdrImage = readbackAsCGImage(
            texture: hdrTexture, device: device, colorSpace: colorSpace
        ) else {
            print("❌ Export: HDR CGImage creation failed")
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
    ) -> Bool {
        let context = CIContext()
        let isJPEG = url.pathExtension.lowercased() == "jpg"
            || url.pathExtension.lowercased() == "jpeg"

        guard let (sdr, hdr, headroom, p3) =
                buildGainMapImages(hdrCGImage: hdrImage, hdrColorSpace: hdrColorSpace,
                                   sdrCGImage: sdrImage, context: context) else {
            print("❌ Export: gain map image build failed")
            return false
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
            return false
        }

        if isJPEG && ultraHDRCompatible {
            imageData = injectUltraHDRMetadata(into: imageData)
        }

        do {
            try imageData.write(to: url)
            let fmt = isJPEG ? "JPEG" : "HEIC"
            print("✅ Export: \(fmt) gain map (\(imageData.count) bytes, headroom \(headroom)) → \(url.path)")
            return true
        } catch {
            print("❌ Export: file write error: \(error)")
            return false
        }
    }

    // MARK: - UltraHDR Compatibility

    private struct GainMapChannelParams {
        var gainMapMin: Float
        var gainMapMax: Float
        var gamma: Float
        var offsetSDR: Float
        var offsetHDR: Float
    }

    private struct GainMapXMPParams {
        var baseRenditionIsHDR: Bool = false
        var baseHeadroom: Float = 0.0
        var alternateHeadroom: Float = 0.0
        var channels: [GainMapChannelParams] = []
    }

    private static func injectUltraHDRMetadata(into jpegData: Data) -> Data {
        guard let params = parseGainMapParamsFromJPEG(jpegData) else {
            print("⚠️ UltraHDR: could not parse HDRToneMap XMP, skipping injection")
            return jpegData
        }

        guard let secondaryStart = findSecondaryImageStart(in: jpegData) else {
            print("⚠️ UltraHDR: could not find secondary image, skipping injection")
            return jpegData
        }

        guard let primaryExifEnd = findExifAPP1End(in: jpegData) else {
            print("⚠️ UltraHDR: could not find Exif APP1 end, skipping injection")
            return jpegData
        }

        // Step 1: Build the gain map params XMP and inject into secondary image
        let gainmapXMP = buildGainMapParamsXMP(params: params)
        let gainmapSegment = buildXMPAPP1Segment(gainmapXMP)

        // Find insertion point in secondary: right after its SOI (before existing APP1)
        let secondaryInsertOffset = secondaryStart + 2
        let secondaryOriginalLength = jpegData.count - secondaryStart
        let newSecondaryLength = secondaryOriginalLength + gainmapSegment.count

        // Step 2: Build the primary Container:Directory XMP
        let containerXMP = buildContainerDirectoryXMP(gainMapLength: newSecondaryLength)
        let containerSegment = buildXMPAPP1Segment(containerXMP)

        guard containerSegment.count <= 0xFFFF + 2, gainmapSegment.count <= 0xFFFF + 2 else {
            print("⚠️ UltraHDR: XMP segment too large, skipping injection")
            return jpegData
        }

        // Step 3: Assemble the file.
        // Insert containerSegment into primary (after Exif, before MPF).
        // Insert gainmapSegment into secondary (after SOI, before existing segments).
        // Inserting before MPF means MPF-relative offsets stay valid.
        var result = Data(capacity: jpegData.count + containerSegment.count + gainmapSegment.count)

        // Primary: SOI through Exif APP1
        result.append(jpegData[0..<primaryExifEnd])
        // Primary: injected Container:Directory XMP
        result.append(containerSegment)
        // Primary: rest of primary (MPF, ICC, DQT ... EOI)
        result.append(jpegData[primaryExifEnd..<secondaryStart])
        // Secondary: SOI
        result.append(jpegData[secondaryStart..<secondaryInsertOffset])
        // Secondary: injected hdrgm: gain map params XMP
        result.append(gainmapSegment)
        // Secondary: rest of secondary (existing XMP, ICC, image data ... EOI)
        result.append(jpegData[secondaryInsertOffset...])

        print("✅ UltraHDR: injected Container:Directory (\(containerSegment.count)B) + hdrgm params (\(gainmapSegment.count)B)")
        return result
    }

    private static func buildXMPAPP1Segment(_ xmpString: String) -> Data {
        let xmpBytes = Array(xmpString.utf8)
        let identifier: [UInt8] = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0x00]
        let segmentLength = 2 + identifier.count + xmpBytes.count

        var segment = Data()
        segment.append(contentsOf: [0xFF, 0xE1])
        segment.append(UInt8((segmentLength >> 8) & 0xFF))
        segment.append(UInt8(segmentLength & 0xFF))
        segment.append(contentsOf: identifier)
        segment.append(contentsOf: xmpBytes)
        return segment
    }

    private static func findExifAPP1End(in data: Data) -> Int? {
        var offset = 2 // skip SOI

        while offset + 3 < data.count {
            guard data[offset] == 0xFF else { return nil }
            let marker = data[offset + 1]
            let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])

            if marker == 0xE1 {
                let payloadStart = offset + 4
                if payloadStart + 4 < data.count,
                   data[payloadStart] == 0x45, // E
                   data[payloadStart + 1] == 0x78, // x
                   data[payloadStart + 2] == 0x69, // i
                   data[payloadStart + 3] == 0x66 // f
                {
                    return offset + 2 + length
                }
            }

            offset += 2 + length
        }

        return nil
    }

    private static func parseGainMapParamsFromJPEG(_ data: Data) -> GainMapXMPParams? {
        guard let secondaryStart = findSecondaryImageStart(in: data) else { return nil }
        guard let xmpRange = findXMPRange(in: data, from: secondaryStart) else { return nil }
        guard let xmpString = String(data: data[xmpRange], encoding: .utf8) else { return nil }
        return parseHDRToneMapXMP(xmpString)
    }

    private static func findSecondaryImageStart(in data: Data) -> Int? {
        // Find EOI (FF D9) of primary, then SOI (FF D8) of secondary.
        // In compressed data FF is always followed by 00 (stuffing), so FF D9 is unambiguous.
        for i in 2..<(data.count - 3) {
            if data[i] == 0xFF && data[i + 1] == 0xD9
                && data[i + 2] == 0xFF && data[i + 3] == 0xD8 {
                return i + 2
            }
        }
        return nil
    }

    private static func findXMPRange(in data: Data, from start: Int) -> Range<Int>? {
        let xmpIdent = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0x00]
        var offset = start + 2 // skip SOI

        while offset + 3 < data.count {
            guard data[offset] == 0xFF else { break }
            let marker = data[offset + 1]

            if marker == 0xDA || marker == 0xD9 { break }

            let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let segmentEnd = offset + 2 + length

            if marker == 0xE1 {
                let payloadStart = offset + 4
                if payloadStart + xmpIdent.count <= data.count {
                    let slice = Array(data[payloadStart..<(payloadStart + xmpIdent.count)])
                    if slice == xmpIdent {
                        let xmpStart = payloadStart + xmpIdent.count
                        return xmpStart..<segmentEnd
                    }
                }
            }

            offset = segmentEnd
        }

        return nil
    }

    private static func parseHDRToneMapXMP(_ xmp: String) -> GainMapXMPParams? {
        var params = GainMapXMPParams()

        if let val = extractXMLElementValue(from: xmp, tag: "HDRToneMap:BaseRenditionIsHDR") {
            params.baseRenditionIsHDR = val == "1"
        }
        if let val = extractXMLElementValue(from: xmp, tag: "HDRToneMap:BaseHeadroom") {
            params.baseHeadroom = Float(val) ?? 0.0
        }
        if let val = extractXMLElementValue(from: xmp, tag: "HDRToneMap:AlternateHeadroom") {
            params.alternateHeadroom = Float(val) ?? 0.0
        }

        let gainMapMins = extractAllXMLElementValues(from: xmp, tag: "HDRToneMap:GainMapMin")
        let gainMapMaxs = extractAllXMLElementValues(from: xmp, tag: "HDRToneMap:GainMapMax")
        let gammas = extractAllXMLElementValues(from: xmp, tag: "HDRToneMap:Gamma")
        let offsetSDRs = extractAllXMLElementValues(from: xmp, tag: "HDRToneMap:OffsetSDR")
        let offsetHDRs = extractAllXMLElementValues(from: xmp, tag: "HDRToneMap:OffsetHDR")

        guard !gainMapMins.isEmpty else { return nil }

        for i in 0..<gainMapMins.count {
            params.channels.append(GainMapChannelParams(
                gainMapMin: Float(gainMapMins[i]) ?? 0,
                gainMapMax: Float(i < gainMapMaxs.count ? gainMapMaxs[i] : "0") ?? 0,
                gamma: Float(i < gammas.count ? gammas[i] : "1") ?? 1,
                offsetSDR: Float(i < offsetSDRs.count ? offsetSDRs[i] : "0") ?? 0,
                offsetHDR: Float(i < offsetHDRs.count ? offsetHDRs[i] : "0") ?? 0
            ))
        }

        return params
    }

    private static func extractXMLElementValue(from xml: String, tag: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    private static func extractAllXMLElementValues(from xml: String, tag: String) -> [String] {
        var results: [String] = []
        var searchStart = xml.startIndex
        while let start = xml.range(of: "<\(tag)>", range: searchStart..<xml.endIndex),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) {
            results.append(String(xml[start.upperBound..<end.lowerBound]))
            searchStart = end.upperBound
        }
        return results
    }

    private static func buildContainerDirectoryXMP(gainMapLength: Int) -> String {
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"
           xmlns:Container="http://ns.google.com/photos/1.0/container/"
           xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
           hdrgm:Version="1.0">
           <Container:Directory>
            <rdf:Seq>
             <rdf:li rdf:parseType="Resource">
              <Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/>
             </rdf:li>
             <rdf:li rdf:parseType="Resource">
              <Container:Item Item:Semantic="GainMap" Item:Mime="image/jpeg" Item:Length="\(gainMapLength)"/>
             </rdf:li>
            </rdf:Seq>
           </Container:Directory>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
    }

    private static func buildGainMapParamsXMP(params: GainMapXMPParams) -> String {
        let channels = params.channels

        func scalar(_ kp: KeyPath<GainMapChannelParams, Float>,
                    reduce: ([Float]) -> Float = { $0.reduce(0, +) / Float($0.count) }
        ) -> String {
            let vals = channels.map { $0[keyPath: kp] }
            let allSame = vals.allSatisfy { $0 == vals[0] }
            let v = allSame ? vals[0] : reduce(vals)
            return String(format: "%.6f", v)
        }

        let baseIsHDR = params.baseRenditionIsHDR ? "True" : "False"

        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"
           hdrgm:Version="1.0"
           hdrgm:BaseRenditionIsHDR="\(baseIsHDR)"
           hdrgm:GainMapMin="\(scalar(\.gainMapMin, reduce: { $0.min()! }))"
           hdrgm:GainMapMax="\(scalar(\.gainMapMax, reduce: { $0.max()! }))"
           hdrgm:Gamma="\(scalar(\.gamma))"
           hdrgm:OffsetSDR="\(scalar(\.offsetSDR))"
           hdrgm:OffsetHDR="\(scalar(\.offsetHDR))"
           hdrgm:HDRCapacityMin="\(String(format: "%.6f", params.baseHeadroom))"
           hdrgm:HDRCapacityMax="\(String(format: "%.6f", params.alternateHeadroom))"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
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
