//
//  ColorSpaceAliases.swift
//  Tristimulator
//
//  Defines equivalent color space names across different OCIO configs
//

import Foundation

/// Manages color space name equivalencies across different OCIO configurations
struct ColorSpaceAliases {
    
    /// Groups of equivalent color space names
    /// Each group contains names that refer to the same color space across different configs
    static let equivalencyGroups: [[String]] = [
        // ACES AP0 / ACES2065-1 - the ACES interchange space
        [
            "lin_ap0",
            "lin_ap0_scene",
            "linear_ap0_scene",
            "linap0scene",
            "linap0",
            "aces2065-1",
            "aces20651",
            "aces2065_1",
            "aces",
            "aces - aces2065-1",
            "ACES2065-1",  // Exact match for studio config
            "aces2065_1"   // Alternate underscore version
        ],
        
        // ACES AP1 / ACEScg - the ACES working space
        [
            "lin_ap1",
            "lin_ap1_scene",
            "linear_ap1_scene",
            "linap1scene",
            "linap1",
            "acescg",
            "aces - acescg"
        ],
        
        // ACEScct - ACES log working space
        [
            "acescct",
            "aces - acescct",
            "acescct_ap1"
        ],
        
        // ACEScc - ACES log working space (older)
        [
            "acescc",
            "aces - acescc",
            "acescc_ap1"
        ],
        
        // sRGB / Rec.709 encoded (gamma corrected)
        [
            "srgb",
            "srgb_tx",
            "srgb_texture",
            "srgbtexture",
            "srgb_rec709",
            "srgb_encoded_rec709",
            "srgb encoded rec.709 (srgb)",
            "utility - srgb - texture"
        ],
        
        // Linear sRGB / Linear Rec.709
        [
            "linear_rec709",
            "lin_rec709",
            "linear rec.709 (srgb)",
            "lin_rec709_scene",
            "lin_srgb",
            "utility - linear - rec.709",
            "utility - linear - srgb"
        ],
        
        // Rec.709 variations
        [
            "rec709",
            "rec.709",
            "rec_709",
            "bt709",
            "bt.709"
        ],
        
        // Rec.2020 / BT.2020
        [
            "rec2020",
            "rec.2020",
            "rec_2020",
            "bt2020",
            "bt.2020",
            "linear_rec2020",
            "lin_rec2020",
            "linear rec.2020"
        ],
        
        // Display P3
        [
            "displayp3",
            "display_p3",
            "display p3",
            "p3d65",
            "p3-d65",
            "linear_p3d65",
            "lin_p3d65"
        ],
        
        // DCI-P3
        [
            "dcip3",
            "dci-p3",
            "dci_p3"
        ],
        
        // Adobe RGB (1998)
        [
            "adobergb",
            "adobe_rgb",
            "adobe rgb",
            "adobergb1998",
            "adobe rgb (1998)"
        ],
        
        // Sony S-Gamut3
        [
            "sgamut3",
            "s-gamut3",
            "linear_sgamut3",
            "lin_sgamut3",
            "s-log3 s-gamut3"
        ],
        
        // Sony S-Gamut3.Cine
        [
            "sgamut3cine",
            "sgamut3.cine",
            "s-gamut3.cine",
            "linear_sgamut3cine",
            "lin_sgamut3cine",
            "s-log3 s-gamut3.cine"
        ],
        
        // ARRI Wide Gamut 3 / ALEXA Wide Gamut
        [
            "alexawide",
            "alexa_wide",
            "awg3",
            "arri_wide_gamut_3",
            "lin_alexawide",
            "linear_arri_wide_gamut_3"
        ],
        
        // ARRI Wide Gamut 4
        [
            "awg4",
            "arri_wide_gamut_4",
            "lin_awg4",
            "linear_arri_wide_gamut_4"
        ],
        
        // RED Wide Gamut RGB
        [
            "redwidegamutrgb",
            "red_wide_gamut_rgb",
            "rwg",
            "lin_rwg",
            "linear_redwidegamutrgb"
        ],
        
        // Canon Cinema Gamut
        [
            "cinemagamut",
            "cinema_gamut",
            "cgamut",
            "canon_cinema_gamut"
        ],
        
        // Panasonic V-Gamut
        [
            "vgamut",
            "v-gamut",
            "vgamut",
            "lin_vgamut",
            "linear_vgamut"
        ],
        
        // Blackmagic Wide Gamut Gen 5
        [
            "bmdwg5",
            "bmd_widegamut_gen5",
            "blackmagic_wide_gamut_gen5",
            "lin_bmdwg5"
        ],
        
        // DJI D-Gamut
        [
            "dgamut",
            "d-gamut",
            "dji_dgamut",
            "lin_dgamut"
        ],
        
        // DaVinci Wide Gamut
        [
            "davinci_widegamut",
            "dwg",
            "lin_dwg"
        ],
        
        // Apple Log
        [
            "applelog",
            "apple_log",
            "apple log"
        ],
        
        // CIE XYZ
        [
            "xyz",
            "cie_xyz",
            "ciexyz",
            "cie xyz-d65"
        ]
    ]
    
    /// Find a matching color space from available spaces given an input name
    /// - Parameters:
    ///   - colorSpace: The color space name to match
    ///   - availableSpaces: Array of available color space names from the OCIO config
    /// - Returns: A matching color space name from availableSpaces, or nil if no match found
    static func findMatch(for colorSpace: String, in availableSpaces: [String]) -> String? {
        let normalizedInput = normalize(colorSpace)
        
        print("   [ColorSpaceAliases] Input: '\(colorSpace)' -> normalized: '\(normalizedInput)'")
        
        // Special case: "Linear" alone is too ambiguous
        if normalizedInput == "linear" {
            print("   [ColorSpaceAliases] 'linear' is too ambiguous, returning nil")
            return nil
        }
        
        // Strategy 1: Try exact match first
        if let exactMatch = availableSpaces.first(where: {
            normalize($0) == normalizedInput
        }) {
            print("   [ColorSpaceAliases] ✅ Exact match: '\(exactMatch)'")
            return exactMatch
        }
        
        // Strategy 2: Find equivalency group
        for (index, group) in equivalencyGroups.enumerated() {
            let normalizedGroup = group.map { normalize($0) }
            
            if normalizedGroup.contains(normalizedInput) {
                print("   [ColorSpaceAliases] 🔄 Found in group \(index): [\(group.prefix(3).joined(separator: ", "))]...")
                
                // Found the group - now try to find any member in available spaces
                for (aliasIndex, alias) in group.enumerated() {
                    let normalizedAlias = normalize(alias)
                    
                    // First try exact match with this alias
                    if let exactMatch = availableSpaces.first(where: { normalize($0) == normalizedAlias }) {
                        print("   [ColorSpaceAliases] ✅ Exact match with alias '\(alias)' -> '\(exactMatch)'")
                        return exactMatch
                    }
                    
                    // Then try contains match
                    if let match = availableSpaces.first(where: {
                        let normalizedSpace = normalize($0)
                        let matches = normalizedSpace.contains(normalizedAlias) || normalizedAlias.contains(normalizedSpace)
                        if matches && aliasIndex < 3 {  // Only log first few to avoid spam
                            print("   [ColorSpaceAliases]    Checking '\(alias)' against available spaces...")
                        }
                        return matches
                    }) {
                        print("   [ColorSpaceAliases] ✅ Contains match with alias '\(alias)' -> '\(match)'")
                        return match
                    }
                }
                
                print("   [ColorSpaceAliases] ⚠️ Found group but no space matched")
            }
        }
        
        print("   [ColorSpaceAliases] ❌ No match found")
        return nil
    }
    
    /// Normalize a color space name for comparison
    /// Removes underscores, dots, spaces, hyphens and converts to lowercase
    private static func normalize(_ name: String) -> String {
        return name.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}
