//
//  OCIOSettingsStore.swift
//  Tristimulator
//
//  Central store for OCIO pipeline settings.
//
//  • Global defaults are stored in UserDefaults and applied to any image
//    that hasn't been opened before.
//  • Per-image settings are stored in a JSON file under
//    ~/Library/Application Support/Tristimulator/color-settings.json
//    keyed by the image's absolute file path.
//  • Both layers can be exported / imported as portable JSON.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Settings model

/// A snapshot of the full OCIO color pipeline configuration for one image session.
struct OCIOPipelineSettings: Codable, Equatable {
    var sourceSpace:        String
    var destSpace:          String
    var display:            String
    var view:               String
    var metalColorSpace:    String
    var useCPURenderPath:   Bool
    var exposure:           Float
    var lastOpened:         Date
    var dynamicACES2Mode:        Bool
    var dynamicACES2AutoNits:     Bool
    var dynamicACES2Gamut:       ACES2Gamut
    var dynamicACES2TargetNits:  Float
    /// Absolute path to the OCIO config that was active when these settings were saved.
    /// `nil` means the bundled built-in config.
    var ocioConfigPath:     String?
    /// Source transform mode: colorspace or inverse display
    var sourceTransformMode:    SourceTransformMode
    /// Display name for inverse display mode
    var sourceInverseDisplay:   String
    /// View name for inverse display mode
    var sourceInverseView:      String

    // MARK: - View state persistence
    /// Current frame index for image sequences, or -1 / nil if not applicable.
    var currentFrameIndex:      Int?
    /// Current playback time in seconds for movies, or nil if not applicable.
    var currentTime:            Double?
    /// Selected EXR layer name. Empty string means the default layer.
    var selectedEXRLayer:       String?
    /// Zoom magnification level. nil means auto-fit mode.
    var zoomLevel:              Double?
    /// Pan offset (scroll origin) when in manual zoom mode.
    var panX:                   Double?
    var panY:                   Double?
    /// Channel isolation mode (normal, red, green, blue, alpha, luminance).
    var channelMode:            String?

    // MARK: - AMF look toggle persistence
    /// Per-look enable state for the AMF Look Transforms node, keyed by
    /// `AMFLookToggleState.keys(for:)`. `nil` when the image had no AMF or the
    /// settings predate AMF toggle persistence.
    var amfLookStates:          [String: Bool]?
    /// Node-level master switch for the AMF Look Transforms node. `nil` = default (on).
    var amfLooksGloballyEnabled: Bool?

    // MARK: - Scope overlay persistence
    /// Which scope overlays were open, where they sat and their stacking order.
    /// `nil` when the settings predate scope persistence (scopes keep their defaults).
    var scopeLayout:            ScopeLayoutState?

    // MARK: - Window frame persistence
    /// Main window frame (screen coordinates) when this image was last shown
    /// windowed. `nil` when never saved (the window keeps its default frame).
    var windowFrame:            WindowFrame?

    init(
        sourceSpace:             String              = "",
        destSpace:               String              = "",
        display:                 String              = "",
        view:                    String              = "",
        metalColorSpace:         String              = "extendedDisplayP3",
        useCPURenderPath:        Bool                = false,
        exposure:                Float               = 0,
        lastOpened:              Date                = .init(),
        dynamicACES2Mode:        Bool                = true,
        dynamicACES2AutoNits:     Bool                = true,
        dynamicACES2Gamut:       ACES2Gamut          = .p3d65,
        dynamicACES2TargetNits:  Float               = 1000.0,
        ocioConfigPath:          String?             = nil,
        sourceTransformMode:     SourceTransformMode = .colorspace,
        sourceInverseDisplay:    String              = "",
        sourceInverseView:       String              = "",
        currentFrameIndex:       Int?                = nil,
        currentTime:             Double?             = nil,
        selectedEXRLayer:        String?             = nil,
        zoomLevel:               Double?             = nil,
        panX:                    Double?             = nil,
        panY:                    Double?             = nil,
        channelMode:             String?             = nil,
        amfLookStates:           [String: Bool]?     = nil,
        amfLooksGloballyEnabled: Bool?               = nil,
        scopeLayout:             ScopeLayoutState?   = nil,
        windowFrame:             WindowFrame?        = nil
    ) {
        self.sourceSpace             = sourceSpace
        self.destSpace               = destSpace
        self.display                 = display
        self.view                    = view
        self.metalColorSpace         = metalColorSpace
        self.useCPURenderPath        = useCPURenderPath
        self.exposure                = exposure
        self.lastOpened              = lastOpened
        self.dynamicACES2Mode        = dynamicACES2Mode
        self.dynamicACES2AutoNits     = dynamicACES2AutoNits
        self.dynamicACES2Gamut       = dynamicACES2Gamut
        self.dynamicACES2TargetNits  = dynamicACES2TargetNits
        self.ocioConfigPath          = ocioConfigPath
        self.sourceTransformMode     = sourceTransformMode
        self.sourceInverseDisplay    = sourceInverseDisplay
        self.sourceInverseView       = sourceInverseView
        self.currentFrameIndex       = currentFrameIndex
        self.currentTime             = currentTime
        self.selectedEXRLayer        = selectedEXRLayer
        self.zoomLevel               = zoomLevel
        self.panX                    = panX
        self.panY                    = panY
        self.channelMode             = channelMode
        self.amfLookStates           = amfLookStates
        self.amfLooksGloballyEnabled = amfLooksGloballyEnabled
        self.scopeLayout             = scopeLayout
        self.windowFrame             = windowFrame
    }

    // Custom decoder for backward compatibility with existing JSON files
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceSpace            = try c.decode(String.self,             forKey: .sourceSpace)
        destSpace              = try c.decode(String.self,             forKey: .destSpace)
        display                = try c.decode(String.self,             forKey: .display)
        view                   = try c.decode(String.self,             forKey: .view)
        metalColorSpace        = try c.decode(String.self,             forKey: .metalColorSpace)
        useCPURenderPath       = try c.decode(Bool.self,               forKey: .useCPURenderPath)
        exposure               = try c.decode(Float.self,              forKey: .exposure)
        lastOpened             = try c.decode(Date.self,               forKey: .lastOpened)
        dynamicACES2Mode       = try c.decode(Bool.self,               forKey: .dynamicACES2Mode)
        dynamicACES2AutoNits   = try c.decode(Bool.self,               forKey: .dynamicACES2AutoNits)
        dynamicACES2Gamut      = try c.decode(ACES2Gamut.self,         forKey: .dynamicACES2Gamut)
        dynamicACES2TargetNits = try c.decode(Float.self,              forKey: .dynamicACES2TargetNits)
        ocioConfigPath         = try c.decodeIfPresent(String.self,    forKey: .ocioConfigPath)
        sourceTransformMode    = try c.decodeIfPresent(SourceTransformMode.self, forKey: .sourceTransformMode) ?? .colorspace
        sourceInverseDisplay   = try c.decodeIfPresent(String.self,    forKey: .sourceInverseDisplay) ?? ""
        sourceInverseView      = try c.decodeIfPresent(String.self,    forKey: .sourceInverseView) ?? ""
        currentFrameIndex      = try c.decodeIfPresent(Int.self,       forKey: .currentFrameIndex)
        currentTime            = try c.decodeIfPresent(Double.self,    forKey: .currentTime)
        selectedEXRLayer       = try c.decodeIfPresent(String.self,    forKey: .selectedEXRLayer)
        zoomLevel              = try c.decodeIfPresent(Double.self,    forKey: .zoomLevel)
        panX                   = try c.decodeIfPresent(Double.self,    forKey: .panX)
        panY                   = try c.decodeIfPresent(Double.self,    forKey: .panY)
        channelMode            = try c.decodeIfPresent(String.self,    forKey: .channelMode)
        amfLookStates          = try c.decodeIfPresent([String: Bool].self, forKey: .amfLookStates)
        amfLooksGloballyEnabled = try c.decodeIfPresent(Bool.self,     forKey: .amfLooksGloballyEnabled)
        // A malformed scope layout should never cost the user their colour settings.
        scopeLayout            = try? c.decodeIfPresent(ScopeLayoutState.self, forKey: .scopeLayout)
        // Likewise a malformed window frame is simply ignored.
        windowFrame            = try? c.decodeIfPresent(WindowFrame.self, forKey: .windowFrame)
    }
}

// MARK: - On-disk / export document

/// Codable representation of an NSRect for window frame persistence.
struct WindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: NSRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width  = Double(rect.size.width)
        height = Double(rect.size.height)
    }

    var nsRect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}

/// Identifies an extra (duplicate) window that should be reopened on the next launch,
/// preserving its independent OCIO settings via a stable `windowID`.
struct ExtraWindowRecord: Codable, Equatable {
    /// Stable UUID assigned to this window's `ImageDocument.windowID`.
    var windowID: String
    /// Absolute file path shown in this window.
    var filePath: String
    /// Last known frame of this window (screen coordinates). `nil` on first use.
    var savedFrame: WindowFrame?
    /// Index in `NSApp.orderedWindows` at quit time (0 = frontmost).
    /// Used to restore the relative z-order of extra windows on relaunch.
    var zOrderIndex: Int?
}

/// The top-level JSON structure written to disk and used for export.
struct OCIOSettingsDocument: Codable {
    var version:             Int                              = 1
    var exportDate:          Date                             = .init()
    var globalDefaults:      OCIOPipelineSettings
    /// Path to a custom .ocio config file; `nil` means the bundled config is used.
    var customConfigPath:    String?
    /// Map from absolute image file path → saved pipeline settings (primary windows).
    var images:              [String: OCIOPipelineSettings]   = [:]
    /// Map from window UUID → saved pipeline settings (extra/duplicate windows).
    var windows:             [String: OCIOPipelineSettings]   = [:]
    /// Extra (duplicate) windows that should be reopened on the next launch.
    var extraWindowRecords:  [ExtraWindowRecord]              = []
    /// Legacy field — kept for migration from older JSON files that stored just paths.
    var extraWindowPaths:    [String]                         = []
}

// MARK: - Store

/// Singleton that owns all persistent OCIO pipeline settings for Tristimulator.
///
/// Usage:
/// ```swift
/// // Restore settings for last opened image
/// if let s = OCIOSettingsStore.shared.settings(for: imageURL) { ... }
///
/// // Save after any pipeline change
/// OCIOSettingsStore.shared.save(currentSettings, for: imageURL)
/// OCIOSettingsStore.shared.saveAsGlobalDefaults(currentSettings)
///
/// // Export / Import
/// try OCIOSettingsStore.shared.exportJSON(to: exportURL)
/// try OCIOSettingsStore.shared.importJSON(from: importURL)
/// ```
@Observable
final class OCIOSettingsStore {

    // MARK: Shared instance
    static let shared = OCIOSettingsStore()

    // MARK: Observed state
    private(set) var globalDefaults:      OCIOPipelineSettings
    /// Path to a custom OCIO config file; `nil` → bundled config.
    private(set) var customConfigPath:    String?
    /// Extra windows that should be reopened on launch, keyed by stable windowID.
    private(set) var extraWindowRecords:  [ExtraWindowRecord] = []
    // MARK: Private indices
    private var imageIndex:  [String: OCIOPipelineSettings] = [:]
    private var windowIndex: [String: OCIOPipelineSettings] = [:]

    // MARK: Init
    private init() {
        globalDefaults   = Self.loadGlobalDefaultsFromUserDefaults()
        customConfigPath = UserDefaults.standard.string(forKey: UDKeys.customConfigPath)
        let doc          = Self.loadDocument()
        imageIndex       = doc.images
        windowIndex      = doc.windows
        // Migrate legacy extraWindowPaths into ExtraWindowRecord entries.
        if !doc.extraWindowRecords.isEmpty {
            extraWindowRecords = doc.extraWindowRecords
        } else {
            extraWindowRecords = doc.extraWindowPaths.map {
                ExtraWindowRecord(windowID: UUID().uuidString, filePath: $0)
            }
        }
    }

    // MARK: - Per-image API

    /// Return the saved pipeline settings for the given image URL, or `nil`
    /// if this image hasn't been opened before.
    /// Checks the exact path first, then falls back to a sequence-level key
    /// so that all frames in a numbered sequence share settings.
    func settings(for url: URL) -> OCIOPipelineSettings? {
        let exact = url.resolvingSymlinksInPath().path
        if let hit = imageIndex[exact] { return hit }
        return imageIndex[Self.sequenceKey(for: url)]
    }

    /// Persist the pipeline settings for an image URL and flush to disk.
    /// Uses a sequence-level key (frame number replaced with `*`) so that
    /// all frames in a numbered sequence share the same entry.
    func save(_ settings: OCIOPipelineSettings, for url: URL) {
        var s = settings
        s.lastOpened = Date()
        let seqKey = Self.sequenceKey(for: url)
        let exact  = url.resolvingSymlinksInPath().path
        if seqKey != exact { imageIndex.removeValue(forKey: exact) }
        imageIndex[seqKey] = s
        saveImageIndex()
    }

    /// Derive a sequence-level key from a frame URL.
    /// e.g. `/path/to/shot.0042.exr` → `/path/to/shot.*.exr`
    /// If the filename has no trailing digits the full path is returned unchanged.
    static func sequenceKey(for url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath()
        let dir  = resolved.deletingLastPathComponent().path
        let ext  = resolved.pathExtension
        let stem = resolved.deletingPathExtension().lastPathComponent
        let trailingDigits = stem.reversed().prefix(while: { $0.isNumber })
        guard !trailingDigits.isEmpty else { return resolved.path }
        let prefix = String(stem.dropLast(trailingDigits.count))
        return "\(dir)/\(prefix)*.\(ext)"
    }

    // MARK: - Global defaults API

    /// Persist `settings` as the new global defaults (applied to images opened
    /// for the first time). Also flushes the index.
    func saveAsGlobalDefaults(_ settings: OCIOPipelineSettings) {
        // The window frame belongs to one image; new images keep their default frame.
        var settings = settings
        settings.windowFrame = nil
        globalDefaults = settings
        Self.saveGlobalDefaultsToUserDefaults(settings)
        saveImageIndex()
    }

    /// Persist (or clear) the path to a custom OCIO config file.
    func saveCustomConfigPath(_ path: String?) {
        customConfigPath = path
        UserDefaults.standard.set(path, forKey: UDKeys.customConfigPath)
        saveImageIndex()
    }

    // MARK: - Pending extra-window staging

    /// Holds a (windowID, filePath) pair staged by AppDelegate immediately before
    /// it calls `NSDocumentController.makeDocument`.  `DocumentContentView`
    /// consumes it in `handleOnAppear` so the new window claims the right
    /// per-window OCIO settings bucket.  The value is cleared on consumption.
    private(set) var pendingExtraWindow: (windowID: String, filePath: String)? = nil

    /// Stage a (windowID, filePath) pair for the next extra window being created.
    func stagePendingExtraWindow(windowID: String, filePath: String) {
        pendingExtraWindow = (windowID: windowID, filePath: filePath)
    }

    /// Consume and clear the staged pending-window info (call once from the new
    /// window's `handleOnAppear`).
    func consumePendingExtraWindow() -> (windowID: String, filePath: String)? {
        let value = pendingExtraWindow
        pendingExtraWindow = nil
        return value
    }

    // MARK: - Per-window API

    /// Return the saved pipeline settings for a specific window, or `nil` if unknown.
    func settings(forWindow windowID: String) -> OCIOPipelineSettings? {
        windowIndex[windowID]
    }

    /// Persist pipeline settings keyed by the window's stable UUID.
    func save(_ settings: OCIOPipelineSettings, forWindow windowID: String) {
        var s = settings
        s.lastOpened = Date()
        windowIndex[windowID] = s
        saveImageIndex()
    }

    /// Remove settings for a window (call when the extra window is permanently closed).
    func removeWindowSettings(_ windowID: String) {
        if windowIndex.removeValue(forKey: windowID) != nil {
            saveImageIndex()
        }
    }

    // MARK: - Extra window API

    /// Record that an extra window (identified by `windowID`) for `url` should be
    /// reopened on the next launch.
    func addExtraWindow(windowID: String, for url: URL) {
        let path = url.resolvingSymlinksInPath().path
        extraWindowRecords.append(ExtraWindowRecord(windowID: windowID, filePath: path))
        saveImageIndex()
    }

    /// Remove the extra-window record for `windowID` (call when the window closes
    /// so it won't be reopened on the next launch).
    func removeExtraWindow(windowID: String) {
        if let idx = extraWindowRecords.firstIndex(where: { $0.windowID == windowID }) {
            extraWindowRecords.remove(at: idx)
            saveImageIndex()
        }
    }

    /// Persist the on-screen frame of an extra window so it can be restored
    /// after a relaunch.  Call this in `applicationWillTerminate`.
    func updateWindowFrame(windowID: String, frame: NSRect) {
        if let idx = extraWindowRecords.firstIndex(where: { $0.windowID == windowID }) {
            extraWindowRecords[idx].savedFrame = WindowFrame(frame)
            saveImageIndex()
        }
    }

    /// Persist the z-order index of an extra window (index in `NSApp.orderedWindows`
    /// where 0 = frontmost).  Batched with `updateWindowFrame` at quit time
    /// so only one disk write is needed — call `updateWindowAppearance` instead.
    func updateWindowZOrder(windowID: String, zOrderIndex: Int) {
        if let idx = extraWindowRecords.firstIndex(where: { $0.windowID == windowID }) {
            extraWindowRecords[idx].zOrderIndex = zOrderIndex
            // No saveImageIndex here — call updateWindowAppearance for a single write.
        }
    }

    /// Single-write helper that saves both frame and z-order for one extra window.
    /// Call once per window in `applicationWillTerminate` to avoid N disk writes.
    func updateWindowAppearance(windowID: String, frame: NSRect, zOrderIndex: Int) {
        if let idx = extraWindowRecords.firstIndex(where: { $0.windowID == windowID }) {
            extraWindowRecords[idx].savedFrame  = WindowFrame(frame)
            extraWindowRecords[idx].zOrderIndex = zOrderIndex
        }
        // Caller is responsible for calling saveImageIndex() once for the batch.
    }

    /// Flush all pending appearance changes to disk.  Call after the
    /// `updateWindowAppearance` loop finishes in `applicationWillTerminate`.
    func flushAppearanceChanges() {
        saveImageIndex()
    }

    // MARK: - Export / Import

    /// Write the full index + global defaults to `url` as pretty-printed JSON.
    func exportJSON(to url: URL) throws {
        let doc = OCIOSettingsDocument(
            exportDate:          Date(),
            globalDefaults:      globalDefaults,
            customConfigPath:    customConfigPath,
            images:              imageIndex,
            windows:             windowIndex,
            extraWindowRecords:  extraWindowRecords
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting   = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(doc)
        try data.write(to: url, options: .atomic)
    }

    /// Read an exported JSON file and merge (or replace) the current index.
    ///
    /// - Parameters:
    ///   - url:     The `.json` file previously exported by the app.
    ///   - merging: `true` (default) merges imported entries in.
    ///              `false` replaces the entire index.
    func importJSON(from url: URL, merging: Bool = true) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(OCIOSettingsDocument.self, from: data)

        if merging {
            for (key, value) in doc.images   { imageIndex[key]  = value }
            for (key, value) in doc.windows  { windowIndex[key] = value }
        } else {
            imageIndex  = doc.images
            windowIndex = doc.windows
        }
        globalDefaults   = doc.globalDefaults
        customConfigPath = doc.customConfigPath
        Self.saveGlobalDefaultsToUserDefaults(doc.globalDefaults)
        UserDefaults.standard.set(doc.customConfigPath, forKey: UDKeys.customConfigPath)
        saveImageIndex()
    }

    // MARK: - File URL for on-disk index

    static var indexFileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Tristimulator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("color-settings.json")
    }

    // MARK: - Private persistence

    private static func loadDocument() -> OCIOSettingsDocument {
        let url = indexFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return OCIOSettingsDocument(globalDefaults: loadGlobalDefaultsFromUserDefaults())
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Try full document first (current format), fall back to raw dict (legacy).
        if let doc  = try? decoder.decode(OCIOSettingsDocument.self, from: data) { return doc }
        // Legacy: plain dictionary of settings (no wrapper)
        if let dict = try? decoder.decode([String: OCIOPipelineSettings].self, from: data) {
            return OCIOSettingsDocument(globalDefaults: loadGlobalDefaultsFromUserDefaults(), images: dict)
        }
        return OCIOSettingsDocument(globalDefaults: loadGlobalDefaultsFromUserDefaults())
    }

    private func saveImageIndex() {
        let doc = OCIOSettingsDocument(
            exportDate:          Date(),
            globalDefaults:      globalDefaults,
            customConfigPath:    customConfigPath,
            images:              imageIndex,
            windows:             windowIndex,
            extraWindowRecords:  extraWindowRecords
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting     = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(doc) {
            try? data.write(to: Self.indexFileURL, options: .atomic)
        }
    }

    // MARK: - UserDefaults keys
    private enum UDKeys {
        static let destSpace        = "ocio.defaultDestSpace"
        static let display          = "ocio.defaultDisplay"
        static let view             = "ocio.defaultView"
        static let metalColorSpace  = "ocio.defaultMetalColorSpace"
        static let useCPURenderPath = "ocio.defaultUseCPURenderPath"
        static let customConfigPath = "ocio.customConfigPath"
    }

    private static func loadGlobalDefaultsFromUserDefaults() -> OCIOPipelineSettings {
        let ud = UserDefaults.standard
        return OCIOPipelineSettings(
            // sourceSpace deliberately excluded — it's image-specific, not a global default
            destSpace:        ud.string(forKey: UDKeys.destSpace)       ?? "",
            display:          ud.string(forKey: UDKeys.display)         ?? "",
            view:             ud.string(forKey: UDKeys.view)            ?? "",
            metalColorSpace:  ud.string(forKey: UDKeys.metalColorSpace) ?? "extendedDisplayP3",
            useCPURenderPath: ud.bool(forKey:   UDKeys.useCPURenderPath)
        )
    }

    private static func saveGlobalDefaultsToUserDefaults(_ settings: OCIOPipelineSettings) {
        let ud = UserDefaults.standard
        ud.set(settings.destSpace,        forKey: UDKeys.destSpace)
        ud.set(settings.display,          forKey: UDKeys.display)
        ud.set(settings.view,             forKey: UDKeys.view)
        ud.set(settings.metalColorSpace,  forKey: UDKeys.metalColorSpace)
        ud.set(settings.useCPURenderPath, forKey: UDKeys.useCPURenderPath)
    }
}
