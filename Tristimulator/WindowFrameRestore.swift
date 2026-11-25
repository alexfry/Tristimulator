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

    /// Applies a saved per-image frame, clamped to the visible screens.
    /// Does nothing in full screen or when the frame is unusable.
    func restore(savedFrame: WindowFrame) {
        guard !styleMask.contains(.fullScreen),
              let target = savedFrame.clamped(toVisibleFrames: NSScreen.screens.map(\.visibleFrame)),
              target != frame else { return }
        setFrame(target, display: true)
    }
}
