//
//  DocumentContentView.swift
//  Tristimulator
//
//  Created by Alex Fry on 3/6/2026.
//

import SwiftUI
import UniformTypeIdentifiers
import Metal

struct DocumentContentView: View {
    @ObservedObject var document: ImageDocument
    let fileURL: URL?

    /// The NSWindow that hosts this document view, captured by WindowConfigurator.
    /// Used to filter broadcast notifications so only the key window responds.
    @State private var hostWindow: NSWindow? = nil
    /// Triggers a one-shot peak measurement in the Metal view on the next frame.
    @State private var measurePeak = false
    /// Guards against auto-saving while we are programmatically restoring settings.
    @State private var isRestoringSettings = false
    /// Debounce token for auto-saves triggered by onChange — cancelled and
    /// restarted on every change so rapid scrubbing/exposure drags produce at
    /// most one disk write, 0.8 s after the last change.
    @State private var autosaveDebounceTask: Task<Void, Never>? = nil
    /// Guards against re-running the scripting engine on EXR layer changes or
    /// other non-load calls to applyOCIOAndMarkReady. Reset on imageLoadCount change.
    @State private var scriptAppliedForCurrentLoad = false
    /// Controls visibility of the movie transport pill. Fades out after 3 s of mouse inactivity.
    @State private var showMovieControls: Bool = true
    @State private var hideMovieControlsTask: Task<Void, Never>? = nil
    /// True while the cursor is inside the transport pill — suppresses the auto-hide timer.
    @State private var isHoveringMovieControls: Bool = false
    /// True while the cursor is over the full-screen toolbar or info bar pill.
    /// Suppresses the 2-second auto-hide so the controls stay visible.
    @State private var isHoveringFullScreenControls: Bool = false
    /// Controls visibility of the still image info bar in windowed mode.
    /// Fades out after 3 s of mouse inactivity, same pattern as movie controls.
    @State private var showStillInfoBar: Bool = true
    @State private var hideStillInfoBarTask: Task<Void, Never>? = nil
    @State private var isHoveringStillInfoBar: Bool = false
    /// Timestamp of the last mouse-move event inside the window.
    /// A single watcher task compares this against Date.now — no per-event Task allocation.
    @State private var lastMouseActivityDate: Date = .now
    /// Stable ImageData snapshot captured once at movie-open time.
    /// Passed to MovieControlsView so the info bar doesn't re-render at video frame rate.
    @State private var movieImageData: ImageData? = nil
    /// Controls visibility of the image-sequence transport pill — same auto-hide pattern as movies.
    @State private var showSequenceControls: Bool = true
    @State private var hideSequenceControlsTask: Task<Void, Never>? = nil
    @State private var isHoveringSequenceControls: Bool = false
    /// The GPU service for the CIE 1931 Yxy chromaticity diagram (lazy-created on first use).
    @State private var chromaticityService: ChromaticityScopeService?
    /// Whether the in-window CIE 1931 Yxy diagram overlay is visible.
    @State private var showChromaticityDiagram = false
    /// The GPU service for the CIE 1976 UCS u'v' diagram (lazy-created on first use).
    @State private var ucsService: ChromaticityScopeService?
    /// Whether the in-window CIE 1976 u'v' diagram overlay is visible.
    @State private var showUCSDiagram = false
    /// The GPU service for the JMh (Hellwig 2022) polar scope (lazy-created on first use).
    @State private var jmhService: JmhScopeService?
    /// Whether the in-window JMh diagram overlay is visible.
    @State private var showJmhDiagram = false
    /// Where each scope overlay sits. A kind is missing until it is first shown
    /// or restored, and then keeps its place while closed, so it reopens there.
    @State private var scopePlacements: [ScopeKind: ScopeOverlayPlacement] = [:]
    /// Stacking order of the scope overlays (clicking one brings it to front).
    @State private var scopeZOrder = ScopeZOrder()
    @State private var scopeClickResolver = ScopeClickResolver()

    var body: some View {
        // Modifier chain split across three computed properties to avoid type-checker timeout.
        persistenceConfiguredView
    }

    // MARK: - Layered modifier chain

    /// Layer 1: core chrome, appear/disappear, image-load, and EDR-popover onChanges.
    private var baseConfiguredView: some View {
        contentView
            .background(WindowConfigurator(window: $hostWindow))
            // Suppress the toolbar's own background so the vibrancy over image
            // content is all that shows — works in both windowed and full-screen
            // (full-screen uses a separate NSToolbarFullScreenWindow that
            // titlebarAppearsTransparent cannot reach; this SwiftUI modifier does).
            .toolbarBackground(.hidden, for: .windowToolbar)
            .navigationTitle(document.fileURL?.lastPathComponent ?? "Tristimulator")
            .toolbar { toolbarItems }
            .onAppear {
                ScriptingEngine.shared.activeDocument = document
                handleOnAppear()
            }
            .onDisappear {
                document.stopEDRMonitoring()
                // Final save so frame position, zoom, pan etc. are always persisted
                // even if no onChange watcher fired since the last navigation.
                if document.hasAppliedTransforms {
                    saveCurrentSettings()
                }
            }
            .onChange(of: document.imageLoadCount) { oldValue, newValue in
                print("🔔 Image load count changed: \(oldValue) → \(newValue)")
                if newValue > 0 {
                    ScriptingEngine.shared.activeDocument = document
                    document.hasAppliedTransforms = false
                    scriptAppliedForCurrentLoad = false
                    // Don't reset zoom here - let ZoomableImageView handle it with zoom-to-fit
                    initializePipeline()
                    // Snapshot stable metadata once per load for the transport pill info row.
                    if document.movieSource != nil {
                        movieImageData = document.imageManager.currentImage
                    }
                    // (sequence controls read document.imageManager.currentImage directly)
                }
            }
            .onChange(of: document.showEDRInfoPopover) { _, isOpen in
                if isOpen {
                    document.peakPixelResult = nil
                    measurePeak = true
                }
            }
    }

    /// Layer 2: NotificationCenter receivers for keyboard shortcuts and OCIO config changes.
    private var notificationConfiguredView: some View {
        baseConfiguredView
            .onReceive(NotificationCenter.default.publisher(for: .openImage)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                openImage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .loadAMF)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                loadAMFFromPanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleScopes)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                showChromaticityDiagram.toggle()
                if showChromaticityDiagram { updateChromaticity() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleUCS)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                showUCSDiagram.toggle()
                if showUCSDiagram { updateUCS() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleJmh)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                showJmhDiagram.toggle()
                if showJmhDiagram { updateJmh() }
            }

            .onChange(of: document.imageManager.currentImage) { _, _ in
                if showChromaticityDiagram { updateChromaticity() }
                if showUCSDiagram { updateUCS() }
                if showJmhDiagram { updateJmh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .resetExposure)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                document.imageManager.exposure = 0
                Task { await document.imageManager.updateExposure(0) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .increaseExposure)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                let newExposure = min(10, document.imageManager.exposure + 0.5)
                document.imageManager.exposure = newExposure
                Task { await document.imageManager.updateExposure(newExposure) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .decreaseExposure)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                let newExposure = max(-10, document.imageManager.exposure - 0.5)
                document.imageManager.exposure = newExposure
                Task { await document.imageManager.updateExposure(newExposure) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ocioConfigChanged)) { _ in
                print("🔔 OCIO config changed notification received")
                // Stamp the newly-loaded config path into the per-image saved settings
                // BEFORE initializePipeline runs.  Without this, the redirect guard in
                // initializePipeline sees saved.ocioConfigPath != loadedConfigPath and
                // immediately reloads the old per-image config, clobbering the user's choice.
                let newPath = document.imageManager.loadedConfigPath
                if document.isExtraWindow {
                    if var s = OCIOSettingsStore.shared.settings(forWindow: document.windowID) {
                        s.ocioConfigPath = newPath
                        OCIOSettingsStore.shared.save(s, forWindow: document.windowID)
                    }
                } else if let fileURL = document.fileURL,
                          var s = OCIOSettingsStore.shared.settings(for: fileURL) {
                    s.ocioConfigPath = newPath
                    OCIOSettingsStore.shared.save(s, for: fileURL)
                }
                initializePipeline()
            }
            // Keep currentScreen up-to-date so per-window EDR headroom is accurate
            // when the window is moved between displays.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                document.imageManager.currentScreen = hostWindow?.screen
            }
            .onChange(of: hostWindow) { _, newWindow in
                // Set initial screen when the hosting NSWindow is first assigned.
                document.imageManager.currentScreen = newWindow?.screen
            }
    }

    /// Layer 2b: Channel isolation keyboard shortcuts.
    private var channelConfiguredView: some View {
        notificationConfiguredView
            .onReceive(NotificationCenter.default.publisher(for: .channelRed)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                document.channelMode = document.channelMode == .red ? .normal : .red
            }
            .onReceive(NotificationCenter.default.publisher(for: .channelGreen)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                document.channelMode = document.channelMode == .green ? .normal : .green
            }
            .onReceive(NotificationCenter.default.publisher(for: .channelBlue)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                document.channelMode = document.channelMode == .blue ? .normal : .blue
            }
            .onReceive(NotificationCenter.default.publisher(for: .channelAlpha)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                document.channelMode = document.channelMode == .alpha ? .normal : .alpha
            }
            .onReceive(NotificationCenter.default.publisher(for: .channelLuminance)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                document.channelMode = document.channelMode == .luminance ? .normal : .luminance
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyImage)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                copyImageToClipboard()
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyImageNative)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                copyImageNativeToClipboard()
            }
    }

    /// Layer 3a: OCIO settings persistence — auto-save on any pipeline change (part 1).
    private var autosaveConfiguredView: some View {
        channelConfiguredView
            .onChange(of: document.selectedSourceSpace)           { _, _ in autosaveSettings() }
            .onChange(of: document.selectedDestSpace)             { _, _ in autosaveSettings() }
            .onChange(of: document.selectedDisplay)               { _, _ in autosaveSettings() }
            .onChange(of: document.selectedView)                  { _, _ in autosaveSettings() }
            .onChange(of: document.selectedMetalColorSpace)       { _, _ in autosaveSettings() }
            .onChange(of: document.imageManager.useCPURenderPath) { _, _ in autosaveSettings() }
            .onChange(of: document.imageManager.exposure)         { _, _ in autosaveSettings() }
            .onChange(of: document.imageManager.dynamicACES2Mode)       { _, _ in autosaveSettings() }
            .onChange(of: document.imageManager.dynamicACES2AutoNits)   { _, _ in autosaveSettings() }
    }

    /// Layer 3a (continued): auto-save watchers for remaining pipeline and view state.
    private var autosaveConfiguredView2: some View {
        autosaveConfiguredView
            .onChange(of: document.imageManager.dynamicACES2Gamut)      { _, _ in autosaveSettings() }
            .onChange(of: document.imageManager.dynamicACES2TargetNits) { _, _ in autosaveSettings() }
            .onChange(of: document.imageManager.sourceTransformMode)  { _, _ in autosaveSettings() }
            .onChange(of: document.imageManager.sourceInverseDisplay) { _, _ in autosaveSettings() }
            .onChange(of: document.imageManager.sourceInverseView)    { _, _ in autosaveSettings() }
            .onChange(of: document.zoomLevel)                        { _, _ in autosaveSettings() }
            .onChange(of: document.channelMode)                      { _, _ in autosaveSettings() }
            .onChange(of: document.selectedEXRLayer)                 { _, _ in autosaveSettings() }
            .onChange(of: document.imageManager.amfEnabledLooks)         { _, _ in autosaveSettings() }
            .onChange(of: document.imageManager.amfLooksGloballyEnabled) { _, _ in autosaveSettings() }
            .onChange(of: scopeLayoutForPersistence)                 { _, _ in autosaveSettings() }
            // Restored scopes may open before the source texture exists.
            .onChange(of: document.hasAppliedTransforms)             { _, _ in refreshVisibleScopes() }
    }

    /// Layer 3b: Additional onChange watchers (EXR layer, etc.) and export/import.
    private var persistenceConfiguredView: some View {
        autosaveConfiguredView2
            // Reload still image when the user picks a different EXR layer.
            .onChange(of: document.selectedEXRLayer) { _, newLayer in
                // For stills: reload the file with the new layer.
                if let url = document.fileURL,
                   document.movieSource == nil,
                   document.sequenceSource == nil {
                    Task {
                        do {
                            try await document.imageManager.loadImage(from: url, layer: newLayer)
                            // Re-apply the existing OCIO pipeline to the new source
                            // texture WITHOUT running initializePipeline (which would
                            // restore saved settings and overwrite the user's layer
                            // choice).  The pipeline is already set up — only the
                            // source texture changed.
                            await MainActor.run {
                                document.hasAppliedTransforms = false
                            }
                            await applyOCIOAndMarkReady()
                        } catch {
                            print("⚠️ Failed to reload EXR layer \(newLayer): \(error)")
                        }
                    }
                }
                // For sequences: update the source's layer (flushes cache + re-seeks internally).
                document.sequenceSource?.selectedLayer = newLayer
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportGainMapImage)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                exportGainMapImage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportOCIOSettings)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                exportOCIOSettings()
            }
            .onReceive(NotificationCenter.default.publisher(for: .importOCIOSettings)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                importOCIOSettings()
            }
            .onReceive(NotificationCenter.default.publisher(for: .revertToBuiltinOCIO)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                revertToBuiltinOCIOConfig()
            }
            // Playback hotkeys — handle both movies and image sequences.
            .onReceive(NotificationCenter.default.publisher(for: .moviePlayPause)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                if let movie = document.movieSource {
                    movie.isPlaying ? movie.pause() : movie.play()
                } else if let seq = document.sequenceSource {
                    seq.isPlaying ? seq.pause() : seq.play()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .movieJumpBack)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                if let movie = document.movieSource {
                    Task { await movie.stepBackward() }
                } else if let seq = document.sequenceSource {
                    Task { await seq.stepBackward() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .movieJumpForward)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                if let movie = document.movieSource {
                    Task { await movie.stepForward() }
                } else if let seq = document.sequenceSource {
                    Task { await seq.stepForward() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .movieToggleLoop)) { notification in
                guard notification.object as? NSWindow === hostWindow else { return }
                if let movie = document.movieSource {
                    movie.isLooping.toggle()
                } else if let seq = document.sequenceSource {
                    seq.isLooping.toggle()
                }
            }
    }

    // MARK: - Sub-views

    /// Root content: ZStack with image area, sidebar, and full-screen mouse tracking overlay.
    @ViewBuilder private var contentView: some View {
        ZStack {
            VStack(spacing: 0) {
                HSplitView {
                    imageArea
                    sidebar
                }
            }
            // Track mouse for full-screen chrome auto-hide, movie/sequence controls
            // auto-hide, and windowed still info bar auto-hide.
            if document.isFullScreen || document.movieSource != nil || document.sequenceSource != nil
                || (document.imageManager.currentImage != nil
                    && document.movieSource == nil && document.sequenceSource == nil) {
                MouseTrackingView { location in handleMouseMove(location) }
                    .allowsHitTesting(false)
            }
        }
    }

    /// The native toolbar items — hidden in full-screen where the custom
    /// ImageToolbar overlay is used instead.
    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        if !document.isFullScreen {
        ToolbarItem(placement: .principal) {
            ChannelIndicator(mode: document.channelMode)
                .opacity(0)
        }
        .compatHideSharedBackground()
        ToolbarItemGroup(placement: .principal) {
            HStack(spacing: 8) {
                Text("Exposure:")
                    .font(.caption)
                    .padding(.leading, 12)
                ExposureSlider(value: Binding(
                    get: { document.imageManager.exposure },
                    set: { newValue in
                        document.imageManager.exposure = newValue
                        Task { await document.imageManager.updateExposure(newValue) }
                    }
                ))
                .frame(width: 200, height: 24)
                Text(String(format: "%.1f", document.imageManager.exposure))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 35, alignment: .trailing)
                Button(action: {
                    document.imageManager.exposure = 0
                    Task { await document.imageManager.updateExposure(0) }
                }) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Reset exposure")
            }
            Button { document.showEDRInfoPopover.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(document.isHDRAvailable ? .yellow : .primary)
                    Text(document.isHDRAvailable ? "HDR" : "SDR")
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .help(document.isHDRAvailable ? "Extended Dynamic Range available" : "Standard Dynamic Range")
            .popover(isPresented: $document.showEDRInfoPopover, arrowEdge: .bottom) {
                EDRInfoView(peakPixelResult: document.peakPixelResult).frame(width: 400).padding()
            }
        }
        ToolbarItem(placement: .principal) {
            ChannelIndicator(mode: document.channelMode)
                .opacity(document.channelMode != .normal ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: document.channelMode)
        }
        .compatHideSharedBackground()
            
        ToolbarItem(id: "ocio-pipeline", placement: .primaryAction) {
            Button(action: {
                document.showPipelinePopover.toggle()
            }) {
                Label {
                    Text("OCIO Pipeline")
                } icon: {
                    Image("opencolorio-icon-white")
                        .renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 16, height: 16)
                        .foregroundStyle(.primary)
                }
            }
            .help("Show color pipeline")
            .popover(isPresented: $document.showPipelinePopover, arrowEdge: .bottom) {
                ColorPipelineNodeView(
                    imageManager: document.imageManager,
                    selectedSourceSpace: $document.selectedSourceSpace,
                    selectedDestSpace: $document.selectedDestSpace,
                    selectedDisplay: $document.selectedDisplay,
                    selectedView: $document.selectedView,
                    selectedMetalColorSpace: $document.selectedMetalColorSpace,
                    hasAppliedTransforms: $document.hasAppliedTransforms
                )
                .frame(width: 400).padding()
            }
        }


        } // end if !document.isFullScreen
    }

    /// Called from `.onAppear`. Loads the image, starts monitoring, and
    /// registers full-screen notifications.
    private func handleOnAppear() {
        // If AppDelegate staged a windowID for this extra window, claim it now
        // so that initializePipeline() (called after image load) can look up the
        // right per-window OCIO settings bucket.
        if let pending = OCIOSettingsStore.shared.consumePendingExtraWindow() {
            document.windowID      = pending.windowID
            document.isExtraWindow = true
            print("🪟 Claimed extra-window ID \(pending.windowID.prefix(8))…")
        }

        if let fileURL = fileURL {
            document.fileURL = fileURL
            if isMovieURL(fileURL) {
                handleMovieOpen(url: fileURL)
            } else if isImageSequenceURL(fileURL) {
                handleSequenceOpen(url: fileURL)
            } else {
                Task {
                    do {
                        document.selectedEXRLayer = ""   // reset for new file
                        try await document.imageManager.loadImage(from: fileURL)
                        await MainActor.run { document.imageLoadCount += 1 }
                        print("📦 Loaded image from document: \(fileURL.lastPathComponent)")
                    } catch {
                        print("⚠️ Failed to load image from document: \(error)")
                        showError(error)
                    }
                }
            }
        } else {
            print("⚠️ No file URL provided to DocumentContentView")
        }
        document.checkEDRStatus()
        document.startEDRMonitoring()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil, queue: .main
        ) { [weak document] notification in
            guard let document else { return }
            print("🖥️ Entering full screen")
            document.isFullScreen = true
            document.showInfoBarInFullScreen = true
            document.showToolbarInFullScreen = true

            // Configure the main content window.
            if let contentWindow = notification.object as? NSWindow {
                contentWindow.backgroundColor = .black
                if !contentWindow.styleMask.contains(.fullSizeContentView) {
                    contentWindow.styleMask.insert(.fullSizeContentView)
                }
            }

            let hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled {
                    document.showInfoBarInFullScreen = false
                    document.showToolbarInFullScreen = false
                    NSCursor.hide()
                }
            }
            document.hideInfoBarTask = hideTask
            document.hideToolbarTask = hideTask
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil, queue: .main
        ) { [weak document] notification in
            guard let document else { return }
            print("🖥️ Exiting full screen")
            document.isFullScreen = false
            document.showInfoBarInFullScreen = true
            document.showToolbarInFullScreen = true
            document.hideInfoBarTask?.cancel()
            document.hideToolbarTask?.cancel()
            if let window = notification.object as? NSWindow {
                window.backgroundColor = .windowBackgroundColor
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
            }
            NSCursor.unhide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSCursor.unhide()
                CGDisplayShowCursor(CGMainDisplayID())
            }
        }
    }

    /// Main image area: image fills the zone, with floating toolbar (full-screen
    /// only) at the top and info bar pill at the bottom.
    @ViewBuilder private var imageArea: some View {
        ZStack {
            imageViewer
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Full-screen floating toolbar — sits over the image so
            // .regularMaterial can sample the image content behind it.
            if document.isFullScreen {
                VStack(spacing: 0) {
                    ImageToolbar(
                        exposure: Binding(
                            get: { document.imageManager.exposure },
                            set: { newValue in
                                document.imageManager.exposure = newValue
                                Task { await document.imageManager.updateExposure(newValue) }
                            }
                        ),
                        showScopes: $document.showScopes,
                        showPipelinePopover: $document.showPipelinePopover,
                        imageManager: document.imageManager,
                        selectedSourceSpace: $document.selectedSourceSpace,
                        selectedDestSpace: $document.selectedDestSpace,
                        selectedDisplay: $document.selectedDisplay,
                        selectedView: $document.selectedView,
                        selectedMetalColorSpace: $document.selectedMetalColorSpace,
                        hasAppliedTransforms: $document.hasAppliedTransforms,
                        onOpenImage: openImage,
                        onSaveImage: saveImage,
                        showEDRInfoPopover: $document.showEDRInfoPopover,
                        isHDRAvailable: $document.isHDRAvailable,
                        peakPixelResult: $document.peakPixelResult,
                        channelMode: $document.channelMode
                    )
                    .frame(height: 44)
                    .opacity(document.showToolbarInFullScreen ? 1 : 0)
                    .animation(.easeInOut(duration: 0.6), value: document.showToolbarInFullScreen)
                    .onHover { hovering in
                        isHoveringFullScreenControls = hovering
                        if hovering {
                            // Cursor entered — cancel any pending hide so controls stay visible.
                            document.hideInfoBarTask?.cancel()
                            document.hideToolbarTask?.cancel()
                        } else {
                            // Cursor left — restart the 2-second countdown.
                            let hideTask = Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                if !Task.isCancelled {
                                    document.showInfoBarInFullScreen = false
                                    document.showToolbarInFullScreen = false
                                    NSCursor.hide()
                                }
                            }
                            document.hideInfoBarTask = hideTask
                            document.hideToolbarTask = hideTask
                        }
                    }
                    Spacer()
                }
            }

            // Info bar pill — shown for stills only.
            // Movies and sequences embed the info row inside their transport pill.
            if let image = document.imageManager.currentImage,
               document.movieSource == nil,
               document.sequenceSource == nil {
                VStack(spacing: 0) {
                    Spacer()
                    HStack {
                        Spacer()
                        ImageInfoBar(
                            imageData: image,
                            sourceSpace: document.selectedSourceSpace.isEmpty ? nil : document.selectedSourceSpace,
                            ocioConfig: document.imageManager.ocioConfig,
                            imageManager: document.imageManager,
                            selectedLayer: document.selectedEXRLayer,
                            onLayerChange: { newLayer in
                                document.selectedEXRLayer = newLayer
                            }
                        )
                        Spacer()
                    }
                    .padding(.bottom, 12)
                    .opacity({
                        if document.isFullScreen { return document.showInfoBarInFullScreen ? 1 : 0 }
                        return showStillInfoBar ? 1 : 0
                    }())
                    .animation(.easeInOut(duration: 0.6), value: document.showInfoBarInFullScreen)
                    .animation(.easeInOut(duration: 0.6), value: showStillInfoBar)
                    .onHover { hovering in
                        if document.isFullScreen {
                            isHoveringFullScreenControls = hovering
                            if hovering {
                                document.hideInfoBarTask?.cancel()
                                document.hideToolbarTask?.cancel()
                            } else {
                                let hideTask = Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(2))
                                    if !Task.isCancelled {
                                        document.showInfoBarInFullScreen = false
                                        document.showToolbarInFullScreen = false
                                        NSCursor.hide()
                                    }
                                }
                                document.hideInfoBarTask = hideTask
                                document.hideToolbarTask = hideTask
                            }
                        } else {
                            isHoveringStillInfoBar = hovering
                            if hovering {
                                hideStillInfoBarTask?.cancel()
                                hideStillInfoBarTask = nil
                            } else {
                                startStillInfoBarWatcher()
                            }
                        }
                    }
                    .onAppear {
                        if !document.isFullScreen {
                            showStillInfoBar = true
                            startStillInfoBarWatcher()
                        }
                    }
                }
            }

            // ── Movie transport pill ───────────────────────────────────────────────
            if let movie = document.movieSource {
                VStack(spacing: 0) {
                    Spacer()
                    HStack {
                        Spacer()
                        MovieControlsView(
                            movie: movie,
                            imageData: movieImageData,
                            sourceSpace: document.selectedSourceSpace.isEmpty ? nil : document.selectedSourceSpace,
                            onHoverChange: { hovering in
                                isHoveringMovieControls = hovering
                                if hovering {
                                    // Cursor entered pill — cancel any pending hide.
                                    hideMovieControlsTask?.cancel()
                                    hideMovieControlsTask = nil
                                } else {
                                    // Cursor left pill — start fresh watcher countdown.
                                    startMovieControlsWatcher()
                                }
                            }
                        )
                        Spacer()
                    }
                    .padding(.bottom, 20)
                    .opacity(
                        (document.isFullScreen && !document.showInfoBarInFullScreen) || !showMovieControls ? 0 : 1
                    )
                    .animation(.easeInOut(duration: 0.4), value: showMovieControls)
                    .animation(.easeInOut(duration: 0.6), value: document.showInfoBarInFullScreen)
                    .onAppear {
                        // Start the initial 3-second hide countdown when a movie opens.
                        showMovieControls = true
                        startMovieControlsWatcher()
                    }
                }
            }

            // ── Image-sequence transport pill ────────────────────────────────────────
            if let seq = document.sequenceSource {
                VStack(spacing: 0) {
                    Spacer()
                    HStack {
                        Spacer()
                        SequenceControlsView(
                            sequence: seq,
                            imageData: document.imageManager.currentImage,
                            sourceSpace: document.selectedSourceSpace.isEmpty
                                ? nil : document.selectedSourceSpace,
                            selectedLayer: document.selectedEXRLayer,
                            onLayerChange: { newLayer in
                                document.selectedEXRLayer = newLayer
                            },
                            onHoverChange: { hovering in
                                isHoveringSequenceControls = hovering
                                if hovering {
                                    hideSequenceControlsTask?.cancel()
                                    hideSequenceControlsTask = nil
                                } else {
                                    startSequenceControlsWatcher()
                                }
                            },
                            ocioConfig: document.imageManager.ocioConfig,
                            imageManager: document.imageManager
                        )
                        Spacer()
                    }
                    .padding(.bottom, 20)
                    .opacity(
                        (document.isFullScreen && !document.showInfoBarInFullScreen)
                            || !showSequenceControls ? 0 : 1
                    )
                    .animation(.easeInOut(duration: 0.4), value: showSequenceControls)
                    .animation(.easeInOut(duration: 0.6), value: document.showInfoBarInFullScreen)
                    .onAppear {
                        showSequenceControls = true
                        startSequenceControlsWatcher()
                    }
                }
            }

            // ── Scope overlays ─────────────────────────────────────────────────
            // Each overlay is pinned to the nearer horizontal and vertical
            // edges of this container (see ScopeOverlayPlacement), so e.g. the
            // JMh scope on the right stays on the right edge while the window
            // is resized.
            GeometryReader { geo in
                let containerSize = geo.size

                if showChromaticityDiagram {
                    ChromaticityOverlayView(
                        service: chromaticityService,
                        sourceColorSpace: document.selectedSourceSpace,
                        containerSize: containerSize,
                        onClose: { showChromaticityDiagram = false },
                        onModeChanged: { updateChromaticity() },
                        placement: scopePlacementBinding(.yxy),
                        onMouseDown: { scopeMouseDown(.yxy, at: $0) }
                    )
                    .zIndex(scopeZOrder.zIndex(.yxy))
                }

                if showUCSDiagram {
                    UCSOverlayView(
                        service: ucsService,
                        sourceColorSpace: document.selectedSourceSpace,
                        containerSize: containerSize,
                        onClose: { showUCSDiagram = false },
                        onModeChanged: { updateUCS() },
                        placement: scopePlacementBinding(.uv),
                        onMouseDown: { scopeMouseDown(.uv, at: $0) }
                    )
                    .zIndex(scopeZOrder.zIndex(.uv))
                }

                if showJmhDiagram {
                    JmhOverlayView(
                        service: jmhService,
                        sourceColorSpace: document.selectedSourceSpace,
                        containerSize: containerSize,
                        onClose: { showJmhDiagram = false },
                        onMaxMChanged: { updateJmh() },
                        onModeChanged: { updateJmh() },
                        placement: scopePlacementBinding(.jmh),
                        onMouseDown: { scopeMouseDown(.jmh, at: $0) }
                    )
                    .zIndex(scopeZOrder.zIndex(.jmh))
                }
            }

        }
        // Use the same neutral window background as stills — never force black here;
        // MetalEDRImageView handles the black fill via `useBlackBackground` in full-screen.
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 200, maxWidth: .infinity)
    }

    /// ZoomableImageView or a clear placeholder while no image is loaded.
    @ViewBuilder private var imageViewer: some View {
        if let imageData = document.imageManager.currentImage, document.hasAppliedTransforms {
            ZoomableImageView(
                imageData: imageData,
                exposure: document.imageManager.exposure,
                colorTransform: document.imageManager.colorTransform,
                metalColorSpace: document.selectedMetalColorSpace,
                useBlackBackground: document.isFullScreen,
                window: hostWindow,
                gpuProcessor: document.imageManager.gpuProcessor,
                sourceTexture: document.imageManager.originalSourceTexture,
                channelMask: document.channelMode.mask,
                measurePeak: measurePeak,
                onPeakMeasured: { result in
                    document.peakPixelResult = result
                    measurePeak = false
                },
                zoomLevel: $document.zoomLevel,
                onZoomChange: { newZoom in document.zoomLevel = newZoom },
                onAutoFitChange: { isAutoFit in document.isAutoFitZoom = isAutoFit },
                onPanChange: { origin in document.panOffset = origin },
                initialManualZoom: document.restoredManualZoom,
                initialPanOffset: document.restoredPanOffset
            )
        } else {
            Color.clear
        }
    }

    /// Scopes sidebar, hidden in full screen. Colour configuration is the OCIO toolbar popover.
    @ViewBuilder private var sidebar: some View {
        if document.showScopes && !document.isFullScreen {
            ScopesView(
                imageData: document.imageManager.currentImage,
                selectedScope: $document.selectedScope
            )
            .frame(minHeight: 300)
            .frame(minWidth: 300, idealWidth: 400, maxWidth: 500)
        }
    }

    private func checkEDRStatus() {
        document.checkEDRStatus()
    }
    
    private func openImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        // Add support for HDR/EXR formats via OpenImageIO
        panel.allowedContentTypes = [
            .png,
            .jpeg,
            .tiff,
            .bmp,
            .gif,
            UTType(filenameExtension: "exr")!,  // OpenEXR
            UTType(filenameExtension: "hdr")!,  // Radiance HDR
            UTType(filenameExtension: "hdri")!, // HDR variant
            // ── Video ──────────────────────────────────────────────────
            .quickTimeMovie,  // .mov
            .mpeg4Movie,      // .mp4 / .m4v
            .movie,           // generic fallback
        ]

        if panel.runModal() == .OK, let url = panel.url {
            if isMovieURL(url) {
                document.fileURL = url
                handleMovieOpen(url: url)
            } else if isImageSequenceURL(url) {
                document.fileURL = url
                handleSequenceOpen(url: url)
            } else {
                Task {
                    do {
                        document.selectedEXRLayer = ""   // reset for new file
                        try await document.imageManager.loadImage(from: url)
                        await MainActor.run {
                            document.imageLoadCount += 1
                            document.fileURL = url
                        }
                    } catch {
                        showError(error)
                    }
                }
            }
        }
    }

    /// File ▸ Load AMF… — pick an ACES Metadata File and apply its looks to the current image.
    private func loadAMFFromPanel() {
        guard document.imageManager.currentImage != nil else {
            showError(NSError(domain: "com.tristimulator.amf", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Open an image before loading an AMF."]))
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose an ACES Metadata File (.amf)"
        panel.allowedContentTypes = [UTType(filenameExtension: "amf") ?? .xml, .xml]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let amf = try ACESAMFParser.parse(url: url)
            Task { await document.imageManager.attachAMF(amf) }
        } catch {
            showError(error)
        }
    }

    private func saveImage() {
        guard document.imageManager.currentImage != nil else { return }
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Untitled"
        
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    let format = url.pathExtension
                    try await document.imageManager.saveImage(to: url, format: format)
                } catch {
                    showError(error)
                }
            }
        }
    }
    
    @MainActor
    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func copyImageToClipboard() {
        let mgr = document.imageManager
        guard let gpu = mgr.gpuProcessor, gpu.isDisplayPipelineReady else {
            NSSound.beep()
            print("⚠️ Clipboard: OCIO pipeline not ready")
            return
        }

        let isVideo = mgr.isVideoFrame
        guard let srcTex = isVideo ? mgr.currentImage?.metalTexture : mgr.originalSourceTexture else {
            NSSound.beep()
            print("⚠️ Clipboard: no source texture")
            return
        }

        let exposure = mgr.exposure
        let mask = document.channelMode.mask
        let cs = colorSpaceForIdentifier(document.selectedMetalColorSpace)
            ?? CGColorSpace(name: CGColorSpace.extendedDisplayP3)!

        let sdrInfo = buildSDRProcessor(device: srcTex.device)

        Task.detached {
            let ok = await ImageClipboardHelper.copyToClipboard(
                device: srcTex.device,
                gpuProcessor: gpu,
                sourceTexture: srcTex,
                exposure: exposure,
                channelMask: mask,
                colorSpace: cs,
                sdrProcessor: sdrInfo?.processor,
                sdrColorSpace: sdrInfo?.colorSpace
            )
            if !ok {
                await MainActor.run { NSSound.beep() }
            }
        }
    }

    private func copyImageNativeToClipboard() {
        let mgr = document.imageManager
        guard let gpu = mgr.gpuProcessor, gpu.isDisplayPipelineReady else {
            NSSound.beep()
            print("⚠️ Clipboard (native): OCIO pipeline not ready")
            return
        }

        let isVideo = mgr.isVideoFrame
        guard let srcTex = isVideo ? mgr.currentImage?.metalTexture : mgr.originalSourceTexture else {
            NSSound.beep()
            print("⚠️ Clipboard (native): no source texture")
            return
        }

        let exposure = mgr.exposure
        let mask = document.channelMode.mask
        let cs = colorSpaceForIdentifier(document.selectedMetalColorSpace)
            ?? CGColorSpace(name: CGColorSpace.extendedDisplayP3)!

        Task.detached {
            let ok = await ImageClipboardHelper.copyNativeToClipboard(
                device: srcTex.device,
                gpuProcessor: gpu,
                sourceTexture: srcTex,
                exposure: exposure,
                channelMask: mask,
                colorSpace: cs
            )
            if !ok {
                await MainActor.run { NSSound.beep() }
            }
        }
    }

    // MARK: - Scope overlay layout

    /// Binding to a scope's placement, falling back to its default spot.
    private func scopePlacementBinding(_ kind: ScopeKind) -> Binding<ScopeOverlayPlacement> {
        Binding(
            get: { scopePlacements[kind] ?? kind.defaultPlacement },
            set: { scopePlacements[kind] = $0 }
        )
    }

    /// A mouse-down landed on `kind`; raise it (or whichever overlapping scope
    /// under the click was already in front).
    private func scopeMouseDown(_ kind: ScopeKind, at timestamp: TimeInterval) {
        let order = scopeClickResolver.mouseDown(on: kind, at: timestamp, current: scopeZOrder)
        if order != scopeZOrder { scopeZOrder = order }
    }

    /// Current scope visibility, placement and stacking order, as saved per image.
    private var scopeLayoutForPersistence: ScopeLayoutState {
        ScopeLayoutState(
            visible: [.yxy: showChromaticityDiagram, .uv: showUCSDiagram, .jmh: showJmhDiagram],
            placements: scopePlacements,
            zOrder: scopeZOrder)
    }

    /// Re-apply a saved scope layout. `nil` (older settings) leaves the scopes as they are.
    private func restoreScopeLayout(_ layout: ScopeLayoutState?) {
        guard let layout else { return }
        var placements: [ScopeKind: ScopeOverlayPlacement] = [:]
        for kind in ScopeKind.allCases {
            if let p = layout.state(for: kind)?.placement { placements[kind] = p }
        }
        scopePlacements = placements
        scopeZOrder = ScopeZOrder(rawValues: layout.zOrder)
        showChromaticityDiagram = layout.state(for: .yxy)?.visible ?? false
        showUCSDiagram          = layout.state(for: .uv)?.visible ?? false
        showJmhDiagram          = layout.state(for: .jmh)?.visible ?? false
        refreshVisibleScopes()
    }

    /// Feed every open scope the current source texture.
    private func refreshVisibleScopes() {
        if showChromaticityDiagram { updateChromaticity() }
        if showUCSDiagram { updateUCS() }
        if showJmhDiagram { updateJmh() }
    }

    /// Update the CIE 1931 Yxy chromaticity diagram with the current source texture.
    private func updateChromaticity() {
        guard let texture = document.imageManager.originalSourceTexture else { return }
        if chromaticityService == nil {
            chromaticityService = ChromaticityScopeService(device: texture.device, mode: .yxy)
        }
        chromaticityService?.update(
            sourceTexture: texture,
            sourceColorSpace: document.selectedSourceSpace
        )
    }

    /// Update the CIE 1976 UCS u'v' diagram with the current source texture.
    private func updateUCS() {
        guard let texture = document.imageManager.originalSourceTexture else { return }
        if ucsService == nil {
            ucsService = ChromaticityScopeService(device: texture.device, mode: .ucs)
        }
        ucsService?.update(
            sourceTexture: texture,
            sourceColorSpace: document.selectedSourceSpace
        )
    }

    /// Update the JMh (Hellwig 2022) polar scope with the current source texture.
    private func updateJmh() {
        guard let texture = document.imageManager.originalSourceTexture else { return }
        if jmhService == nil {
            jmhService = JmhScopeService(device: texture.device)
        }
        jmhService?.update(
            sourceTexture: texture,
            sourceColorSpace: document.selectedSourceSpace
        )
    }

    private func initializePipeline() {
        print("🔧 initializePipeline() called")
        let colorSpaces = document.imageManager.availableColorSpaces()
        guard !colorSpaces.isEmpty else {
            print("⚠️ No color spaces available")
            return
        }

        print("📦 Available color spaces: \(colorSpaces.count)")

        // ── Restore per-image/per-window saved settings (early return if valid) ───
        let store = OCIOSettingsStore.shared
        let displays = document.imageManager.availableDisplays()

        // Extra windows look up their private settings bucket first (keyed by
        // windowID); primary windows use the per-file bucket.
        let saved: OCIOPipelineSettings?
        if document.isExtraWindow {
            saved = store.settings(forWindow: document.windowID)
                ?? document.fileURL.flatMap { store.settings(for: $0) }
        } else {
            saved = document.fileURL.flatMap { store.settings(for: $0) }
        }

        // ── If the saved settings require a different OCIO config, load it first ──
        // Only do this during the initial restore phase (!hasAppliedTransforms).
        // Once the user is in an active session we leave their config choice alone —
        // otherwise every manual config load would be immediately reverted to the
        // per-image saved value.
        if !document.hasAppliedTransforms,
           let saved = saved,
           let savedConfigPath = saved.ocioConfigPath,
           savedConfigPath != document.imageManager.loadedConfigPath {
            print("🔄 Per-image config differs from current – loading: \(URL(fileURLWithPath: savedConfigPath).lastPathComponent)")
            Task { @MainActor in
                do {
                    try await document.imageManager.loadOCIOConfig(from: savedConfigPath)
                    // Also tell the global store so the config-path text field stays in sync
                    OCIOSettingsStore.shared.saveCustomConfigPath(savedConfigPath)
                    print("✅ Per-image config loaded – re-running initializePipeline")
                    initializePipeline()
                } catch {
                    print("⚠️ Could not load per-image OCIO config '\(savedConfigPath)': \(error)")
                    print("   Falling through to current config defaults")
                    // Continue with current config — initializePipeline will fall
                    // through to defaults since the saved spaces won't validate.
                }
            }
            return
        }

        // AMF look toggles don't depend on the OCIO config, so restore them whenever
        // there are saved settings (even if the colour spaces below turn out stale).
        // Done before the AMF finishes loading is fine: ImageManager keeps the state
        // and overlays it when it initialises the toggles.
        if let saved = saved, !document.hasAppliedTransforms {
            document.imageManager.restoreAMFLookToggles(
                states: saved.amfLookStates,
                globallyEnabled: saved.amfLooksGloballyEnabled)
            // Scope overlays are independent of the OCIO config too.
            restoreScopeLayout(saved.scopeLayout)
        }

        if let saved = saved, let fileURL = document.fileURL {
            let _ = fileURL  // silence unused-variable warning

            // Validate every saved value against the *current* config.
            // If the config has changed since the settings were saved the names
            // will not exist and we must fall through to defaults instead.
            let savedSourceOK = colorSpaces.contains(saved.sourceSpace)
            let savedDestOK   = colorSpaces.contains(saved.destSpace)
            let savedDisplayOK = displays.contains(saved.display)
            let savedViewOK   = savedDisplayOK &&
                document.imageManager.views(for: saved.display).contains(saved.view)

            if savedSourceOK && savedDestOK && savedDisplayOK && savedViewOK {
                let label = document.isExtraWindow
                    ? "window \(document.windowID.prefix(8))…"
                    : fileURL.lastPathComponent
                print("📂 Restoring saved OCIO settings for \(label)")
                isRestoringSettings = true
                document.selectedSourceSpace           = saved.sourceSpace
                document.selectedDestSpace             = saved.destSpace
                document.selectedDisplay               = saved.display
                document.selectedView                  = saved.view
                if saved.dynamicACES2Mode {
                    document.selectedMetalColorSpace = "extendedDisplayP3"
                } else {
                    document.selectedMetalColorSpace = DisplaySurfaceMapping.shared.surface(forDisplay: saved.display)
                }
                document.imageManager.useCPURenderPath = saved.useCPURenderPath
                document.imageManager.exposure         = saved.exposure
                document.imageManager.dynamicACES2Mode       = saved.dynamicACES2Mode
                document.imageManager.dynamicACES2AutoNits    = saved.dynamicACES2AutoNits
                document.imageManager.dynamicACES2Gamut      = saved.dynamicACES2Gamut
                document.imageManager.dynamicACES2TargetNits = saved.dynamicACES2TargetNits
                document.imageManager.sourceTransformMode    = saved.sourceTransformMode
                document.imageManager.sourceInverseDisplay   = saved.sourceInverseDisplay
                document.imageManager.sourceInverseView      = saved.sourceInverseView
                Task { await document.imageManager.updateExposure(saved.exposure) }

                // Restore view state
                if let layer = saved.selectedEXRLayer, !layer.isEmpty {
                    document.selectedEXRLayer = layer
                }
                if let mode = saved.channelMode, let cm = ChannelMode(rawValue: mode) {
                    document.channelMode = cm
                }
                if let zoom = saved.zoomLevel {
                    document.restoredManualZoom = CGFloat(zoom)
                    document.isAutoFitZoom = false
                    if let px = saved.panX, let py = saved.panY {
                        document.restoredPanOffset = CGPoint(x: px, y: py)
                    }
                }
                // Restore frame position for sequences
                if let frameIdx = saved.currentFrameIndex, let seq = document.sequenceSource {
                    seq.seek(to: frameIdx)
                }
                // Restore playback time for movies
                if let time = saved.currentTime, let movie = document.movieSource {
                    movie.seek(to: time)
                }

                isRestoringSettings = false
                if document.imageManager.currentImage != nil {
                    Task { @MainActor in
                        await Task.yield()
                        await applyOCIOAndMarkReady()
                        let label = document.isExtraWindow
                            ? "window \(document.windowID.prefix(8))…"
                            : fileURL.lastPathComponent
                        print("✅ Restored settings applied for \(label)")
                        saveCurrentSettings()
                    }
                }
                return
            } else {
                print("⚠️ Saved settings are stale (config changed) — using defaults")
                print("   sourceOK=\(savedSourceOK) destOK=\(savedDestOK) displayOK=\(savedDisplayOK) viewOK=\(savedViewOK)")
            }
        }

        // ── New image / stale settings: seed from global defaults before empty-checks ──
        let globals = store.globalDefaults
        isRestoringSettings = true
        // Only seed each field when the global value is valid for the current config.
        if !globals.destSpace.isEmpty && colorSpaces.contains(globals.destSpace) {
            document.selectedDestSpace = globals.destSpace
        }
        if !globals.display.isEmpty && displays.contains(globals.display) {
            document.selectedDisplay = globals.display
            let globalViews = document.imageManager.views(for: globals.display)
            if !globals.view.isEmpty && globalViews.contains(globals.view) {
                document.selectedView = globals.view
            }
        }
        if globals.dynamicACES2Mode {
            document.selectedMetalColorSpace = "extendedDisplayP3"
        } else if !globals.display.isEmpty {
            document.selectedMetalColorSpace = DisplaySurfaceMapping.shared.surface(forDisplay: globals.display)
        }
        document.imageManager.useCPURenderPath = globals.useCPURenderPath
        // Restore Dynamic ACES2 settings from global defaults.
        document.imageManager.dynamicACES2Mode       = globals.dynamicACES2Mode
        document.imageManager.dynamicACES2AutoNits    = globals.dynamicACES2AutoNits
        document.imageManager.dynamicACES2Gamut      = globals.dynamicACES2Gamut
        document.imageManager.dynamicACES2TargetNits = globals.dynamicACES2TargetNits
        isRestoringSettings = false

        // Always try to match the new image's color space
        var tagMatchedSpace: String?
        if let metadata = document.imageManager.currentImage?.metadata {
            let imageColorSpace = metadata.colorSpace
            if !imageColorSpace.isEmpty,
               let matchedSpace = ColorSpaceAliases.findMatch(for: imageColorSpace, in: colorSpaces) {
                document.selectedSourceSpace = matchedSpace
                tagMatchedSpace = matchedSpace
                print("🎯 Re-matched new image color space '\(imageColorSpace)' to '\(matchedSpace)'")
            }
        }
        
        if document.selectedSourceSpace.isEmpty {
            // Only set defaults if nothing is selected yet
            if let sceneLinear = document.imageManager.ocioConfig?.sceneLinearColorSpace() {
                document.selectedSourceSpace = sceneLinear
            } else if let defaultSpace = document.imageManager.ocioConfig?.defaultColorSpace() {
                document.selectedSourceSpace = defaultSpace
            } else {
                document.selectedSourceSpace = colorSpaces[0]
            }
            print("📌 Set default source space: \(document.selectedSourceSpace)")
        } else {
            print("ℹ️ Keeping existing source space: \(document.selectedSourceSpace)")
        }

        // Preference: bring display-referred images in through an inverse output transform.
        // Off by default; this block then changes nothing.
        if UserDefaults.standard.bool(forKey: InverseDisplaySelection.preferenceKey) {
            applyInverseDisplayPreference(tagMatchedSpace: tagMatchedSpace)
        }
        
        // Keep dest space as-is (working space shouldn't change when loading new images)
        if document.selectedDestSpace.isEmpty {
            if let sceneLinear = document.imageManager.ocioConfig?.sceneLinearColorSpace() {
                document.selectedDestSpace = sceneLinear
            } else if let defaultSpace = document.imageManager.ocioConfig?.defaultColorSpace() {
                document.selectedDestSpace = defaultSpace
            } else {
                document.selectedDestSpace = colorSpaces[0]
            }
            print("📌 Set default dest space: \(document.selectedDestSpace)")
        } else {
            print("ℹ️ Keeping existing dest space: \(document.selectedDestSpace)")
        }
        
        if !displays.isEmpty && document.selectedDisplay.isEmpty {
            // Choose display based on HDR capability
            let preferredDisplay: String
            let preferredView: String
            
            if document.isHDRAvailable {
                // HDR-capable display
                preferredDisplay = "Display P3 HDR - Display"
                preferredView = "ACES 2.0 - HDR 1000 nits (P3 D65)"
                print("🌟 HDR capable display detected, using HDR display profile")
            } else {
                // SDR display
                preferredDisplay = "Display P3 - Display"
                preferredView = "ACES 2.0 - SDR 100 nits (P3 D65)"
                print("📺 SDR display detected, using SDR display profile")
            }
            
            // Try to use the preferred display if it exists, otherwise fall back
            if displays.contains(preferredDisplay) {
                document.selectedDisplay = preferredDisplay
                print("✅ Using preferred display: \(preferredDisplay)")
            } else if let defaultDisplay = document.imageManager.ocioConfig?.defaultDisplay(), !defaultDisplay.isEmpty {
                document.selectedDisplay = defaultDisplay
                print("⚠️ Preferred display '\(preferredDisplay)' not found, using default: \(defaultDisplay)")
            } else {
                document.selectedDisplay = displays[0]
                print("⚠️ Preferred display '\(preferredDisplay)' not found, using first available: \(displays[0])")
            }
            
            let views = document.imageManager.views(for: document.selectedDisplay)
            if !views.isEmpty {
                // Try to use the preferred view if it exists for this display
                if views.contains(preferredView) {
                    document.selectedView = preferredView
                    print("✅ Using preferred view: \(preferredView)")
                } else if let defaultView = document.imageManager.ocioConfig?.defaultView(forDisplay: document.selectedDisplay), !defaultView.isEmpty {
                    document.selectedView = defaultView
                    print("⚠️ Preferred view '\(preferredView)' not found, using default: \(defaultView)")
                } else {
                    document.selectedView = views[0]
                    print("⚠️ Preferred view '\(preferredView)' not found, using first available: \(views[0])")
                }
            }
            print("📌 Set display: \(document.selectedDisplay), view: \(document.selectedView)")

            // Default to Dynamic ACES 2 mode when using the built-in config.
            // This gives the best out-of-box HDR experience — peak nits are
            // derived from the display's current EDR headroom automatically.
            if store.customConfigPath == nil {
                document.imageManager.dynamicACES2Mode    = true
                document.imageManager.dynamicACES2AutoNits = true
                print("📌 Enabled Dynamic ACES 2 mode (built-in config default)")
            }
        }
        
        // Apply transforms
        if document.imageManager.currentImage != nil {
            print("🎨 Applying transforms: \(document.selectedSourceSpace) → \(document.selectedDestSpace) → Display(\(document.selectedDisplay)/\(document.selectedView))")

            Task { @MainActor in
                // Give SwiftUI one frame to lay out before showing the image.
                await Task.yield()
                // Await the full OCIO pipeline compile so draw() always has a
                // ready pipeline the first time the image appears — no raw flash.
                await applyOCIOAndMarkReady()
                print("✅ Transforms complete, showing image")
                saveCurrentSettings()
            }
        } else {
            print("⚠️ No current image to transform")
        }
    }

    /// With the "inverse output transform for display-referred images" preference on,
    /// choose the source mode for a newly opened image that has no saved settings.
    /// If the tag matched an SDR display colour space with an invertible SDR view, use
    /// Inverse Display mode on that display/view; otherwise use Color Space mode.
    /// Scripting overrides run later and still win.
    private func applyInverseDisplayPreference(tagMatchedSpace: String?) {
        let manager = document.imageManager
        guard let config = manager.ocioConfig else { return }

        guard let space = tagMatchedSpace,
              let target = InverseDisplaySelection.target(
                  for: space, in: InverseDisplayConfigQuery(config: config))
        else {
            manager.sourceTransformMode = .colorspace
            return
        }

        do {
            // Build the inverse once up front so a non-invertible view falls back cleanly.
            _ = try OCIOProcessor.makeInverseDisplayProcessor(
                config: config, display: target.display, view: target.view)
        } catch {
            print("⚠️ Inverse display preference: inv(\(target.display)/\(target.view)) failed to build (\(error.localizedDescription)); staying in Color Space mode for '\(space)'")
            manager.sourceTransformMode = .colorspace
            return
        }

        manager.sourceInverseDisplay = target.display
        manager.sourceInverseView = target.view
        manager.sourceTransformMode = .inverseDisplay
        print("🔁 Inverse display preference: '\(space)' → inv(\(target.display)/\(target.view))")
    }

    /// Compile the OCIO GPU pipeline for the current settings, then reveal the image
    /// by setting `hasAppliedTransforms = true`.  Both steps happen in one awaited
    /// call so the Metal view's first `draw()` always has a ready pipeline —
    /// eliminating the "raw" flash that occurred when `hasAppliedTransforms` was set
    /// before the async compile finished.
    @MainActor
    private func applyOCIOAndMarkReady() async {
        // Run scripting overrides on the first pipeline compile per image load.
        // scriptAppliedForCurrentLoad is false only for the initial image open,
        // not for EXR layer changes or manual setting changes.
        if !scriptAppliedForCurrentLoad, !document.hasAppliedTransforms,
           let fileURL = document.fileURL
        {
            scriptAppliedForCurrentLoad = true
            await applyScriptingOverrides(for: fileURL)
        }

        let sourceSpace = document.selectedSourceSpace
        defer { document.hasAppliedTransforms = true }
        guard !sourceSpace.isEmpty,
              !document.selectedDisplay.isEmpty,
              !document.selectedView.isEmpty else { return }
        do {
            if document.imageManager.dynamicACES2Mode {
                try await document.imageManager.applyDynamicACES2Transform(sourceSpace: sourceSpace)
            } else {
                try await document.imageManager.applyDisplayTransform(
                    from: sourceSpace,
                    display: document.selectedDisplay,
                    view: document.selectedView)
            }
        } catch {
            print("⚠️ applyOCIOAndMarkReady: \(error)")
        }
    }

    // MARK: - Scripting

    /// Evaluate the user's rules script and apply any returned settings before
    /// the first pipeline compile. The image remains hidden (hasAppliedTransforms
    /// is still false) so the user never sees an intermediate state.
    @MainActor
    private func applyScriptingOverrides(for fileURL: URL) async {
        let engine = ScriptingEngine.shared
        guard engine.isEnabled, !engine.scriptPath.isEmpty else { return }

        let ctx = ScriptingContext(
            fileURL:            fileURL,
            imageData:          document.imageManager.currentImage,
            loadedConfigPath:   document.imageManager.loadedConfigPath,
            currentSourceSpace: document.selectedSourceSpace,
            currentDisplay:     document.selectedDisplay,
            currentView:        document.selectedView
        )

        guard let result = await engine.evaluate(context: ctx) else { return }
        print("🎬 [Scripting] Applying overrides for \(fileURL.lastPathComponent)")

        // Load a different config first — must happen before space/display names are set,
        // as those names are only valid within the newly loaded config.
        if let configPath = result.ocioConfig,
           configPath != document.imageManager.loadedConfigPath
        {
            do {
                try await document.imageManager.loadOCIOConfig(from: configPath)
                OCIOSettingsStore.shared.saveCustomConfigPath(configPath)
                print("📁 [Scripting] Loaded config: \(URL(fileURLWithPath: configPath).lastPathComponent)")
            } catch {
                print("⚠️ [Scripting] Failed to load config '\(configPath)': \(error)")
            }
        }

        let colorSpaces = document.imageManager.availableColorSpaces()
        let displays    = document.imageManager.availableDisplays()

        if let space = result.sourceSpace, colorSpaces.contains(space) {
            document.selectedSourceSpace = space
        }
        if let display = result.display, displays.contains(display) {
            document.selectedDisplay = display
            if let view = result.view,
               document.imageManager.views(for: display).contains(view)
            {
                document.selectedView = view
            }
        } else if let view = result.view,
                  document.imageManager.views(for: document.selectedDisplay).contains(view)
        {
            document.selectedView = view
        }

        // When the script loaded a new config but didn't specify display/view,
        // fall back to the config's defaults so the pickers aren't left blank.
        if result.ocioConfig != nil {
            if result.display == nil || !displays.contains(document.selectedDisplay) {
                let fallback = document.imageManager.ocioConfig?.defaultDisplay() ?? displays.first ?? ""
                if !fallback.isEmpty {
                    document.selectedDisplay = fallback
                }
            }
            let views = document.imageManager.views(for: document.selectedDisplay)
            if result.view == nil || !views.contains(document.selectedView) {
                let fallback = document.imageManager.ocioConfig?.defaultView(forDisplay: document.selectedDisplay) ?? views.first ?? ""
                if !fallback.isEmpty {
                    document.selectedView = fallback
                }
            }
        }
        if let exposure = result.exposure {
            document.imageManager.exposure = exposure
            await document.imageManager.updateExposure(exposure)
        }
        if let layer = result.selectedEXRLayer, !layer.isEmpty {
            document.selectedEXRLayer = layer
        }
        if let modeStr = result.sourceTransformMode {
            let mode: SourceTransformMode? = switch modeStr {
            case "colorspace",     "Color Space":      .colorspace
            case "inverseDisplay", "Inverse Display":  .inverseDisplay
            default:                                    SourceTransformMode(rawValue: modeStr)
            }
            if let mode { document.imageManager.sourceTransformMode = mode }
        }
    }

    // MARK: - Settings persistence

    /// Persist the current pipeline state and update global defaults.
    ///
    /// • Extra windows (opened via "New Window for This Image") save to the
    ///   per-windowID bucket so their settings don't overwrite the primary
    ///   window's per-file settings.
    /// • Primary windows save to the per-file bucket (existing behaviour).
    private func saveCurrentSettings() {
        let amfToggles = document.imageManager.amfLookTogglesForPersistence()
        let settings = OCIOPipelineSettings(
            sourceSpace:            document.selectedSourceSpace,
            destSpace:              document.selectedDestSpace,
            display:                document.selectedDisplay,
            view:                   document.selectedView,
            metalColorSpace:        document.selectedMetalColorSpace,
            useCPURenderPath:       document.imageManager.useCPURenderPath,
            exposure:               document.imageManager.exposure,
            dynamicACES2Mode:       document.imageManager.dynamicACES2Mode,
            dynamicACES2AutoNits:    document.imageManager.dynamicACES2AutoNits,
            dynamicACES2Gamut:      document.imageManager.dynamicACES2Gamut,
            dynamicACES2TargetNits: document.imageManager.dynamicACES2TargetNits,
            ocioConfigPath:         document.imageManager.loadedConfigPath,
            sourceTransformMode:    document.imageManager.sourceTransformMode,
            sourceInverseDisplay:   document.imageManager.sourceInverseDisplay,
            sourceInverseView:      document.imageManager.sourceInverseView,
            currentFrameIndex:      document.sequenceSource?.currentIndex,
            currentTime:            document.movieSource?.currentTime,
            selectedEXRLayer:       document.selectedEXRLayer.isEmpty ? nil : document.selectedEXRLayer,
            zoomLevel:              document.isAutoFitZoom ? nil : Double(document.zoomLevel),
            panX:                   document.isAutoFitZoom ? nil : document.panOffset.x,
            panY:                   document.isAutoFitZoom ? nil : document.panOffset.y,
            channelMode:            document.channelMode == .normal ? nil : document.channelMode.rawValue,
            amfLookStates:          amfToggles.states,
            amfLooksGloballyEnabled: amfToggles.globallyEnabled,
            scopeLayout:            scopeLayoutForPersistence
        )
        let store = OCIOSettingsStore.shared
        if document.isExtraWindow {
            // Extra windows use a stable windowID — don't overwrite the primary
            // window's per-file entry.
            store.save(settings, forWindow: document.windowID)
            print("💾 OCIO settings saved for extra window \(document.windowID.prefix(8))…")
        } else {
            guard let fileURL = document.fileURL else { return }
            store.save(settings, for: fileURL)
            print("💾 OCIO settings saved for \(fileURL.lastPathComponent)")
        }
        // Propagate to global defaults so new images start with the user's
        // most-recently chosen pipeline.
        store.saveAsGlobalDefaults(settings)
    }

    /// Called from `onChange` modifiers; skips saves during programmatic restore.
    /// Debounced: the actual disk write fires 0.8 s after the last change so that
    /// rapid scrubbing or exposure drags don't hammer the file system per-frame.
    private func autosaveSettings() {
        guard !isRestoringSettings,
              document.hasAppliedTransforms else { return }
        autosaveDebounceTask?.cancel()
        autosaveDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            saveCurrentSettings()
        }
    }

    // MARK: - Revert to built-in OCIO config

    private func revertToBuiltinOCIOConfig() {
        Task { @MainActor in
            do {
                try await document.imageManager.revertToBundledOCIOConfig()

                // Clear any stored custom config path so future launches don't reload it.
                OCIOSettingsStore.shared.saveCustomConfigPath(nil)

                // Reset all pipeline selections so initializePipeline() rebuilds
                // from scratch using fresh defaults from the bundled config.
                document.selectedSourceSpace     = ""
                document.selectedDestSpace       = ""
                document.selectedDisplay         = ""
                document.selectedView            = ""
                document.hasAppliedTransforms    = false

                // Re-run pipeline initialization with the restored config.
                NotificationCenter.default.post(name: .ocioConfigChanged, object: nil)
                print("↩ Reverted to built-in OCIO config")
            } catch {
                showError(error)
            }
        }
    }

    // MARK: - SDR Processor for Gain Maps

    private func buildSDRProcessor(device: MTLDevice) -> (processor: OCIOGPUProcessor, colorSpace: CGColorSpace)? {
        let mgr = document.imageManager
        guard let config = mgr.ocioConfig else {
            print("⚠️ SDR Processor: no OCIO config")
            return nil
        }

        let sdrGpu = OCIOGPUProcessor(device: device)

        if mgr.dynamicACES2Mode {
            // ACES2: same pipeline with peakNits=100 (SDR)
            guard let linearSpace = config.sceneLinearColorSpace() else {
                print("⚠️ SDR Processor: no scene-linear space in config")
                return nil
            }
            do {
                let gamut = mgr.dynamicACES2Gamut
                let aces2Proc = try OCIOProcessor.makeDynamicACES2Processor(
                    config: config,
                    sourceSpace: linearSpace,
                    peakNits: 100.0,
                    outputGamutXY: gamut.xy
                )

                let sourceSpace = document.selectedSourceSpace.isEmpty
                    ? (config.sceneLinearColorSpace() ?? "ACES2065-1")
                    : document.selectedSourceSpace

                try sdrGpu.setupCombinedACES2Transform(
                    config: config,
                    sourceSpace: sourceSpace,
                    peakNits: 100.0,
                    gamutTag: gamut.rawValue,
                    aces2Processor: aces2Proc
                )

                let sdrCS: CGColorSpace
                switch gamut {
                case .p3d65:  sdrCS = CGColorSpace(name: CGColorSpace.displayP3)!
                case .rec709: sdrCS = CGColorSpace(name: CGColorSpace.sRGB)!
                case .rec2020: sdrCS = CGColorSpace(name: CGColorSpace.itur_2020)!
                }

                print("✅ SDR Processor: ACES2 peakNits=100, gamut=\(gamut.rawValue)")
                return (sdrGpu, sdrCS)
            } catch {
                print("❌ SDR Processor: ACES2 setup failed: \(error)")
                return nil
            }
        } else {
            // Config mode: find a suitable SDR display using the existing
            // DisplaySurfaceMapping rules to derive the correct CGColorSpace.
            let displays = config.displayNames()
            let sourceSpace = document.selectedSourceSpace.isEmpty
                ? (config.sceneLinearColorSpace() ?? "ACES2065-1")
                : document.selectedSourceSpace

            let hdrSurfaces: Set<String> = [
                "itur_2100_PQ", "itur_2100_HLG",
                "extendedDisplayP3", "extendedSRGB",
                "extendedLinearDisplayP3", "extendedLinearSRGB", "extendedLinearITUR_2020"
            ]

            // Ranked preference: P3 SDR first, then sRGB/709, then anything non-HDR
            let preferred = ["p3", "srgb", "rec.?709", "bt.?709", "709"]

            var candidates: [(display: String, surface: String, rank: Int)] = []
            for displayName in displays {
                let surface = DisplaySurfaceMapping.shared.surface(forDisplay: displayName)
                guard !hdrSurfaces.contains(surface) else { continue }
                let lower = displayName.lowercased()
                var rank = preferred.count
                for (i, pat) in preferred.enumerated() {
                    if let regex = try? NSRegularExpression(pattern: pat, options: .caseInsensitive),
                       regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                        rank = i
                        break
                    }
                }
                candidates.append((displayName, surface, rank))
            }
            candidates.sort { $0.rank < $1.rank }

            for candidate in candidates {
                let views = config.viewNames(forDisplay: candidate.display)
                guard let firstView = views.first else { continue }
                guard let cs = colorSpaceForIdentifier(candidate.surface) else { continue }
                do {
                    try sdrGpu.setupCombinedTransform(
                        config: config,
                        sourceSpace: sourceSpace,
                        display: candidate.display,
                        view: firstView
                    )
                    print("✅ SDR Processor: config mode \(candidate.display) / \(firstView) → \(candidate.surface)")
                    return (sdrGpu, cs)
                } catch {
                    print("⚠️ SDR Processor: failed \(candidate.display)/\(firstView): \(error)")
                    continue
                }
            }

            print("⚠️ SDR Processor: no suitable SDR display found in config")
            return nil
        }
    }

    // MARK: - Export Gain Map Image

    private func exportGainMapImage() {
        let mgr = document.imageManager
        guard let gpu = mgr.gpuProcessor, gpu.isDisplayPipelineReady else {
            NSSound.beep()
            print("⚠️ Export: OCIO pipeline not ready")
            return
        }

        let isVideo = mgr.isVideoFrame
        guard let srcTex = isVideo ? mgr.currentImage?.metalTexture : mgr.originalSourceTexture else {
            NSSound.beep()
            print("⚠️ Export: no source texture")
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (document.fileURL?.deletingPathExtension().lastPathComponent ?? "export") + "_hdr"
        panel.message = "Export OCIO-processed image with HDR gain map"
        panel.allowedContentTypes = [.jpeg, .heic]

        let ultraHDRToggle = NSButton(checkboxWithTitle: "UltraHDR Compatible (Chrome / Android)", target: nil, action: nil)
        ultraHDRToggle.toolTip = "Inject UltraHDR metadata so Chrome and Android apps can display HDR"
        let accessoryBox = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 32))
        ultraHDRToggle.frame = NSRect(x: 12, y: 4, width: 320, height: 24)
        accessoryBox.addSubview(ultraHDRToggle)
        panel.accessoryView = accessoryBox

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ultraHDR = ultraHDRToggle.state == .on
        let exposure = mgr.exposure
        let mask = document.channelMode.mask
        let cs = colorSpaceForIdentifier(document.selectedMetalColorSpace)
            ?? CGColorSpace(name: CGColorSpace.extendedDisplayP3)!

        let sdrInfo = buildSDRProcessor(device: srcTex.device)

        Task.detached {
            let outcome = await ImageClipboardHelper.exportGainMapImage(
                device: srcTex.device,
                gpuProcessor: gpu,
                sourceTexture: srcTex,
                exposure: exposure,
                channelMask: mask,
                colorSpace: cs,
                url: url,
                sdrProcessor: sdrInfo?.processor,
                sdrColorSpace: sdrInfo?.colorSpace,
                ultraHDRCompatible: ultraHDR
            )
            await MainActor.run {
                switch outcome {
                case .saved:
                    break
                case .failed:
                    NSSound.beep()
                case .savedWithoutUltraHDR(let reason):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Saved without UltraHDR metadata"
                    alert.informativeText = "The image was saved as an HDR gain-map JPEG, but the UltraHDR metadata for Chrome and Android couldn't be added: \(reason)."
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Export / Import

    private func exportOCIOSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "tristimulator-color-settings"
        panel.message = "Export OCIO pipeline settings as JSON"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OCIOSettingsStore.shared.exportJSON(to: url)
            print("📤 OCIO settings exported to \(url.lastPathComponent)")
        } catch {
            showError(error)
        }
    }

    private func importOCIOSettings() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.message = "Import previously exported OCIO pipeline settings"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OCIOSettingsStore.shared.importJSON(from: url)
            print("📥 OCIO settings imported from \(url.lastPathComponent)")
            // If the current image has newly imported settings, apply them immediately
            if let fileURL = document.fileURL,
               let saved = OCIOSettingsStore.shared.settings(for: fileURL) {
                isRestoringSettings = true
                document.selectedSourceSpace           = saved.sourceSpace
                document.selectedDestSpace             = saved.destSpace
                document.selectedDisplay               = saved.display
                document.selectedView                  = saved.view
                if saved.dynamicACES2Mode {
                    document.selectedMetalColorSpace = "extendedDisplayP3"
                } else {
                    document.selectedMetalColorSpace = DisplaySurfaceMapping.shared.surface(forDisplay: saved.display)
                }
                document.imageManager.useCPURenderPath = saved.useCPURenderPath
                document.imageManager.exposure         = saved.exposure
                document.imageManager.dynamicACES2Mode       = saved.dynamicACES2Mode
                document.imageManager.dynamicACES2AutoNits    = saved.dynamicACES2AutoNits
                document.imageManager.dynamicACES2Gamut      = saved.dynamicACES2Gamut
                document.imageManager.dynamicACES2TargetNits = saved.dynamicACES2TargetNits
                document.imageManager.restoreAMFLookToggles(
                    states: saved.amfLookStates,
                    globallyEnabled: saved.amfLooksGloballyEnabled)
                restoreScopeLayout(saved.scopeLayout)
                Task { await document.imageManager.updateExposure(saved.exposure) }
                isRestoringSettings = false
                applyColorTransformAndReapplyDisplay()
            }
        } catch {
            showError(error)
        }
    }

    private func applyColorTransformAndReapplyDisplay() {
        document.applyCurrentOCIOTransform()
    }

    // MARK: - Movie support

    /// Returns true for URL path extensions that AVFoundation can decode.
    private func isMovieURL(_ url: URL) -> Bool {
        let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mxf", "dv"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Open `url` as a movie via AVFoundation.  Creates and owns a `MovieSource`,
    /// grabs the first frame, and triggers `initializePipeline()` so the full OCIO
    /// pipeline is compiled once before playback starts.
    private func handleMovieOpen(url: URL) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ Metal not available — cannot open movie")
            return
        }

        let movie = MovieSource(url: url, device: device)
        document.movieSource = movie

        // Wire the frame callback immediately so startFrameExtraction (called below)
        // can deliver frames as soon as it starts.  Previously this was set in
        // MovieControlsView.onAppear; setting it here decouples it from the view lifecycle.
        movie.onFrame = { [weak document] tex, _ in
            guard let document else { return }
            document.imageManager.loadFrame(
                tex,
                colorSpaceHint: document.selectedSourceSpace.isEmpty
                    ? "Rec.709"
                    : document.selectedSourceSpace
            )
        }

        Task { @MainActor in
            // Load duration / frame rate metadata from the asset.
            await movie.loadMetadata()

            print("🎬 Movie loaded: \(url.lastPathComponent)")
            print("   Size: \(Int(movie.naturalSize.width))×\(Int(movie.naturalSize.height))")
            print("   Duration: \(String(format: "%.2f", movie.duration))s @ \(movie.frameRate) fps")

            // Seek to frame 0 and extract the first texture.  Use "Rec.709" as a
            // default hint — the user can override via the Source Space picker.
            if let tex = await movie.seekAndCapture(to: 0) {
                document.imageManager.loadFrame(tex, colorSpaceHint: "Rec.709")
                // Increment imageLoadCount to fire initializePipeline() and compile
                // the OCIO GPU pipeline for this first frame's dimensions.
                document.imageLoadCount += 1
                // Start observers AFTER the first seekAndCapture so the initial
                // seek does not double-deliver via timeJumpedNotification.
                movie.startFrameExtraction()
            } else {
                print("⚠️ Could not decode first frame of \(url.lastPathComponent)")
            }
        }
    }

    // MARK: - Image sequence support

    /// Returns true when `url` is a numbered still-image file that belongs to a
    /// multi-frame sequence (i.e. at least one sibling shares the same prefix+ext).
    ///
    /// Detection is fast: first a cheaply-validated numeric-suffix check rules out
    /// unnumbered stills without touching the filesystem; only matching candidates
    /// trigger the (cheap) directory scan.
    private func isImageSequenceURL(_ url: URL) -> Bool {
        guard !isMovieURL(url) else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        let trailingDigits = stem.reversed().prefix(while: { $0.isNumber })
        guard !trailingDigits.isEmpty else { return false }
        // Directory scan: returns > 1 only if siblings with the same prefix exist.
        return ImageSequenceSource.discoverSequence(from: url).count > 1
    }

    /// Open `url` as an image sequence via OpenImageIO.  Creates and owns an
    /// `ImageSequenceSource`, delivers the first frame, and increments
    /// `imageLoadCount` to trigger `initializePipeline()`.
    private func handleSequenceOpen(url: URL) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ Metal not available — cannot open image sequence")
            return
        }

        let seq = ImageSequenceSource(representativeURL: url, device: device)
        document.selectedEXRLayer = ""   // reset for new sequence
        document.sequenceSource = seq
        document.movieSource = nil   // sequences and movies are mutually exclusive

        // Deliver every new frame into the GPU pipeline.
        // `loadFrame(_:ImageData)` preserves the full OIIO metadata (color space,
        // bit depth, HDR flag) rather than the minimal Rec.709 hint used for video.
        seq.onFrame = { [weak document] _, imgData in
            guard let document else { return }
            document.imageManager.loadFrame(imgData)
        }

        Task { @MainActor in
            await seq.loadMetadata()

            guard seq.isLoaded else {
                print("⚠️ ImageSequenceSource: could not load first frame of \(url.lastPathComponent)")
                return
            }

            print("🎞️ Sequence loaded: \(url.lastPathComponent)")
            print("   \(seq.frameCount) frames @ \(seq.frameRate) fps")
            if let firstFrame = seq.frames.first {
                print("   Directory: \(firstFrame.deletingLastPathComponent().lastPathComponent)/")
            }

            // Trigger OCIO pipeline compilation for the sequence frame geometry.
            document.imageLoadCount += 1
        }
    }

    private func handleMouseMove(_ location: CGPoint) {
        // Movie controls auto-hide: just stamp the time and ensure controls are visible.
        // A single persistent watcher task (started in startMovieControlsWatcher) polls
        // this timestamp — no per-event Task allocation.
        if document.movieSource != nil && !isHoveringMovieControls {
            lastMouseActivityDate = .now
            if !showMovieControls {
                showMovieControls = true
                startMovieControlsWatcher()
            }
        }

        // Sequence controls auto-hide — same pattern as movies.
        if document.sequenceSource != nil && !isHoveringSequenceControls {
            lastMouseActivityDate = .now
            if !showSequenceControls {
                showSequenceControls = true
                startSequenceControlsWatcher()
            }
        }

        // Windowed still info bar auto-hide: same watcher pattern.
        if document.movieSource == nil && document.sequenceSource == nil
            && !document.isFullScreen && !isHoveringStillInfoBar {
            if !showStillInfoBar {
                showStillInfoBar = true
                startStillInfoBarWatcher()
            } else {
                // Already visible — just reset the countdown.
                lastMouseActivityDate = .now
            }
        }

        guard document.isFullScreen else { return }

        // Show cursor on movement
        NSCursor.unhide()
        
        // Cancel any pending hide tasks
        document.hideInfoBarTask?.cancel()
        document.hideToolbarTask?.cancel()
        
        // Show toolbar and info bar immediately on mouse movement
        if !document.showInfoBarInFullScreen { document.showInfoBarInFullScreen = true }
        if !document.showToolbarInFullScreen  { document.showToolbarInFullScreen  = true }

        // If the cursor is currently over a control, don't schedule a new hide —
        // the onHover handler will restart the countdown when the cursor leaves.
        guard !isHoveringFullScreenControls else { return }

        // Schedule hiding toolbar, info bar, and cursor after 2 seconds of inactivity
        let hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                document.showInfoBarInFullScreen = false
                document.showToolbarInFullScreen = false
                NSCursor.hide()
            }
        }
        
        document.hideInfoBarTask = hideTask
        document.hideToolbarTask = hideTask
    }

    /// Starts (or restarts) the single persistent watcher task for movie controls auto-hide.
    /// Polls every 0.5 s — O(1) tasks total regardless of mouse-move event frequency.
    private func startMovieControlsWatcher() {
        hideMovieControlsTask?.cancel()
        lastMouseActivityDate = .now
        hideMovieControlsTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                // Only hide if the cursor is not over the pill.
                if !isHoveringMovieControls,
                   Date.now.timeIntervalSince(lastMouseActivityDate) >= 3.0 {
                    showMovieControls = false
                    return   // Done — next mouse move restarts the watcher.
                }
            }
        }
    }

    /// Starts (or restarts) the watcher task for image-sequence controls auto-hide.
    private func startSequenceControlsWatcher() {
        hideSequenceControlsTask?.cancel()
        lastMouseActivityDate = .now
        hideSequenceControlsTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                if !isHoveringSequenceControls,
                   Date.now.timeIntervalSince(lastMouseActivityDate) >= 3.0 {
                    showSequenceControls = false
                    return
                }
            }
        }
    }

    /// Starts (or restarts) the watcher task for windowed still info bar auto-hide.
    private func startStillInfoBarWatcher() {
        hideStillInfoBarTask?.cancel()
        lastMouseActivityDate = .now
        hideStillInfoBarTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                if !isHoveringStillInfoBar,
                   Date.now.timeIntervalSince(lastMouseActivityDate) >= 3.0 {
                    showStillInfoBar = false
                    return   // Done — next mouse move restarts the watcher.
                }
            }
        }
    }
} // end DocumentContentView

#Preview {
    DocumentContentView(document: ImageDocument(), fileURL: nil)
        .frame(width: 1200, height: 800)
}

// MARK: - Window Configurator

/// Configures the underlying NSWindow with `.fullSizeContentView` so that the
/// NSScrollView extends behind the toolbar area, giving macOS enough image
/// content to apply vibrancy. The toolbar background itself is hidden via the
/// `.toolbarBackground(.hidden, for: .windowToolbar)` SwiftUI modifier on the
/// parent view, which reaches both the windowed NSWindow and the separate
/// NSToolbarFullScreenWindow used in full-screen mode.
private struct WindowConfigurator: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.configure(view.window)
            window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only configure and update binding when the window reference changes.
        // Avoids DispatchQueue.main.async on every SwiftUI update cycle, which
        // would mutate the @Binding and trigger another view evaluation.
        guard let w = nsView.window, w !== window else { return }
        Self.configure(w)
        // Defer the binding write to avoid mutating state during view update.
        DispatchQueue.main.async { [weak w] in
            guard let w, self.window !== w else { return }
            self.window = w
        }
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

#Preview {
    let doc = ImageDocument()
    let url = Bundle.main.url(forResource: "OCIO_logo_frame_flared", withExtension: "exr")
    DocumentContentView(document: doc, fileURL: url)
}
