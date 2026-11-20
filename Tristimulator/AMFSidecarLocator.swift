//
//  AMFSidecarLocator.swift
//  Tristimulator
//
//  Locates an ACES Metadata File (.amf) sidecar associated with an image URL.
//

import Foundation

enum AMFSidecarLocator {

    /// Find an `.amf` sidecar for the given image URL.
    ///
    /// Search order:
    /// 1. Exact stem match — `image.exr` → `image.amf`
    /// 2. Sequence stem  — strip trailing frame number digits, e.g. `A001C030_001.exr` → `A001C030.amf`
    /// 3. Single-file fallback — if exactly one `.amf` exists in the same directory, use it
    static func findAMF(for imageURL: URL) -> URL? {
        let dir  = imageURL.deletingLastPathComponent()
        let stem = imageURL.deletingPathExtension().lastPathComponent

        // 1. Exact stem
        let exact = dir.appendingPathComponent(stem).appendingPathExtension("amf")
        if FileManager.default.fileExists(atPath: exact.path) { return exact }

        // 2. Sequence stem — strip trailing _NNN or .NNN digits
        let stripped = stripFrameNumber(from: stem)
        if stripped != stem {
            let candidate = dir.appendingPathComponent(stripped).appendingPathExtension("amf")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }

        // 3. Single .amf in directory
        let amfsInDir = (try? FileManager.default.contentsOfDirectory(at: dir,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]))
            .map { urls in urls.filter { $0.pathExtension.lowercased() == "amf" } }

        if let amfs = amfsInDir, amfs.count == 1 {
            return amfs[0]
        }

        return nil
    }

    // Remove a trailing frame-number suffix from a filename stem.
    // Handles patterns like:
    //   A001C030_001  → A001C030
    //   shot.0100     → shot
    //   IMAGE.1001    → IMAGE
    private static func stripFrameNumber(from stem: String) -> String {
        // Match an optional separator (_ or .) followed by 3–8 digits at end of string.
        let pattern = #"[_.]?\d{3,8}$"#
        guard let range = stem.range(of: pattern, options: .regularExpression) else {
            return stem
        }
        return String(stem[stem.startIndex..<range.lowerBound])
    }
}
