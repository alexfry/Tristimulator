//
//  MovieControlsView.swift
//  Tristimulator
//
//  Pure-SwiftUI floating transport HUD for movies.
//
//  Combines playback controls with the image info strip in a single dark-glass
//  pill that floats over the Metal image view — no AVPlayerView box, no
//  separate background strip.
//
//  Glass recipe (QuickTime-style):
//    .regularMaterial (dark env) → prominent backdrop blur, medium-dark tint
//    + black.opacity(0.28)       → nudges to charcoal without killing the blur
//    + 0.5 pt white stroke       → specular edge highlight = "glass" feel
//

import SwiftUI
import AppKit

// MARK: - AppKit drag overlay
//
// NSView subclass placed in .background so it sits behind all SwiftUI controls.
// Slider and Button views absorb their own mouse events before AppKit reaches
// this layer, so scrubbing / button clicks are unaffected. Everything else
// (labels, divider, info row, padding) falls through here and moves the pill.
//
// event.deltaX / deltaY are raw hardware deltas — always 1:1 with the mouse,
// no SwiftUI coordinate-space conversion needed.

private final class PillDragNSView: NSView {
    var onDelta: ((CGFloat, CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Accept the mouse-down so we receive subsequent drag events.
    }

    override func mouseDragged(with event: NSEvent) {
        onDelta?(event.deltaX, event.deltaY)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

private struct PillDragOverlay: NSViewRepresentable {
    var onDelta: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> PillDragNSView {
        let v = PillDragNSView()
        v.onDelta = onDelta
        return v
    }
    func updateNSView(_ nsView: PillDragNSView, context: Context) {
        nsView.onDelta = onDelta
    }
}

// MARK: - Movie controls

struct MovieControlsView: View {

    let movie: MovieSource
    /// Pass the current ImageData to show the info row inside the pill.
    var imageData: ImageData? = nil
    /// When non-nil, overrides `imageData.metadata.colorSpace` in the info row.
    /// Pass `document.selectedSourceSpace` so it always reflects the OCIO source space.
    var sourceSpace: String? = nil
    /// Called when the cursor enters or leaves the pill bounds.
    /// Lets the parent suppress the auto-hide timer while the cursor is over the controls.
    var onHoverChange: ((Bool) -> Void)? = nil

    /// Non-nil while the user is actively dragging the scrub slider.
    @State private var scrubTime: Double? = nil

    // MARK: - Dragging
    //
    // Accumulated pixel offset. Updated by the AppKit overlay via raw deltaX/Y.
    @State private var offset: CGSize = .zero

    var body: some View {
        VStack(spacing: 6) {

            // ── Row 1: Volume | Transport ─────────────────────────────────────
            HStack(spacing: 0) {

                // Volume — left quadrant, fixed width so transport stays centred
                HStack(spacing: 6) {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 12))
                        .frame(width: 16)
                    Slider(
                        value: Binding(
                            get: { Double(movie.volume) },
                            set: { movie.volume = Float($0) }
                        ),
                        in: 0...1
                    )
                    .frame(width: 100)
                }
                .foregroundStyle(.secondary)

                Spacer()

                // Transport — centred
                HStack(spacing: 28) {
                    Button {
                        Task { await movie.stepBackward() }
                    } label: {
                        Image(systemName: "backward.frame")
                            .font(.system(size: 18, weight: .medium))
                    }

                    Button {
                        movie.isPlaying ? movie.pause() : movie.play()
                    } label: {
                        Image(systemName: movie.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 26)
                    }

                    Button {
                        Task { await movie.stepForward() }
                    } label: {
                        Image(systemName: "forward.frame")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                Spacer()

                // Mirror the volume width so transport stays visually centred
                Color.clear.frame(width: 122)
            }
            .padding(.top, 10)

            // ── Row 2: Timecode | Scrub | Duration | Loop ────────────────────
            HStack(spacing: 8) {

                Text(formatTimecode(scrubTime ?? movie.currentTime, fps: movie.frameRate))
                    .monospacedDigit()
                    .frame(minWidth: 80, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { scrubTime ?? movie.currentTime },
                        set: { newValue in
                            scrubTime = newValue
                            movie.seek(to: newValue)
                        }
                    ),
                    in: 0...max(movie.duration, 1),
                    onEditingChanged: { editing in
                        if !editing { scrubTime = nil }
                    }
                )

                Text(formatTimecode(movie.duration, fps: movie.frameRate))
                    .monospacedDigit()
                    .frame(minWidth: 80, alignment: .leading)

                // Loop toggle — right of duration
                Button {
                    movie.isLooping.toggle()
                } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(movie.isLooping ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, imageData != nil ? 10 : 14)

            // ── Image info row ────────────────────────────────────────────────
            if let img = imageData {
                Divider()
                    .padding(.horizontal, -24)

                infoRow(for: img)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 9)
            }
        }
        .padding(.horizontal, 24)
        // fixedSize prevents the pill from greedily expanding to fill all
        // available vertical space when placed inside a Spacer-padded VStack.
        .fixedSize(horizontal: false, vertical: true)
        // AppKit drag overlay — sized to pill content, 1:1 mouse deltas.
        .background {
            PillDragOverlay { dx, dy in
                offset.width  += dx
                offset.height += dy
            }
        }
        .frame(maxWidth: 560)
        .compatGlass(in: .rect(cornerRadius: 16))
        .offset(x: offset.width, y: offset.height)
        .onHover { inside in onHoverChange?(inside) }
        .onDisappear {
            movie.stopFrameExtraction()
            movie.onFrame = nil
        }
    }

    // MARK: - Volume icon

    private var volumeIcon: String {
        switch movie.volume {
        case 0:          return "speaker.slash.fill"
        case ..<0.4:     return "speaker.wave.1.fill"
        case ..<0.75:    return "speaker.wave.2.fill"
        default:         return "speaker.wave.3.fill"
        }
    }

    // MARK: - Info row

    @ViewBuilder
    private func infoRow(for img: ImageData) -> some View {
        HStack(spacing: 14) {
            infoItem(icon: "ruler",              label: "\(img.width) × \(img.height)")
            infoDivider()
            infoItem(icon: "square.stack.3d.up", label: "\(img.channels) ch")
            infoDivider()
            infoItem(icon: "number",             label: "\(img.metadata.bitDepth)-bit")
            infoDivider()
            infoItem(icon: "paintpalette",       label: sourceSpace ?? img.metadata.colorSpace)
            if let nits = img.metadata.maxLuminance, nits > 0 {
                infoDivider()
                infoItem(icon: "lightbulb.max",  label: String(format: "%.0f nits", nits))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func infoItem(icon: String, label: String) -> some View {
        Label(label, systemImage: icon)
    }

    private func infoDivider() -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 11)
    }

    // MARK: - Timecode helper

    /// Formats seconds as SMPTE drop-free timecode: HH:MM:SS:FF
    private func formatTimecode(_ seconds: Double, fps: Float) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00:00:00" }
        let r = max(Int(fps.rounded()), 1)
        let totalFrames = Int((seconds * Double(r)).rounded())
        let ff = totalFrames % r
        let totalSecs = totalFrames / r
        let ss = totalSecs % 60
        let mm = (totalSecs / 60) % 60
        let hh = totalSecs / 3600
        return String(format: "%02d:%02d:%02d:%02d", hh, mm, ss, ff)
    }
}
