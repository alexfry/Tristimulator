//
//  ImageDocument.swift
//  Tristimulator
//
//  Created by Alex Fry on 3/6/2026.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import simd

/// Which color channel (if any) to solo in the viewport.
/// Applied in scene-linear space, after exposure and before the display transform.
enum ChannelMode: String, CaseIterable {
    case normal, red, green, blue, alpha, luminance

    /// Channel isolation mask passed to the shader as a float4.
    /// xyz = RGB dot weights (used when w == 0).
    /// w == 1 signals "show alpha replicated to RGB".
    var mask: SIMD4<Float> {
        switch self {
        case .normal:    return SIMD4<Float>(1, 1, 1, 0)
        case .red:       return SIMD4<Float>(1, 0, 0, 0)
        case .green:     return SIMD4<Float>(0, 1, 0, 0)
        case .blue:      return SIMD4<Float>(0, 0, 1, 0)
        case .alpha:     return SIMD4<Float>(0, 0, 0, 1)
        case .luminance: return SIMD4<Float>(1.0/3.0, 1.0/3.0, 1.0/3.0, 0)
        }
    }
}

class ImageDocument: ReferenceFileDocument, ObservableObject {

    // MARK: - Readable content types
    // Mirrors the UTImportedTypeDeclarations + CFBundleDocumentTypes in Info.plist.
    // System UTIs use static UTType constants or string identifiers;
    // custom UTIs (declared in Info.plist) use UTType(importedAs:).
    static var readableContentTypes: [UTType] = {
        var types: [UTType] = [
            // ── Standard system UTIs ──────────────────────────────────────────
            .png, .jpeg, .tiff, .bmp, .gif,
            .heic, .heif,
            .webP,
            // PSD/Photoshop
            UTType("com.adobe.photoshop-image")!,
            // Targa
            UTType("com.truevision.tga-image")!,
            // SGI / RGB
            UTType("com.sgi.sgi-image")!,
            // ICO
            UTType("com.microsoft.ico")!,
            // JPEG-2000
            UTType("public.jpeg-2000")!,
            // Portable bitmap family (PBM / PPM / PGM / PNM)
            UTType("public.pbm")!,

            // ── Custom UTIs declared in Info.plist (UTImportedTypeDeclarations) ──
            // VFX / Film
            UTType(importedAs: "com.ilm.openexr-image"),         // EXR
            UTType(importedAs: "com.smpte.dpx-image"),           // DPX
            UTType(importedAs: "com.kodak.cineon-image"),         // Cineon
            UTType(importedAs: "com.radiance.hdr-image"),         // HDR / RGBE
            UTType(importedAs: "com.autodesk.iff-image"),         // IFF (Maya)
            UTType(importedAs: "com.autodesk.rla-image"),         // RLA
            UTType(importedAs: "com.softimage.pic-image"),        // Softimage PIC
            // TIFF texture variants (.tx / .env / .sm / .vsm)
            UTType(importedAs: "com.alexanderfry.tristimulator.tiff-texture"),
            // Textures
            UTType(importedAs: "com.microsoft.directdraw-surface"), // DDS
            // Float / bitmap
            UTType(importedAs: "com.netpbm.pfm-image"),           // PFM
            // Modern
            UTType(importedAs: "public.jxl"),                     // JPEG XL
            // Scientific
            UTType(importedAs: "edu.fits.fits-image"),            // FITS
            UTType(importedAs: "org.dcm4che.dicom-image"),        // DICOM

            // CLF / Common LUT Format
            UTType(importedAs: "org.acescentral.clf"),             // CLF

            // ACES Metadata File (sidecar / standalone)
            UTType(importedAs: "com.ampas.aces-metadata-file"),   // AMF

            // ── Movie / video formats (opened via AVFoundation) ───────────────
            .quickTimeMovie,    // com.apple.quicktime-movie  (.mov)
            .mpeg4Movie,        // public.mpeg-4              (.mp4, .m4v)
            .movie,             // public.movie               (generic fallback)
        ]
        return types
    }()
    
    // Per-document state - moved from ContentView
    @Published var imageManager = ImageManager()

    /// Non-nil when the open document is a movie file rather than a still image.
    /// Created and owned here so the MovieSource lifetime matches the document.
    @Published var movieSource: MovieSource? = nil

    /// Non-nil when the open document is an image sequence.
    /// Mutually exclusive with `movieSource` — only one can be non-nil at a time.
    @Published var sequenceSource: ImageSequenceSource? = nil

    /// Stable `ImageData` snapshot from the first decoded sequence frame.
    /// Passed to `SequenceControlsView` so the info row doesn't re-render every frame.
    @Published var sequenceImageData: ImageData? = nil

    /// The currently selected EXR layer.  Empty string means the default/unnamed RGBA layer.
    @Published var selectedEXRLayer: String = ""

    @Published var channelMode: ChannelMode = .normal

    @Published var showScopes = false
    @Published var selectedScope: ScopeType = .histogram
    @Published var showPipelinePopover = false

    /// Stable UUID identifying this window's OCIO settings slot.
    /// • Primary windows: re-generated each launch (settings are keyed by file path).
    /// • Extra (duplicate) windows: assigned persistently so settings survive restarts.
    var windowID: String = UUID().uuidString

    /// `true` for windows opened via "New Window for This Image"; `false` for
    /// the primary window opened by the document system.  Extra windows store
    /// their OCIO settings keyed by `windowID` rather than by file path.
    var isExtraWindow: Bool = false
    
    // Track image load count to detect when new images are loaded
    @Published var imageLoadCount = 0
    
    // Shared color pipeline state
    @Published var selectedSourceSpace = ""
    @Published var selectedDestSpace = ""
    @Published var selectedDisplay = ""
    @Published var selectedView = ""
    @Published var selectedMetalColorSpace = "extendedDisplayP3"
    
    // Track if transforms have been applied
    @Published var hasAppliedTransforms = false
    
    // Zoom level state
    @Published var zoomLevel: CGFloat = 1.0
    /// True when the image is in auto-fit (zoom-to-fit) mode.
    @Published var isAutoFitZoom: Bool = true
    /// Scroll origin in manual zoom mode; stored for persistence.
    var panOffset: CGPoint = .zero
    /// Restored zoom level to pass to ZoomableImageView on initial display.
    /// Consumed once — set to nil after initial use.
    var restoredManualZoom: CGFloat? = nil
    /// Restored pan offset to pass to ZoomableImageView on initial display.
    var restoredPanOffset: CGPoint? = nil
    
    // Full-screen state
    @Published var isFullScreen = false
    @Published var showInfoBarInFullScreen = true
    @Published var showToolbarInFullScreen = true
    var hideInfoBarTask: Task<Void, Never>?
    var hideToolbarTask: Task<Void, Never>?
    
    // EDR info popover
    @Published var showEDRInfoPopover = false
    /// Per-channel RGBA maximum measured from the drawable after opening the
    /// HDR popover.  Nil until the first measurement completes.
    @Published var peakPixelResult: SIMD4<Float>? = nil

    // EDR status monitoring
    @Published var isHDRAvailable = false
    var edrCheckTimer: Timer?
    
    // File URL for reference
    var fileURL: URL?
    
    init() {
        // Empty document for new windows
    }
    
    required init(configuration: ReadConfiguration) throws {
        // The file URL is stored in the configuration's file
        // For a document-based app, we need to extract it properly
        
        // FileWrapper can contain the URL via the filename property
        // But for a document being opened, we should use the fileURL from the configuration
        // Since ReadConfiguration doesn't directly expose the URL, we'll need to handle it differently
        
        // Store the filename temporarily - the actual URL will be set when the document is opened
        if let filename = configuration.file.filename {
            // This is just the filename, not the full path
            // The view will need to handle getting the actual file URL
            print("📄 Document init with filename: \(filename)")
        }
        
        // Note: Actual image loading happens after init in the view's onAppear
        // The view will get the proper file URL from the DocumentGroup's file parameter
    }
    
    func snapshot(contentType: UTType) throws -> Data {
        // For read-only document, return empty data
        // Could implement saving processed images here in the future
        return Data()
    }
    
    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: snapshot)
    }
    
    // MARK: - Helper Methods
    
    func loadImageFromFile() async throws {
        guard let url = fileURL else {
            throw NSError(domain: "ImageDocument", code: 1, userInfo: [NSLocalizedDescriptionKey: "No file URL available"])
        }
        
        try await imageManager.loadImage(from: url)
        await MainActor.run {
            imageLoadCount += 1
        }
    }

    // MARK: - OCIO pipeline application

    /// Apply the current OCIO pipeline (source→working-space color transform, then
    /// the display/view or Dynamic ACES2 output transform) to whatever is sitting in
    /// `imageManager.originalImageData`.
    ///
    /// This is the shared entry point used by both:
    ///  • `DocumentContentView.applyColorTransformAndReapplyDisplay()` for still images
    ///  • The `MovieSource.onFrame` callback for each incoming video frame
    /// Apply the AMF sidecar's colour pipeline to the current image using the current
    /// OCIO settings as fallbacks when transform IDs cannot be auto-mapped.
    func applyAMFPipeline() {
        let sourceSpace = selectedSourceSpace
        let display     = selectedDisplay
        let view        = selectedView
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.imageManager.applyAMFPipeline(
                    sourceSpace: sourceSpace,
                    display: display,
                    view: view)
                self.hasAppliedTransforms = true
            } catch {
                print("❌ [AMF] applyAMFPipeline: \(error.localizedDescription)")
            }
        }
    }

    func applyCurrentOCIOTransform() {
        let sourceSpace = selectedSourceSpace
        guard !sourceSpace.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.imageManager.dynamicACES2Mode {
                do {
                    try await self.imageManager.applyDynamicACES2Transform(sourceSpace: sourceSpace)
                } catch {
                    print("❌ [OCIOTransform] applyDynamicACES2Transform: \(error)")
                }
                return
            }
            guard !self.selectedDisplay.isEmpty, !self.selectedView.isEmpty else { return }
            do {
                try await self.imageManager.applyDisplayTransform(from: sourceSpace,
                                                                  display: self.selectedDisplay,
                                                                  view: self.selectedView)
            } catch {
                print("❌ [OCIOTransform] applyDisplayTransform: \(error)")
            }
        }
    }
    
    func checkEDRStatus() {
        let maxPotential = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let newHDRStatus = maxPotential > 1.0
        
        // Only update if status changed to avoid unnecessary UI updates
        if newHDRStatus != isHDRAvailable {
            isHDRAvailable = newHDRStatus
            print("🖥️ EDR status changed: \(isHDRAvailable ? "HDR" : "SDR") (Max: \(String(format: "%.1f", maxPotential))x)")
        }
    }
    
    func startEDRMonitoring() {
        checkEDRStatus()
        
        edrCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkEDRStatus()
        }
    }
    
    func stopEDRMonitoring() {
        edrCheckTimer?.invalidate()
        edrCheckTimer = nil
    }
}
