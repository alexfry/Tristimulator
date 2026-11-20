//
//  ZoomableImageView.swift
//  Tristimulator
//
//  Created by Alex Fry on 3/6/2026.
//

import SwiftUI
import AppKit
import MetalKit

/// Custom clip view that centers the document view when it's smaller than the visible area
class CenteringClipView: NSClipView {
    var centersDocumentView = true
    
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        
        guard centersDocumentView,
              let documentView = documentView else {
            return rect
        }
        
        let documentFrame = documentView.frame
        
        // Center horizontally if document is narrower than bounds
        if documentFrame.width < proposedBounds.width {
            rect.origin.x = (documentFrame.width - proposedBounds.width) / 2.0
        }
        
        // Center vertically if document is shorter than bounds
        if documentFrame.height < proposedBounds.height {
            rect.origin.y = (documentFrame.height - proposedBounds.height) / 2.0
        }
        
        return rect
    }
}

/// A zoomable and pannable image view that switches between auto-fit and manual zoom modes
struct ZoomableImageView: View {
    var imageData: ImageData
    var exposure: Float
    var colorTransform: ColorTransform?
    var metalColorSpace: String
    var useBlackBackground: Bool = false

    /// The NSWindow that owns this view, used to filter broadcast zoom notifications
    /// so that only the key (foreground) window responds.
    var window: NSWindow? = nil
    /// Compiled OCIO GPU processor — passed through to MetalEDRImageView so the
    /// renderer can apply the OCIO transform inline in draw(), without a separate
    /// async compute pass or per-frame texture allocation.
    var gpuProcessor: OCIOGPUProcessor? = nil
    /// Original (pre-OCIO) source texture for still images.
    /// Passed to MetalEDRImageView so draw() can use the unified inline OCIO path
    /// (same as movies), giving one GPU submission and zero per-frame allocations.
    var sourceTexture: MTLTexture? = nil
    /// Channel isolation mask applied in scene-linear space.
    var channelMask: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
    /// Set to `true` to trigger a one-shot peak measurement on the next draw.
    var measurePeak: Bool = false
    /// Called on the main thread with per-channel RGBA maxima once measurement completes.
    var onPeakMeasured: ((SIMD4<Float>) -> Void)? = nil

    // Zoom level control
    @Binding var zoomLevel: CGFloat
    var onZoomChange: ((CGFloat) -> Void)?
    var onAutoFitChange: ((Bool) -> Void)?
    var onPanChange: ((CGPoint) -> Void)?
    
    /// When non-nil, the view initializes in manual-zoom mode at this magnification.
    var initialManualZoom: CGFloat? = nil
    /// When non-nil, the scroll view restores this scroll origin after entering manual-zoom mode.
    var initialPanOffset: CGPoint? = nil

    @State private var isAutoFitMode = true
    @State private var manualZoomLevel: CGFloat = 1.0
    @State private var shouldZoomIn = false
    @State private var shouldZoomOut = false
    
    var body: some View {
        ZStack {
            if isAutoFitMode {
                // Auto-fit mode: use SwiftUI layout.
                // In full-screen the toolbar is a floating overlay in its own
                // NSToolbarFullScreenWindow; SwiftUI still reserves a top safe
                // area for it, so we must ignore it so the image fills the
                // full screen and is visible through the toolbar vibrancy.
                MetalEDRImageView(
                    imageData: imageData,
                    exposure: exposure,
                    colorTransform: colorTransform,
                    metalColorSpace: metalColorSpace,
                    useBlackBackground: useBlackBackground,
                    gpuProcessor: gpuProcessor,
                    sourceTexture: sourceTexture,
                    isAutoFitMode: true,
                    channelMask: channelMask,
                    measurePeak: measurePeak,
                    onPeakMeasured: onPeakMeasured
                )
                .aspectRatio(CGFloat(imageData.width) / CGFloat(imageData.height), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(useBlackBackground ? Color.black : Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea(useBlackBackground ? .all : [], edges: .top)
                .gesture(MagnifyGesture()
                    .onChanged { value in
                        // Switch to manual zoom on first pinch
                        manualZoomLevel = -1 // -1 means "calculate fit"
                        isAutoFitMode = false
                        onAutoFitChange?(false)
                    }
                )
            } else {
                // Manual zoom mode: NSScrollView extends behind the toolbar
                // in both windowed and full-screen modes.
                ManualZoomView(
                    imageData: imageData,
                    exposure: exposure,
                    colorTransform: colorTransform,
                    metalColorSpace: metalColorSpace,
                    useBlackBackground: useBlackBackground,
                    initialZoom: manualZoomLevel,
                    initialPanOffset: initialPanOffset,
                    shouldZoomIn: $shouldZoomIn,
                    shouldZoomOut: $shouldZoomOut,
                    onZoomChange: onZoomChange,
                    onPanChange: onPanChange,
                    channelMask: channelMask,
                    measurePeak: measurePeak,
                    onPeakMeasured: onPeakMeasured,
                    gpuProcessor: gpuProcessor,
                    sourceTexture: sourceTexture
                )
                .ignoresSafeArea(.all, edges: .top)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { notification in
            guard notification.object as? NSWindow === window else { return }
            if isAutoFitMode {
                // Switch to manual mode starting at fit level, then zoom in
                manualZoomLevel = -1 // -1 means "calculate fit"
                shouldZoomIn = true
                isAutoFitMode = false
                onAutoFitChange?(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { notification in
            guard notification.object as? NSWindow === window else { return }
            if isAutoFitMode {
                // Switch to manual mode starting at fit level, then zoom out
                manualZoomLevel = -1 // -1 means "calculate fit"
                shouldZoomOut = true
                isAutoFitMode = false
                onAutoFitChange?(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomActualSize)) { notification in
            guard notification.object as? NSWindow === window else { return }
            // Switch to manual mode at 1:1
            manualZoomLevel = 1.0
            isAutoFitMode = false
            onAutoFitChange?(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomToFit)) { notification in
            guard notification.object as? NSWindow === window else { return }
            // Switch back to auto-fit mode
            isAutoFitMode = true
            onAutoFitChange?(true)
        }
        .onAppear {
            if let zoom = initialManualZoom {
                manualZoomLevel = zoom
                isAutoFitMode = false
                onAutoFitChange?(false)
            }
        }
    }
}

/// NSScrollView-based view for manual zoom and pan
struct ManualZoomView: NSViewRepresentable {
    var imageData: ImageData
    var exposure: Float
    var colorTransform: ColorTransform?
    var metalColorSpace: String
    var useBlackBackground: Bool = false
    var initialZoom: CGFloat
    var initialPanOffset: CGPoint? = nil
    @Binding var shouldZoomIn: Bool
    @Binding var shouldZoomOut: Bool
    var onZoomChange: ((CGFloat) -> Void)?
    var onPanChange: ((CGPoint) -> Void)?
    var channelMask: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
    var measurePeak: Bool = false
    var onPeakMeasured: ((SIMD4<Float>) -> Void)? = nil
    var gpuProcessor: OCIOGPUProcessor? = nil
    var sourceTexture: MTLTexture? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = useBlackBackground ? .black : .windowBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 32.0
        
        // Use a centering clip view
        let centeringClipView = CenteringClipView()
        centeringClipView.centersDocumentView = true
        scrollView.contentView = centeringClipView
        
        // Create the Metal view
        let metalView = MetalEDRImageView(
            imageData: imageData,
            exposure: exposure,
            colorTransform: colorTransform,
            metalColorSpace: metalColorSpace,
            useBlackBackground: useBlackBackground,
            gpuProcessor: gpuProcessor,
            sourceTexture: sourceTexture,
            isAutoFitMode: false,
            channelMask: channelMask,
            measurePeak: measurePeak,
            onPeakMeasured: onPeakMeasured
        )
        let hostingView = NSHostingView(rootView: metalView)
        
        // Set the size to the actual image size for 100% zoom
        let imageSize = NSSize(width: imageData.width, height: imageData.height)
        hostingView.frame.size = imageSize
        
        scrollView.documentView = hostingView
        
        // Store coordinator for notifications
        context.coordinator.scrollView = scrollView
        context.coordinator.hostingView = hostingView
        context.coordinator.onZoomChange = onZoomChange
        context.coordinator.onPanChange = onPanChange
        context.coordinator.imageWidth = imageData.width
        context.coordinator.imageHeight = imageData.height

        // Observe viewport changes for viewport-aware OCIO processing.
        // The clip view's bounds change on scroll and magnification.
        centeringClipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.viewportDidChange),
            name: NSView.boundsDidChangeNotification,
            object: centeringClipView
        )

        // Observe zoom notifications
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleZoomIn),
            name: .zoomIn,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleZoomOut),
            name: .zoomOut,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleZoomActualSize),
            name: .zoomActualSize,
            object: nil
        )
        
        // Set initial zoom - if -1, calculate fit; otherwise use provided value
        if initialZoom < 0 {
            // Calculate zoom-to-fit after layout
            DispatchQueue.main.async {
                let visibleRect = scrollView.bounds
                let widthRatio = visibleRect.width / CGFloat(imageSize.width)
                let heightRatio = visibleRect.height / CGFloat(imageSize.height)
                let fitZoom = min(widthRatio, heightRatio)
                scrollView.magnification = fitZoom
                onZoomChange?(fitZoom)
                
                // Apply initial zoom in/out if requested
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    context.coordinator.centerImage()
                    
                    // Now apply the zoom in/out
                    if shouldZoomIn {
                        let newZoom = min(scrollView.maxMagnification, scrollView.magnification * 1.4)
                        scrollView.animator().magnification = newZoom
                        onZoomChange?(newZoom)
                        DispatchQueue.main.async {
                            shouldZoomIn = false
                        }
                    } else if shouldZoomOut {
                        let newZoom = max(scrollView.minMagnification, scrollView.magnification / 1.4)
                        scrollView.animator().magnification = newZoom
                        onZoomChange?(newZoom)
                        DispatchQueue.main.async {
                            shouldZoomOut = false
                        }
                    }
                }
            }
        } else {
            scrollView.magnification = initialZoom
            
            // Restore saved pan offset or center after a moment
            let savedPan = initialPanOffset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let pan = savedPan {
                    scrollView.contentView.scroll(to: pan)
                } else {
                    context.coordinator.centerImage()
                }
            }
        }
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hostingView = scrollView.documentView as? NSHostingView<MetalEDRImageView> else { return }
        
        // Update background color
        scrollView.backgroundColor = useBlackBackground ? .black : .windowBackgroundColor
        
        // Update the Metal view with new data
        let visibleRect = context.coordinator.currentVisibleRectInSource
        let metalView = MetalEDRImageView(
            imageData: imageData,
            exposure: exposure,
            colorTransform: colorTransform,
            metalColorSpace: metalColorSpace,
            useBlackBackground: useBlackBackground,
            gpuProcessor: gpuProcessor,
            sourceTexture: sourceTexture,
            isAutoFitMode: false,
            drawableVisibleRect: visibleRect,
            channelMask: channelMask,
            measurePeak: measurePeak,
            onPeakMeasured: onPeakMeasured
        )
        hostingView.rootView = metalView
        
        context.coordinator.onZoomChange = onZoomChange
        context.coordinator.onPanChange = onPanChange
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var hostingView: NSHostingView<MetalEDRImageView>?
        var onZoomChange: ((CGFloat) -> Void)?
        var onPanChange: ((CGPoint) -> Void)?
        /// Image dimensions in pixels — used to calculate visible rect in source coords.
        var imageWidth: Int = 0
        var imageHeight: Int = 0
        
        @objc func handleZoomIn() {
            guard let scrollView, scrollView.window?.isKeyWindow == true else { return }
            let newZoom = min(scrollView.maxMagnification, scrollView.magnification * 1.4)
            scrollView.animator().magnification = newZoom
            onZoomChange?(newZoom)
        }
        
        @objc func handleZoomOut() {
            guard let scrollView, scrollView.window?.isKeyWindow == true else { return }
            let newZoom = max(scrollView.minMagnification, scrollView.magnification / 1.4)
            scrollView.animator().magnification = newZoom
            onZoomChange?(newZoom)
        }
        
        @objc func handleZoomActualSize() {
            guard let scrollView, scrollView.window?.isKeyWindow == true else { return }
            scrollView.animator().magnification = 1.0
            onZoomChange?(1.0)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.centerImage()
            }
        }
        
        /// The visible region in source-pixel coordinates, updated on scroll/zoom.
        var currentVisibleRectInSource: CGRect? = nil

        @objc func viewportDidChange(_ notification: Notification) {
            guard let scrollView = scrollView else { return }
            let clipBounds = scrollView.contentView.bounds
            let mag = max(0.001, scrollView.magnification)

            // Report pan offset for persistence.
            onPanChange?(clipBounds.origin)

            // clipBounds is in the magnified document coordinate system.
            // Divide by magnification to get source-pixel coordinates.
            currentVisibleRectInSource = CGRect(
                x: clipBounds.origin.x / mag,
                y: clipBounds.origin.y / mag,
                width: clipBounds.width / mag,
                height: clipBounds.height / mag
            )

            // Push the updated viewport directly to the MTKView's coordinator
            // and trigger a redraw.  We can't rely on SwiftUI's updateNSView
            // because it won't run in response to scroll/zoom notifications.
            if let hostingView = hostingView {
                func findMTKView(in view: NSView) -> MTKView? {
                    if let mtk = view as? MTKView { return mtk }
                    for sub in view.subviews {
                        if let found = findMTKView(in: sub) { return found }
                    }
                    return nil
                }
                if let mtkView = findMTKView(in: hostingView) {
                    // Directly update the MetalEDRImageView coordinator
                    // so the crop optimization uses the current viewport.
                    if let edrCoordinator = mtkView.delegate as? MetalEDRImageView.Coordinator {
                        edrCoordinator.drawableVisibleRect = currentVisibleRectInSource
                    }
                    mtkView.needsDisplay = true
                }
            }
        }

        func centerImage() {
            guard let scrollView = scrollView,
                  let hostingView = hostingView else { return }
            
            let clipView = scrollView.contentView
            let documentRect = hostingView.frame
            let clipRect = clipView.bounds
            
            var origin = documentRect.origin
            
            if documentRect.width > clipRect.width {
                origin.x = 0
            } else {
                origin.x = -(clipRect.width - documentRect.width) / 2
            }
            
            if documentRect.height > clipRect.height {
                origin.y = 0
            } else {
                origin.y = -(clipRect.height - documentRect.height) / 2
            }
            
            clipView.scroll(to: origin)
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
