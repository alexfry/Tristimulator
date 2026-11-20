//
//  AMFOCIOMapper.swift
//  Tristimulator
//
//  Maps ACES AMF transform IDs to OCIO color space names and suggests
//  source space configuration based on a parsed AMF sidecar.
//

import Foundation

enum AMFOCIOMapper {

    // MARK: - Public API

    /// Suggest an OCIO source color space based on the AMF's active input transform.
    ///
    /// Returns `nil` when:
    /// - There is no active input transform.
    /// - The transform has `applied = true` (pixels are already in scene-linear ACES).
    /// - No mapping can be determined.
    static func suggestSourceSpace(
        from amf: ACESMetadataFile,
        availableSpaces: [String]
    ) -> String? {
        guard let pipeline = amf.pipeline,
              let input = pipeline.inputTransform,
              !input.applied,
              let transformId = input.transformId else { return nil }

        // Derive a candidate name from the transform ID, then find the best
        // match among the available OCIO color spaces.
        let candidates = ocioSpaceCandidates(for: transformId)
        return bestMatch(from: candidates, in: availableSpaces)
    }

    /// Suggest an OCIO color space for any transform ID string (input, look working
    /// space, or output). Useful for informational display when no match is needed
    /// for automation.
    static func ocioSpaceHint(for transformId: String) -> String? {
        let candidates = ocioSpaceCandidates(for: transformId)
        return candidates.first
    }

    // MARK: - Candidate generation

    /// Returns an ordered list of OCIO color space name candidates for a given
    /// AMF transform ID, most specific first.
    private static func ocioSpaceCandidates(for transformId: String) -> [String] {
        let id = transformId.lowercased()

        // ── ACEScsc working space transforms ─────────────────────────────
        if id.contains("acescsc") {
            if id.contains("acescct") { return ["ACEScct", "ACES - ACEScct"] }
            if id.contains("acescc")  { return ["ACEScc",  "ACES - ACEScc"] }
            if id.contains("acescg")  { return ["ACEScg",  "ACES - ACEScg"] }
            if id.contains("aces_to_aces") || id.contains("aces2065") {
                return ["ACES2065-1", "ACES - ACES2065-1", "lin_ap0"]
            }
        }

        // ── IDT / Input Device Transforms ────────────────────────────────

        // ARRI
        if id.contains("idt.arri") || id.contains("arri") {
            if id.contains("logc4")             { return ["ARRI LogC4", "Input - ARRI - ARRI LogC4"] }
            if id.contains("logc3") || id.contains("logc") {
                if id.contains("ei3200")        { return ["ARRI LogC3 EI3200", "Input - ARRI - ARRI LogC3 EI3200"] }
                if id.contains("ei2000")        { return ["ARRI LogC3 EI2000", "Input - ARRI - ARRI LogC3 EI2000"] }
                if id.contains("ei1600")        { return ["ARRI LogC3 EI1600", "Input - ARRI - ARRI LogC3 EI1600"] }
                if id.contains("ei1280")        { return ["ARRI LogC3 EI1280", "Input - ARRI - ARRI LogC3 EI1280"] }
                if id.contains("ei1000")        { return ["ARRI LogC3 EI1000", "Input - ARRI - ARRI LogC3 EI1000"] }
                if id.contains("ei800")         { return ["ARRI LogC3 EI800",  "Input - ARRI - ARRI LogC3 EI800"] }
                if id.contains("ei640")         { return ["ARRI LogC3 EI640",  "Input - ARRI - ARRI LogC3 EI640"] }
                if id.contains("ei500")         { return ["ARRI LogC3 EI500",  "Input - ARRI - ARRI LogC3 EI500"] }
                if id.contains("ei400")         { return ["ARRI LogC3 EI400",  "Input - ARRI - ARRI LogC3 EI400"] }
                if id.contains("ei320")         { return ["ARRI LogC3 EI320",  "Input - ARRI - ARRI LogC3 EI320"] }
                if id.contains("ei200")         { return ["ARRI LogC3 EI200",  "Input - ARRI - ARRI LogC3 EI200"] }
                if id.contains("ei160")         { return ["ARRI LogC3 EI160",  "Input - ARRI - ARRI LogC3 EI160"] }
                return ["ARRI LogC3 EI800", "Input - ARRI - ARRI LogC3 EI800"]
            }
            return []
        }

        // Sony
        if id.contains("idt.sony") || id.contains("sony") {
            if id.contains("slog3")             { return ["S-Log3 S-Gamut3.Cine", "Input - Sony - S-Log3 S-Gamut3.Cine"] }
            if id.contains("slog2")             { return ["S-Log2 S-Gamut",       "Input - Sony - S-Log2 S-Gamut"] }
            if id.contains("venice") && id.contains("slog3") {
                return ["S-Log3 Venice S-Gamut3.Cine", "Input - Sony - S-Log3 Venice S-Gamut3.Cine"]
            }
            return []
        }

        // RED
        if id.contains("idt.red") || id.contains(".red.") {
            if id.contains("log3g12") || id.contains("redlogfilm") {
                return ["REDlogFilm", "Input - RED - REDlogFilm"]
            }
            if id.contains("redlog3g10") { return ["Log3G10", "Input - RED - Log3G10"] }
            return []
        }

        // Canon
        if id.contains("idt.canon") || id.contains("canon") {
            if id.contains("clog3")             { return ["Canon Log 3", "Input - Canon - Canon Log 3"] }
            if id.contains("clog2")             { return ["Canon Log 2", "Input - Canon - Canon Log 2"] }
            if id.contains("clog")              { return ["Canon Log",   "Input - Canon - Canon Log"] }
            return []
        }

        // Nikon
        if id.contains("idt.nikon") || id.contains("nikon") {
            if id.contains("nlog")              { return ["N-Log", "Input - Nikon - N-Log"] }
            return []
        }

        // Panasonic
        if id.contains("idt.panasonic") || id.contains("panasonic") {
            if id.contains("vlog")              { return ["V-Log", "Input - Panasonic - V-Log"] }
            return []
        }

        // Blackmagic
        if id.contains("idt.blackmagic") || id.contains("blackmagic") || id.contains("bmd") {
            if id.contains("bmdfilm4k")         { return ["BMDFilm 4K", "Input - Blackmagic - BMDFilm 4K"] }
            if id.contains("bmdfilm")           { return ["BMDFilm",    "Input - Blackmagic - BMDFilm"] }
            return []
        }

        // GoPro
        if id.contains("idt.gopro") || id.contains("protune") {
            return ["Protune Flat", "Input - GoPro - Protune Flat"]
        }

        // Academy / generic ACES IDTs
        if id.contains("idt.academy") {
            // Linear ACES scene input
            if id.contains("lineartoaces") || id.contains("aces_csc") {
                return ["ACES2065-1", "ACES - ACES2065-1", "lin_ap0"]
            }
            return ["ACES2065-1", "ACES - ACES2065-1"]
        }

        // sRGB / Rec.709 generic
        if id.contains("srgb")   { return ["sRGB", "Utility - sRGB - Texture"] }
        if id.contains("rec709") { return ["Rec.709", "Utility - Rec.709 - Camera"] }

        return []
    }

    // MARK: - Matching

    /// Finds the best match from `candidates` in the list of available OCIO spaces.
    /// Tries exact match first, then case-insensitive, then substring containment.
    private static func bestMatch(from candidates: [String], in available: [String]) -> String? {
        for candidate in candidates {
            // Exact
            if let exact = available.first(where: { $0 == candidate }) { return exact }
        }
        for candidate in candidates {
            // Case-insensitive
            let lower = candidate.lowercased()
            if let ci = available.first(where: { $0.lowercased() == lower }) { return ci }
        }
        for candidate in candidates {
            // Substring
            let lower = candidate.lowercased()
            if let sub = available.first(where: { $0.lowercased().contains(lower) }) { return sub }
        }
        return nil
    }
}
