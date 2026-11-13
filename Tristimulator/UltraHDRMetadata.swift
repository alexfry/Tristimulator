//
//  UltraHDRMetadata.swift
//  Tristimulator
//
//  Adds Google Ultra HDR / Adobe gain-map ("hdrgm") XMP to a gain-map JPEG written by
//  Core Image, so Android and older Chrome builds that only read the XMP form see the
//  gain map. The ISO 21496-1 metadata Core Image wrote is left in place, so Apple
//  platforms, Safari and current Chrome keep reading it.
//
//  Core Image on macOS 27 writes the gain-map parameters only as binary ISO 21496-1
//  (an APP2 segment starting "urn:iso:std:iso:ts:21496:-1" in the gain-map image).
//  This reads that binary form first and falls back to Apple's HDRToneMap XMP.
//
//  Units: gain map min/max and HDR headrooms/capacities are log2 in both ISO 21496-1
//  and hdrgm; gamma and offsets are linear in both, so values copy across unchanged.
//
//  Foundation only, so it can be unit-tested without ImageIO.
//

import Foundation

// Pure data processing: nonisolated so it runs off the main actor and in tests.
nonisolated enum UltraHDRMetadata {

    nonisolated struct Channel: Equatable {
        var gainMapMin: Double    // log2
        var gainMapMax: Double    // log2
        var gamma: Double         // linear
        var offsetSDR: Double     // linear (ISO base offset when the base is SDR)
        var offsetHDR: Double     // linear (ISO alternate offset)
    }

    nonisolated struct Params: Equatable {
        var baseRenditionIsHDR = false
        var hdrCapacityMin: Double = 0   // log2 (ISO baseHdrHeadroom)
        var hdrCapacityMax: Double = 0   // log2 (ISO alternateHdrHeadroom)
        var channels: [Channel] = []     // 1 or 3
    }

    nonisolated enum Source: String { case iso21496 = "ISO 21496-1", appleHDRToneMapXMP = "HDRToneMap XMP" }

    nonisolated enum InjectionError: Error, Equatable, CustomStringConvertible {
        case notJPEG
        case noGainMapImage
        case noGainMapMetadata
        case malformedISOMetadata(String)
        case unsupportedISOVersion(Int)
        case hdrBaseUnsupported
        case malformedMPF(String)
        case segmentTooLarge

        var description: String {
            switch self {
            case .notJPEG: return "the data isn't a JPEG"
            case .noGainMapImage: return "the JPEG has no gain-map image"
            case .noGainMapMetadata: return "the gain-map image has neither ISO 21496-1 nor HDRToneMap metadata"
            case .malformedISOMetadata(let why): return "the ISO 21496-1 metadata is malformed (\(why))"
            case .unsupportedISOVersion(let v): return "ISO 21496-1 minimum version \(v) isn't supported"
            case .hdrBaseUnsupported: return "the base image is HDR, which Ultra HDR JPEG doesn't support"
            case .malformedMPF(let why): return "the MPF index is malformed (\(why))"
            case .segmentTooLarge: return "the XMP doesn't fit in a JPEG segment"
            }
        }
    }

    nonisolated struct InjectionResult {
        var data: Data
        var params: Params
        var source: Source
        /// False when the file already had hdrgm XMP and was returned unchanged.
        var injected: Bool
    }

    static let isoIdentifier = Array("urn:iso:std:iso:ts:21496:-1".utf8) + [0]
    static let xmpIdentifier = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]
    static let hdrgmNamespace = "http://ns.adobe.com/hdr-gain-map/1.0/"

    // MARK: - Entry point

    static func inject(into jpeg: Data) throws -> InjectionResult {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw InjectionError.notJPEG }

        let primarySegments = try segments(bytes, imageStart: 0)
        let mpf = try MPFIndex(bytes: bytes, primarySegments: primarySegments)
        let gainMapStart = try mpf?.secondaryStart() ?? scanForSecondaryImage(bytes)
        guard let gainMapStart, gainMapStart + 4 <= bytes.count,
              bytes[gainMapStart] == 0xFF, bytes[gainMapStart + 1] == 0xD8 else {
            throw InjectionError.noGainMapImage
        }
        let gainMapSegments = try segments(bytes, imageStart: gainMapStart)

        let (params, source) = try readParams(bytes: bytes, gainMapSegments: gainMapSegments)

        if hasHdrgmXMP(bytes, primarySegments) {
            return InjectionResult(data: jpeg, params: params, source: source, injected: false)
        }

        // Gain-map image: hdrgm parameters right after its SOI.
        let gainMapXMP = try xmpSegment(gainMapParamsXMP(params))
        let gainMapEnd = mpf?.secondaryEnd(fileLength: bytes.count) ?? bytes.count
        let newGainMapLength = (gainMapEnd - gainMapStart) + gainMapXMP.count

        // Primary image: Container directory right after APP0/APP1 Exif, before MPF, so the
        // MPF offsets (relative to the MPF header) keep pointing at the gain map.
        let containerXMP = try xmpSegment(containerDirectoryXMP(gainMapLength: newGainMapLength))
        let insertAt = primaryInsertionOffset(bytes, primarySegments)
        if let mpf, insertAt > mpf.segmentOffset {
            throw InjectionError.malformedMPF("MPF comes before Exif")
        }

        var out = [UInt8]()
        out.reserveCapacity(bytes.count + containerXMP.count + gainMapXMP.count)
        out += bytes[0..<insertAt]
        out += containerXMP
        out += bytes[insertAt..<(gainMapStart + 2)]
        out += gainMapXMP
        out += bytes[(gainMapStart + 2)...]

        if let mpf {
            // Primary grew by containerXMP; gain map grew by gainMapXMP; anything stored
            // after the gain map moved by gainMapXMP.
            try mpf.patch(&out, shift: containerXMP.count,
                          primaryGrowth: containerXMP.count,
                          gainMapGrowth: gainMapXMP.count)
        }
        return InjectionResult(data: Data(out), params: params, source: source, injected: true)
    }

    // MARK: - Reading parameters

    static func readParams(bytes: [UInt8], gainMapSegments: [Segment]) throws -> (Params, Source) {
        for s in gainMapSegments where s.marker == 0xE2 && s.payloadHasPrefix(bytes, isoIdentifier) {
            let payload = Array(bytes[(s.payloadStart + isoIdentifier.count)..<s.end])
            if payload.count > 4 {   // the primary image carries a 4-byte version-only record
                return (try parseISO21496(payload), .iso21496)
            }
        }
        for s in gainMapSegments where s.marker == 0xE1 && s.payloadHasPrefix(bytes, xmpIdentifier) {
            let xmp = String(decoding: bytes[(s.payloadStart + xmpIdentifier.count)..<s.end], as: UTF8.self)
            if let p = parseHDRToneMapXMP(xmp) {
                if p.baseRenditionIsHDR { throw InjectionError.hdrBaseUnsupported }
                return (p, .appleHDRToneMapXMP)
            }
        }
        throw InjectionError.noGainMapMetadata
    }

    /// Parses the ISO 21496-1 binary gain-map metadata (after the URN identifier).
    /// Layout as in libultrahdr's decodeGainmapMetadata: big-endian rationals.
    static func parseISO21496(_ b: [UInt8]) throws -> Params {
        var r = Reader(b)
        let minVersion = try r.u16()
        guard minVersion == 0 else { throw InjectionError.unsupportedISOVersion(Int(minVersion)) }
        _ = try r.u16()                       // writer version
        let flags = try r.u8()
        let channelCount = (flags & 0x80) != 0 ? 3 : 1
        let backward = (flags & 0x04) != 0    // base rendition is HDR
        let common = (flags & 0x08) != 0

        func frac(_ n: Int64, _ d: UInt32, _ what: String) throws -> Double {
            guard d != 0 else { throw InjectionError.malformedISOMetadata("\(what) denominator is 0") }
            return Double(n) / Double(d)
        }

        var p = Params()
        if common {
            let d = try r.u32()
            p.hdrCapacityMin = try frac(Int64(try r.u32()), d, "base headroom")
            p.hdrCapacityMax = try frac(Int64(try r.u32()), d, "alternate headroom")
            for _ in 0..<channelCount {
                p.channels.append(Channel(
                    gainMapMin: try frac(Int64(try r.s32()), d, "gain map min"),
                    gainMapMax: try frac(Int64(try r.s32()), d, "gain map max"),
                    gamma: try frac(Int64(try r.u32()), d, "gamma"),
                    offsetSDR: try frac(Int64(try r.s32()), d, "base offset"),
                    offsetHDR: try frac(Int64(try r.s32()), d, "alternate offset")))
            }
        } else {
            p.hdrCapacityMin = try frac(Int64(try r.u32()), try r.u32(), "base headroom")
            p.hdrCapacityMax = try frac(Int64(try r.u32()), try r.u32(), "alternate headroom")
            for _ in 0..<channelCount {
                p.channels.append(Channel(
                    gainMapMin: try frac(Int64(try r.s32()), try r.u32(), "gain map min"),
                    gainMapMax: try frac(Int64(try r.s32()), try r.u32(), "gain map max"),
                    gamma: try frac(Int64(try r.u32()), try r.u32(), "gamma"),
                    offsetSDR: try frac(Int64(try r.s32()), try r.u32(), "base offset"),
                    offsetHDR: try frac(Int64(try r.s32()), try r.u32(), "alternate offset")))
            }
        }
        if backward { throw InjectionError.hdrBaseUnsupported }
        for c in p.channels where c.gainMapMax < c.gainMapMin || c.gamma <= 0 {
            throw InjectionError.malformedISOMetadata("gain map max < min or gamma ≤ 0")
        }
        guard p.hdrCapacityMax > p.hdrCapacityMin else {
            throw InjectionError.malformedISOMetadata("alternate headroom ≤ base headroom")
        }
        return p
    }

    /// Apple's HDRToneMap XMP (written by earlier Core Image versions), element or attribute form.
    static func parseHDRToneMapXMP(_ xmp: String) -> Params? {
        func all(_ name: String) -> [Double] { xmpValues(xmp, "HDRToneMap:" + name).compactMap(Double.init) }
        let mins = all("GainMapMin")
        guard !mins.isEmpty else { return nil }
        let maxs = all("GainMapMax"), gammas = all("Gamma")
        let baseOffsets = all("BaseOffset") + all("OffsetSDR")
        let altOffsets = all("AlternateOffset") + all("OffsetHDR")
        var p = Params()
        let isHDR = xmpValues(xmp, "HDRToneMap:BaseRenditionIsHDR").first.map { ["1", "true"].contains($0.lowercased()) }
        p.baseRenditionIsHDR = isHDR ?? false
        p.hdrCapacityMin = all("BaseHeadroom").first ?? 0
        p.hdrCapacityMax = all("AlternateHeadroom").first ?? 0
        func at(_ a: [Double], _ i: Int, _ def: Double) -> Double { i < a.count ? a[i] : (a.first ?? def) }
        for i in 0..<mins.count {
            p.channels.append(Channel(gainMapMin: mins[i], gainMapMax: at(maxs, i, 0), gamma: at(gammas, i, 1),
                                      offsetSDR: at(baseOffsets, i, 1.0 / 64), offsetHDR: at(altOffsets, i, 1.0 / 64)))
        }
        return p
    }

    /// Values for `name` written either as `<name>v</name>` or `name="v"`.
    static func xmpValues(_ xml: String, _ name: String) -> [String] {
        var out: [String] = []
        var from = xml.startIndex
        while let s = xml.range(of: "<\(name)>", range: from..<xml.endIndex),
              let e = xml.range(of: "</\(name)>", range: s.upperBound..<xml.endIndex) {
            out.append(xml[s.upperBound..<e.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
            from = e.upperBound
        }
        from = xml.startIndex
        while let s = xml.range(of: "\(name)=\"", range: from..<xml.endIndex),
              let e = xml.range(of: "\"", range: s.upperBound..<xml.endIndex) {
            out.append(String(xml[s.upperBound..<e.lowerBound]))
            from = e.upperBound
        }
        return out
    }

    // MARK: - Writing XMP

    static func format(_ v: Double) -> String { String(format: "%.6f", v) }

    static func gainMapParamsXMP(_ p: Params) -> String {
        let ch = p.channels
        // One value when the channels agree (what libultrahdr reads); an rdf:Seq of three
        // per the Adobe gain map spec otherwise.
        func field(_ name: String, _ kp: KeyPath<Channel, Double>) -> (attr: String, elem: String) {
            let vals = ch.map { $0[keyPath: kp] }
            if vals.allSatisfy({ $0 == vals[0] }) { return ("\n   hdrgm:\(name)=\"\(format(vals[0]))\"", "") }
            let lis = vals.map { "<rdf:li>\(format($0))</rdf:li>" }.joined()
            return ("", "\n   <hdrgm:\(name)><rdf:Seq>\(lis)</rdf:Seq></hdrgm:\(name)>")
        }
        let fields = [field("GainMapMin", \.gainMapMin), field("GainMapMax", \.gainMapMax),
                      field("Gamma", \.gamma), field("OffsetSDR", \.offsetSDR), field("OffsetHDR", \.offsetHDR)]
        let attrs = fields.map(\.attr).joined(), elems = fields.map(\.elem).joined()
        let close = elems.isEmpty ? "/>" : ">\(elems)\n  </rdf:Description>"
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:hdrgm="\(hdrgmNamespace)"
           hdrgm:Version="1.0"
           hdrgm:BaseRenditionIsHDR="\(p.baseRenditionIsHDR ? "True" : "False")"\(attrs)
           hdrgm:HDRCapacityMin="\(format(p.hdrCapacityMin))"
           hdrgm:HDRCapacityMax="\(format(p.hdrCapacityMax))"\(close)
         </rdf:RDF>
        </x:xmpmeta>
        """
    }

    static func containerDirectoryXMP(gainMapLength: Int) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:hdrgm="\(hdrgmNamespace)"
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

    static func xmpSegment(_ xmp: String) throws -> [UInt8] {
        let payload = xmpIdentifier + Array(xmp.utf8)
        let length = payload.count + 2
        guard length <= 0xFFFF else { throw InjectionError.segmentTooLarge }
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }

    // MARK: - JPEG structure

    nonisolated struct Segment {
        var offset: Int        // of the 0xFF marker byte
        var marker: UInt8
        var payloadStart: Int  // after the 2-byte length
        var end: Int           // one past the segment
        func payloadHasPrefix(_ b: [UInt8], _ p: [UInt8]) -> Bool {
            payloadStart + p.count <= end && Array(b[payloadStart..<(payloadStart + p.count)]) == p
        }
    }

    /// Marker segments of the image starting at `imageStart`, up to (not including) SOS.
    static func segments(_ b: [UInt8], imageStart: Int) throws -> [Segment] {
        var out: [Segment] = []
        var o = imageStart + 2
        while o + 4 <= b.count {
            guard b[o] == 0xFF else { throw InjectionError.notJPEG }
            let m = b[o + 1]
            if m == 0xFF { o += 1; continue }                        // fill byte
            if m == 0xDA || m == 0xD9 { break }
            let len = Int(b[o + 2]) << 8 | Int(b[o + 3])
            guard len >= 2, o + 2 + len <= b.count else { throw InjectionError.notJPEG }
            out.append(Segment(offset: o, marker: m, payloadStart: o + 4, end: o + 2 + len))
            o += 2 + len
        }
        return out
    }

    static func scanForSecondaryImage(_ b: [UInt8]) -> Int? {
        guard b.count > 6 else { return nil }
        for i in 2..<(b.count - 3) where b[i] == 0xFF && b[i + 1] == 0xD9 && b[i + 2] == 0xFF && b[i + 3] == 0xD8 {
            return i + 2
        }
        return nil
    }

    static func hasHdrgmXMP(_ b: [UInt8], _ segs: [Segment]) -> Bool {
        segs.contains { s in
            s.marker == 0xE1 && s.payloadHasPrefix(b, xmpIdentifier)
                && String(decoding: b[s.payloadStart..<s.end], as: UTF8.self).contains(hdrgmNamespace)
        }
    }

    /// After APP0 (JFIF) and APP1 Exif in the primary image, else right after SOI.
    static func primaryInsertionOffset(_ b: [UInt8], _ segs: [Segment]) -> Int {
        var at = 2
        for s in segs {
            let isExif = s.marker == 0xE1 && s.payloadHasPrefix(b, Array("Exif".utf8) + [0, 0])
            if s.marker == 0xE0 || isExif { at = s.end } else { break }
        }
        return at
    }

    // MARK: - MPF (CIPA DC-007)

    nonisolated struct MPFIndex {
        var segmentOffset: Int
        var tiffStart: Int                 // offsets in the MP entries are relative to this
        var bigEndian: Bool
        var entriesStart: Int              // absolute offset of the first 16-byte MP entry
        var count: Int
        var sizes: [Int]
        var offsets: [Int]                 // 0 for the first image

        init?(bytes b: [UInt8], primarySegments: [Segment]) throws {
            guard let s = primarySegments.first(where: {
                $0.marker == 0xE2 && $0.payloadHasPrefix(b, Array("MPF".utf8) + [0])
            }) else { return nil }
            segmentOffset = s.offset
            tiffStart = s.payloadStart + 4
            guard tiffStart + 8 <= s.end else { throw InjectionError.malformedMPF("short header") }
            switch (b[tiffStart], b[tiffStart + 1]) {
            case (0x4D, 0x4D): bigEndian = true
            case (0x49, 0x49): bigEndian = false
            default: throw InjectionError.malformedMPF("bad byte order")
            }
            let be = bigEndian
            func u16(_ o: Int) -> Int { be ? Int(b[o]) << 8 | Int(b[o + 1]) : Int(b[o + 1]) << 8 | Int(b[o]) }
            func u32(_ o: Int) -> Int {
                let v = (0..<4).map { Int(b[o + $0]) }
                return be ? v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3] : v[3] << 24 | v[2] << 16 | v[1] << 8 | v[0]
            }
            let ifd = tiffStart + u32(tiffStart + 4)
            guard ifd + 2 <= s.end else { throw InjectionError.malformedMPF("IFD out of range") }
            var entries: Int?, count = 0
            for i in 0..<u16(ifd) {
                let e = ifd + 2 + 12 * i
                guard e + 12 <= s.end else { throw InjectionError.malformedMPF("IFD entry out of range") }
                if u16(e) == 0xB002 { count = u32(e + 4) / 16; entries = tiffStart + u32(e + 8) }
            }
            guard let entries, count >= 2, entries + 16 * count <= s.end else {
                throw InjectionError.malformedMPF("no MP entry list for two images")
            }
            self.entriesStart = entries
            self.count = count
            sizes = (0..<count).map { u32(entries + 16 * $0 + 4) }
            offsets = (0..<count).map { u32(entries + 16 * $0 + 8) }
        }

        func secondaryStart() throws -> Int? {
            let start = tiffStart + offsets[1]
            return offsets[1] > 0 ? start : nil
        }
        func secondaryEnd(fileLength: Int) -> Int { min(tiffStart + offsets[1] + sizes[1], fileLength) }

        /// Rewrites the MP entry sizes/offsets in `out`, whose MPF segment moved by `shift`.
        func patch(_ out: inout [UInt8], shift: Int, primaryGrowth: Int, gainMapGrowth: Int) throws {
            let base = entriesStart + shift
            func put(_ o: Int, _ v: Int) throws {
                guard v >= 0, v <= Int(UInt32.max) else { throw InjectionError.malformedMPF("value out of range") }
                let bytes = (0..<4).map { UInt8((v >> (8 * (3 - $0))) & 0xFF) }
                for i in 0..<4 { out[o + i] = bigEndian ? bytes[i] : bytes[3 - i] }
            }
            try put(base + 4, sizes[0] + primaryGrowth)
            try put(base + 16 + 4, sizes[1] + gainMapGrowth)
            for i in 2..<max(count, 2) where offsets[i] > offsets[1] {
                try put(base + 16 * i + 8, offsets[i] + gainMapGrowth)
            }
        }
    }

    // MARK: - Big-endian reader

    nonisolated struct Reader {
        let b: [UInt8]; var pos = 0
        init(_ b: [UInt8]) { self.b = b }
        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard pos + n <= b.count else { throw InjectionError.malformedISOMetadata("truncated") }
            defer { pos += n }
            return b[pos..<(pos + n)]
        }
        mutating func u8() throws -> UInt8 { try take(1).first! }
        mutating func u16() throws -> UInt16 { try take(2).reduce(0) { $0 << 8 | UInt16($1) } }
        mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func s32() throws -> Int32 { Int32(bitPattern: try u32()) }
    }
}
