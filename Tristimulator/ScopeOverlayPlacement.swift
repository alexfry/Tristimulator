//
//  ScopeOverlayPlacement.swift
//  Tristimulator
//
//  Shared placement model for the floating scope overlays (CIE 1931 Yxy,
//  CIE 1976 u'v', JMh). An overlay is anchored to the nearer horizontal
//  edge (left/right) and the nearer vertical edge (top/bottom) of the image
//  area, so one sitting bottom-right stays pinned there while the window is
//  resized. Also hosts the corner resize handle the overlays share.
//

import SwiftUI
import AppKit

/// Horizontal edge of the image area an overlay is pinned to.
enum ScopeOverlayEdge: String, Codable, Equatable {
    case leading, trailing
}

/// Vertical edge of the image area an overlay is pinned to.
enum ScopeOverlayVerticalEdge: String, Codable, Equatable {
    case top, bottom
}

/// Corner of an overlay that a resize handle sits in.
enum ScopeOverlayCorner: Equatable, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    var isTop: Bool { self == .topLeading || self == .topTrailing }
}

/// Position and size of a floating scope overlay, stored relative to the
/// horizontal and vertical edges it is pinned to rather than as an absolute
/// offset, so it follows those edges when the window is resized.
struct ScopeOverlayPlacement: Codable, Equatable {
    /// Horizontal edge the overlay is pinned to.
    var edge: ScopeOverlayEdge
    /// Distance from the pinned container side to the overlay's matching side.
    var edgeInset: CGFloat
    /// Vertical edge the overlay is pinned to.
    var verticalEdge: ScopeOverlayVerticalEdge = .top
    /// Distance from the pinned container top/bottom to the overlay's matching edge.
    var verticalInset: CGFloat
    var size: CGSize
    /// Image-area size the insets and size were set at, when the "scale scopes
    /// with window" preference is on. `nil` means the values are absolute
    /// (plain edge pinning). See `effective(in:minSize:maxSize:)`.
    var referenceSize: CGSize? = nil

    /// Height kept on screen when clamping vertically, so the title bar
    /// (the drag area) never disappears below the bottom edge.
    static let visibleTitleHeight: CGFloat = 28

    /// The overlay's frame in container coordinates, clamped so it stays
    /// inside the container (title bar always on screen). Clamping happens
    /// only here, so stored insets survive the window shrinking and growing.
    /// A zero-sized container (before first layout) is not clamped against.
    func frame(in container: CGSize) -> CGRect {
        var x: CGFloat
        switch edge {
        case .leading:  x = edgeInset
        case .trailing: x = container.width - size.width - edgeInset
        }
        var y: CGFloat
        switch verticalEdge {
        case .top:    y = verticalInset
        case .bottom: y = container.height - size.height - verticalInset
        }
        if container.width > 0 {
            x = min(max(0, x), max(0, container.width - size.width))
        }
        if container.height > 0 {
            y = min(max(0, y), max(0, container.height - Self.visibleTitleHeight))
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Placement for `frame`. Each axis is pinned to the given edge, or, when
    /// that is nil, to whichever edge is nearer the frame's centre (falling
    /// back to the fallback edge while the container size is unknown).
    static func anchored(to frame: CGRect, in container: CGSize,
                         edge: ScopeOverlayEdge? = nil,
                         verticalEdge: ScopeOverlayVerticalEdge? = nil,
                         fallbackEdge: ScopeOverlayEdge = .leading,
                         fallbackVerticalEdge: ScopeOverlayVerticalEdge = .top) -> ScopeOverlayPlacement {
        let h: ScopeOverlayEdge
        if let edge {
            h = edge
        } else if container.width > 0 {
            h = frame.midX > container.width / 2 ? .trailing : .leading
        } else {
            h = fallbackEdge
        }
        let v: ScopeOverlayVerticalEdge
        if let verticalEdge {
            v = verticalEdge
        } else if container.height > 0 {
            v = frame.midY > container.height / 2 ? .bottom : .top
        } else {
            v = fallbackVerticalEdge
        }
        let hInset = h == .leading ? frame.minX : container.width - frame.maxX
        let vInset = v == .top ? frame.minY : container.height - frame.maxY
        return ScopeOverlayPlacement(edge: h, edgeInset: hInset,
                                     verticalEdge: v, verticalInset: vInset, size: frame.size)
    }

    /// Placement after dragging the title bar by (dx, dy). The overlay stays
    /// inside the container and re-pins, on each axis, to the edge nearer
    /// its centre.
    func dragged(dx: CGFloat, dy: CGFloat, in container: CGSize) -> ScopeOverlayPlacement {
        var f = frame(in: container)
        f.origin.x += dx
        f.origin.y += dy
        let moved = ScopeOverlayPlacement.anchored(to: f, in: container,
                                                   edge: edge, verticalEdge: verticalEdge)
        let clamped = moved.frame(in: container)
        return ScopeOverlayPlacement.anchored(to: clamped, in: container,
                                              fallbackEdge: edge, fallbackVerticalEdge: verticalEdge)
    }

    /// Placement after dragging a resize handle in `corner` by (dx, dy).
    /// The corner follows the cursor and the opposite corner stays fixed:
    /// leading corners move the left side, trailing corners the right side,
    /// top corners the top edge and bottom corners the bottom edge. The
    /// pinned edges are kept and their insets recomputed from the new frame
    /// (so growing a bottom-pinned overlay downwards shrinks its bottom inset).
    /// Size stays within `minSize`…`maxSize` and, where the container is
    /// known, the overlay does not grow past the container's edges.
    func resized(corner: ScopeOverlayCorner, dx: CGFloat, dy: CGFloat,
                 minSize: CGSize, maxSize: CGSize, in container: CGSize) -> ScopeOverlayPlacement {
        let f = frame(in: container)
        var maxW = maxSize.width
        if container.width > 0 {
            maxW = min(maxW, corner.isLeading ? f.maxX : container.width - f.minX)
        }
        maxW = max(minSize.width, maxW)
        var maxH = maxSize.height
        if container.height > 0 {
            maxH = min(maxH, corner.isTop ? f.maxY : container.height - f.minY)
        }
        maxH = max(minSize.height, maxH)
        let requestedW = corner.isLeading ? f.width - dx : f.width + dx
        let requestedH = corner.isTop ? f.height - dy : f.height + dy
        let newW = min(maxW, max(minSize.width, requestedW))
        let newH = min(maxH, max(minSize.height, requestedH))
        let newX = corner.isLeading ? f.maxX - newW : f.minX
        let newY = corner.isTop ? f.maxY - newH : f.minY
        let newFrame = CGRect(x: newX, y: newY, width: newW, height: newH)
        return ScopeOverlayPlacement.anchored(to: newFrame, in: container,
                                              edge: edge, verticalEdge: verticalEdge)
    }

    /// The same placement with its size limited to `minSize`…`maxSize`
    /// (guards against odd values in saved settings).
    func clampingSize(min minSize: CGSize, max maxSize: CGSize) -> ScopeOverlayPlacement {
        var p = self
        p.size.width  = Swift.min(maxSize.width,  Swift.max(minSize.width,  size.width))
        p.size.height = Swift.min(maxSize.height, Swift.max(minSize.height, size.height))
        return p
    }

    // MARK: Scale-with-window mode

    /// This placement as plain absolute values for `container`.
    ///
    /// When a reference size is recorded, the insets scale with
    /// the image area per axis (so each scope keeps its relative distance from
    /// its pinned edges) and the size scales uniformly by the smaller of the
    /// two factors, so diagrams keep their aspect ratio and never outgrow the
    /// area in either direction. The scaled size is limited to `minSize`…
    /// `maxSize`. The stored values are untouched, so shrinking and growing the
    /// window is lossless. Without a usable reference the placement is returned
    /// unchanged. The reference is honoured regardless of the preference, so a
    /// scaled placement draws the same until `settled` converts it; that keeps
    /// scopes from jumping for a frame when the preference flips.
    func effective(in container: CGSize,
                   minSize: CGSize, maxSize: CGSize) -> ScopeOverlayPlacement {
        var p = self
        p.referenceSize = nil
        guard let ref = referenceSize, ref.width > 0, ref.height > 0,
              container.width > 0, container.height > 0 else { return p }
        let sx = container.width / ref.width
        let sy = container.height / ref.height
        let s = Swift.min(sx, sy)
        p.edgeInset = edgeInset * sx
        p.verticalInset = verticalInset * sy
        p.size = CGSize(width: size.width * s, height: size.height * s)
        return p.clampingSize(min: minSize, max: maxSize)
    }

    /// Applies a drag or resize `edit` to what is on screen and stores the
    /// result. In scaling mode the result is recorded against the current
    /// image-area size; otherwise it is absolute.
    func edited(in container: CGSize, scaling: Bool, minSize: CGSize, maxSize: CGSize,
                _ edit: (ScopeOverlayPlacement) -> ScopeOverlayPlacement) -> ScopeOverlayPlacement {
        var p = edit(effective(in: container, minSize: minSize, maxSize: maxSize))
        if scaling, container.width > 0, container.height > 0 { p.referenceSize = container }
        return p
    }

    /// The placement to store when a scope is shown or the preference changes,
    /// such that the scope stays exactly where it is on screen.
    /// - Scaling on: a placement without a reference adopts the current area as
    ///   its reference (scale 1 now, proportional from here on).
    /// - Scaling off: a placement with a reference is baked to the absolute
    ///   values it currently renders with.
    func settled(in container: CGSize, scaling: Bool,
                 minSize: CGSize, maxSize: CGSize) -> ScopeOverlayPlacement {
        guard container.width > 0, container.height > 0 else { return self }
        if scaling {
            guard referenceSize == nil else { return self }
            var p = self
            p.referenceSize = container
            return p
        } else {
            guard referenceSize != nil else { return self }
            return effective(in: container, minSize: minSize, maxSize: maxSize)
        }
    }

    /// One-line description for the Debug drag-end log.
    func debugDescription(in container: CGSize) -> String {
        let f = frame(in: container)
        func r(_ v: CGFloat) -> String { String(format: "%.0f", v) }
        return "area \(r(container.width))x\(r(container.height)) (mid y \(r(container.height / 2))), "
            + "frame x \(r(f.minX)) y \(r(f.minY)) w \(r(f.width)) h \(r(f.height)) "
            + "(centre \(r(f.midX)), \(r(f.midY))), "
            + "pinned \(edge.rawValue) \(r(edgeInset)) / \(verticalEdge.rawValue) \(r(verticalInset))"
            + (referenceSize.map { ", scaled from \(r($0.width))x\(r($0.height))" } ?? "")
    }
}

// MARK: - Shared resize handle

final class ScopeResizeHandleNSView: NSView {
    var onDelta: ((CGFloat, CGFloat) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) { onDelta?(event.deltaX, event.deltaY) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}

/// Invisible corner hot spot that reports mouse-drag deltas (dx, dy), with
/// y increasing downwards.
struct ScopeResizeHandle: NSViewRepresentable {
    var onDelta: (CGFloat, CGFloat) -> Void
    func makeNSView(context: Context) -> ScopeResizeHandleNSView {
        let v = ScopeResizeHandleNSView(); v.onDelta = onDelta; return v
    }
    func updateNSView(_ nsView: ScopeResizeHandleNSView, context: Context) { nsView.onDelta = onDelta }
}

/// Side length of the bottom corner resize hot spots.
private let bottomHandleSize: CGFloat = 16
/// Side length of the top corner resize hot spots. Smaller and flush with
/// the corner so they stay clear of the header's close button and title.
private let topHandleSize: CGFloat = 10

extension View {
    /// Adds a resize hot spot in each of the four corners that updates
    /// `placement` within the given size limits. Added after the content, so
    /// inside its hot spot a corner wins over the header's drag area.
    func scopeResizeHandles(placement: Binding<ScopeOverlayPlacement>,
                            container: CGSize, scaling: Bool,
                            minSize: CGSize, maxSize: CGSize) -> some View {
        func handle(_ corner: ScopeOverlayCorner) -> some View {
            let side = corner.isTop ? topHandleSize : bottomHandleSize
            return ScopeResizeHandle { dx, dy in
                placement.wrappedValue = placement.wrappedValue.edited(
                    in: container, scaling: scaling, minSize: minSize, maxSize: maxSize) {
                    $0.resized(corner: corner, dx: dx, dy: dy,
                               minSize: minSize, maxSize: maxSize, in: container)
                }
            }
            .frame(width: side, height: side)
            .padding(corner.isTop ? 0 : 2)
        }
        return self
            .overlay(alignment: .topLeading)     { handle(.topLeading) }
            .overlay(alignment: .topTrailing)    { handle(.topTrailing) }
            .overlay(alignment: .bottomLeading)  { handle(.bottomLeading) }
            .overlay(alignment: .bottomTrailing) { handle(.bottomTrailing) }
    }
}

// MARK: - Shared title-bar drag handle

final class ScopeDragHandleNSView: NSView {
    var onDelta: ((CGFloat, CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var didDrag = false
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Accept the mouse-down so we receive subsequent drag events.
    override func mouseDown(with event: NSEvent) { didDrag = false }
    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        onDelta?(event.deltaX, event.deltaY)
    }
    override func mouseUp(with event: NSEvent) { if didDrag { onEnd?() } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// Header background that moves its overlay by mouse-drag deltas. SwiftUI
/// content above it that is hit-testable (buttons, sliders) keeps its clicks;
/// everything else in the header falls through to here.
struct ScopeDragHandle: NSViewRepresentable {
    var onDelta: (CGFloat, CGFloat) -> Void
    var onEnd: () -> Void = {}
    func makeNSView(context: Context) -> ScopeDragHandleNSView {
        let v = ScopeDragHandleNSView(); v.onDelta = onDelta; v.onEnd = onEnd; return v
    }
    func updateNSView(_ nsView: ScopeDragHandleNSView, context: Context) {
        nsView.onDelta = onDelta; nsView.onEnd = onEnd
    }
}

extension ScopeOverlayPlacement {
    /// Debug builds print where a scope landed after a title-bar drag, to
    /// check the nearer-edge pinning against what is on screen.
    func logDragEnd(_ name: String, in container: CGSize) {
        #if DEBUG
        print("🔭 \(name) drag ended: \(debugDescription(in: container))")
        #endif
    }
}

// MARK: - Mouse-down observer (z-order)

/// Reports every left mouse-down that lands inside its bounds, without
/// consuming it, so clicking anywhere on a scope (diagram, slider, header,
/// resize corner) can raise it. Uses a local event monitor because the
/// diagram's Metal view and SwiftUI controls would otherwise swallow it.
final class ScopeMouseDownNSView: NSView {
    var onMouseDown: ((TimeInterval) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, let window = self.window, event.window === window {
                let p = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(p) { self.onMouseDown?(event.timestamp) }
            }
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

struct ScopeMouseDownObserver: NSViewRepresentable {
    var onMouseDown: (TimeInterval) -> Void
    func makeNSView(context: Context) -> ScopeMouseDownNSView {
        let v = ScopeMouseDownNSView(); v.onMouseDown = onMouseDown; return v
    }
    func updateNSView(_ nsView: ScopeMouseDownNSView, context: Context) { nsView.onMouseDown = onMouseDown }
}
