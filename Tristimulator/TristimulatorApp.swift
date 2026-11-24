//
//  TristimulatorApp.swift
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

import SwiftUI
import UniformTypeIdentifiers

@main
struct TristimulatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showAbout = false
    @AppStorage(TristimulatorDefaults.scopesScaleWithWindow) private var scopesScaleWithWindow = false
    
    var body: some Scene {
        // Document-based app - each image gets its own window
        DocumentGroup(viewing: ImageDocument.self) { file in
            DocumentContentView(document: file.document, fileURL: file.fileURL)
        }
        .windowToolbarStyle(.unified)
        // Enable automatic state restoration
        .defaultAppStorage(UserDefaults.standard)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Tristimulator") {
                    showAbout = true
                    NSApp.activate(ignoringOtherApps: true)
                    let controller = NSHostingController(rootView: AboutView())
                    let window = NSWindow(contentViewController: controller)
                    window.title = "About Tristimulator"
                    window.styleMask = [.titled, .closable]
                    window.isReleasedWhenClosed = false
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                }
            }

            // Remove CommandGroup(replacing: .newItem) - document apps handle File > Open automatically

            // "New Window" lets you open the same image in a second window with
            // different OCIO settings.  Placed after the standard New/Open items.
            CommandGroup(after: .newItem) {
                Button("New Window for This Image") {
                    NotificationCenter.default.post(name: .newWindow, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .help("Open this image in a new window with independent OCIO settings")

                Button("Load AMF…") {
                    NotificationCenter.default.post(name: .loadAMF, object: NSApp.keyWindow)
                }
                .help("Load an ACES Metadata File (AMF) sidecar and apply its looks to the current image")
            }
            
            // Appended to the standard group, not replacing it: that group also holds
            // Close, Open Recent and Share. The save, rename and move commands in it are removed by
            // AppDelegate.removeSaveCommands().
            CommandGroup(after: .saveItem) {
                Button("Export Gain Map Image…") {
                    NotificationCenter.default.post(name: .exportGainMapImage, object: NSApp.keyWindow)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .help("Export OCIO-processed image as JPEG or HEIC with HDR gain map")
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Copy Image") {
                    NotificationCenter.default.post(name: .copyImage, object: NSApp.keyWindow)
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Copy Image (Native Colorspace)") {
                    NotificationCenter.default.post(name: .copyImageNative, object: NSApp.keyWindow)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Button("Enter Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .zoomIn, object: NSApp.keyWindow)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOut, object: NSApp.keyWindow)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Zoom to Fit") {
                    NotificationCenter.default.post(name: .zoomToFit, object: NSApp.keyWindow)
                }
                .keyboardShortcut("9", modifiers: .command)

                Button("Fit") {
                    NotificationCenter.default.post(name: .zoomToFit, object: NSApp.keyWindow)
                }
                .keyboardShortcut("f", modifiers: [])

                Button("Actual Size") {
                    NotificationCenter.default.post(name: .zoomActualSize, object: NSApp.keyWindow)
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("Toggle CIE 1931 Yxy") {
                    NotificationCenter.default.post(name: .toggleScopes, object: NSApp.keyWindow)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Toggle CIE 1976 u\u{2032}v\u{2032}") {
                    NotificationCenter.default.post(name: .toggleUCS, object: NSApp.keyWindow)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Toggle JMh") {
                    NotificationCenter.default.post(name: .toggleJmh, object: NSApp.keyWindow)
                }
                .keyboardShortcut("3", modifiers: .command)

                Toggle("Scale Scopes with Window", isOn: $scopesScaleWithWindow)
            }

            // Shader-baking commands. The menu item stays in the menu bar so it
            // can be shown or hidden without rebuilding the SwiftUI command
            // tree; AppDelegate hides it unless ShowDebugMenu is on or Option
            // is held.
            CommandMenu("Debug") {
                Button("Bake QuickLook Shader") {
                    ShaderBaker.bake()
                }
                Button("Bake Inverse sRGB Shader") {
                    ShaderBaker.bakeInverse()
                }
            }

            CommandMenu("Playback") {
                Button("Play / Pause") {
                    NotificationCenter.default.post(name: .moviePlayPause, object: NSApp.keyWindow)
                }
                .keyboardShortcut(.space, modifiers: [])

                Divider()

                Button("Step Back One Frame") {
                    NotificationCenter.default.post(name: .movieJumpBack, object: NSApp.keyWindow)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button("Step Forward One Frame") {
                    NotificationCenter.default.post(name: .movieJumpForward, object: NSApp.keyWindow)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Divider()

                Button("Loop") {
                    NotificationCenter.default.post(name: .movieToggleLoop, object: NSApp.keyWindow)
                }
                .keyboardShortcut("l", modifiers: .command)
            }
            
            CommandMenu("Image") {
                Button("Reset Exposure") {
                    NotificationCenter.default.post(name: .resetExposure, object: NSApp.keyWindow)
                }
                .keyboardShortcut("\\", modifiers: .command)
                
                Divider()
                
                Button("Increase Exposure") {
                    NotificationCenter.default.post(name: .increaseExposure, object: NSApp.keyWindow)
                }
                .keyboardShortcut("]", modifiers: .command)
                
                Button("Decrease Exposure") {
                    NotificationCenter.default.post(name: .decreaseExposure, object: NSApp.keyWindow)
                }
                .keyboardShortcut("[", modifiers: .command)

                Divider()

                Button("Red Channel") {
                    NotificationCenter.default.post(name: .channelRed, object: NSApp.keyWindow)
                }
                .keyboardShortcut("r", modifiers: [])

                Button("Green Channel") {
                    NotificationCenter.default.post(name: .channelGreen, object: NSApp.keyWindow)
                }
                .keyboardShortcut("g", modifiers: [])

                Button("Blue Channel") {
                    NotificationCenter.default.post(name: .channelBlue, object: NSApp.keyWindow)
                }
                .keyboardShortcut("b", modifiers: [])

                Button("Alpha Channel") {
                    NotificationCenter.default.post(name: .channelAlpha, object: NSApp.keyWindow)
                }
                .keyboardShortcut("a", modifiers: [])

                Button("Luminance") {
                    NotificationCenter.default.post(name: .channelLuminance, object: NSApp.keyWindow)
                }
                .keyboardShortcut("y", modifiers: [])
            }

            CommandMenu("OCIO") {
                Button("Export Settings…") {
                    NotificationCenter.default.post(name: .exportOCIOSettings, object: NSApp.keyWindow)
                }
                .help("Save current OCIO pipeline settings to a JSON file")

                Button("Import Settings…") {
                    NotificationCenter.default.post(name: .importOCIOSettings, object: NSApp.keyWindow)
                }
                .help("Load OCIO pipeline settings from a previously exported JSON file")

                Divider()

                Button("Revert to Built-in Config") {
                    NotificationCenter.default.post(name: .revertToBuiltinOCIO, object: NSApp.keyWindow)
                }
                .help("Switch this window back to the internally bundled OCIO config and reset all pipeline values to default")

                Divider()

                Button("Reveal Settings File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([OCIOSettingsStore.indexFileURL])
                }
                .help("Show the color-settings.json file in Finder")
            }

            CommandGroup(replacing: .help) {
                Button("Tristimulator Help") {
                    TristimulatorHelpBook.open()
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Window("Settings", id: "settings") {
            PreferencesView()
        }
        .defaultSize(width: 700, height: 500)
        .commands {
            SettingsCommand()
        }
    }
}
// MARK: - Notification Names

extension Notification.Name {
    static let openImage = Notification.Name("openImage")
    static let toggleScopes = Notification.Name("toggleScopes")
    static let toggleUCS = Notification.Name("toggleUCS")
    static let toggleJmh = Notification.Name("toggleJmh")
    static let resetExposure = Notification.Name("resetExposure")
    static let increaseExposure = Notification.Name("increaseExposure")
    static let decreaseExposure = Notification.Name("decreaseExposure")
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let zoomToFit = Notification.Name("zoomToFit")
    static let zoomActualSize = Notification.Name("zoomActualSize")
    static let ocioConfigChanged     = Notification.Name("ocioConfigChanged")
    static let exportOCIOSettings     = Notification.Name("exportOCIOSettings")
    static let importOCIOSettings     = Notification.Name("importOCIOSettings")
    static let revertToBuiltinOCIO    = Notification.Name("revertToBuiltinOCIO")
    static let newWindow              = Notification.Name("newWindow")
    static let loadAMF                 = Notification.Name("loadAMF")
    // Movie playback
    static let moviePlayPause          = Notification.Name("moviePlayPause")
    static let movieJumpBack           = Notification.Name("movieJumpBack")
    static let movieJumpForward        = Notification.Name("movieJumpForward")
    static let movieToggleLoop         = Notification.Name("movieToggleLoop")
    // Clipboard
    static let copyImage               = Notification.Name("copyImage")
    static let copyImageNative         = Notification.Name("copyImageNative")
    static let exportGainMapImage      = Notification.Name("exportGainMapImage")
    // Channel isolation
    static let channelRed              = Notification.Name("channelRed")
    static let channelGreen            = Notification.Name("channelGreen")
    static let channelBlue             = Notification.Name("channelBlue")
    static let channelAlpha            = Notification.Name("channelAlpha")
    static let channelLuminance        = Notification.Name("channelLuminance")
}

// MARK: - Defaults and Help

enum TristimulatorDefaults {
    /// Persisted Debug-menu visibility. Missing or false keeps the menu hidden.
    /// Hold Option to reveal it until the key is released.
    static let showDebugMenu = "ShowDebugMenu"
    /// When true, scope overlays scale and move proportionally with the image
    /// area as the window is resized. False (default) pins them to the nearer
    /// edges at a fixed size.
    static let scopesScaleWithWindow = "ScopesScaleWithWindow"
    /// When true, a newly opened image whose colour space tag matches an SDR display
    /// colour space (e.g. "sRGB - Display") starts in Inverse Display mode, inverting that
    /// display's SDR view instead of converting from the display colour space.
    /// Missing or false (default) keeps Color Space mode.
    static let inverseDisplayForDisplayReferred = "InverseDisplayForDisplayReferred"
}

enum TristimulatorHelpBook {
    /// Must match `CFBundleHelpBookName` in Info.plist and `HPDBookTitle` in the help book.
    static let name = "Tristimulator Help"
    static let welcomeAnchor = "welcome"

    static func open() {
        // Register the bundled book explicitly so Help Viewer picks up this
        // build's copy (Debug builds run from DerivedData, not /Applications),
        // then open the book's title page via the standard Help action.
        // openHelpAnchor falls back to generic macOS Help when helpd has not
        // indexed the anchor yet, so it is not used here.
        NSHelpManager.shared.registerBooks(in: .main)
        NSApp.showHelp(nil)
    }
}

/// Master switch for the bundled sample-image fallback.
///
/// When `true`, `AppDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)`
/// opens the bundled OpenEXR `OCIO_logo_frame_flared.exr` if Tristimulator is
/// reactivated and no window is visible (a Dock click after every document
/// window has been closed). Failed loads do not use this path; they show an error.
///
/// Leave this `false` to keep the feature off. `openBundledSampleImage()` is
/// unchanged so the behaviour can be restored by setting this to `true`.
private let automaticFallbackImageEnabled = false

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Extra-window tracking
    // Maps each NSWindow opened as an extra duplicate → (file URL, stable windowID).
    // When the window closes we remove both the extra-window record and its
    // per-window OCIO settings from OCIOSettingsStore.
    private var trackedExtraWindows: [NSWindow: (url: URL, windowID: String)] = [:]

    /// Set to `true` in `applicationWillTerminate` so that `handleWindowClose`
    /// does **not** erase the extra-window records during a normal quit — they
    /// must survive on disk to be reopened on the next launch.
    private var isTerminating = false

    /// Retained so the modifier-flag monitor stays installed for the process lifetime.
    private var debugMenuEventMonitor: Any?

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enable state restoration. ShowDebugMenu is registered false so a missing
        // value stays off without overwriting a value the user has set.
        UserDefaults.standard.register(defaults: [
            "NSQuitAlwaysKeepsWindows": true,
            TristimulatorDefaults.showDebugMenu: false,
            TristimulatorDefaults.scopesScaleWithWindow: false
        ])

        installDebugMenuGate()

        // Listen for "New Window" menu requests.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNewWindow),
            name: .newWindow,
            object: nil
        )

        // Detect when any window closes so we can untrack extra windows.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        // After a short delay (letting macOS finish its own state restoration),
        // reopen windows that the user had opened via "New Window for This Image".
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.reopenExtraWindows()
        }

        print("🚀 App launched - state restoration enabled")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Persist each extra window's frame and z-order in a single disk write.
        let store = OCIOSettingsStore.shared
        let orderedWindows = NSApp.orderedWindows   // index 0 = frontmost
        for (window, record) in trackedExtraWindows {
            let zIdx = orderedWindows.firstIndex(of: window) ?? Int.max
            store.updateWindowAppearance(
                windowID: record.windowID,
                frame: window.frame,
                zOrderIndex: zIdx
            )
        }
        store.flushAppearanceChanges()
        isTerminating = true
        print("👋 App terminating — extra-window records preserved for next launch")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if automaticFallbackImageEnabled && !flag {
            openBundledSampleImage()
        }
        return true
    }

    // MARK: Debug menu visibility

    /// Hides the Debug menu unless `ShowDebugMenu` is true or Option is held.
    /// Called on menu construction, defaults changes, activation, and before a
    /// click is delivered so the menu bar is current when it opens.
    private func installDebugMenuGate() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(debugMenuVisibilityTrigger(_:)),
            name: NSMenu.didAddItemNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(debugMenuVisibilityTrigger(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(debugMenuVisibilityTrigger(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        // SwiftUI re-adds and resets its menu items whenever it rebuilds a menu,
        // so re-hide the save commands on every add or change in any menu.
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            center.addObserver(
                self,
                selector: #selector(menuItemsDidChange(_:)),
                name: name,
                object: nil
            )
        }
        applyDebugMenuVisibility(modifierFlags: NSEvent.modifierFlags)
        debugMenuEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            self?.applyDebugMenuVisibility(modifierFlags: event.modifierFlags)
            return event
        }
        // SwiftUI may install the menu bar just after launch.
        DispatchQueue.main.async { [weak self] in
            self?.applyDebugMenuVisibility(modifierFlags: NSEvent.modifierFlags)
        }
    }

    @objc private func debugMenuVisibilityTrigger(_ notification: Notification) {
        if notification.name == NSMenu.didAddItemNotification {
            guard (notification.object as? NSMenu) === NSApp.mainMenu else { return }
        }
        // UserDefaults posts this on the thread that wrote the value.
        if Thread.isMainThread {
            applyDebugMenuVisibility(modifierFlags: NSEvent.modifierFlags)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyDebugMenuVisibility(modifierFlags: NSEvent.modifierFlags)
            }
        }
    }

    private func applyDebugMenuVisibility(modifierFlags: NSEvent.ModifierFlags) {
        removeSaveCommands()
        guard let item = NSApp.mainMenu?.item(withTitle: "Debug") else { return }
        let persisted = UserDefaults.standard.bool(forKey: TristimulatorDefaults.showDebugMenu)
        let optionHeld = modifierFlags.contains(.option)
        item.isHidden = !(persisted || optionHeld)
    }

    // MARK: Save commands

    /// Standard document commands that write, rename or move the source file.
    /// Tristimulator is a viewer: a save would replace the source image, and
    /// it should not rename or relocate the user's files either.
    private static let saveCommandActions: Set<String> = [
        "saveDocument:", "saveDocumentAs:", "saveDocumentTo:",
        "duplicateDocument:", "revertDocumentToSaved:", "browseDocumentVersions:",
        "renameDocument:", "moveDocument:"
    ]

    /// Removes Save, Save As, Duplicate, Rename, Move To and Revert from the
    /// menu bar. They are removed rather than hidden: AppKit pairs Duplicate
    /// with its Option-key alternate Save As… and un-hides Duplicate every time
    /// the File menu opens, so a hidden Duplicate still appears. A removed item
    /// also has no key equivalent, so Command-S and Shift-Command-S do nothing.
    /// SwiftUI re-adds its menu items when it rebuilds the menu bar, so this runs
    /// at launch, from every menu add/change notification, and before key-down
    /// events are matched against shortcuts.
    private func removeSaveCommands() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for top in mainMenu.items {
            guard let menu = top.submenu else { continue }
            var doomed: [NSMenuItem] = []
            var previousWasRevert = false
            for item in menu.items {
                let action = item.action.map { NSStringFromSelector($0) } ?? ""
                if Self.saveCommandActions.contains(action) {
                    doomed.append(item)
                    previousWasRevert = (action == "revertDocumentToSaved:")
                } else if previousWasRevert, item.submenu != nil {
                    // The "Revert To" versions submenu sits right after Revert To Saved.
                    doomed.append(item)
                    previousWasRevert = false
                } else {
                    previousWasRevert = false
                }
            }
            for item in doomed where item.menu === menu {
                menu.removeItem(item)
            }
        }
    }

    private var saveCommandRemovalScheduled = false

    /// Menu notifications arrive while SwiftUI or AppKit is in the middle of
    /// building a menu. Removing items from inside that would shift indexes
    /// under them, so the removal runs once the current pass has finished.
    @objc private func menuItemsDidChange(_ notification: Notification) {
        guard !saveCommandRemovalScheduled else { return }
        saveCommandRemovalScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.saveCommandRemovalScheduled = false
            self.removeSaveCommands()
        }
    }

    // MARK: New Window command

    /// Opens the image shown in the *current key window* in a brand-new, independent
    /// window — works whether the source window is a primary document window or an
    /// extra window that was opened via this same command.
    @objc private func handleNewWindow() {
        let sourceWindow = NSApp.keyWindow

        // Prefer the document controller's knowledge (primary windows).
        // Fall back to our own extra-window tracking (duplicate windows, which
        // are NOT registered with NSDocumentController).
        let url: URL?
        if let docURL = NSDocumentController.shared.currentDocument?.fileURL {
            url = docURL
        } else if let sourceWindow, let record = trackedExtraWindows[sourceWindow] {
            url = record.url
        } else {
            print("⚠️ New Window: no current document URL")
            return
        }

        openExtraWindow(
            for: url!,
            windowID: UUID().uuidString,
            sourceFrame: sourceWindow?.frame,
            recordInStore: true
        )
    }

    // MARK: Extra-window helpers

    /// Low-level routine that creates a fresh document window for `url`.
    ///
    /// - Parameters:
    ///   - windowID:      The stable UUID to assign to `ImageDocument.windowID`.
    ///                    Pass a freshly generated UUID for user-initiated windows;
    ///                    pass the stored UUID when restoring on launch so the
    ///                    per-window OCIO settings can be looked up correctly.
    ///   - sourceFrame:   Frame of the window being duplicated. When provided the
    ///                    new window is given the same size and cascaded slightly
    ///                    so both windows are simultaneously visible.
    ///   - recordInStore: `true` when the user explicitly creates a new window;
    ///                    `false` when we're restoring on launch (already in store).
    private func openExtraWindow(for url: URL, windowID: String, sourceFrame: NSRect? = nil, recordInStore: Bool) {
        do {
            let typeID = UTType(filenameExtension: url.pathExtension)?.identifier
                      ?? url.pathExtension

            // Stage the windowID BEFORE makeDocument so that DocumentContentView
            // can claim it in handleOnAppear before initializePipeline runs.
            OCIOSettingsStore.shared.stagePendingExtraWindow(
                windowID: windowID,
                filePath: url.resolvingSymlinksInPath().path
            )

            let newDoc = try NSDocumentController.shared.makeDocument(
                withContentsOf: url,
                ofType: typeID
            )
            // Intentionally NOT calling addDocument so macOS restoration
            // doesn't interfere — we track and reopen these ourselves.
            newDoc.makeWindowControllers()
            newDoc.showWindows()

            // Position the new window:
            // • Restore (recordInStore=false): use the saved frame exactly.
            // • User-triggered (recordInStore=true): match size and cascade slightly.
            if let frame = sourceFrame {
                let newFrame: NSRect
                if recordInStore {
                    // Cascade so both windows are simultaneously visible.
                    let cascade = CGFloat(trackedExtraWindows.count + 1) * 22
                    newFrame = NSRect(
                        origin: NSPoint(x: frame.origin.x + cascade,
                                        y: frame.origin.y - cascade),
                        size: frame.size
                    )
                } else {
                    // Restore: place window exactly where it was when the user quit.
                    newFrame = frame
                }
                for wc in newDoc.windowControllers {
                    wc.window?.setFrame(newFrame, display: true)
                }
            }

            // Record every NSWindow owned by the new document.
            for wc in newDoc.windowControllers {
                if let window = wc.window {
                    trackedExtraWindows[window] = (url: url, windowID: windowID)
                }
            }

            if recordInStore {
                OCIOSettingsStore.shared.addExtraWindow(windowID: windowID, for: url)
            }
            print("📲 Opened extra window \(windowID.prefix(8))… for \(url.lastPathComponent)")
        } catch {
            // Clear the staged ID if opening failed so it doesn't pollute the next window.
            _ = OCIOSettingsStore.shared.consumePendingExtraWindow()
            print("⚠️ openExtraWindow failed: \(error)")
        }
    }

    /// Reopens any extra windows that were persisted in `OCIOSettingsStore`.
    /// Called once after launch, after macOS state restoration has settled.
    private func reopenExtraWindows() {
        let records = OCIOSettingsStore.shared.extraWindowRecords
        guard !records.isEmpty else { return }
        print("🔄 Restoring \(records.count) extra window(s)…")
        let fm = FileManager.default
        for record in records {
            if fm.fileExists(atPath: record.filePath) {
                let url = URL(fileURLWithPath: record.filePath)
                openExtraWindow(
                    for: url,
                    windowID: record.windowID,
                    sourceFrame: record.savedFrame?.nsRect,
                    recordInStore: false
                )
            } else {
                OCIOSettingsStore.shared.removeExtraWindow(windowID: record.windowID)
                OCIOSettingsStore.shared.removeWindowSettings(record.windowID)
                print("⚠️ Extra window file gone, removed from store: \(record.filePath)")
            }
        }

        // Restore z-order among extra windows.
        // Sort by saved index descending (back → front) then call orderFront on
        // each so the window with the smallest saved index ends up topmost.
        let zOrdered = records
            .compactMap { record -> (NSWindow, Int)? in
                guard let zIdx = record.zOrderIndex else { return nil }
                let entry = trackedExtraWindows.first { $0.value.windowID == record.windowID }
                guard let window = entry?.key else { return nil }
                return (window, zIdx)
            }
            .sorted { $0.1 > $1.1 }   // highest index (furthest back) first
        for (window, _) in zOrdered {
            window.orderFront(nil)
        }
    }

    // MARK: Window close observer

    @objc private func handleWindowClose(_ notification: Notification) {
        // During app quit every window closes — don't erase the records or the
        // extra windows won't be reopened on the next launch.
        guard !isTerminating else { return }
        guard let window = notification.object as? NSWindow else { return }
        if let record = trackedExtraWindows.removeValue(forKey: window) {
            let store = OCIOSettingsStore.shared
            store.removeExtraWindow(windowID: record.windowID)
            store.removeWindowSettings(record.windowID)
            print("🗑️ Extra window closed, removed from persistence: \(record.url.lastPathComponent)")
        }
    }

    // MARK: Sample image fallback

    private func openBundledSampleImage() {
        guard let bundledImagePath = Bundle.main.path(
            forResource: "OCIO_logo_frame_flared", ofType: "exr"
        ) else {
            print("ℹ️ No bundled sample image found.")
            return
        }
        let sampleImageURL = URL(fileURLWithPath: bundledImagePath)
        print("📦 Opening bundled sample image: \(bundledImagePath)")
        NSDocumentController.shared.openDocument(
            withContentsOf: sampleImageURL, display: true
        ) { _, _, error in
            if let error = error {
                print("⚠️ Failed to open bundled sample image: \(error)")
            } else {
                print("✅ Opened bundled sample image successfully")
            }
        }
    }
}


