//
//  DisplaySurfaceMapping.swift
//  Tristimulator
//
//  Maps OCIO display names to Metal Surface Output identifiers.
//  Rules are stored in ~/Library/Application Support/Tristimulator/display-surface-mapping.json
//  and can be edited by the user. First match wins (case-insensitive regex).
//

import Foundation

struct DisplaySurfaceMapping {

    struct Rule: Codable {
        let pattern: String
        let surface: String
    }

    struct MappingFile: Codable {
        var rules: [Rule]
        var fallback: String
    }

    static let shared = DisplaySurfaceMapping()

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tristimulator")
        return dir.appendingPathComponent("display-surface-mapping.json")
    }()

    private static let defaultMapping = MappingFile(
        rules: [
            Rule(pattern: "display.*p3.*hdr",        surface: "extendedDisplayP3"),
            Rule(pattern: "display.*p3",             surface: "displayP3"),
            Rule(pattern: "dci|p3.?dci",             surface: "dcip3"),
            Rule(pattern: "p3.?d65",                 surface: "p3d65"),
            Rule(pattern: "rec\\.?709|bt\\.?709",    surface: "bt1886"),
            Rule(pattern: "srgb",                    surface: "sRGB"),
            Rule(pattern: "rec\\.?2020|bt\\.?2020",  surface: "itur_2020"),
            Rule(pattern: "rec\\.?2100.*hlg|hlg",    surface: "itur_2100_HLG"),
            Rule(pattern: "rec\\.?2100.*pq|pq",      surface: "itur_2100_PQ"),
            Rule(pattern: "rec\\.?2100",             surface: "itur_2100_PQ"),
        ],
        fallback: "extendedDisplayP3"
    )

    private let mapping: MappingFile

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let loaded = try? JSONDecoder().decode(MappingFile.self, from: data) {
            mapping = loaded
        } else {
            mapping = Self.defaultMapping
            Self.seedFile()
        }
    }

    private static func seedFile() {
        let url = fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(defaultMapping) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func surface(forDisplay displayName: String) -> String {
        let lower = displayName.lowercased()
        for rule in mapping.rules {
            if let regex = try? NSRegularExpression(pattern: rule.pattern, options: .caseInsensitive),
               regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                return rule.surface
            }
        }
        return mapping.fallback
    }
}
