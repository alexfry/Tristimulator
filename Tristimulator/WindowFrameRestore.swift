//
//  WindowFrameRestore.swift
//  Tristimulator
//
//  Per-image main window frame: the frame is saved with each image's OCIO
//  settings (`OCIOPipelineSettings.windowFrame`) and re-applied when that
//  image's settings load, clamped so it fits on a connected screen.
//

import AppKit

extension WindowFrame {
    /// The frame moved and, if needed, shrunk so it lies inside one of
    /// `visibleFrames` (screen `visibleFrame`s, menu bar and Dock excluded).
    /// Picks the screen the frame overlaps most, or the first screen (main)
    /// when it overlaps none, e.g. a display that is no longer connected.
    /// Returns nil for degenerate frames or when there are no screens.
    func clamped(toVisibleFrames visibleFrames: [NSRect]) -> NSRect? {
        let frame = nsRect
        guard frame.width.isFinite, frame.height.isFinite, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width >= 1, frame.height >= 1,
              let fallback = visibleFrames.first else { return nil }

        func overlap(_ r: NSRect) -> CGFloat {
            let i = r.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        let screen = visibleFrames.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
            ?? fallback

        var r = frame
        r.size.width  = min(r.width, screen.width)
        r.size.height = min(r.height, screen.height)
        r.origin.x = min(max(r.minX, screen.minX), screen.maxX - r.width)
        r.origin.y = min(max(r.minY, screen.minY), screen.maxY - r.height)
        return r
    }
}

extension NSWindow {
    /// Frame worth saving for this image, or nil while the window is in full
    /// screen (the windowed frame is what should come back).
    var persistableFrame: WindowFrame? {
        styleMask.contains(.fullScreen) ? nil : WindowFrame(frame)
    }

    /// Applies a saved per-image frame, clamped to the visible screens, with no
    /// animation. Does nothing in full screen or when the frame is unusable.
    /// Returns the frame applied (or already in place), nil when skipped.
    @discardableResult
    func restore(savedFrame: WindowFrame, display: Bool = true) -> NSRect? {
        guard !styleMask.contains(.fullScreen),
              let target = savedFrame.clamped(toVisibleFrames: NSScreen.screens.map(\.visibleFrame))
        else { return nil }
        if target != frame {
            setFrame(target, display: display, animate: false)
        }
        return target
    }
}

/// Invisible view behind each document's content that hands back its window
/// the moment it is added to one. For a newly opened document that happens
/// while SwiftUI is still building the window, before it is ordered on
/// screen, so the image's saved frame can be applied before the first frame
/// is drawn instead of snapping the window to size later.
final class WindowAttachView: NSView {
    /// Called once, synchronously, with the first window this view joins.
    var onAttach: ((NSWindow) -> Void)?
    /// Saved frame for the window being opened; read when the view attaches.
    var initialFrame: (() -> WindowFrame?)?
    /// Called once the saved frame has been applied to the window.
    var onInitialFrameApplied: (() -> Void)?

    private var attached = false
    private var holdObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !attached, let window else { return }
        attached = true
        onAttach?(window)
        guard let saved = initialFrame?(),
              let target = window.restore(savedFrame: saved, display: false) else { return }
        onInitialFrameApplied?()
        if !window.isVisible {
            holdFrameUntilShown(window, target: target)
        }
    }

    /// AppKit/SwiftUI may still cascade or size the window between now and it
    /// going on screen; put the saved frame back on any such change (still
    /// before display) until the window is shown, then stop.
    private func holdFrameUntilShown(_ window: NSWindow, target: NSRect) {
        let center = NotificationCenter.default
        let revert: (Notification) -> Void = { [weak window] _ in
            guard let window, !window.inLiveResize,
                  !window.styleMask.contains(.fullScreen),
                  window.frame != target else { return }
            window.setFrame(target, display: false, animate: false)
        }
        holdObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map {
            center.addObserver(forName: $0, object: window, queue: nil, using: revert)
        }
        // Stop one run-loop turn after the window is shown (occlusion state
        // changes when it goes on screen), with a short cap in case it never is.
        holdObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                object: window, queue: nil) { [weak self, weak window] _ in
            guard window?.isVisible == true else { return }
            DispatchQueue.main.async { self?.stopHolding() }
        })
        let tokens = holdObservers
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            tokens.forEach { center.removeObserver($0) }
        }
    }

    private func stopHolding() {
        holdObservers.forEach { NotificationCenter.default.removeObserver($0) }
        holdObservers.removeAll()
    }
}
