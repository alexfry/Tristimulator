//
//  ACESAMFParser.swift
//  Tristimulator
//
//  Parses ACES Metadata Files (.amf) — XML sidecar format v2.0.
//  Spec: https://docs.acescentral.com/amf/specification/
//

import Foundation
import simd

// MARK: - Data Model

struct ACESMetadataFile: Equatable {
    let sourceURL: URL
    let uuid: String?
    let description: String?
    let creationDateTime: String?
    let modificationDateTime: String?
    let author: AMFAuthor?
    let clipId: AMFClipId?
    let pipeline: AMFPipeline?
    let archivedPipelines: [AMFPipeline]
}

struct AMFAuthor: Equatable {
    let name: String?
    let emailAddress: String?
}

struct AMFClipId: Equatable {
    let clipName: String?
    /// Sequence pattern string, e.g. "ACES_OT_VWG_SampleFrames.####.exr [1-81]"
    let sequencePattern: String?
    let fileURI: String?
    let uuid: String?
}

struct AMFPipeline: Equatable {
    let uuid: String?
    let systemVersion: String?
    let author: AMFAuthor?
    let inputTransform: AMFInputTransform?
    /// Working colour space for look transforms (ACES 2.0 — may be empty/nil)
    let workingLocation: String?
    let lookTransforms: [AMFLookTransform]
    let outputTransform: AMFOutputTransform?
}

struct AMFInputTransform: Equatable {
    let applied: Bool
    let description: String?
    let transformId: String?
    let hashValue: String?
    let hashAlgorithm: String?
}

struct AMFLookTransform: Equatable {
    let applied: Bool
    let description: String?
    let transformId: String?
    let hashValue: String?
    let hashAlgorithm: String?
    /// Relative path to an external CLF file (e.g. "grade.clf")
    let clfFile: String?
    /// Parsed CLF document when `clfFile` was successfully resolved
    let clf: CLFDocument?
    /// Working space conversion applied around an embedded CDL
    let cdlWorkingSpaceId: String?
    /// CDL embedded directly in the AMF (not via CLF)
    let cdl: AMFCDL?
}

struct AMFCDL: Equatable {
    let slope: SIMD3<Double>
    let offset: SIMD3<Double>
    let power: SIMD3<Double>
    let saturation: Double
}

struct AMFOutputTransform: Equatable {
    let applied: Bool
    let description: String?
    /// Combined RRTODT identifier (ACES 1.x combined, or bare transformId)
    let rrtodtTransformId: String?
    /// Separate RRT transform ID (ACES 1.x split)
    let rrtTransformId: String?
    /// Separate ODT transform ID (ACES 1.x split)
    let odtTransformId: String?
    let hashValue: String?
    let hashAlgorithm: String?
}

// MARK: - Errors

enum AMFParseError: Error, LocalizedError {
    case notAnAMFFile
    case xmlError(Error)
    case missingRootElement

    var errorDescription: String? {
        switch self {
        case .notAnAMFFile:       return "File does not appear to be an ACES Metadata File"
        case .xmlError(let e):    return "XML parse error: \(e.localizedDescription)"
        case .missingRootElement: return "AMF root element not found"
        }
    }
}

// MARK: - Parser

struct ACESAMFParser {

    static func parse(url: URL) throws -> ACESMetadataFile {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw AMFParseError.xmlError(error) }

        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw AMFParseError.xmlError(error)
        }

        guard let root = doc.rootElement(), root.localName == "acesMetadataFile" else {
            throw AMFParseError.notAnAMFFile
        }

        return try parseRoot(root, sourceURL: url)
    }

    // MARK: - Root

    private static func parseRoot(_ root: XMLElement, sourceURL: URL) throws -> ACESMetadataFile {
        let amfInfo = child(root, "amfInfo")
        let dtEl    = child(amfInfo, "dateTime")

        let uuid        = text(child(amfInfo, "uuid"))
        let description = text(child(amfInfo, "description"))
        let creation    = text(child(dtEl, "creationDateTime"))
        let modified    = text(child(dtEl, "modificationDateTime"))
        let author      = amfInfo.flatMap { parseAuthor($0) }
        let clipId      = child(root, "clipId").map { parseClipId($0) }

        let pipelineEl  = child(root, "pipeline")
        let pipeline    = pipelineEl.map { parsePipeline($0, amfURL: sourceURL) }

        let archived = children(root, "archivedPipeline")
            .map { parsePipeline($0, amfURL: sourceURL) }

        return ACESMetadataFile(
            sourceURL: sourceURL,
            uuid: uuid,
            description: description,
            creationDateTime: creation,
            modificationDateTime: modified,
            author: author,
            clipId: clipId,
            pipeline: pipeline,
            archivedPipelines: archived
        )
    }

    // MARK: - Author (can appear in amfInfo or pipelineInfo)

    private static func parseAuthor(_ parent: XMLElement) -> AMFAuthor? {
        guard let authorEl = child(parent, "author") else { return nil }
        return AMFAuthor(
            name: text(child(authorEl, "name")),
            emailAddress: text(child(authorEl, "emailAddress"))
        )
    }

    // MARK: - clipId

    private static func parseClipId(_ el: XMLElement) -> AMFClipId {
        // <sequence min="1" max="81" idx="#">pattern</sequence>
        var sequencePattern: String? = nil
        if let seqEl = child(el, "sequence") {
            var parts: [String] = []
            if let pattern = text(seqEl) { parts.append(pattern) }
            let min = attr(seqEl, "min")
            let max = attr(seqEl, "max")
            if let mn = min, let mx = max { parts.append("[\(mn)-\(mx)]") }
            sequencePattern = parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        return AMFClipId(
            clipName: text(child(el, "clipName")),
            sequencePattern: sequencePattern,
            fileURI: text(child(child(el, "file"), "uri") ?? child(el, "uri")),
            uuid: text(child(el, "uuid"))
        )
    }

    // MARK: - pipeline

    private static func parsePipeline(_ el: XMLElement, amfURL: URL) -> AMFPipeline {
        let info   = child(el, "pipelineInfo")
        let uuid   = text(child(info, "uuid"))
        let sysVer = parseSystemVersion(info)
        let author = info.flatMap { parseAuthor($0) }

        let inputEl  = child(el, "inputTransform")
        let outputEl = child(el, "outputTransform")

        // workingLocation — may be empty element or have content
        let wlEl = child(el, "workingLocation")
        let workingLocation: String? = wlEl.flatMap { text($0) }

        let lookEls = children(el, "lookTransform")

        return AMFPipeline(
            uuid: uuid,
            systemVersion: sysVer,
            author: author,
            inputTransform: inputEl.map { parseInputTransform($0) },
            workingLocation: workingLocation,
            lookTransforms: lookEls.map { parseLookTransform($0, amfURL: amfURL) },
            outputTransform: outputEl.flatMap { parseOutputTransform($0) }
        )
    }

    private static func parseSystemVersion(_ pipelineInfo: XMLElement?) -> String? {
        guard let info = pipelineInfo, let sv = child(info, "systemVersion") else { return nil }
        let major = text(child(sv, "majorVersion")) ?? "0"
        let minor = text(child(sv, "minorVersion")) ?? "0"
        let patch = text(child(sv, "patchVersion")) ?? "0"
        return "\(major).\(minor).\(patch)"
    }

    // MARK: - inputTransform

    private static func parseInputTransform(_ el: XMLElement) -> AMFInputTransform {
        let hashEl = child(el, "hash")
        return AMFInputTransform(
            applied: boolAttr(el, "applied") ?? false,
            description: text(child(el, "description")),
            transformId: text(child(el, "transformId")),
            hashValue: text(hashEl),
            hashAlgorithm: hashEl.flatMap { attr($0, "algorithm") }
        )
    }

    // MARK: - lookTransform

    private static func parseLookTransform(_ el: XMLElement, amfURL: URL) -> AMFLookTransform {
        let applied = boolAttr(el, "applied") ?? false
        let hashEl  = child(el, "hash")

        // CDL working space
        let wsEl   = child(el, "cdlWorkingSpace")
        let fromEl = child(wsEl, "fromCdlWorkingSpace")
        let wsId   = text(child(fromEl, "transformId"))

        // Embedded CDL
        let cdl = parseCDL(from: el)

        // External CLF file reference
        let clfFile = text(child(el, "file"))
        var clf: CLFDocument? = nil
        if let relativePath = clfFile {
            let dir      = amfURL.deletingLastPathComponent()
            let clfURL   = dir.appendingPathComponent(relativePath)
            clf = try? CLFParser.parse(url: clfURL)
        }

        return AMFLookTransform(
            applied: applied,
            description: text(child(el, "description")),
            transformId: text(child(el, "transformId")),
            hashValue: text(hashEl),
            hashAlgorithm: hashEl.flatMap { attr($0, "algorithm") },
            clfFile: clfFile,
            clf: clf,
            cdlWorkingSpaceId: wsId,
            cdl: cdl
        )
    }

    private static func parseCDL(from el: XMLElement) -> AMFCDL? {
        let sopEl = child(el, "SOPNode")
        let satEl = child(el, "SatNode")
        guard sopEl != nil || satEl != nil else { return nil }
        let slope  = parseTriple(text(child(sopEl, "Slope")))  ?? SIMD3(1, 1, 1)
        let offset = parseTriple(text(child(sopEl, "Offset"))) ?? SIMD3(0, 0, 0)
        let power  = parseTriple(text(child(sopEl, "Power")))  ?? SIMD3(1, 1, 1)
        let sat    = Double(text(child(satEl, "Saturation")) ?? "1") ?? 1.0
        return AMFCDL(slope: slope, offset: offset, power: power, saturation: sat)
    }

    // MARK: - outputTransform

    private static func parseOutputTransform(_ el: XMLElement) -> AMFOutputTransform? {
        let applied   = boolAttr(el, "applied") ?? false
        let hashEl    = child(el, "hash")

        // ACES 2.0 combined: bare <transformId> directly on outputTransform
        // ACES 2.0 combined RRTODT element
        let rrtodtEl  = child(el, "referenceRenderingTransformOutputDeviceTransform")
                     ?? child(el, "rrtodt")

        // ACES 1.x split: separate RRT + ODT children
        let rrtEl     = child(el, "referenceRenderingTransform")
        let odtEl     = child(el, "outputDeviceTransform")

        // Bare transformId on the outputTransform itself (most common in ACES 2.0)
        let bareId    = text(child(el, "transformId"))

        let hasContent = rrtodtEl != nil || rrtEl != nil || odtEl != nil || bareId != nil
        guard hasContent else { return nil }

        return AMFOutputTransform(
            applied: applied,
            description: text(child(el, "description")),
            rrtodtTransformId: rrtodtEl.flatMap { text(child($0, "transformId")) } ?? bareId,
            rrtTransformId: rrtEl.flatMap { text(child($0, "transformId")) },
            odtTransformId: odtEl.flatMap { text(child($0, "transformId")) },
            hashValue: text(hashEl),
            hashAlgorithm: hashEl.flatMap { attr($0, "algorithm") }
        )
    }

    // MARK: - XML helpers

    private static func children(_ element: XMLElement?, _ localName: String) -> [XMLElement] {
        guard let element else { return [] }
        return element.children?.compactMap { $0 as? XMLElement }.filter { $0.localName == localName } ?? []
    }

    private static func child(_ element: XMLElement?, _ localName: String) -> XMLElement? {
        children(element, localName).first
    }

    private static func text(_ element: XMLElement?) -> String? {
        guard let s = element?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    private static func attr(_ element: XMLElement, _ name: String) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    private static func boolAttr(_ element: XMLElement, _ name: String) -> Bool? {
        attr(element, name).map { $0.lowercased() == "true" }
    }

    private static func parseTriple(_ s: String?) -> SIMD3<Double>? {
        guard let s else { return nil }
        let parts = s.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return SIMD3(parts[0], parts[1], parts[2])
    }
}
