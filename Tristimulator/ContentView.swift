//
//  ContentView.swift
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

import SwiftUI
import UniformTypeIdentifiers

// DEPRECATED: This ContentView is no longer used.
// The app now uses DocumentContentView (see DocumentContentView.swift)
/*
struct ContentView: View {
    @State private var imageManager = ImageManager()
    @State private var showScopes = false
    @State private var selectedScope: ScopeType = .histogram
    @State private var showColorControls = false
    @State private var showPipelinePopover = false
    
    // Track image load count to detect when new images are loaded
    @State private var imageLoadCount = 0
    
    // Shared color pipeline state
    @State private var selectedSourceSpace = ""
    @State private var selectedDestSpace = ""
    @State private var selectedDisplay = ""
    @State private var selectedView = ""
    @State private var selectedMetalColorSpace = "extendedDisplayP3"
    
    // Track if transforms have been applied (persists across popover open/close)
    @State private var hasAppliedTransforms = false
    
    // Zoom level state
    @State private var zoomLevel: CGFloat = 1.0
    
    // Full-screen state
    @State private var isFullScreen = false
    @State private var showInfoBarInFullScreen = true
    @State private var showToolbarInFullScreen = true
    @State private var hideInfoBarTask: Task<Void, Never>?
    @State private var hideToolbarTask: Task<Void, Never>?
    @State private var windowTitle: String = "Tristimulator"
    
    // EDR info popover
    @State private var showEDRInfoPopover = false
    
    // EDR status monitoring
    @State private var isHDRAvailable = false
    @State private var edrCheckTimer: Timer?
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Custom toolbar overlay for full-screen mode only
                if isFullScreen {
                    ImageToolbar(
                        exposure: Binding(
                            get: { imageManager.exposure },
                            set: { newValue in
                                imageManager.exposure = newValue
                                Task { await imageManager.updateExposure(newValue) }
                            }
                        ),
                        showScopes: $showScopes,
                        showColorControls: $showColorControls,
                        showPipelinePopover: $showPipelinePopover,
                        imageManager: imageManager,
                        selectedSourceSpace: $selectedSourceSpace,
                        selectedDestSpace: $selectedDestSpace,
                        selectedDisplay: $selectedDisplay,
                        selectedView: $selectedView,
                        selectedMetalColorSpace: $selectedMetalColorSpace,
                        hasAppliedTransforms: $hasAppliedTransforms,
                        isFullScreen: isFullScreen,
                        onOpenImage: openImage,
                        onSaveImage: saveImage,
                        showEDRInfoPopover: $showEDRInfoPopover,
                        isHDRAvailable: $isHDRAvailable
                    )
                    .frame(height: 44)
                    .background(Color.black)
                    .opacity(showToolbarInFullScreen ? 1 : 0)
                    .animation(.easeInOut(duration: 0.6), value: showToolbarInFullScreen)
                }
                
                HSplitView {
                // Main image view
                VStack(spacing: 0) {
                    // Image viewer with zoom and pan - with background
                    Group {
                        if let imageData = imageManager.currentImage, hasAppliedTransforms {
                            ZoomableImageView(
                                imageData: imageData,
                                exposure: imageManager.exposure,
                                colorTransform: imageManager.colorTransform,
                                metalColorSpace: selectedMetalColorSpace,
                                useBlackBackground: isFullScreen,
                                zoomLevel: $zoomLevel,
                                onZoomChange: { newZoom in
                                    zoomLevel = newZoom
                                }
                            )
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    // Image info bar - fades in/out in full screen
                    if let image = imageManager.currentImage {
                        ImageInfoBar(imageData: image, ocioConfig: imageManager.ocioConfig, imageManager: imageManager)
                            .frame(height: 30)
                            .opacity(isFullScreen && !showInfoBarInFullScreen ? 0 : 1)
                            .animation(.easeInOut(duration: 0.6), value: showInfoBarInFullScreen)
                            .zIndex(1) // Keep info bar on top
                    }
                }
                .background(isFullScreen ? Color.black : Color(nsColor: .windowBackgroundColor))
                .frame(minWidth: 200, maxWidth: .infinity)
                
                // Scopes and controls sidebar - hide in full screen
                if (showScopes || showColorControls) && !isFullScreen {
                    VStack(spacing: 0) {
                        if showScopes {
                            ScopesView(
                                imageData: imageManager.currentImage,
                                selectedScope: $selectedScope
                            )
                            .frame(minHeight: 300)
                        }
                        
                        if showColorControls {
                            Divider()
                            
                            ColorPipelineNodeView(
                                imageManager: imageManager,
                                selectedSourceSpace: $selectedSourceSpace,
                                selectedDestSpace: $selectedDestSpace,
                                selectedDisplay: $selectedDisplay,
                                selectedView: $selectedView,
                                selectedMetalColorSpace: $selectedMetalColorSpace,
                                hasAppliedTransforms: $hasAppliedTransforms
                            )
                            .frame(minHeight: 400)
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 400, maxWidth: 500)
                }
            }
            }
            
            // Mouse tracking overlay for full screen
            if isFullScreen {
                MouseTrackingView { location in
                    handleMouseMove(location)
                }
                .allowsHitTesting(false)
            }
        }
        .navigationTitle(windowTitle)
        .toolbar(id: "main") {
            if !isFullScreen {
                // Native toolbar items for windowed mode
                ToolbarItem(id: "exposure", placement: .principal) {
                    HStack(spacing: 8) {
                        Text("Exposure:")
                            .font(.caption)
                        
                        ExposureSlider(value: Binding(
                            get: { imageManager.exposure },
                            set: { newValue in
                                imageManager.exposure = newValue
                                Task { await imageManager.updateExposure(newValue) }
                            }
                        ))
                        .frame(width: 200, height: 24)
                        
                        Text(String(format: "%.1f", imageManager.exposure))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                        
                        Button(action: { 
                            imageManager.exposure = 0
                            Task { await imageManager.updateExposure(0) }
                        }) {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .help("Reset exposure")
                    }
                    .padding(.horizontal, 12)
                }
                
                ToolbarItem(id: "ocio-pipeline", placement: .primaryAction) {
                    Button(action: {
                        if NSEvent.modifierFlags.contains(.option) {
                            showColorControls.toggle()
                        } else {
                            showPipelinePopover.toggle()
                        }
                    }) {
                        Label {
                            Text("OCIO Pipeline")
                        } icon: {
                            Image(colorScheme == .dark ? "opencolorio-icon-white" : "opencolorio-icon-color")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                        }
                    }
                    .help("Toggle color pipeline overlay (Option-click for Color sidebar)")
                    .popover(isPresented: $showPipelinePopover, arrowEdge: .bottom) {
                        ColorPipelineNodeView(
                            imageManager: imageManager,
                            selectedSourceSpace: $selectedSourceSpace,
                            selectedDestSpace: $selectedDestSpace,
                            selectedDisplay: $selectedDisplay,
                            selectedView: $selectedView,
                            selectedMetalColorSpace: $selectedMetalColorSpace,
                            hasAppliedTransforms: $hasAppliedTransforms
                        )
                        .frame(width: 400)
                        .padding()
                    }
                }
                
                ToolbarItem(id: "hdr-indicator", placement: .status) {
                    Button(action: {
                        showEDRInfoPopover.toggle()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "sun.max.fill")
                                .foregroundStyle(isHDRAvailable ? .yellow : .primary)
                            Text(isHDRAvailable ? "HDR" : "SDR")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .help(isHDRAvailable ? "Extended Dynamic Range available (click for details)" : "Standard Dynamic Range (click for details)")
                    .popover(isPresented: $showEDRInfoPopover, arrowEdge: .bottom) {
                        EDRInfoView()
                            .frame(width: 400)
                            .padding()
                    }
                }
            }
        }
        .onAppear {
            // Check initial EDR status
            checkEDRStatus()
            
            // Set up timer to periodically check EDR status (e.g., when moving windows between displays)
            edrCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                checkEDRStatus()
            }
            
            // Monitor full-screen state changes
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: nil,
                queue: .main
            ) { notification in
                print("🖥️ Entering full screen")
                isFullScreen = true
                showInfoBarInFullScreen = true
                showToolbarInFullScreen = true
                
                // Configure window for full screen
                if let window = notification.object as? NSWindow {
                    // Make window background black
                    window.backgroundColor = .black
                }
                
                // Schedule initial hide after entering full screen
                let hideTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    
                    if !Task.isCancelled {
                        showInfoBarInFullScreen = false
                        showToolbarInFullScreen = false
                        NSCursor.hide()
                    }
                }
                
                hideInfoBarTask = hideTask
                hideToolbarTask = hideTask
                
                print("🖥️ isFullScreen = \(isFullScreen)")
            }
            
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: nil,
                queue: .main
            ) { notification in
                print("🖥️ Exiting full screen")
                isFullScreen = false
                showInfoBarInFullScreen = true
                showToolbarInFullScreen = true
                
                // Cancel any pending hide tasks
                hideInfoBarTask?.cancel()
                hideToolbarTask?.cancel()
                
                // Restore window appearance
                if let window = notification.object as? NSWindow {
                    window.backgroundColor = .windowBackgroundColor
                }
                
                // Make sure cursor is visible when exiting full screen
                NSCursor.unhide()
                
                // Force cursor visibility after a moment to ensure it sticks
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSCursor.unhide()
                    CGDisplayShowCursor(CGMainDisplayID())
                }
                
                print("🖥️ isFullScreen = \(isFullScreen)")
            }
            
            // Auto-load bundled sample image if available
            if let bundledImagePath = Bundle.main.path(forResource: "OCIO_logo_frame_flared", ofType: "exr") {
                let testImageURL = URL(fileURLWithPath: bundledImagePath)
                
                print("📦 Found bundled sample image: \(bundledImagePath)")
                
                Task {
                    do {
                        try await imageManager.loadImage(from: testImageURL)
                        await MainActor.run {
                            imageLoadCount += 1 // Trigger onChange
                            // Keep default "Tristimulator" title for bundled sample
                        }
                    } catch {
                        print("⚠️ Failed to auto-load bundled sample image: \(error)")
                    }
                }
            } else {
                print("ℹ️ No bundled sample image found. Use File > Open to load an image.")
            }
        }
        .onDisappear {
            // Clean up timer
            edrCheckTimer?.invalidate()
            edrCheckTimer = nil
        }
        .onChange(of: imageLoadCount) { oldValue, newValue in
            print("🔔 Image load count changed: \(oldValue) → \(newValue)")
            if newValue > 0 {
                hasAppliedTransforms = false
                // Don't reset zoom here - let ZoomableImageView handle it with zoom-to-fit
                initializePipeline()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openImage)) { _ in
            openImage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleScopes)) { _ in
            showScopes.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleColorControls)) { _ in
            showColorControls.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetExposure)) { _ in
            imageManager.exposure = 0
            Task { await imageManager.updateExposure(0) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .increaseExposure)) { _ in
            let newExposure = min(10, imageManager.exposure + 0.5)
            imageManager.exposure = newExposure
            Task { await imageManager.updateExposure(newExposure) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .decreaseExposure)) { _ in
            let newExposure = max(-10, imageManager.exposure - 0.5)
            imageManager.exposure = newExposure
            Task { await imageManager.updateExposure(newExposure) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ocioConfigChanged)) { _ in
            // When OCIO config changes, re-initialize the pipeline
            print("🔔 OCIO config changed notification received")
            initializePipeline()
        }
    }
    
    private func checkEDRStatus() {
        let maxPotential = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let newHDRStatus = maxPotential > 1.0
        
        // Only update if status changed to avoid unnecessary UI updates
        if newHDRStatus != isHDRAvailable {
            isHDRAvailable = newHDRStatus
            print("🖥️ EDR status changed: \(isHDRAvailable ? "HDR" : "SDR") (Max: \(String(format: "%.1f", maxPotential))x)")
        }
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
        ]
        
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await imageManager.loadImage(from: url)
                    await MainActor.run {
                        imageLoadCount += 1 // Trigger onChange
                        // Update window title to show filename
                        windowTitle = url.lastPathComponent
                    }
                } catch {
                    showError(error)
                }
            }
        }
    }
    
    private func saveImage() {
        guard imageManager.currentImage != nil else { return }
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Untitled"
        
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    let format = url.pathExtension
                    try await imageManager.saveImage(to: url, format: format)
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
    
    private func initializePipeline() {
        print("🔧 initializePipeline() called")
        let colorSpaces = imageManager.availableColorSpaces()
        guard !colorSpaces.isEmpty else {
            print("⚠️ No color spaces available")
            return
        }
        
        print("📦 Available color spaces: \(colorSpaces.count)")
        
        // Always try to match the new image's color space
        if let metadata = imageManager.currentImage?.metadata {
            let imageColorSpace = metadata.colorSpace
            if !imageColorSpace.isEmpty,
               let matchedSpace = ColorSpaceAliases.findMatch(for: imageColorSpace, in: colorSpaces) {
                selectedSourceSpace = matchedSpace
                print("🎯 Re-matched new image color space '\(imageColorSpace)' to '\(matchedSpace)'")
        } else if selectedSourceSpace.isEmpty {
            // Only set defaults if nothing is selected yet
            if let sceneLinear = imageManager.ocioConfig?.sceneLinearColorSpace() {
                selectedSourceSpace = sceneLinear
            } else if let defaultSpace = imageManager.ocioConfig?.defaultColorSpace() {
                selectedSourceSpace = defaultSpace
            } else {
                selectedSourceSpace = colorSpaces[0]
            }
            print("📌 Set default source space: \(selectedSourceSpace)")
        } else {
            print("ℹ️ Keeping existing source space: \(selectedSourceSpace)")
        }
        
        // Keep dest space as-is (working space shouldn't change when loading new images)
        if selectedDestSpace.isEmpty {
            if let sceneLinear = imageManager.ocioConfig?.sceneLinearColorSpace() {
                selectedDestSpace = sceneLinear
            } else if let defaultSpace = imageManager.ocioConfig?.defaultColorSpace() {
                selectedDestSpace = defaultSpace
            } else {
                selectedDestSpace = colorSpaces[0]
            }
            print("📌 Set default dest space: \(selectedDestSpace)")
        } else {
            print("ℹ️ Keeping existing dest space: \(selectedDestSpace)")
        }
        
        let displays = imageManager.availableDisplays()
        if !displays.isEmpty && selectedDisplay.isEmpty {
            if let defaultDisplay = imageManager.ocioConfig?.defaultDisplay(), !defaultDisplay.isEmpty {
                selectedDisplay = defaultDisplay
            } else {
                selectedDisplay = displays[0]
            }
            
            let views = imageManager.views(for: selectedDisplay)
            if !views.isEmpty {
                if let defaultView = imageManager.ocioConfig?.defaultView(forDisplay: selectedDisplay), !defaultView.isEmpty {
                    selectedView = defaultView
                } else {
                    selectedView = views[0]
                }
            }
            print("📌 Set display: \(selectedDisplay), view: \(selectedView)")
        }
        
        // Apply transforms
        if imageManager.currentImage != nil {
            print("🎨 Applying transforms: \(selectedSourceSpace) → \(selectedDestSpace) → Display(\(selectedDisplay)/\(selectedView))")
            
            Task { @MainActor in
                // Give SwiftUI one frame to render with opacity 0
                await Task.yield()
                
                applyColorTransformAndReapplyDisplay()
                hasAppliedTransforms = true
                print("✅ Transforms complete, showing image")
            }
        } else {
            print("⚠️ No current image to transform")
        }
    }
    
    private func applyColorTransformAndReapplyDisplay() {
        print("🎨 applyColorTransformAndReapplyDisplay() - Source: '\(selectedSourceSpace)'")
        guard !selectedDisplay.isEmpty && !selectedView.isEmpty else {
            print("⚠️ Display or view is empty, skipping display transform")
            return
        }
        do {
            try imageManager.applyDisplayTransform(
                from: selectedSourceSpace,
                display: selectedDisplay,
                view: selectedView)
            print("✅ Display transform applied")
        } catch {
            print("❌ Error applying display transform: \(error)")
        }
    }
    
    private func handleMouseMove(_ location: CGPoint) {
        guard isFullScreen else { return }
        
        // Show cursor on movement
        NSCursor.unhide()
        
        // Cancel any pending hide tasks
        hideInfoBarTask?.cancel()
        hideToolbarTask?.cancel()
        
        // Show toolbar and info bar immediately on mouse movement
        if !showInfoBarInFullScreen {
            showInfoBarInFullScreen = true
        }
        if !showToolbarInFullScreen {
            showToolbarInFullScreen = true
        }
        
        // Schedule hiding info bar, toolbar, and cursor after 2 seconds of inactivity
        let hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            
            // Only hide if task wasn't cancelled
            if !Task.isCancelled {
                showInfoBarInFullScreen = false
                showToolbarInFullScreen = false
                NSCursor.hide()
            }
        }
        
        hideInfoBarTask = hideTask
        hideToolbarTask = hideTask
    }
}
*/

// Note: ScopeType, MouseTrackingView, EDRInfoView, etc. are still defined below
// and shared between ContentView and DocumentContentView

enum ScopeType: String, CaseIterable, Identifiable {
    case histogram = "Histogram"
    case waveform = "Waveform"
    case vectorscope = "Vectorscope"
    case parade = "RGB Parade"
    case chromaticity = "CIE Yxy"
    
    var id: String { rawValue }
}

// MARK: - Mouse Tracking View

struct MouseTrackingView: NSViewRepresentable {
    let onMouseMoved: (CGPoint) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = MouseTrackingNSView()
        view.onMouseMoved = onMouseMoved
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let trackingView = nsView as? MouseTrackingNSView {
            trackingView.onMouseMoved = onMouseMoved
        }
    }
}

class MouseTrackingNSView: NSView {
    var onMouseMoved: ((CGPoint) -> Void)?
    private var trackingArea: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        if let existingArea = trackingArea {
            removeTrackingArea(existingArea)
        }
        
        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        
        if let area = trackingArea {
            addTrackingArea(area)
        }
    }
    
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseMoved?(location)
    }
}

// MARK: - EDR Info View

struct EDRInfoView: View {
    @State private var edrInfo: EDRInformation
    var peakPixelResult: SIMD4<Float>? = nil

    init(peakPixelResult: SIMD4<Float>? = nil) {
        _edrInfo = State(initialValue: EDRInformation.current())
        self.peakPixelResult = peakPixelResult
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.yellow)
                    .font(.title2)
                Text("Extended Dynamic Range Info")
                    .font(.headline)
            }
            
            Divider()
            
            // EDR Metrics
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(
                    label: "Maximum Potential EDR Headroom",
                    value: String(format: "%.2f", edrInfo.maxPotentialHeadroom),
                    description: "Maximum EDR value this display can achieve"
                )
                
                InfoRow(
                    label: "Current EDR Headroom",
                    value: String(format: "%.2f", edrInfo.currentHeadroom),
                    description: "Current available EDR headroom"
                )
                
                InfoRow(
                    label: "Maximum Extended Linear Brightness",
                    value: String(format: "%.2f", edrInfo.maxExtendedLinearBrightness),
                    description: "Maximum brightness in extended linear color space"
                )
                
                if let colorSpace = edrInfo.colorSpace {
                    InfoRow(
                        label: "Screen Color Space",
                        value: colorSpace,
                        description: "Color space of the main screen"
                    )
                }
                
                if let depth = edrInfo.screenDepth {
                    InfoRow(
                        label: "Screen Depth",
                        value: depth,
                        description: "Bit depth and color space information"
                    )
                }
                
                InfoRow(
                    label: "HDR Capable",
                    value: edrInfo.isHDRCapable ? "Yes" : "No",
                    description: "Whether the display supports HDR"
                )
                
                InfoRow(
                    label: "Display Status",
                    value: edrInfo.referenceDisplayModeStatus,
                    description: "Current display mode information"
                )
            }

            Divider()

            // Peak Brightness — measured from the drawable post display transform.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle.magnifyingglass")
                    Text("Peak Brightness (Display-Linear)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                if let peak = peakPixelResult {
                    PeakBrightnessRows(peak: peak)
                } else {
                    Text("Measuring…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Extended-linear Display P3 · 1.0\u{202F}=\u{202F}SDR white")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // Refresh button
            HStack {
                Spacer()
                Button("Refresh") {
                    edrInfo = EDRInformation.current()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Peak Brightness helper

/// Computes and renders per-channel max rows from a SIMD4<Float> result.
/// Isolated into its own view so `let` bindings work cleanly outside @ViewBuilder.
private struct PeakBrightnessRows: View {
    let peak: SIMD4<Float>
    var body: some View {
        let r     = peak.x
        let g     = peak.y
        let b     = peak.z
        let luma  = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let stops = Darwin.log2f(max(luma, 1e-6))
        return VStack(alignment: .leading, spacing: 12) {
            InfoRow(label: "Peak Red",
                    value: String(format: "%.4f", r),
                    description: "Maximum red channel (extended-linear Display P3)")
            InfoRow(label: "Peak Green",
                    value: String(format: "%.4f", g),
                    description: "Maximum green channel (extended-linear Display P3)")
            InfoRow(label: "Peak Blue",
                    value: String(format: "%.4f", b),
                    description: "Maximum blue channel (extended-linear Display P3)")
            InfoRow(label: "Peak Luminance",
                    value: String(format: "%.4f", luma),
                    description: String(format: "%+.2f stops vs SDR white (BT.709 luma coefficients)", stops))
        }
    }
}

// MARK: - Peak Brightness helper

struct InfoRow: View {
    let label: String
    let value: String
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(value)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - EDR Information Model

struct EDRInformation {
    let maxPotentialHeadroom: CGFloat
    let currentHeadroom: CGFloat
    let maxExtendedLinearBrightness: CGFloat
    let colorSpace: String?
    let screenDepth: String?
    let isHDRCapable: Bool
    let referenceDisplayModeStatus: String
    
    static func current() -> EDRInformation {
        guard let mainScreen = NSScreen.main else {
            return EDRInformation(
                maxPotentialHeadroom: 1.0,
                currentHeadroom: 1.0,
                maxExtendedLinearBrightness: 1.0,
                colorSpace: nil,
                screenDepth: nil,
                isHDRCapable: false,
                referenceDisplayModeStatus: "No screen available"
            )
        }
        
        // Get EDR headroom values
        let maxPotential = mainScreen.maximumPotentialExtendedDynamicRangeColorComponentValue
        let currentHeadroom = mainScreen.maximumExtendedDynamicRangeColorComponentValue
        
        // Get maximum extended linear brightness (macOS 14.0+)
        var maxBrightness: CGFloat = 1.0
        if #available(macOS 14.0, *) {
            maxBrightness = mainScreen.maximumReferenceExtendedDynamicRangeColorComponentValue
        }
        
        // Get color space information
        var colorSpaceName: String?
        if let cgColorSpace = mainScreen.colorSpace?.cgColorSpace {
            colorSpaceName = cgColorSpace.name as String? ?? "Unknown"
        }
        
        // Get screen depth using modern API
        let depthDescription = "\(mainScreen.depth.bitsPerPixel) bits per pixel"
        
        // Determine if HDR capable
        let isHDR = maxPotential > 1.0
        
        // Note: referenceDisplayModeStatus is not available on NSScreen in macOS
        // It's only available on UIScreen in iOS/iPadOS
        let referenceStatus = isHDR ? "EDR available (Max: \(String(format: "%.1f", maxPotential))x)" : "SDR only"
        
        return EDRInformation(
            maxPotentialHeadroom: maxPotential,
            currentHeadroom: currentHeadroom,
            maxExtendedLinearBrightness: maxBrightness,
            colorSpace: colorSpaceName,
            screenDepth: depthDescription,
            isHDRCapable: isHDR,
            referenceDisplayModeStatus: referenceStatus
        )
    }
}

// Preview moved to DocumentContentView.swift
