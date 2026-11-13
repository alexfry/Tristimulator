//
//  UltraHDRMetadataTests.swift
//  TristimulatorTests
//
//  The "UltraHDR Compatible" export adds Google/Adobe hdrgm XMP to Core Image gain-map
//  JPEGs. Core Image on macOS 27 writes only binary ISO 21496-1 gain-map metadata, so the
//  injector must derive the XMP from it, keep the ISO data, and fix up the MPF index.
//

import Testing
import Foundation
#if canImport(ImageIO) && canImport(CoreImage)
import ImageIO
import CoreImage
#endif
@testable import Tristimulator

// MARK: - Synthetic JPEG builder (marker structure only; no entropy-coded data needed)

private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
private func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * (3 - $0)) & 0xFF) } }
private func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] { [0xFF, marker] + be16(payload.count + 2) + payload }
private let fakeScan: [UInt8] = segment(0xDA, [1, 1, 0, 0, 63, 0]) + [0x12, 0x34, 0xFF, 0x00, 0x56] + [0xFF, 0xD9]

/// ISO 21496-1 gain-map metadata payload (after the URN), non-common-denominator layout.
private func isoPayload(channels: Int = 1, baseHR: (Int, Int) = (0, 1), altHR: (Int, Int) = (3, 1),
                        min: (Int, Int) = (0, 1), max: (Int, Int) = (5, 2), gamma: (Int, Int) = (1, 1),
                        baseOffset: (Int, Int) = (1, 64), altOffset: (Int, Int) = (1, 64),
                        backward: Bool = false) -> [UInt8] {
    var flags: UInt8 = channels == 3 ? 0x80 : 0
    if backward { flags |= 0x04 }
    var p: [UInt8] = be16(0) + be16(0) + [flags]
    p += be32(baseHR.0) + be32(baseHR.1) + be32(altHR.0) + be32(altHR.1)
    for _ in 0..<channels {
        p += be32(min.0) + be32(min.1) + be32(max.0) + be32(max.1) + be32(gamma.0) + be32(gamma.1)
        p += be32(baseOffset.0) + be32(baseOffset.1) + be32(altOffset.0) + be32(altOffset.1)
    }
    return p
}

/// Primary (JFIF, Exif, MPF, ISO version) + gain-map image laid out like Core Image's output.
private func makeGainMapJPEG(gainMapSegments: [[UInt8]]) -> [UInt8] {
    let iso = UltraHDRMetadata.isoIdentifier
    let gainMap = [0xFF, 0xD8] + gainMapSegments.flatMap { $0 } + fakeScan
    func primary(mpfSizes: (Int, Int), mpfOffset: Int) -> [UInt8] {
        // MPF: "MPF\0" + big-endian TIFF header + IFD with B000 version, B001 count, B002 entries.
        var tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A] + be32(8)
        let entriesOffset = 8 + 2 + 3 * 12 + 4
        tiff += be16(3)
        tiff += be16(0xB000) + be16(7) + be32(4) + Array("0100".utf8)
        tiff += be16(0xB001) + be16(4) + be32(1) + be32(2)
        tiff += be16(0xB002) + be16(7) + be32(32) + be32(entriesOffset)
        tiff += be32(0)
        tiff += be32(0x030000) + be32(mpfSizes.0) + be32(0) + be16(0) + be16(0)
        tiff += be32(0) + be32(mpfSizes.1) + be32(mpfOffset) + be16(0) + be16(0)
        return [0xFF, 0xD8]
            + segment(0xE0, Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
            + segment(0xE1, Array("Exif".utf8) + [0, 0] + [0x4D, 0x4D, 0, 0x2A] + be32(8) + be16(0) + be32(0))
            + segment(0xE2, Array("MPF".utf8) + [0] + tiff)
            + segment(0xE2, iso + be16(0) + be16(0))
            + fakeScan
    }
    // Two passes: sizes and the MPF-relative offset depend on the primary's own length.
    let draft = primary(mpfSizes: (0, 0), mpfOffset: 0)
    let tiffStartInDraft = locateMPFTiffStart(draft)
    let final = primary(mpfSizes: (draft.count, gainMap.count), mpfOffset: draft.count - tiffStartInDraft)
    return final + gainMap
}

private func locateMPFTiffStart(_ b: [UInt8]) -> Int {
    let segs = try! UltraHDRMetadata.segments(b, imageStart: 0)
    let s = segs.first { $0.marker == 0xE2 && $0.payloadHasPrefix(b, Array("MPF".utf8) + [0]) }!
    return s.payloadStart + 4
}

private func xmpStrings(_ b: [UInt8], imageStart: Int) -> [String] {
    (try! UltraHDRMetadata.segments(b, imageStart: imageStart))
        .filter { $0.marker == 0xE1 && $0.payloadHasPrefix(b, UltraHDRMetadata.xmpIdentifier) }
        .map { String(decoding: b[($0.payloadStart + UltraHDRMetadata.xmpIdentifier.count)..<$0.end], as: UTF8.self) }
}

private func attr(_ xml: String, _ name: String) -> String? { UltraHDRMetadata.xmpValues(xml, name).first }

@Suite("UltraHDR metadata injection")
@MainActor
struct UltraHDRMetadataTests {

    @Test func isoOnlyInputGetsHdrgmXMP() throws {
        let iso = UltraHDRMetadata.isoIdentifier
        let input = makeGainMapJPEG(gainMapSegments: [segment(0xE2, iso + isoPayload())])
        let r = try UltraHDRMetadata.inject(into: Data(input))
        #expect(r.injected)
        #expect(r.source == .iso21496)
        let out = [UInt8](r.data)

        let mpf = try #require(try UltraHDRMetadata.MPFIndex(
            bytes: out, primarySegments: UltraHDRMetadata.segments(out, imageStart: 0)))
        let gainMapStart = mpf.tiffStart + mpf.offsets[1]
        #expect(out[gainMapStart] == 0xFF && out[gainMapStart + 1] == 0xD8)
        #expect(mpf.sizes[0] == gainMapStart)                       // primary size patched
        #expect(gainMapStart + mpf.sizes[1] == out.count)            // gain-map size patched

        let primaryXMP = try #require(xmpStrings(out, imageStart: 0).first)
        #expect(primaryXMP.contains("Item:Semantic=\"GainMap\""))
        #expect(attr(primaryXMP, "Item:Length") == String(mpf.sizes[1]))

        let gm = try #require(xmpStrings(out, imageStart: gainMapStart).first)
        // ISO and hdrgm are both log2 for min/max/headroom; gamma and offsets are linear.
        #expect(attr(gm, "hdrgm:Version") == "1.0")
        #expect(attr(gm, "hdrgm:BaseRenditionIsHDR") == "False")
        #expect(attr(gm, "hdrgm:GainMapMin") == "0.000000")
        #expect(attr(gm, "hdrgm:GainMapMax") == "2.500000")
        #expect(attr(gm, "hdrgm:Gamma") == "1.000000")
        #expect(attr(gm, "hdrgm:OffsetSDR") == "0.015625")
        #expect(attr(gm, "hdrgm:OffsetHDR") == "0.015625")
        #expect(attr(gm, "hdrgm:HDRCapacityMin") == "0.000000")
        #expect(attr(gm, "hdrgm:HDRCapacityMax") == "3.000000")

        // The ISO metadata is still there, unchanged, in both images.
        let isoCount = out.indices.dropLast(iso.count).filter { out[$0] == iso[0] && Array(out[$0..<($0 + iso.count)]) == iso }.count
        #expect(isoCount == 2)
        #expect(try UltraHDRMetadata.readParams(bytes: out, gainMapSegments: UltraHDRMetadata.segments(out, imageStart: gainMapStart)).0 == r.params)
    }

    @Test func injectionIsIdempotent() throws {
        let input = makeGainMapJPEG(gainMapSegments: [segment(0xE2, UltraHDRMetadata.isoIdentifier + isoPayload())])
        let once = try UltraHDRMetadata.inject(into: Data(input))
        let twice = try UltraHDRMetadata.inject(into: once.data)
        #expect(!twice.injected)
        #expect(twice.data == once.data)
    }

    @Test func differingChannelsAreWrittenAsSequences() throws {
        var p = UltraHDRMetadata.Params(hdrCapacityMin: 0, hdrCapacityMax: 3)
        p.channels = [1.0, 2.0, 3.0].map { .init(gainMapMin: 0, gainMapMax: $0, gamma: 1, offsetSDR: 0, offsetHDR: 0) }
        let xmp = UltraHDRMetadata.gainMapParamsXMP(p)
        #expect(xmp.contains("<hdrgm:GainMapMax><rdf:Seq><rdf:li>1.000000</rdf:li><rdf:li>2.000000</rdf:li><rdf:li>3.000000</rdf:li></rdf:Seq></hdrgm:GainMapMax>"))
        #expect(attr(xmp, "hdrgm:GainMapMin") == "0.000000")
    }

    @Test func parsesCommonDenominatorLayout() throws {
        // flags 0x08: one denominator for every value.
        var p: [UInt8] = be16(0) + be16(0) + [0x08] + be32(1000) + be32(0) + be32(2934)
        p += be32(0) + be32(2441) + be32(1000) + be32(10) + be32(20)
        let params = try UltraHDRMetadata.parseISO21496(p)
        #expect(params.hdrCapacityMax == 2.934)
        #expect(params.channels == [.init(gainMapMin: 0, gainMapMax: 2.441, gamma: 1, offsetSDR: 0.01, offsetHDR: 0.02)])
    }

    @Test func legacyHDRToneMapXMPStillWorks() throws {
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description xmlns:HDRToneMap="http://ns.apple.com/HDRToneMap/1.0/">
        <HDRToneMap:BaseHeadroom>0</HDRToneMap:BaseHeadroom><HDRToneMap:AlternateHeadroom>2.5</HDRToneMap:AlternateHeadroom>
        <HDRToneMap:GainMapMin>0</HDRToneMap:GainMapMin><HDRToneMap:GainMapMax>2</HDRToneMap:GainMapMax>
        <HDRToneMap:Gamma>1</HDRToneMap:Gamma>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let input = makeGainMapJPEG(gainMapSegments: [segment(0xE1, UltraHDRMetadata.xmpIdentifier + Array(xmp.utf8))])
        let r = try UltraHDRMetadata.inject(into: Data(input))
        #expect(r.source == .appleHDRToneMapXMP)
        #expect(r.params.hdrCapacityMax == 2.5)
        #expect(r.params.channels.first?.gainMapMax == 2)
    }

    @Test func failuresAreReportedNotSwallowed() {
        let none = makeGainMapJPEG(gainMapSegments: [segment(0xE2, Array("ICC_PROFILE".utf8) + [0, 1, 1])])
        #expect(throws: UltraHDRMetadata.InjectionError.noGainMapMetadata) { try UltraHDRMetadata.inject(into: Data(none)) }

        let hdrBase = makeGainMapJPEG(gainMapSegments: [segment(0xE2, UltraHDRMetadata.isoIdentifier + isoPayload(backward: true))])
        #expect(throws: UltraHDRMetadata.InjectionError.hdrBaseUnsupported) { try UltraHDRMetadata.inject(into: Data(hdrBase)) }

        #expect(throws: UltraHDRMetadata.InjectionError.notJPEG) { try UltraHDRMetadata.inject(into: Data([0x89, 0x50, 0x4E, 0x47, 0, 0])) }

        let single = [0xFF, 0xD8] + fakeScan
        #expect(throws: UltraHDRMetadata.InjectionError.noGainMapImage) { try UltraHDRMetadata.inject(into: Data(single)) }
    }

    #if canImport(ImageIO) && canImport(CoreImage)
    /// End to end with a real Core Image gain-map JPEG, as the export path makes it.
    @Test func coreImageJPEGStillReadsAsGainMapAfterInjection() throws {
        let extLinear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        // 64×32 linear ramp from 0 to 4× SDR white.
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 64, y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, colorSpace: extLinear)!,
            "inputColor1": CIColor(red: 4, green: 4, blue: 4, colorSpace: extLinear)!,
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        let ctx = CIContext(options: [.workingColorSpace: extLinear])
        let hdrCG = try #require(ctx.createCGImage(gradient, from: gradient.extent, format: .RGBAh, colorSpace: extLinear))
        let hdr = CIImage(cgImage: hdrCG, options: [.contentHeadroom: 4.0])
        let sdr = hdr.applyingFilter("CIToneMapHeadroom", parameters: ["inputSourceHeadroom": 4.0, "inputTargetHeadroom": 1.0])
        let jpeg = try #require(ctx.jpegRepresentation(of: sdr, colorSpace: p3,
                                                       options: [.hdrImage: hdr, .hdrGainMapAsRGB: true]))

        func isoInfo(_ d: Data) -> [String: Any]? {
            guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
            return CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any]
        }
        func alternateHeadroom(_ info: [String: Any]?) -> Double? {
            guard let md = info?[kCGImageAuxiliaryDataInfoMetadata as String] else { return nil }
            let tags = CGImageMetadataCopyTags(md as! CGImageMetadata) as? [CGImageMetadataTag] ?? []
            let tag = tags.first { CGImageMetadataTagCopyName($0) as String? == "AlternateHeadroom" }
            return tag.flatMap { CGImageMetadataTagCopyValue($0) }.flatMap { Double("\($0)") }
        }
        let before = try #require(isoInfo(jpeg), "Core Image should write an ISO gain map")
        let headroomBefore = try #require(alternateHeadroom(before))

        let r = try UltraHDRMetadata.inject(into: jpeg)
        #expect(r.injected)
        let after = try #require(isoInfo(r.data), "ImageIO must still find the ISO gain map")
        #expect(alternateHeadroom(after) == headroomBefore)
        #expect(abs(r.params.hdrCapacityMax - headroomBefore) < 1e-4)

        // Still decodes, and the SDR base is untouched.
        let src = try #require(CGImageSourceCreateWithData(r.data as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(img.width == 64 && img.height == 32)

        let out = [UInt8](r.data)
        let mpf = try #require(try UltraHDRMetadata.MPFIndex(bytes: out, primarySegments: UltraHDRMetadata.segments(out, imageStart: 0)))
        #expect(mpf.tiffStart + mpf.offsets[1] + mpf.sizes[1] == out.count)
        #expect(xmpStrings(out, imageStart: mpf.tiffStart + mpf.offsets[1]).first?.contains("hdrgm:GainMapMax") == true)
    }
    #endif
}
