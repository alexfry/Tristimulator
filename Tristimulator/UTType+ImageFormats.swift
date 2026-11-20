//
//  UTType+ImageFormats.swift
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

import UniformTypeIdentifiers

extension UTType {
    /// OpenEXR image format
    static let exr = UTType(filenameExtension: "exr")!
    
    /// Radiance HDR format
    static let hdr = UTType(filenameExtension: "hdr")!
    
    /// DPX (Digital Picture Exchange) format
    static let dpx = UTType(filenameExtension: "dpx")!
    
    /// Cineon format
    static let cineon = UTType(filenameExtension: "cin")!
    
    /// All supported HDR formats
    static var hdrFormats: [UTType] {
        [.exr, .hdr, .dpx, .cineon]
    }
    
    /// All supported image formats for Tristimulator
    static var tristimulatorFormats: [UTType] {
        [
            // HDR formats
            .exr, .hdr, .dpx, .cineon,
            
            // Standard formats
            .png, .jpeg, .tiff, .bmp, .gif,
            
            // Other
            .image
        ]
    }
}
