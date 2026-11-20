//
//  OCIOProcessor+Swift.swift
//  Tristimulator
//
//  Swift extensions providing throwing convenience for OCIO display processor
//

import Foundation

extension OCIOConfig {
    /// Convenience property to access the config description
    var configInfo: String? {
        return self.configDescription()
    }
}

extension OCIOProcessor {
    
    /// Create a display processor with throwing error handling
    /// The Objective-C factory method +displayProcessorWithConfig:sourceSpace:display:view:error:
    /// gets imported as display(with:sourceSpace:display:view:) in Swift
    static func makeDisplayProcessor(
        config: OCIOConfig,
        sourceSpace: String,
        display: String,
        view: String
    ) throws -> OCIOProcessor {
        // Swift imports BOOL-returning methods with NSError** as throwing methods
        // The method is renamed from displayProcessorWithConfig to display(with:...)
        return try OCIOProcessor.display(
            with: config,
            sourceSpace: sourceSpace,
            display: display,
            view: view
        )
    }

    /// Create a processor that converts `sourceSpace` to the config's scene-linear space.
    /// Returns the processor and the name of the resolved scene-linear space.
    /// Throws if the config has no recognised scene-linear role.
    static func makeLinearizeProcessor(
        config: OCIOConfig,
        sourceSpace: String
    ) throws -> (processor: OCIOProcessor, linearSpaceName: String) {
        guard let linearSpaceName = config.sceneLinearColorSpace() else {
            throw NSError(
                domain: "com.tristimulator.ocio", code: 6,
                userInfo: [NSLocalizedDescriptionKey:
                    "No scene_linear, aces_interchange, linear, or compositing_linear role "
                    + "found in the OCIO config. Cannot build a linearize pre-pass."])
        }
        // +processorWithConfig:sourceSpace:destinationSpace:error: bridges to
        // OCIOProcessor(config:sourceSpace:destinationSpace:) in Swift.
        let processor = try OCIOProcessor(config: config,
                                         sourceSpace: sourceSpace,
                                         destinationSpace: linearSpaceName)
        return (processor, linearSpaceName)
    }

    /// Create a dynamic ACES 2 output transform processor.
    ///
    /// - Parameters:
    ///   - config:         OCIO config used to resolve the source space to ACES2065-1.
    ///   - sourceSpace:    Working color space of the input image (e.g. "ACES2065-1", "ACEScg").
    ///   - peakNits:       Target peak display luminance in nits.
    ///   - edrScale:       Multiply factor that maps ACES2 output (0–1 where 1=peakNits) into
    ///                     EDR Metal-layer linear units (1.0 = SDR white ≈ 100 nits).
    ///                     Typically `peakNits / 100.0` — or the display's
    ///                     `maximumPotentialExtendedDynamicRangeColorComponentValue`.
    ///   - outputGamutXY:  8-element array [Rx,Ry, Gx,Gy, Bx,By, Wx,Wy].
    ///                     Nil → P3-D65.
    static func makeDynamicACES2Processor(
        config: OCIOConfig,
        sourceSpace: String,
        peakNits: Double,
        outputGamutXY: [Double]? = nil
    ) throws -> OCIOProcessor {
        let gamutNS = outputGamutXY.map { $0.map { NSNumber(value: $0) } }
        return try OCIOProcessor.aces2DynamicProcessor(
            with: config,
            sourceSpace: sourceSpace,
            peakNits: peakNits,
            outputGamutXY: gamutNS
        )
    }
    
    static func makeACES2FixedFunctionProcessor(
        config: OCIOConfig,
        peakNits: Double,
        outputGamutXY: [Double]? = nil
    ) throws -> OCIOProcessor {
        let gamutNS = outputGamutXY.map { $0.map { NSNumber(value: $0) } }
        return try OCIOProcessor.aces2FixedFunctionProcessor(
            with: config,
            peakNits: peakNits,
            outputGamutXY: gamutNS
        )
    }

    /// Create an inverse display transform processor (display-referred → scene-linear)
    ///
    /// This is essential for ACES 2.0 configs where display transforms aren't exposed as
    /// bidirectional colorspaces. Applies the display/view transform in reverse to convert
    /// display-referred image data back to scene-linear.
    ///
    /// - Parameters:
    ///   - config:  The OCIO configuration
    ///   - display: Display name to invert (e.g., "ACES", "sRGB")
    ///   - view:    View name to invert (e.g., "ACES 1.0 - SDR Video")
    /// - Returns: A processor that inverts the display/view transform
    /// - Throws: Error if the processor cannot be created
    /// Build a processor from an ordered list of transform-step dictionaries.
    /// Each step is a `[String: String]` with a `"type"` key; see the Objective-C header for details.
    static func makeGroupTransformProcessor(
        config: OCIOConfig,
        steps: [[String: String]]
    ) throws -> OCIOProcessor {
        return try OCIOProcessor.groupTransformProcessor(with: config, steps: steps)
    }

    static func makeInverseDisplayProcessor(
        config: OCIOConfig,
        display: String,
        view: String
    ) throws -> OCIOProcessor {
        // Swift imports the Objective-C method inverseDisplayProcessorWithConfig:display:view:error:
        // as inverseDisplay(with:display:view:) - note it's a throwing method automatically
        return try OCIOProcessor.inverseDisplay(
            with: config,
            display: display,
            view: view
        )
    }

    /// Inverse display processor that pins the destination scene-referred space explicitly
    /// (rather than the config's scene_linear role). Used by ShaderBaker so the baked inverse
    /// shader outputs a known space (e.g. ACES2065-1 / AP0), the exact inverse of the forward
    /// ACES 2 display shader.
    static func makeInverseDisplayProcessor(
        config: OCIOConfig,
        sourceSpace: String,
        display: String,
        view: String
    ) throws -> OCIOProcessor {
        return try OCIOProcessor.inverseDisplay(
            with: config,
            sourceSpace: sourceSpace,
            display: display,
            view: view
        )
    }
}



