//
//  ImageManager.swift
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

import Foundation
import Metal
import Combine
import AppKit   // NSScreen

// MARK: - Source Transform Mode

/// Defines how the source image's color space is interpreted and transformed
enum SourceTransformMode: String, CaseIterable, Identifiable, Codable {
    /// Standard colorspace-to-colorspace transform (e.g., sRGB → ACES2065-1)
    case colorspace = "Color Space"
    
    /// Inverse display transform (for ACES 2.0 configs where display transforms
    /// aren't exposed as colorspaces). Applies display/view transform in reverse
    /// to convert display-referred image to scene-referred working space.
    case inverseDisplay = "Inverse Display"
    
    var id: String { rawValue }
}

// MARK: - ACES2 output gamut presets

/// Output colour gamut for the Dynamic ACES2 display transform.
/// The values are the xy chromaticity coordinates used by the
/// `ACES2_OutputTransform` FixedFunctionTransform.
enum ACES2Gamut: String, CaseIterable, Identifiable, Codable {
    case rec709  = "Rec.709"
    case p3d65   = "P3-D65"
    case rec2020 = "Rec.2020"

    var id: String { rawValue }

    /// [Rx,Ry, Gx,Gy, Bx,By, Wx,Wy] — indices 1–8 of the ACES2_OutputTransform params
    var xy: [Double] {
        switch self {
        case .p3d65:   return [0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.3127, 0.3290]
        case .rec709:  return [0.640, 0.330, 0.300, 0.600, 0.150, 0.060, 0.3127, 0.3290]
        case .rec2020: return [0.708, 0.292, 0.170, 0.797, 0.131, 0.046, 0.3127, 0.3290]
        }
    }

    /// The Metal layer color space identifier that matches the linear output of
    /// FIXED_FUNCTION_ACES_OUTPUT_TRANSFORM_20 for this gamut.
    /// ACES2 OT produces display-referred *linear* values (no EOTF applied),
    /// so the drawable must use an extendedLinear* color space so the system
    /// compositor interprets them correctly (1.0 = SDR white).
    var linearMetalColorSpace: String {
        switch self {
        case .p3d65:   return "extendedLinearDisplayP3"
        case .rec709:  return "extendedLinearSRGB"
        case .rec2020: return "extendedLinearITUR_2020"
        }
    }
}

// MARK: - Color Space Family Tree

/// A tree node representing a family hierarchy for OCIO color spaces.
/// Children are sub-families (e.g. "Input" → "ARRI", "Sony"), and
/// `colorSpaces` holds leaf color space names at this level.
class ColorSpaceFamilyNode: Identifiable {
    let id = UUID()
    let name: String
    /// Color spaces that belong directly to this family level.
    var colorSpaces: [String] = []
    /// Sub-family nodes, ordered by first insertion.
    var children: [ColorSpaceFamilyNode] = []

    init(name: String) { self.name = name }

    /// Insert a color space into the tree at the given family path.
    func insert(colorSpace: String, path: [String]) {
        if path.isEmpty {
            colorSpaces.append(colorSpace)
        } else {
            let childName = path[0]
            let remaining = Array(path.dropFirst())
            if let existing = children.first(where: { $0.name == childName }) {
                existing.insert(colorSpace: colorSpace, path: remaining)
            } else {
                let child = ColorSpaceFamilyNode(name: childName)
                children.append(child)
                child.insert(colorSpace: colorSpace, path: remaining)
            }
        }
    }
}

@Observable
class ImageManager {
    var currentImage: ImageData?
    var exposure: Float = 0.0
    var colorTransform: ColorTransform?
    var ocioConfig: OCIOConfig?
    /// Absolute path to the currently loaded OCIO config file.
    /// `nil` means the bundled default config is in use.
    var loadedConfigPath: String?

    /// When true, display transforms run on the OCIO CPU processor instead of the Metal GPU path.
    /// Use this to compare GPU output against the reference CPU rendering.
    var useCPURenderPath: Bool = false
    
    // MARK: - Source Transform Mode
    
    /// Controls how the source image's color is interpreted
    var sourceTransformMode: SourceTransformMode = .colorspace
    
    /// For inverse display mode: the display name to invert
    var sourceInverseDisplay: String = ""
    
    /// For inverse display mode: the view name to invert
    var sourceInverseView: String = ""

    // MARK: Dynamic ACES2 mode

    /// When true, the Display node uses the built-in ACES2 output transform
    /// with peak nits set dynamically from the current EDR headroom.
    /// When false, the normal OCIO config display/view selectors are used.
    var dynamicACES2Mode: Bool = false

    /// When true, peak nits are derived automatically from the display's *current*
    /// EDR headroom (`maximumExtendedDynamicRangeColorComponentValue`).  When false,
    /// `dynamicACES2TargetNits` is used instead.
    var dynamicACES2AutoNits: Bool = true

    /// User-controlled peak nit target for the ACES2 output transform.
    /// Defines where scene-white tone-maps to; reasonable range 100–4000 nit.
    var dynamicACES2TargetNits: Float = 1000.0

    /// Output colour gamut used in Dynamic ACES2 mode.
    var dynamicACES2Gamut: ACES2Gamut = .p3d65

    /// Peak luminance (nits) used in the most-recently compiled dynamic ACES2 processor.
    /// Updated each time `applyDynamicACES2Transform` runs.
    private(set) var dynamicACES2PeakNits: Float = 100.0

    /// Source color space that was last passed to `applyDynamicACES2Transform`.
    /// Stored so `updateExposure` can re-fire the transform without extra arguments.
    private var dynamicACES2SourceSpace: String = ""

    /// Tracks the EDR headroom used in the last auto-nits build so we only
    /// rebuild when it changes meaningfully.
    private var lastKnownEDR: Float = 0
    /// Polls current EDR headroom every 2 s and rebuilds the ACES2 processor
    /// when auto-nits mode is active and the value has changed by >1 %.
    private var edrPollCancellable: AnyCancellable?

    /// The NSScreen that currently hosts this window's content view.
    /// Set by DocumentContentView whenever the window moves to a different display.
    /// Falls back to NSScreen.main so the app still works before the window is shown.
    var currentScreen: NSScreen?

    private let device: MTLDevice
    private var loadingCancellable: AnyCancellable?
    
    // Store original image data so we can re-apply transforms from scratch
    private var originalImageData: ImageData?

    // MARK: - AMF look application
    //
    // `applyAMFPipeline` bakes the AMF look transforms into a new source texture and then
    // replaces `originalImageData` with that looked result (so the GPU display pass runs on
    // the graded data). To support per-stage toggles — which must re-apply from scratch
    // rather than re-bake on top of an already-looked image — we keep a pristine snapshot
    // of the un-looked source, captured on every load.
    private var amfSourceSnapshot: ImageData?
    /// Per-look enable state, aligned with `pipeline.lookTransforms`. Toggled from the
    /// Look Transforms node; re-applies the looks when changed.
    var amfEnabledLooks: [Bool] = []
    /// Node-level master switch. When false the whole Look Transforms node is bypassed
    /// without disturbing the per-look enable state (so it is restored when re-enabled).
    var amfLooksGloballyEnabled: Bool = true
    /// A manually-loaded AMF (File ▸ Load AMF…) that overrides any path-discovered sidecar.
    /// Re-applied to every incoming frame so it survives sequence scrubbing/playback.
    /// Cleared when a brand-new file is opened via `loadImage`.
    private var manualAMFOverride: ACESMetadataFile?
    /// AMF toggle state restored from the per-image saved settings
    /// (`OCIOPipelineSettings.amfLookStates` / `.amfLooksGloballyEnabled`).
    /// Overlaid onto the defaults whenever the toggles are (re)initialised for an AMF,
    /// so an AMF that finishes loading after the settings restore doesn't reset the
    /// user's saved toggles to the defaults.
    private var restoredAMFLookStates: [String: Bool]?
    private var restoredAMFLooksGloballyEnabled: Bool?

    /// `true` when the current image came from a video frame (no CPU pixel data).
    /// Video frames skip the CPU color-transform step and go straight to the GPU pipeline.
    var isVideoFrame: Bool { originalImageData?.pixelData.isEmpty ?? false }

    /// The original pre-OCIO source texture (always `originalImageData.metalTexture`).
    /// Passed to MetalEDRImageView so draw() can encode the OCIO compute pass inline,
    /// giving one GPU submission per frame and zero per-change allocations for stills.
    var originalSourceTexture: MTLTexture? { originalImageData?.metalTexture }
    
    // Store intermediate transformed data (after color space conversion but before display)
    private var transformedImageData: ImageData?

    // GPU-accelerated OCIO processor (display pass: working-space / linear → display/view)
    var gpuProcessor: OCIOGPUProcessor?
    
    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device

        // Poll current EDR headroom every 2 s.  The closure does nothing unless
        // dynamic ACES2 auto-nits is active, making it very cheap in all other states.
        // Wrapped in Task { @MainActor in } so that @Observable mutations inside
        // applyDynamicACES2Transform are seen by SwiftUI's update scheduler.
        edrPollCancellable = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self,
                      self.dynamicACES2Mode,
                      self.dynamicACES2AutoNits,
                      !self.dynamicACES2SourceSpace.isEmpty else { return }
                let current = Float((self.currentScreen ?? NSScreen.main)?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
                guard abs(current - self.lastKnownEDR) / max(self.lastKnownEDR, 1e-6) > 0.01 else { return }
                let ss = self.dynamicACES2SourceSpace
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.applyDynamicACES2Transform(sourceSpace: ss)
                    } catch {
                        print("❌ EDR poll: applyDynamicACES2Transform failed: \(error)")
                    }
                }
            }
        self.gpuProcessor = OCIOGPUProcessor(device: device)
        
        // Try to load OCIO config in order of preference:
        // 1. Bundled resource (if available)
        // 2. OCIO environment variable
        
        let fileManager = FileManager.default
        
        // Look for bundled OCIO config
        if let bundledConfigPath = Bundle.main.path(forResource: "OCIO/studio-config-v4.0.0_aces-v2.0_ocio-v2.5", ofType: "ocio") {
            print("📦 Found bundled OCIO config: \(bundledConfigPath)")
            
            // Try to load the bundled config
            do {
                self.ocioConfig = try OCIOConfig(path: bundledConfigPath)
                self.loadedConfigPath = bundledConfigPath   // ← mark as loaded
                print("✅ OpenColorIO loaded from bundled resource")
                print("📊 Version: \(OpenColorIOBridge.version())")
                print("📁 Config: \(bundledConfigPath)")
                
                // Print available color spaces
                let colorSpaces = ocioConfig?.colorSpaceNames() ?? []
                print("🎨 Available color spaces: \(colorSpaces.count)")
                if colorSpaces.count > 0 {
                    print("   \(colorSpaces.prefix(10).joined(separator: ", "))")
                }
                
                // Print available displays
                let displays = ocioConfig?.displayNames() ?? []
                print("🖥️  Available displays: \(displays.joined(separator: ", "))")
                
                // Print role information
                if let sceneLinear = ocioConfig?.sceneLinearColorSpace() {
                    print("🎬 Scene-linear role: \(sceneLinear)")
                }
                if let defaultSpace = ocioConfig?.defaultColorSpace() {
                    print("📌 Default role: \(defaultSpace)")
                }
                if let config = ocioConfig {
                    let defaultDisplay = config.defaultDisplay()
                    if !defaultDisplay.isEmpty {
                        print("🖥️  Default display: \(defaultDisplay)")
                        let defaultView = config.defaultView(forDisplay: defaultDisplay)
                        if !defaultView.isEmpty {
                            print("👁️  Default view: \(defaultView)")
                        }
                    }
                }
            } catch {
                print("⚠️ Failed to load bundled OCIO config:")
                print("   \(error.localizedDescription)")
                self.ocioConfig = OCIOConfig.default()
                // Still record the path so the UI can show it even though load failed
                self.loadedConfigPath = bundledConfigPath
            }
        } else {
            print("⚠️ Bundled OCIO config not found, falling back to environment variable...")
            self.ocioConfig = OCIOConfig.default()
            // Capture the OCIO env-var path so the UI and settings store can see it
            if let ocioEnv = ProcessInfo.processInfo.environment["OCIO"] {
                self.loadedConfigPath = ocioEnv
            }
        }
        
        if ocioConfig != nil {
            if Bundle.main.path(forResource: "studio-config-v4.0.0_aces-v2.0_ocio-v2.5", ofType: "ocio") == nil {
                print("✅ OpenColorIO loaded from environment variable")
                print("📊 Version: \(OpenColorIOBridge.version())")
            }
        } else {
            print("⚠️ OpenColorIO config not found. Set OCIO environment variable or bundle a config file.")
        }
    }
    
    /// Load an image from a URL, optionally selecting a named EXR layer.
    /// - Parameters:
    ///   - url:   File URL to load.
    ///   - layer: EXR layer name ("" = default/unnamed RGBA layer).
    func loadImage(from url: URL, layer: String = "") async throws {
        guard url.isFileURL else {
            throw ImageError.invalidURL
        }

        let isEXR = url.pathExtension.lowercased() == "exr"

        if isEXR {
            // ── Direct OpenEXR path ──────────────────────────────────────────
            // Uses OpenEXR for the texture read (fast, supports layers reliably)
            // and a lightweight OIIO header-only open for metadata + layer names.
            let dev = self.device
            let result: (texture: MTLTexture, spec: OIIOImageSpec, exrLayers: [String]) =
                try await Task {
                    // 1) Header-only metadata via OIIO (no pixel decode).
                    //    This also extracts layer names from the full channel list.
                    let spec = try OpenImageIOBridge.readMetadata(atPath: url.path)
                    // 2) Layer names — try both OIIO and direct OpenEXR, keep the
                    //    richer result (multi-part EXRs may expose channels
                    //    differently through each API).
                    let oiioLayers: [String] = spec.layerNames as [String]
                    let exrLayers: [String] = (try? OpenImageIOBridge.layerNames(atPath: url.path)) ?? []
                    let layers = exrLayers.count > oiioLayers.count ? exrLayers : oiioLayers
                    // 3) Texture via direct OpenEXR read.
                    let tex = try OpenImageIOBridge.readTexture(atPath: url.path,
                                                                layer: layer,
                                                                device: dev)
                    return (tex, spec, layers)
                }.value

            let spec = result.spec
            var metadata = ImageMetadata(
                colorSpace: spec.colorSpace,
                bitDepth: Int(spec.bitDepth),
                isHDR: spec.isHDR,
                maxLuminance: spec.maxLuminance > 0 ? spec.maxLuminance : nil,
                attributes: spec.attributes
            )
            metadata.layerNames = result.exrLayers
            metadata.amfData = AMFSidecarLocator.findAMF(for: url)
                .flatMap { try? ACESAMFParser.parse(url: $0) }

            currentImage = ImageData(
                width: result.texture.width,
                height: result.texture.height,
                channels: 4,
                pixelData: Data(),   // GPU-only — same as sequence/video frames
                metadata: metadata,
                metalTexture: result.texture
            )
        } else {
            // ── OIIO path for non-EXR formats ───────────────────────────────
            let oiioImage = try await Task {
                if layer.isEmpty {
                    return try OpenImageIOBridge.readImage(atPath: url.path)
                } else {
                    return try OpenImageIOBridge.readImage(atPath: url.path, layer: layer)
                }
            }.value

            guard let texture = oiioImage.createMetalTexture(device) else {
                throw ImageError.textureCreationFailed
            }

            let layerNames: [String] = oiioImage.spec.layerNames as [String]
            var metadata = ImageMetadata(
                colorSpace: oiioImage.spec.colorSpace,
                bitDepth: Int(oiioImage.spec.bitDepth),
                isHDR: oiioImage.spec.isHDR,
                maxLuminance: oiioImage.spec.maxLuminance > 0 ? oiioImage.spec.maxLuminance : nil,
                attributes: oiioImage.spec.attributes
            )
            metadata.layerNames = layerNames
            metadata.amfData = AMFSidecarLocator.findAMF(for: url)
                .flatMap { try? ACESAMFParser.parse(url: $0) }

            currentImage = ImageData(
                width: Int(oiioImage.spec.width),
                height: Int(oiioImage.spec.height),
                channels: Int(oiioImage.spec.channels),
                pixelData: oiioImage.pixelData,
                metadata: metadata,
                metalTexture: texture
            )
        }
        
        // A freshly-opened file uses its own (path-discovered) AMF, if any.
        manualAMFOverride = nil

        // Store original data so we can re-apply transforms
        originalImageData = currentImage
        // Pristine, un-looked source for AMF look re-application (toggles).
        amfSourceSnapshot = currentImage

        // Initially, transformed data is the same as original (no transform applied yet)
        transformedImageData = currentImage

        // Reset exposure when loading new image
        exposure = 0.0

        // WORKAROUND: Recreate GPU processor to avoid texture reuse bug
        self.gpuProcessor  = OCIOGPUProcessor(device: device)

        // Initialise the AMF look toggles for this image. The looks themselves are folded
        // into the GPU display shader by `applyDisplayTransform` (run by the view's
        // pipeline init), so they apply on load and persist across sequence frames.
        ensureAMFEnabledLooksInitialized()
    }

    /// Load a single decoded video frame (an `MTLTexture` produced by `MovieSource`)
    /// directly into the pipeline, bypassing OpenImageIO entirely.
    ///
    /// The texture is used as-is; the existing OCIO GPU processor applies the
    /// display transform on the next `applyDisplayTransform` call.  `pixelData`
    /// is left empty because video frames are GPU-only — the CPU path will skip
    /// the color-transform step automatically when it sees an empty buffer.
    ///
    /// - Parameters:
    ///   - texture:         The decoded frame as an `rgba32Float` Metal texture.
    ///   - colorSpaceHint:  A display name stored in `ImageMetadata.colorSpace`
    ///                      (shown in the info bar; does not affect OCIO logic —
    ///                       the user picks the actual source space via the OCIO UI).
    func loadFrame(_ texture: MTLTexture, colorSpaceHint: String) {
        let metadata = ImageMetadata(
            colorSpace: colorSpaceHint,
            bitDepth: 32,
            isHDR: true,
            maxLuminance: nil,
            attributes: [:]
        )
        let raw = ImageData(
            width:     texture.width,
            height:    texture.height,
            channels:  4,
            pixelData: Data(), // empty — GPU-path only for video frames
            metadata:  metadata,
            metalTexture: texture
        )
        let data = applyingManualAMF(raw) ?? raw
        originalImageData  = data
        transformedImageData = data
        currentImage       = data
        amfSourceSnapshot  = data
        // Do NOT recreate gpuProcessor here — the compiled OCIO shader is
        // reused across all frames; only the input texture changes.
    }

    /// Load a pre-built `ImageData` frame (e.g. from an image sequence) directly
    /// into the pipeline.  Preserves the full OIIO metadata already embedded in
    /// `imageData` (color space, bit depth, HDR flag, etc.) without reconstruction.
    ///
    /// Like the texture-only overload above, this bypasses the CPU color-transform
    /// step — the OCIO GPU processor drives display transforms on every draw call.
    func loadFrame(_ imageData: ImageData) {
        // A manually-loaded AMF overrides the frame's own path-discovered sidecar so it
        // persists across the sequence.
        let data = applyingManualAMF(imageData) ?? imageData
        originalImageData    = data
        transformedImageData = data
        currentImage         = data
        amfSourceSnapshot    = data
        // Do NOT recreate gpuProcessor here — the compiled OCIO shader is
        // reused across all frames; only the input texture changes.
    }

    /// Save current image to a URL
    func saveImage(to url: URL, format: String) async throws {
        guard currentImage != nil else {
            throw ImageError.noImageLoaded
        }
        
        // For now, this is a placeholder - we'd need to create an OIIOImage from ImageData
        // In a full implementation, we'd maintain the original OIIOImage or reconstruct it
        throw ImageError.notImplemented
    }
    
    /// Apply color transformation using OCIO
    /// Supports two modes:
    /// - Colorspace mode: Standard colorspace-to-colorspace transform
    /// - Inverse Display mode: Inverts a display/view transform (for ACES 2.0 configs)
    func applyColorTransform(from sourceSpace: String, to destSpace: String) throws {
        guard let config = ocioConfig else {
            throw ImageError.ocioNotAvailable
        }
        
        guard let originalData = originalImageData else {
            throw ImageError.noImageLoaded
        }
        
        // Handle different source transform modes
        switch sourceTransformMode {
        case .colorspace:
            try applyColorspaceTransform(from: sourceSpace, to: destSpace, originalData: originalData, config: config)
            
        case .inverseDisplay:
            try applyInverseDisplayTransform(to: destSpace, originalData: originalData, config: config)
        }
    }
    
    /// Standard colorspace-to-colorspace transform
    private func applyColorspaceTransform(from sourceSpace: String, to destSpace: String, originalData: ImageData, config: OCIOConfig) throws {
        // If source and dest are the same, just reset to original (no transform needed)
        if sourceSpace == destSpace {
            print("🔄 Source and dest spaces are identical (\(sourceSpace)), resetting to original")
            transformedImageData = nil
            currentImage = originalData
            
            colorTransform = ColorTransform(
                sourceColorSpace: sourceSpace,
                destinationColorSpace: destSpace,
                display: nil,
                view: nil
            )
            return
        }
        
        print("🔄 [Colorspace Mode] Applying color transform: \(sourceSpace) → \(destSpace)")

        // Video frames have no CPU pixel data — the full source→display transform
        // is handled entirely by the OCIO GPU kernel in applyDisplayTransform.
        // Just carry the original texture forward as the "transformed" state.
        if originalData.pixelData.isEmpty {
            transformedImageData = originalData
            currentImage = originalData
            colorTransform = ColorTransform(
                sourceColorSpace: sourceSpace,
                destinationColorSpace: destSpace,
                display: nil,
                view: nil
            )
            print("ℹ️  Skipping CPU color transform — video frame (no pixel data)")
            return
        }
        
        // Create OCIO processor
        let processor = try OCIOProcessor(
            config: config,
            sourceSpace: sourceSpace,
            destinationSpace: destSpace
        )
        
        // Process the ORIGINAL pixel data (not the current displayed data)
        let processedData = try processor.processPixelData(
            originalData.pixelData,
            width: originalData.width,
            height: originalData.height,
            channels: originalData.channels
        )
        
        // Recreate Metal texture with processed data
        if let newTexture = createMetalTexture(from: processedData, width: originalData.width, height: originalData.height, channels: originalData.channels) {
            let transformedData = ImageData(
                width: originalData.width,
                height: originalData.height,
                channels: originalData.channels,
                pixelData: processedData,
                metadata: originalData.metadata,
                metalTexture: newTexture
            )
            
            // Store this as the transformed intermediate state
            transformedImageData = transformedData
            currentImage = transformedData
        }
        
        // Store the transform information
        colorTransform = ColorTransform(
            sourceColorSpace: sourceSpace,
            destinationColorSpace: destSpace,
            display: nil,
            view: nil
        )
        
        print("✅ Color transform applied successfully")
    }
    
    /// Inverse display transform: applies display/view transform in reverse
    /// This is needed for ACES 2.0 configs where display transforms aren't exposed as colorspaces
    private func applyInverseDisplayTransform(to destSpace: String, originalData: ImageData, config: OCIOConfig) throws {
        guard !sourceInverseDisplay.isEmpty && !sourceInverseView.isEmpty else {
            throw ImageError.invalidInverseDisplayConfig
        }
        
        print("🔄 [Inverse Display Mode] Applying inverse display transform: \(sourceInverseDisplay)/\(sourceInverseView) → \(destSpace)")
        
        // Video frames have no CPU pixel data — handled by GPU
        if originalData.pixelData.isEmpty {
            transformedImageData = originalData
            currentImage = originalData
            colorTransform = ColorTransform(
                sourceColorSpace: "Inverse(\(sourceInverseDisplay)/\(sourceInverseView))",
                destinationColorSpace: destSpace,
                display: sourceInverseDisplay,
                view: sourceInverseView
            )
            print("ℹ️  Skipping CPU inverse display transform — video frame (no pixel data)")
            return
        }
        
        // Step 1: Create inverse display processor (display-referred → scene-linear)
        // This inverts the display/view transform
        let inverseDisplayProcessor = try OCIOProcessor.makeInverseDisplayProcessor(
            config: config,
            display: sourceInverseDisplay,
            view: sourceInverseView
        )
        
        // Step 2: Apply inverse display transform to get scene-linear data
        let sceneLinearData = try inverseDisplayProcessor.processPixelData(
            originalData.pixelData,
            width: originalData.width,
            height: originalData.height,
            channels: originalData.channels
        )
        
        // Step 3: If destination is not scene-linear, apply additional transform
        let finalData: Data
        if let sceneLinearSpace = config.sceneLinearColorSpace(), sceneLinearSpace != destSpace {
            print("   Converting from scene-linear (\(sceneLinearSpace)) to \(destSpace)")
            let secondProcessor = try OCIOProcessor(
                config: config,
                sourceSpace: sceneLinearSpace,
                destinationSpace: destSpace
            )
            finalData = try secondProcessor.processPixelData(
                sceneLinearData,
                width: originalData.width,
                height: originalData.height,
                channels: originalData.channels
            )
        } else {
            finalData = sceneLinearData
        }
        
        // Recreate Metal texture with processed data
        if let newTexture = createMetalTexture(from: finalData, width: originalData.width, height: originalData.height, channels: originalData.channels) {
            let transformedData = ImageData(
                width: originalData.width,
                height: originalData.height,
                channels: originalData.channels,
                pixelData: finalData,
                metadata: originalData.metadata,
                metalTexture: newTexture
            )
            
            // Store this as the transformed intermediate state
            transformedImageData = transformedData
            currentImage = transformedData
        }
        
        // Store the transform information
        colorTransform = ColorTransform(
            sourceColorSpace: "Inverse(\(sourceInverseDisplay)/\(sourceInverseView))",
            destinationColorSpace: destSpace,
            display: sourceInverseDisplay,
            view: sourceInverseView
        )
        
        print("✅ Inverse display transform applied successfully")
    }
    
    /// Apply display transform (GPU-accelerated)
    func applyDisplayTransform(from sourceSpace: String, display: String, view: String) async throws {
        guard let config = ocioConfig else {
            throw ImageError.ocioNotAvailable
        }

        // --- CPU reference path: mirrors the GPU combined pass ---
        // source → scene_linear → ×exposure → display/view
        // Starts from originalImageData so intermediate dest-space data is irrelevant.
        // Video frames have no CPU pixel data — always use the GPU path regardless of the toggle.
        let hasPixelData = (originalImageData?.pixelData.isEmpty == false)

        if useCPURenderPath && hasPixelData {
            guard let originalData = originalImageData else {
                throw ImageError.noImageLoaded
            }
            guard let sceneLinearSpace = config.sceneLinearColorSpace() else {
                throw ImageError.ocioNotAvailable
            }

            // Step 1: source → scene_linear
            // In inverse display mode, use the inverse display processor instead of linearize
            let linearData: Data
            if sourceTransformMode == .inverseDisplay && !sourceInverseDisplay.isEmpty && !sourceInverseView.isEmpty {
                print("🖥️ [CPU] Combined display transform (inverse): inv(\(sourceInverseDisplay)/\(sourceInverseView)) → [\(sceneLinearSpace)] → \(display)/\(view) exposure=\(exposure)")
                let invProc = try OCIOProcessor.makeInverseDisplayProcessor(
                    config: config, display: sourceInverseDisplay, view: sourceInverseView)
                linearData = try invProc.processPixelData(
                    originalData.pixelData,
                    width: originalData.width, height: originalData.height,
                    channels: originalData.channels)
            } else {
                print("🖥️ [CPU] Combined display transform: \(sourceSpace) → [\(sceneLinearSpace)] → \(display)/\(view) exposure=\(exposure)")
                let (linProcessor, _) = try OCIOProcessor.makeLinearizeProcessor(
                    config: config, sourceSpace: sourceSpace)
                linearData = try linProcessor.processPixelData(
                    originalData.pixelData,
                    width: originalData.width, height: originalData.height,
                    channels: originalData.channels)
            }

            // Step 2: apply exposure in scene-linear space
            let exposedData = applyExposureToPixelData(linearData,
                                                       channels: originalData.channels,
                                                       exposure: exposure)

            // Step 3: scene_linear → display/view
            let dispProcessor = try OCIOProcessor.makeDisplayProcessor(
                config: config, sourceSpace: sceneLinearSpace, display: display, view: view)
            let processedData = try dispProcessor.processPixelData(
                exposedData,
                width: originalData.width, height: originalData.height,
                channels: originalData.channels)

            guard let newTexture = createMetalTexture(
                from: processedData,
                width: originalData.width, height: originalData.height,
                channels: originalData.channels) else {
                throw ImageError.textureCreationFailed
            }
            let newImageData = ImageData(
                width: originalData.width, height: originalData.height,
                channels: originalData.channels, pixelData: processedData,
                metadata: originalData.metadata, metalTexture: newTexture)
            currentImage = newImageData
            colorTransform = ColorTransform(
                sourceColorSpace: sourceSpace,
                destinationColorSpace: "\(display) / \(view)",
                display: display, view: view)
            print("✅ [CPU] Display transform applied")
            return
        }
        // --- GPU path: combined single-pass shader (source → scene_linear → ×exposure → display) ---
        // Always reads from the original source texture; the combined kernel handles the full
        // chain, so exposure is always applied in scene-linear space for both stills and video.
        guard let originalData = originalImageData else {
            throw ImageError.noImageLoaded
        }
        guard let gpu = gpuProcessor else {
            throw ImageError.gpuNotAvailable
        }

        guard let inputTexture = originalData.metalTexture else {
            throw ImageError.textureCreationFailed
        }

        // One compiled kernel: source → scene_linear → ×exp2(exposure) → display/view
        // Compilation runs on a background thread (Metal shader compile can take 100-500ms).
        // OCIOGPUProcessor serialises setups and coalesces queued ones (latest wins); draw()
        // keeps using the previous pipeline snapshot until the new one is published.
        let capturedGpu = gpu
        let capturedConfig = config
        let compileSource = sourceSpace
        let compileDisplay = display
        let compileView = view
        let useInverseDisplay = (sourceTransformMode == .inverseDisplay
                                 && !sourceInverseDisplay.isEmpty
                                 && !sourceInverseView.isEmpty)
        let invDisplay = sourceInverseDisplay
        let invView = sourceInverseView
        let sourceModeSig = useInverseDisplay ? "inv:\(invDisplay)/\(invView)" : ""
        // AMF look transforms are folded into the combined display shader so they apply to
        // every frame (and persist across a sequence). Computed on the main actor here.
        let capturedLookSteps = amfGPULookSteps()
        let capturedLookSig = lookSig(capturedLookSteps)
        let compiled = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let ran: Bool
                    if useInverseDisplay {
                        ran = try capturedGpu.setupCombinedInverseDisplayTransform(
                            config: capturedConfig,
                            inverseDisplay: invDisplay,
                            inverseView: invView,
                            display: compileDisplay,
                            view: compileView)
                    } else {
                        ran = try capturedGpu.setupCombinedTransform(
                            config: capturedConfig,
                            sourceSpace: compileSource,
                            display: compileDisplay,
                            view: compileView,
                            lookSteps: capturedLookSteps)
                    }
                    cont.resume(returning: ran)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        // A newer transform request superseded this one before it compiled; that request
        // will commit its own state, so don't overwrite it with these stale parameters.
        guard compiled else { return }

        // Video frames: inline draw() renderer handles all GPU work — processTexture would
        // hold the CVMetalTexture alive inside the GPU command buffer, starving AVFoundation's
        // pixel buffer pool.  Return as soon as the pipeline is compiled.
        if !hasPixelData {
            colorTransform = ColorTransform(
                sourceColorSpace: sourceSpace,
                destinationColorSpace: "\(display) / \(view)",
                display: display,
                view: view,
                amfLookSig: capturedLookSig,
                sourceModeSig: sourceModeSig
            )
            return
        }

        guard let processedTexture = await gpu.processTexture(input: inputTexture, exposure: exposure) else {
            throw ImageError.gpuProcessingFailed
        }

        // Video frames guarded above — only stills reach here.
        if originalData.pixelData.isEmpty == false {
            currentImage = ImageData(
                width: originalData.width,
                height: originalData.height,
                channels: originalData.channels,
                pixelData: originalData.pixelData,
                metadata: originalData.metadata,
                metalTexture: processedTexture
            )
        }

        colorTransform = ColorTransform(
            sourceColorSpace: sourceSpace,
            destinationColorSpace: "\(display) / \(view)",
            display: display,
            view: view,
            amfLookSig: capturedLookSig,
            sourceModeSig: sourceModeSig
        )
    }

    // MARK: - Dynamic ACES2 transform

    /// Apply the ACES2 output transform with peak luminance derived from the current EDR headroom.
    ///
    /// - The OCIO pipeline: `sourceSpace` → ACES2065-1 → ACES2_OutputTransform(peakNits) → ×edrScale
    /// - Exposure is applied inside the Metal compute kernel (before OCIO), same as the
    ///   normal display transform path.
    /// - `edrScale = peakNits / 100` maps ACES2’s normalised 0–1 output into EDR linear units
    ///   where 1.0 = SDR white ≈ 100 nits.
    func applyDynamicACES2Transform(sourceSpace: String) async throws {
        guard let config = ocioConfig else { throw ImageError.ocioNotAvailable }

        let peakNits: Float
        let snapshotEDR: Float
        if dynamicACES2AutoNits {
            let currentEDR = (currentScreen ?? NSScreen.main)?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
            peakNits = max(100.0, (Float(currentEDR) * 100.0).rounded())
            snapshotEDR = Float(currentEDR)
        } else {
            peakNits = min(10000.0, max(100.0, dynamicACES2TargetNits))
            snapshotEDR = lastKnownEDR  // unchanged
        }
        // Note: dynamicACES2PeakNits and lastKnownEDR are updated AFTER successful
        // GPU processing below, so the slider and retry-guard only advance when
        // the rendering actually committed.
        dynamicACES2SourceSpace = sourceSpace

        // Video frames have no CPU pixel data — always use the GPU path regardless of the toggle.
        let hasPixelData = (originalImageData?.pixelData.isEmpty == false)

        let useInverseDisplay = (sourceTransformMode == .inverseDisplay
                                 && !sourceInverseDisplay.isEmpty
                                 && !sourceInverseView.isEmpty)
        let invDisplay = sourceInverseDisplay
        let invView    = sourceInverseView
        let sourceModeSig = useInverseDisplay ? "inv:\(invDisplay)/\(invView)" : ""

        // AMF look transforms folded into the ACES2 combined pass (non-inverse path),
        // so looks apply in Dynamic ACES2 mode and persist across frames.
        let aces2LookSteps = useInverseDisplay ? [] : amfGPULookSteps()
        let aces2LookSig = lookSig(aces2LookSteps)

        if useCPURenderPath && hasPixelData {
            // CPU combined path: source → scene_linear → ×exposure → ACES2 from scene_linear
            guard let originalData = originalImageData else { throw ImageError.noImageLoaded }
            guard let sceneLinearSpace = config.sceneLinearColorSpace() else { throw ImageError.ocioNotAvailable }

            let linearData: Data
            if useInverseDisplay {
                let invProc = try OCIOProcessor.makeInverseDisplayProcessor(
                    config: config, display: invDisplay, view: invView)
                linearData = try invProc.processPixelData(
                    originalData.pixelData,
                    width: originalData.width, height: originalData.height,
                    channels: originalData.channels)
            } else {
                let (linProcessor, _) = try OCIOProcessor.makeLinearizeProcessor(
                    config: config, sourceSpace: sourceSpace)
                linearData = try linProcessor.processPixelData(
                    originalData.pixelData,
                    width: originalData.width, height: originalData.height,
                    channels: originalData.channels)
            }

            let exposedData = applyExposureToPixelData(linearData,
                                                       channels: originalData.channels,
                                                       exposure: exposure)

            let aces2FromLinear = try OCIOProcessor.makeDynamicACES2Processor(
                config: config,
                sourceSpace: sceneLinearSpace,
                peakNits: Double(peakNits),
                outputGamutXY: dynamicACES2Gamut.xy)
            let processedData = try aces2FromLinear.processPixelData(
                exposedData,
                width: originalData.width, height: originalData.height,
                channels: originalData.channels)
            guard let texture = createMetalTexture(from: processedData,
                                                   width: originalData.width,
                                                   height: originalData.height,
                                                   channels: originalData.channels) else {
                throw ImageError.textureCreationFailed
            }
            currentImage = ImageData(width: originalData.width, height: originalData.height,
                                     channels: originalData.channels, pixelData: processedData,
                                     metadata: originalData.metadata, metalTexture: texture)
            // Commit only on success so the slider and timer retry-guard stay accurate
            dynamicACES2PeakNits = peakNits
            lastKnownEDR = snapshotEDR
        } else {
            // GPU combined path: source → scene_linear → ×exposure → ACES2 from scene_linear.
            // Feed originalImageData — the combined kernel handles linearisation internally.
            guard let originalData = originalImageData else { throw ImageError.noImageLoaded }
            guard let sceneLinearSpace = config.sceneLinearColorSpace() else { throw ImageError.ocioNotAvailable }
            guard let gpu = gpuProcessor else { throw ImageError.gpuNotAvailable }

            // Only rebuild the OCIO processor and recompile the shader when something changed.
            // Compilation runs on a background thread — OCIO C++ + Metal pipeline compile can
            // take 100-500ms per pass.  OCIOGPUProcessor runs one setup at a time and coalesces
            // queued ones (latest wins); draw() keeps the previous snapshot until the new one lands.
            let cacheSourceKey = useInverseDisplay ? "inv(\(invDisplay)/\(invView))" : sourceSpace
            if !gpu.isACES2PipelineReady(sourceSpace: cacheSourceKey, peakNits: peakNits, gamutTag: dynamicACES2Gamut.rawValue, lookSig: aces2LookSig) {
                let edrHeadroom = (currentScreen ?? NSScreen.main)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
                print("🎨 Dynamic ACES2: peakNits=\(Int(peakNits)) auto=\(dynamicACES2AutoNits) displayEDR=\(String(format: "%.1f×", edrHeadroom)) gamut=\(dynamicACES2Gamut.rawValue) inverseDisplay=\(useInverseDisplay)")
                // Snapshot values needed on the background thread before suspending.
                let capturedGpu              = gpu
                let capturedConfig           = config
                let capturedSourceSpace      = sourceSpace
                let capturedPeakNits         = peakNits
                let capturedGamutTag         = dynamicACES2Gamut.rawValue
                let capturedLinearSpace      = sceneLinearSpace
                let capturedTargetNits       = Double(peakNits)
                let capturedGamutXY          = dynamicACES2Gamut.xy
                let capturedUseInverse       = useInverseDisplay
                let capturedInvDisplay       = invDisplay
                let capturedInvView          = invView
                let capturedLookSteps        = aces2LookSteps
                let compiled = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let ran: Bool
                            let aces2Proc = try OCIOProcessor.makeDynamicACES2Processor(
                                config: capturedConfig,
                                sourceSpace: capturedLinearSpace,
                                peakNits: capturedTargetNits,
                                outputGamutXY: capturedGamutXY)
                            if capturedUseInverse {
                                ran = try capturedGpu.setupCombinedInverseDisplayACES2Transform(
                                    config: capturedConfig,
                                    inverseDisplay: capturedInvDisplay,
                                    inverseView: capturedInvView,
                                    peakNits: capturedPeakNits,
                                    gamutTag: capturedGamutTag,
                                    aces2Processor: aces2Proc)
                            } else {
                                ran = try capturedGpu.setupCombinedACES2Transform(
                                    config: capturedConfig,
                                    sourceSpace: capturedSourceSpace,
                                    peakNits: capturedPeakNits,
                                    gamutTag: capturedGamutTag,
                                    aces2Processor: aces2Proc,
                                    lookSteps: capturedLookSteps)
                            }
                            cont.resume(returning: ran)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                // Superseded by a newer request (e.g. a later headroom tick) before compiling.
                // Leave dynamicACES2PeakNits / lastKnownEDR for that request to commit.
                guard compiled else { return }
            }

            // Video frames: inline draw() handles all GPU work. processTexture would hold
            // the CVMetalTexture in a GPU command buffer, starving AVFoundation's buffer pool.
            // The pipeline is now compiled — return immediately; draw() picks it up.
            if !hasPixelData {
                dynamicACES2PeakNits = peakNits
                lastKnownEDR = snapshotEDR
                colorTransform = ColorTransform(
                    sourceColorSpace: sourceSpace,
                    destinationColorSpace: "Dynamic ACES2 (\(Int(peakNits)) nits)",
                    display: nil,
                    view: nil,
                    amfLookSig: aces2LookSig,
                    sourceModeSig: sourceModeSig
                )
                return
            }

            guard let inputTexture = originalData.metalTexture else { throw ImageError.textureCreationFailed }
            guard let processedTexture = await gpu.processTexture(input: inputTexture, exposure: exposure) else {
                throw ImageError.gpuProcessingFailed
            }
            // Only stills reach here (video returned above).
            if !originalData.pixelData.isEmpty {
                currentImage = ImageData(width: originalData.width, height: originalData.height,
                                         channels: originalData.channels, pixelData: originalData.pixelData,
                                         metadata: originalData.metadata, metalTexture: processedTexture)
            }
            // Commit only on success so the slider and timer retry-guard stay accurate
            dynamicACES2PeakNits = peakNits
            lastKnownEDR = snapshotEDR
        }

        colorTransform = ColorTransform(
            sourceColorSpace: sourceSpace,
            destinationColorSpace: "Dynamic ACES2 (\(Int(peakNits)) nits)",
            display: nil,
            view: nil,
            amfLookSig: aces2LookSig,
            sourceModeSig: sourceModeSig
        )
    }

    // MARK: - AMF pipeline application

    /// Apply the colour pipeline described in the AMF sidecar attached to the current image.
    ///
    /// Unapplied transforms (IDT + looks + output) are chained into a single OCIO
    /// GroupTransform and processed on the CPU. The result is stored as `currentImage`
    /// and the GPU pipeline is invalidated so the renderer displays it directly.
    ///
    /// - Parameters:
    ///   - sourceSpace: Current OCIO source space (fallback if AMF IDT cannot be auto-mapped).
    ///   - display:     Current OCIO display (fallback if AMF output transform cannot be mapped).
    ///   - view:        Current OCIO view (fallback if AMF output transform cannot be mapped).
    func applyAMFPipeline(sourceSpace: String, display: String, view: String) async throws {
        guard let config = ocioConfig else { throw ImageError.ocioNotAvailable }
        guard let amf = (currentImage?.metadata.amfData ?? originalImageData?.metadata.amfData) else {
            throw NSError(domain: "com.tristimulator.amf", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No AMF data available"])
        }
        // Always apply looks from the pristine, un-looked source so per-stage toggles
        // re-apply from scratch instead of re-baking on top of an already-looked image.
        guard let originalData = amfSourceSnapshot ?? originalImageData else {
            throw ImageError.noImageLoaded
        }

        // Indices of looks the user has enabled (nil → all unapplied looks).
        let enabledLookIndices: Set<Int>? = amfEnabledLooks.isEmpty
            ? nil
            : Set(amfEnabledLooks.enumerated().filter { $0.element }.map { $0.offset })

        // For GPU-only frames (e.g. image sequences), read pixel data back from the texture
        let inputPixelData: Data
        let inputChannels: Int
        if originalData.pixelData.isEmpty {
            guard let texture = originalData.metalTexture else {
                throw ImageError.noImageLoaded
            }
            print("🔍 [AMF] Source texture: \(texture.width)x\(texture.height) format=\(texture.pixelFormat.rawValue)")
            if texture.pixelFormat == .rgba16Float {
                // Float16 texture — read at half-precision stride, then convert to Float32 for OCIO
                let float16BytesPerRow = texture.width * 4 * MemoryLayout<UInt16>.stride
                var float16Data = Data(count: float16BytesPerRow * texture.height)
                float16Data.withUnsafeMutableBytes { ptr in
                    texture.getBytes(ptr.baseAddress!,
                                     bytesPerRow: float16BytesPerRow,
                                     from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                                     mipmapLevel: 0)
                }
                let pixelCount = texture.width * texture.height * 4
                var float32Data = Data(count: pixelCount * MemoryLayout<Float>.stride)
                float16Data.withUnsafeBytes { src in
                    float32Data.withUnsafeMutableBytes { dst in
                        let srcPtr = src.baseAddress!.assumingMemoryBound(to: Float16.self)
                        let dstPtr = dst.baseAddress!.assumingMemoryBound(to: Float.self)
                        for i in 0..<pixelCount {
                            dstPtr[i] = Float(srcPtr[i])
                        }
                    }
                }
                inputPixelData = float32Data
            } else {
                let bytesPerRow = texture.width * 4 * MemoryLayout<Float>.stride
                var bytes = Data(count: bytesPerRow * texture.height)
                bytes.withUnsafeMutableBytes { ptr in
                    texture.getBytes(ptr.baseAddress!,
                                     bytesPerRow: bytesPerRow,
                                     from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                                     mipmapLevel: 0)
                }
                inputPixelData = bytes
            }
            inputChannels = 4
        } else {
            inputPixelData = originalData.pixelData
            inputChannels = originalData.channels
        }

        let buildResult = AMFOCIOPipelineBuilder.buildSteps(
            from: amf,
            config: config,
            currentSourceSpace: sourceSpace,
            currentDisplay: display,
            currentView: view,
            enabledLookIndices: enabledLookIndices
        )

        for warning in buildResult.warnings { print("⚠️ [AMF] \(warning)") }

        // No steps can mean either (a) the AMF genuinely has nothing to apply, or
        // (b) the user disabled every look via the toggles. In both cases the correct
        // result is the pristine source — restore it rather than erroring.
        guard !buildResult.isEmpty else {
            if !amfEnabledLooks.isEmpty {
                originalImageData = originalData
                currentImage      = originalData
                print("🎬 [AMF] All looks disabled — showing pristine source")
                return
            }
            throw NSError(domain: "com.tristimulator.amf", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                              "AMF pipeline has no unapplied transforms to apply"])
        }

        print("🎬 [AMF] Applying \(buildResult.steps.count)-step pipeline...")

        // Sample a handful of pixels from the input so we can see the data range
        inputPixelData.withUnsafeBytes { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            let count = inputPixelData.count / MemoryLayout<Float>.stride
            var mn: Float =  .infinity, mx: Float = -.infinity
            var nan = 0, neg = 0
            for i in stride(from: 0, to: count, by: 4) {
                for c in 0..<3 {
                    let v = p[i + c]
                    if v.isNaN { nan += 1; continue }
                    if v < 0 { neg += 1 }
                    if v < mn { mn = v }
                    if v > mx { mx = v }
                }
            }
            let centerIdx = (originalData.height / 2) * originalData.width * 4
                          + (originalData.width / 2) * 4
            if centerIdx + 3 < count {
                print(String(format: "🔍 [AMF] IN  range R/G/B min=%.4f max=%.4f nan=%d neg=%d  center RGBA=(%.4f, %.4f, %.4f, %.4f)",
                             mn, mx, nan, neg,
                             p[centerIdx], p[centerIdx + 1], p[centerIdx + 2], p[centerIdx + 3]))
            }
        }

        // Build and run the group transform on a background thread (may be slow for large images)
        let capturedConfig = config
        let capturedSteps  = buildResult.steps
        let processedData: Data = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let processor = try OCIOProcessor.makeGroupTransformProcessor(
                        config: capturedConfig, steps: capturedSteps)
                    let data = try processor.processPixelData(
                        inputPixelData,
                        width: originalData.width,
                        height: originalData.height,
                        channels: inputChannels)
                    cont.resume(returning: data)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        // Sample the OCIO output the same way
        processedData.withUnsafeBytes { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            let count = processedData.count / MemoryLayout<Float>.stride
            var mn: Float =  .infinity, mx: Float = -.infinity
            var nan = 0, neg = 0
            for i in stride(from: 0, to: count, by: 4) {
                for c in 0..<3 {
                    let v = p[i + c]
                    if v.isNaN { nan += 1; continue }
                    if v < 0 { neg += 1 }
                    if v < mn { mn = v }
                    if v > mx { mx = v }
                }
            }
            let centerIdx = (originalData.height / 2) * originalData.width * 4
                          + (originalData.width / 2) * 4
            if centerIdx + 3 < count {
                print(String(format: "🔍 [AMF] OUT range R/G/B min=%.4f max=%.4f nan=%d neg=%d  center RGBA=(%.4f, %.4f, %.4f, %.4f)",
                             mn, mx, nan, neg,
                             p[centerIdx], p[centerIdx + 1], p[centerIdx + 2], p[centerIdx + 3]))
            }
        }

        // Build a .rgba16Float texture that matches the source-frame format the rest of
        // the renderer expects (MPS bilinear scaling on rgba32Float HDR sources caused
        // hue / luminance artefacts in highlights downstream).
        let halfDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: originalData.width,
            height: originalData.height,
            mipmapped: false)
        halfDesc.usage = [.shaderRead, .shaderWrite]
        halfDesc.storageMode = .shared
        guard let newTexture = device.makeTexture(descriptor: halfDesc) else {
            throw ImageError.textureCreationFailed
        }
        let pixelCount16 = originalData.width * originalData.height * 4
        var half16Data = Data(count: pixelCount16 * MemoryLayout<UInt16>.stride)
        processedData.withUnsafeBytes { src in
            half16Data.withUnsafeMutableBytes { dst in
                let srcPtr = src.baseAddress!.assumingMemoryBound(to: Float.self)
                let dstPtr = dst.baseAddress!.assumingMemoryBound(to: Float16.self)
                for i in 0..<pixelCount16 {
                    dstPtr[i] = Float16(srcPtr[i])
                }
            }
        }
        let halfBytesPerRow = originalData.width * 4 * MemoryLayout<UInt16>.stride
        half16Data.withUnsafeBytes { bytes in
            newTexture.replace(
                region: MTLRegionMake2D(0, 0, originalData.width, originalData.height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: halfBytesPerRow
            )
        }

        // Read back the new texture and compare to what we just wrote
        do {
            let bpr = newTexture.width * 4 * MemoryLayout<UInt16>.stride
            var readback = Data(count: bpr * newTexture.height)
            readback.withUnsafeMutableBytes { ptr in
                newTexture.getBytes(ptr.baseAddress!,
                                    bytesPerRow: bpr,
                                    from: MTLRegionMake2D(0, 0, newTexture.width, newTexture.height),
                                    mipmapLevel: 0)
            }
            readback.withUnsafeBytes { raw in
                let p = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
                let count = readback.count / MemoryLayout<Float16>.stride
                var mn: Float =  .infinity, mx: Float = -.infinity
                for i in stride(from: 0, to: count, by: 4) {
                    for c in 0..<3 {
                        let v = Float(p[i + c])
                        if v.isNaN { continue }
                        if v < mn { mn = v }
                        if v > mx { mx = v }
                    }
                }
                let centerIdx = (originalData.height / 2) * originalData.width * 4
                              + (originalData.width / 2) * 4
                print(String(format: "🔍 [AMF] TEX range R/G/B min=%.4f max=%.4f  center RGBA=(%.4f, %.4f, %.4f, %.4f)  format=%d",
                             mn, mx,
                             Float(p[centerIdx]), Float(p[centerIdx + 1]), Float(p[centerIdx + 2]), Float(p[centerIdx + 3]),
                             newTexture.pixelFormat.rawValue))
            }
        }

        // The processed texture holds scene-linear (ACES2065-1) pixels with the AMF
        // look transforms baked in. Replace the source texture so the existing GPU
        // display pipeline applies the user's current display/view transform on top.
        // Empty pixelData ensures the renderer treats this as a video-frame texture
        // (sampled directly) rather than re-creating a texture from CPU bytes.
        let lookedImage = ImageData(
            width: originalData.width, height: originalData.height,
            channels: inputChannels, pixelData: Data(),
            metadata: originalData.metadata, metalTexture: newTexture)

        originalImageData = lookedImage
        currentImage      = lookedImage

        print("✅ [AMF] Look transforms applied (output transform deferred to display pipeline)")
        if !buildResult.warnings.isEmpty {
            print("⚠️ [AMF] \(buildResult.warnings.count) warning(s) during pipeline construction")
        }
    }

    // MARK: - AMF auto-apply / re-apply

    /// Apply the manual AMF override (if any) to an `ImageData`, returning a copy whose
    /// metadata carries the override's AMF. No-op when there is no override.
    private func applyingManualAMF(_ data: ImageData?) -> ImageData? {
        guard let d = data, let amf = manualAMFOverride else { return data }
        var meta = d.metadata
        meta.amfData = amf
        return ImageData(width: d.width, height: d.height, channels: d.channels,
                         pixelData: d.pixelData, metadata: meta,
                         metalTexture: d.metalTexture, contentTag: d.contentTag)
    }

    /// Attach a manually-loaded AMF to the current image (and its source snapshots), reset
    /// the look toggles, and apply the looks. The override persists across sequence frames.
    /// Used by File ▸ Load AMF…
    func attachAMF(_ amf: ACESMetadataFile) async {
        // A manually-loaded AMF starts from its own defaults, not the saved toggles.
        restoredAMFLookStates = nil
        restoredAMFLooksGloballyEnabled = nil
        manualAMFOverride = amf
        originalImageData = applyingManualAMF(originalImageData)
        amfSourceSnapshot = applyingManualAMF(amfSourceSnapshot)
        currentImage      = applyingManualAMF(currentImage)
        resetAMFEnabledLooks(for: amf)
        await reapplyAMFLooks()
    }

    /// Default the per-look enable toggles for `amf`: enable every look that Tristimulator
    /// can actually apply (`.applied`), leave unresolvable / baked looks off. Any toggle
    /// state restored from the per-image settings is then overlaid, matched by stable
    /// look key (see `AMFLookToggleState`).
    private func resetAMFEnabledLooks(for amf: ACESMetadataFile) {
        let looks = amf.pipeline?.lookTransforms ?? []
        let defaults: [Bool]
        if let config = ocioConfig {
            let status = AMFOCIOPipelineBuilder.applicationStatus(for: amf, config: config)
            defaults = status.looks.map { $0 == .applied }
        } else {
            defaults = looks.map { _ in true }
        }
        amfEnabledLooks = AMFLookToggleState.merge(
            defaults: defaults,
            keys: AMFLookToggleState.keys(for: looks),
            resolvable: defaults,
            saved: restoredAMFLookStates)
        amfLooksGloballyEnabled = restoredAMFLooksGloballyEnabled ?? true
    }

    /// Restore AMF toggle state from saved per-image settings. Safe to call before the
    /// image / AMF has loaded: the state is kept and applied when the toggles are
    /// initialised. If the AMF is already loaded the toggles are updated immediately;
    /// the caller is responsible for re-running the display transform.
    func restoreAMFLookToggles(states: [String: Bool]?, globallyEnabled: Bool?) {
        restoredAMFLookStates = states
        restoredAMFLooksGloballyEnabled = globallyEnabled
        if let amf = currentImage?.metadata.amfData ?? originalImageData?.metadata.amfData {
            resetAMFEnabledLooks(for: amf)
        }
    }

    /// AMF toggle state to persist with the per-image settings. Falls back to the
    /// restored state when the AMF isn't loaded / initialised yet, so an early save
    /// can't wipe the saved toggles.
    func amfLookTogglesForPersistence() -> (states: [String: Bool]?, globallyEnabled: Bool?) {
        guard let amf = currentImage?.metadata.amfData ?? originalImageData?.metadata.amfData else {
            return (restoredAMFLookStates, restoredAMFLooksGloballyEnabled)
        }
        let looks = amf.pipeline?.lookTransforms ?? []
        guard amfEnabledLooks.count == looks.count else {
            return (restoredAMFLookStates, restoredAMFLooksGloballyEnabled)
        }
        let states = AMFLookToggleState.snapshot(
            keys: AMFLookToggleState.keys(for: looks), enabled: amfEnabledLooks)
        return (states, amfLooksGloballyEnabled)
    }

    /// Per-stage status reflecting the live toggle state, for the AMF popover so its
    /// badges match the Look Transforms node. Resolvable looks that the user has disabled
    /// (per-look off, or the node globally bypassed) are reported as `.disabled`.
    /// NOTE: pure / read-only — safe to call from a SwiftUI view body. It must NOT mutate
    /// observable state (e.g. `ensureAMFEnabledLooksInitialized`), or it would trigger a
    /// "modifying state during view update" loop.
    func effectiveAMFStatus(for amf: ACESMetadataFile) -> AMFApplicationStatus? {
        guard let config = ocioConfig else { return nil }
        var status = AMFOCIOPipelineBuilder.applicationStatus(for: amf, config: config)
        // Only the currently-displayed image's AMF reflects the toggle state.
        let activeAMF = currentImage?.metadata.amfData ?? originalImageData?.metadata.amfData
        guard activeAMF?.sourceURL == amf.sourceURL else { return status }
        let enabledArr = amfEnabledLooks
        let countMatches = (enabledArr.count == status.looks.count)
        status.looks = status.looks.enumerated().map { i, s in
            guard s == .applied else { return s }
            // If toggles aren't initialised yet (count mismatch), treat as enabled (default).
            let enabled = countMatches ? enabledArr[i] : true
            return (enabled && amfLooksGloballyEnabled) ? .applied : .disabled
        }
        return status
    }

    /// Ensure the per-look toggle array matches the current AMF (initialise it to the
    /// resolvable looks when empty or out of sync). Used by the Look Transforms node and
    /// the display pipeline so toggles are populated for both stills and sequences.
    func ensureAMFEnabledLooksInitialized() {
        guard let amf = currentImage?.metadata.amfData ?? originalImageData?.metadata.amfData else { return }
        let lookCount = amf.pipeline?.lookTransforms.count ?? 0
        if amfEnabledLooks.count != lookCount {
            resetAMFEnabledLooks(for: amf)
        }
    }

    /// AMF look-transform steps (enabled looks only) to fold into the GPU display shader.
    /// Empty when there is no AMF or no enabled look. Because the looks live in the
    /// compiled display shader, they apply to every frame and persist across a sequence.
    func amfGPULookSteps() -> [[String: String]] {
        ensureAMFEnabledLooksInitialized()
        guard amfLooksGloballyEnabled else { return [] }   // node bypassed
        guard let amf = currentImage?.metadata.amfData ?? originalImageData?.metadata.amfData,
              let config = ocioConfig,
              amfEnabledLooks.contains(true) else { return [] }
        let enabled = Set(amfEnabledLooks.enumerated().filter { $0.element }.map { $0.offset })
        return AMFOCIOPipelineBuilder.buildSteps(
            from: amf, config: config,
            currentSourceSpace: "", currentDisplay: "", currentView: "",
            enabledLookIndices: enabled).steps
    }

    /// Master switch for the whole Look Transforms node. Toggling it bypasses or restores
    /// all looks without disturbing the individual per-look enable state.
    func setAMFLooksGloballyEnabled(_ enabled: Bool) {
        amfLooksGloballyEnabled = enabled
        Task { await reapplyAMFLooks() }
    }

    /// Stable signature of a set of look steps — used both to key the GPU shader cache and
    /// to make `ColorTransform` compare unequal when looks change (forcing a redraw).
    func lookSig(_ steps: [[String: String]]) -> String {
        steps.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|") }
            .joined(separator: ";")
    }

    /// Re-apply the AMF looks after the user flips a look's enable toggle by rebuilding the
    /// display transform (the looks are folded into the GPU display shader). Uses the last
    /// applied source/display/view from `colorTransform`.
    func reapplyAMFLooks() async {
        guard currentImage?.metadata.amfData != nil || originalImageData?.metadata.amfData != nil,
              let ct = colorTransform else { return }
        if dynamicACES2Mode {
            // ACES2 mode has no display/view (they are nil on the colorTransform).
            try? await applyDynamicACES2Transform(sourceSpace: ct.sourceColorSpace)
        } else if let display = ct.display, let view = ct.view {
            try? await applyDisplayTransform(from: ct.sourceColorSpace, display: display, view: view)
        }
    }

    func updateExposure(_ newExposure: Float) async {
        self.exposure = newExposure

        // CPU path: exposure is baked into pixel data, must re-run the full transform.
        if useCPURenderPath && (originalImageData?.pixelData.isEmpty == false) {
            if dynamicACES2Mode && !dynamicACES2SourceSpace.isEmpty {
                try? await applyDynamicACES2Transform(sourceSpace: dynamicACES2SourceSpace)
            } else if let transform = colorTransform,
                      let display = transform.display,
                      let view = transform.view {
                try? await applyDisplayTransform(from: transform.sourceColorSpace,
                                                 display: display, view: view)
            }
            return
        }

        // GPU path (both stills and movies): self.exposure is already updated above.
        // draw() reads the updated value on the very next display tick:
        //   • Movies:  inline compute pass in draw() — next decoded frame carries new exposure.
        //   • Stills:  MetalEDRImageView now uses the same inline compute path as movies;
        //              self.exposure is @Observable so SwiftUI calls updateNSView which sets
        //              needsDisplay = true, and draw() encodes compute+render in one submission.
        // No processTexture call, no async wait, no per-frame texture allocation.
    }


    /// Multiply every RGB channel by exp2(exposure). Alpha is left unchanged.
    /// Input data must be packed Float32 with `channels` values per pixel.
    private func applyExposureToPixelData(_ data: Data, channels: Int, exposure: Float) -> Data {
        guard exposure != 0 else { return data }
        let scale = exp2(exposure)
        var result = data
        result.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            let floats = ptr.bindMemory(to: Float.self)
            var i = 0
            while i + channels - 1 < floats.count {
                floats[i]     *= scale          // R
                floats[i + 1] *= scale          // G
                floats[i + 2] *= scale          // B
                // channel 3 (alpha) intentionally skipped
                i += channels
            }
        }
        return result
    }

    /// Get available color spaces from OCIO
    func availableColorSpaces() -> [String] {
        guard let config = ocioConfig else {
            return [] // No fallback - if OCIO isn't loaded, don't pretend we have color spaces
        }
        return config.colorSpaceNames()
    }

    /// Build a hierarchical tree of color spaces based on OCIO family paths.
    /// Family strings use '/' as a separator (e.g. "Input/ARRI"), producing nested menus.
    func colorSpaceFamilyTree() -> ColorSpaceFamilyNode {
        guard let config = ocioConfig else { return ColorSpaceFamilyNode(name: "Root") }
        let names = config.colorSpaceNames()

        let root = ColorSpaceFamilyNode(name: "Root")
        for name in names {
            let rawFamily = config.family(forColorSpace: name)
            let segments = rawFamily.isEmpty ? [] : rawFamily.split(separator: "/").map(String.init)
            root.insert(colorSpace: name, path: segments)
        }
        return root
    }
    
    /// Get available displays from OCIO
    func availableDisplays() -> [String] {
        guard let config = ocioConfig else {
            return [] // No displays without OCIO
        }
        return config.displayNames()
    }
    
    /// Get views for a specific display
    func views(for display: String) -> [String] {
        guard let config = ocioConfig else {
            return []
        }
        return config.viewNames(forDisplay: display)
    }
    
    /// Get the scene-linear color space from OCIO roles
    func sceneLinearColorSpace() -> String? {
        return ocioConfig?.sceneLinearColorSpace()
    }
    
    /// Get the default color space from OCIO roles
    func defaultColorSpace() -> String? {
        return ocioConfig?.defaultColorSpace()
    }
    
    /// Reload the bundled OCIO config, discarding any custom config that was loaded.
    /// After this call `loadedConfigPath` will point to the bundled file (or `nil`
    /// if the bundle is somehow missing).
    func revertToBundledOCIOConfig() async throws {
        guard let bundledPath = Bundle.main.path(
            forResource: "OCIO/studio-config-v4.0.0_aces-v2.0_ocio-v2.5",
            ofType: "ocio"
        ) else {
            // No bundled config — fall back to environment variable
            await MainActor.run {
                self.ocioConfig = OCIOConfig.default()
                self.loadedConfigPath = ProcessInfo.processInfo.environment["OCIO"]
            }
            return
        }
        // Reuse the existing loader so all the logging / display printing happens.
        try await loadOCIOConfig(from: bundledPath)
    }

    /// Load a custom OCIO config from a file path
    func loadOCIOConfig(from path: String) async throws {
        let fileManager = FileManager.default
        
        // Verify file exists and is readable
        guard fileManager.fileExists(atPath: path) else {
            throw ImageError.invalidPath
        }
        
        guard fileManager.isReadableFile(atPath: path) else {
            throw ImageError.fileNotReadable
        }
        
        // Try to load the config
        do {
            let config = try OCIOConfig(path: path)
            
            // Update on main actor
            await MainActor.run {
                self.ocioConfig = config
                self.loadedConfigPath = path
                
                print("✅ OpenColorIO config loaded successfully")
                print("📁 Config: \(path)")
                
                // Print available color spaces
                let colorSpaces = config.colorSpaceNames()
                print("🎨 Available color spaces: \(colorSpaces.count)")
                if colorSpaces.count > 0 {
                    print("   \(colorSpaces.prefix(10).joined(separator: ", "))")
                }
                
                // Print available displays
                let displays = config.displayNames()
                print("🖥️  Available displays: \(displays.joined(separator: ", "))")
                
                // Print role information
                if let sceneLinear = config.sceneLinearColorSpace() {
                    print("🎬 Scene-linear role: \(sceneLinear)")
                }
                if let defaultSpace = config.defaultColorSpace() {
                    print("📌 Default role: \(defaultSpace)")
                }
                
                let defaultDisplay = config.defaultDisplay()
                if !defaultDisplay.isEmpty {
                    print("🖥️  Default display: \(defaultDisplay)")
                    let defaultView = config.defaultView(forDisplay: defaultDisplay)
                    if !defaultView.isEmpty {
                        print("👁️  Default view: \(defaultView)")
                    }
                }
                
                // Re-apply transforms if image is loaded
                if let _ = self.currentImage {
                    print("🔄 Re-applying transforms with new config...")
                    // Note: The caller should handle re-initializing the pipeline
                }
            }
        } catch {
            throw ImageError.ocioConfigLoadFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Private Helpers
    
    /// Create a Metal texture from processed pixel data
    private func createMetalTexture(from data: Data, width: Int, height: Int, channels: Int) -> MTLTexture? {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, // Always use RGBA for Metal
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        textureDescriptor.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            return nil
        }
        
        // Metal textures are always RGBA, so bytesPerRow must match that
        let metalBytesPerRow = width * 4 * MemoryLayout<Float>.stride
        
        // If input data has fewer channels, we need to convert it
        if channels == 3 {
            // Convert RGB to RGBA by adding alpha channel
            var rgbaData = Data(count: width * height * 4 * MemoryLayout<Float>.stride)
            
            data.withUnsafeBytes { srcBytes in
                rgbaData.withUnsafeMutableBytes { dstBytes in
                    let src = srcBytes.bindMemory(to: Float.self)
                    let dst = dstBytes.bindMemory(to: Float.self)
                    
                    for i in 0..<(width * height) {
                        dst[i * 4 + 0] = src[i * 3 + 0] // R
                        dst[i * 4 + 1] = src[i * 3 + 1] // G
                        dst[i * 4 + 2] = src[i * 3 + 2] // B
                        dst[i * 4 + 3] = 1.0            // A
                    }
                }
            }
            
            rgbaData.withUnsafeBytes { bytes in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: bytes.baseAddress!,
                    bytesPerRow: metalBytesPerRow
                )
            }
        } else if channels == 4 {
            // Already RGBA, copy directly
            data.withUnsafeBytes { bytes in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: bytes.baseAddress!,
                    bytesPerRow: metalBytesPerRow
                )
            }
        } else {
            print("⚠️ Unsupported channel count: \(channels)")
            return nil
        }
        
        return texture
    }
}

enum ImageError: LocalizedError {
    case invalidURL
    case invalidPath
    case fileNotReadable
    case loadFailed
    case textureCreationFailed
    case noImageLoaded
    case ocioNotAvailable
    case ocioConfigLoadFailed(String)
    case gpuNotAvailable
    case gpuProcessingFailed
    case invalidInverseDisplayConfig
    case notImplemented
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL provided"
        case .invalidPath:
            return "Invalid file path"
        case .fileNotReadable:
            return "File exists but is not readable. Check file permissions."
        case .loadFailed:
            return "Failed to load image"
        case .textureCreationFailed:
            return "Failed to create Metal texture"
        case .noImageLoaded:
            return "No image is currently loaded"
        case .ocioNotAvailable:
            return "OpenColorIO is not available"
        case .ocioConfigLoadFailed(let details):
            return "Failed to load OCIO config: \(details)"
        case .gpuNotAvailable:
            return "GPU processor is not available"
        case .gpuProcessingFailed:
            return "GPU processing failed"
        case .invalidInverseDisplayConfig:
            return "Inverse display mode requires both display and view to be selected"
        case .notImplemented:
            return "Feature not yet implemented"
        }
    }
}
