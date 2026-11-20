//
//  CLFParser.swift
//  Tristimulator
//
//  Parses Common LUT Format (.clf) files — Academy S-2014-006 / CLF v3.
//  Handles all standard process operators for display purposes.
//  Large LUT data arrays are summarised (size only) rather than stored.
//

import Foundation
import simd

// MARK: - Data Model

struct CLFDocument: Equatable {
    let sourceURL: URL
    let id: String?
    let name: String?
    let clfVersion: String?
    let inverseOf: String?
    let descriptions: [String]
    let inputDescriptors: [String]
    let outputDescriptors: [String]
    let operators: [CLFOperator]
}

// MARK: Operators

enum CLFOperator: Equatable {
    case cdl(CLFCDLOp)
    case lut1d(CLFLUTOp)
    case lut3d(CLFLUTOp)
    case matrix(CLFMatrixOp)
    case log(CLFLogOp)
    case exponent(CLFExponentOp)
    case range(CLFRangeOp)
    case reference(CLFReferenceOp)
    case unknown(name: String, id: String?, description: String?)

    var id: String? {
        switch self {
        case .cdl(let o):        return o.id
        case .lut1d(let o):      return o.id
        case .lut3d(let o):      return o.id
        case .matrix(let o):     return o.id
        case .log(let o):        return o.id
        case .exponent(let o):   return o.id
        case .range(let o):      return o.id
        case .reference(let o):  return o.id
        case .unknown(_, let i, _): return i
        }
    }

    var description: String? {
        switch self {
        case .cdl(let o):        return o.description
        case .lut1d(let o):      return o.description
        case .lut3d(let o):      return o.description
        case .matrix(let o):     return o.description
        case .log(let o):        return o.description
        case .exponent(let o):   return o.description
        case .range(let o):      return o.description
        case .reference(let o):  return o.description
        case .unknown(_, _, let d): return d
        }
    }

    /// Short human-readable operator type label
    var typeName: String {
        switch self {
        case .cdl:       return "CDL"
        case .lut1d:     return "LUT 1D"
        case .lut3d:     return "LUT 3D"
        case .matrix:    return "Matrix"
        case .log:       return "Log"
        case .exponent:  return "Exponent"
        case .range:     return "Range"
        case .reference: return "Reference"
        case .unknown(let n, _, _): return n
        }
    }
}

struct CLFCDLOp: Equatable {
    let id: String?
    let description: String?
    let style: String?       // "Fwd", "Rev", "FwdNoClamp", "RevNoClamp"
    let inBitDepth: String?
    let outBitDepth: String?
    let slope: SIMD3<Double>
    let offset: SIMD3<Double>
    let power: SIMD3<Double>
    let saturation: Double
}

struct CLFLUTOp: Equatable {
    let id: String?
    let description: String?
    let inBitDepth: String?
    let outBitDepth: String?
    let interpolation: String?
    let dimensions: Int          // 1 or 3
    /// Number of entries per channel (1D) or entries per axis (3D)
    let size: Int?
    /// For 3D: separate sizes per axis when non-uniform
    let size3: SIMD3<Int>?
    let halfDomain: Bool
    let rawHalfs: Bool
}

struct CLFMatrixOp: Equatable {
    let id: String?
    let description: String?
    let inBitDepth: String?
    let outBitDepth: String?
    /// Row-major values; 3×3 or 3×4 or 4×4
    let values: [Double]
    let dim: (rows: Int, cols: Int)

    static func == (lhs: CLFMatrixOp, rhs: CLFMatrixOp) -> Bool {
        lhs.id == rhs.id &&
        lhs.description == rhs.description &&
        lhs.inBitDepth == rhs.inBitDepth &&
        lhs.outBitDepth == rhs.outBitDepth &&
        lhs.values == rhs.values &&
        lhs.dim.rows == rhs.dim.rows &&
        lhs.dim.cols == rhs.dim.cols
    }
}

struct CLFLogOp: Equatable {
    let id: String?
    let description: String?
    let style: String?       // "log2", "antiLog2", "log10", "antiLog10", "linToLog", "logToLin", "cameraLinToLog", "cameraLogToLin"
    let inBitDepth: String?
    let outBitDepth: String?
    /// Per-channel log params (R, G, B or a single set applied to all)
    let params: [CLFLogParams]
}

struct CLFLogParams: Equatable {
    let channel: String?         // "R", "G", "B" or nil = all channels
    let base: Double?
    let logSideSlope: Double?
    let logSideOffset: Double?
    let linSideSlope: Double?
    let linSideOffset: Double?
    let linearSlope: Double?
    let linBreak: Double?
    let logBreak: Double?
}

struct CLFExponentOp: Equatable {
    let id: String?
    let description: String?
    let style: String?   // "basicFwd", "basicRev", "basicMirrorFwd", "basicMirrorRev",
                         // "basicPassThruFwd", "basicPassThruRev",
                         // "moncurveFwd", "moncurveRev", "moncurveMirrorFwd", "moncurveMirrorRev"
    let inBitDepth: String?
    let outBitDepth: String?
    let params: [CLFExponentParams]
}

struct CLFExponentParams: Equatable {
    let channel: String?
    let exponent: Double?
    let offset: Double?
    let gamma: Double?
    let offset2: Double?  // "offset" for moncurve — distinct from linearOffset
    let linearSlope: Double?
}

struct CLFRangeOp: Equatable {
    let id: String?
    let description: String?
    let style: String?    // "noClamp" or nil (clamp)
    let inBitDepth: String?
    let outBitDepth: String?
    let minInValue: Double?
    let maxInValue: Double?
    let minOutValue: Double?
    let maxOutValue: Double?
}

struct CLFReferenceOp: Equatable {
    let id: String?
    let description: String?
    let style: String?    // "Fwd" or "Rev"
    let path: String?
    let aliases: [String]
}

// MARK: - Errors

enum CLFParseError: Error, LocalizedError {
    case notACLFFile
    case xmlError(Error)

    var errorDescription: String? {
        switch self {
        case .notACLFFile:     return "File does not appear to be a CLF ProcessList"
        case .xmlError(let e): return "XML parse error: \(e.localizedDescription)"
        }
    }
}

// MARK: - Parser

struct CLFParser {

    static func parse(url: URL) throws -> CLFDocument {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw CLFParseError.xmlError(error) }

        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw CLFParseError.xmlError(error)
        }

        guard let root = doc.rootElement(), root.localName == "ProcessList" else {
            throw CLFParseError.notACLFFile
        }

        return parseProcessList(root, url: url)
    }

    // MARK: - ProcessList

    private static func parseProcessList(_ root: XMLElement, url: URL) -> CLFDocument {
        let id         = attr(root, "id")
        let name       = attr(root, "name")
        let clfVersion = attr(root, "compCLFversion") ?? attr(root, "version")
        let inverseOf  = attr(root, "inverseOf")

        let descriptions     = strings(root, "Description")
        let inputDescriptors = strings(root, "InputDescriptor")
        let outputDescriptors = strings(root, "OutputDescriptor")

        // Collect all child elements that are process operators.
        // We skip Description / InputDescriptor / OutputDescriptor / Info.
        let nonMetaNames: Set<String> = ["Description", "InputDescriptor",
                                          "OutputDescriptor", "Info"]
        let opElements = (root.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { !nonMetaNames.contains($0.localName ?? "") }

        let operators = opElements.compactMap { parseOperator($0) }

        return CLFDocument(
            sourceURL: url,
            id: id,
            name: name,
            clfVersion: clfVersion,
            inverseOf: inverseOf,
            descriptions: descriptions,
            inputDescriptors: inputDescriptors,
            outputDescriptors: outputDescriptors,
            operators: operators
        )
    }

    // MARK: - Operator dispatch

    private static func parseOperator(_ el: XMLElement) -> CLFOperator? {
        switch el.localName {
        case "CDLTransform", "ASC_CDL":
            return parseCDL(el).map { .cdl($0) }
        case "LUT1D":
            return parseLUT(el, dimensions: 1).map { .lut1d($0) }
        case "LUT3D":
            return parseLUT(el, dimensions: 3).map { .lut3d($0) }
        case "Matrix":
            return parseMatrix(el).map { .matrix($0) }
        case "Log":
            return parseLog(el).map { .log($0) }
        case "Exponent":
            return parseExponent(el).map { .exponent($0) }
        case "Range":
            return parseRange(el).map { .range($0) }
        case "Reference":
            return parseReference(el).map { .reference($0) }
        case nil:
            return nil
        default:
            return .unknown(
                name: el.localName ?? "?",
                id: attr(el, "id"),
                description: string(el, "Description")
            )
        }
    }

    // MARK: - CDL

    private static func parseCDL(_ el: XMLElement) -> CLFCDLOp? {
        let sopEl = child(el, "SOPNode")
        let satEl = child(el, "SatNode")

        let slope  = parseTriple(string(sopEl, "Slope"))  ?? SIMD3(1, 1, 1)
        let offset = parseTriple(string(sopEl, "Offset")) ?? SIMD3(0, 0, 0)
        let power  = parseTriple(string(sopEl, "Power"))  ?? SIMD3(1, 1, 1)
        let sat    = Double(string(satEl, "Saturation") ?? "1") ?? 1.0

        return CLFCDLOp(
            id: attr(el, "id"),
            description: string(el, "Description"),
            style: attr(el, "style"),
            inBitDepth: attr(el, "inBitDepth"),
            outBitDepth: attr(el, "outBitDepth"),
            slope: slope, offset: offset, power: power, saturation: sat
        )
    }

    // MARK: - LUT 1D / 3D

    private static func parseLUT(_ el: XMLElement, dimensions: Int) -> CLFLUTOp? {
        let arrayEl = child(el, "Array")
        var size: Int?    = nil
        var size3: SIMD3<Int>? = nil

        if let dimStr = attr(arrayEl, "dim") {
            let parts = dimStr.split(separator: " ").compactMap { Int($0) }
            if dimensions == 1 {
                size = parts.first
            } else if dimensions == 3 {
                if parts.count >= 3 {
                    size3 = SIMD3(parts[0], parts[1], parts[2])
                    size = parts[0]
                } else if parts.count == 1 {
                    size = parts[0]
                    size3 = SIMD3(parts[0], parts[0], parts[0])
                }
            }
        }

        return CLFLUTOp(
            id: attr(el, "id"),
            description: string(el, "Description"),
            inBitDepth: attr(el, "inBitDepth"),
            outBitDepth: attr(el, "outBitDepth"),
            interpolation: attr(el, "interpolation"),
            dimensions: dimensions,
            size: size,
            size3: size3,
            halfDomain: attr(el, "halfDomain") == "true",
            rawHalfs: attr(el, "rawHalfs") == "true"
        )
    }

    // MARK: - Matrix

    private static func parseMatrix(_ el: XMLElement) -> CLFMatrixOp? {
        let arrayEl = child(el, "Array")
        let dimStr  = attr(arrayEl, "dim") ?? ""
        let dimParts = dimStr.split(separator: " ").compactMap { Int($0) }
        let rows = dimParts.first  ?? 3
        let cols = dimParts.count > 1 ? dimParts[1] : 3

        let rawText = arrayEl?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let values = rawText
            .split(whereSeparator: { $0.isWhitespace || $0 == "\n" })
            .compactMap { Double($0) }

        return CLFMatrixOp(
            id: attr(el, "id"),
            description: string(el, "Description"),
            inBitDepth: attr(el, "inBitDepth"),
            outBitDepth: attr(el, "outBitDepth"),
            values: values,
            dim: (rows: rows, cols: cols)
        )
    }

    // MARK: - Log

    private static func parseLog(_ el: XMLElement) -> CLFLogOp? {
        let paramEls = el.children?.compactMap { $0 as? XMLElement }.filter { $0.localName == "LogParams" } ?? []

        let params: [CLFLogParams] = paramEls.map { p in
            CLFLogParams(
                channel: attr(p, "channel"),
                base: doubleAttr(p, "base"),
                logSideSlope: doubleAttr(p, "logSideSlope"),
                logSideOffset: doubleAttr(p, "logSideOffset"),
                linSideSlope: doubleAttr(p, "linSideSlope"),
                linSideOffset: doubleAttr(p, "linSideOffset"),
                linearSlope: doubleAttr(p, "linearSlope"),
                linBreak: doubleAttr(p, "linBreak"),
                logBreak: doubleAttr(p, "logBreak")
            )
        }

        return CLFLogOp(
            id: attr(el, "id"),
            description: string(el, "Description"),
            style: attr(el, "style"),
            inBitDepth: attr(el, "inBitDepth"),
            outBitDepth: attr(el, "outBitDepth"),
            params: params
        )
    }

    // MARK: - Exponent

    private static func parseExponent(_ el: XMLElement) -> CLFExponentOp? {
        let paramEls = el.children?.compactMap { $0 as? XMLElement }.filter { $0.localName == "ExponentParams" } ?? []

        let params: [CLFExponentParams] = paramEls.map { p in
            CLFExponentParams(
                channel: attr(p, "channel"),
                exponent: doubleAttr(p, "exponent"),
                offset: doubleAttr(p, "offset"),
                gamma: doubleAttr(p, "gamma"),
                offset2: doubleAttr(p, "offset"),
                linearSlope: doubleAttr(p, "linearSlope")
            )
        }

        return CLFExponentOp(
            id: attr(el, "id"),
            description: string(el, "Description"),
            style: attr(el, "style"),
            inBitDepth: attr(el, "inBitDepth"),
            outBitDepth: attr(el, "outBitDepth"),
            params: params
        )
    }

    // MARK: - Range

    private static func parseRange(_ el: XMLElement) -> CLFRangeOp? {
        CLFRangeOp(
            id: attr(el, "id"),
            description: string(el, "Description"),
            style: attr(el, "style"),
            inBitDepth: attr(el, "inBitDepth"),
            outBitDepth: attr(el, "outBitDepth"),
            minInValue: doubleText(child(el, "minInValue")),
            maxInValue: doubleText(child(el, "maxInValue")),
            minOutValue: doubleText(child(el, "minOutValue")),
            maxOutValue: doubleText(child(el, "maxOutValue"))
        )
    }

    // MARK: - Reference

    private static func parseReference(_ el: XMLElement) -> CLFReferenceOp? {
        let aliasEls: [XMLElement] = el.children?.compactMap { $0 as? XMLElement }.filter { $0.localName == "Alias" } ?? []
        let aliases = aliasEls
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return CLFReferenceOp(
            id: attr(el, "id"),
            description: string(el, "Description"),
            style: attr(el, "style"),
            path: attr(el, "path"),
            aliases: aliases
        )
    }

    // MARK: - XML helpers

    private static func child(_ el: XMLElement?, _ localName: String) -> XMLElement? {
        el?.children?.compactMap { $0 as? XMLElement }.first { $0.localName == localName }
    }

    private static func string(_ el: XMLElement?, _ localName: String) -> String? {
        guard let v = child(el, localName)?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !v.isEmpty else { return nil }
        return v
    }

    private static func strings(_ el: XMLElement, _ localName: String) -> [String] {
        (el.children?.compactMap { $0 as? XMLElement } ?? [])
            .filter { $0.localName == localName }
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func attr(_ el: XMLElement?, _ name: String) -> String? {
        el?.attribute(forName: name)?.stringValue
    }

    private static func doubleAttr(_ el: XMLElement, _ name: String) -> Double? {
        attr(el, name).flatMap { Double($0) }
    }

    private static func doubleText(_ el: XMLElement?) -> Double? {
        el?.stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func parseTriple(_ s: String?) -> SIMD3<Double>? {
        guard let s else { return nil }
        let parts = s.split(whereSeparator: { $0.isWhitespace })
            .compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return SIMD3(parts[0], parts[1], parts[2])
    }
}
