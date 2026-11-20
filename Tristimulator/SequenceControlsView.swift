//
//  SequenceControlsView.swift
//  Tristimulator
//
//  Transport HUD for image sequences — styled identically to the MovieControlsView
//  glass pill so the two modes feel consistent to users.
//
//  Differences from MovieControlsView:
//    • No volume control (sequences have no audio).
//    • Frame rate picker in place of the volume control, letting users set
//      the playback rate for sequences that have no embedded timing metadata.
//    • Frame-number display (## / total) instead of SMPTE timecode on the
//      left counter; the right counter still shows a timecode for orientation.
//    • The info row is updated every frame because OIIO provides richer per-
//      frame metadata (actual colour space, bit depth) than AVFoundation.
//

import SwiftUI
import AppKit

// MARK: - AppKit drag overlay (shared style with MovieControlsView)

private final class SeqPillDragNSView: NSView {
    var onDelta: ((CGFloat, CGFloat) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) { onDelta?(event.deltaX, event.deltaY) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

private struct SeqPillDragOverlay: NSViewRepresentable {
    var onDelta: (CGFloat, CGFloat) -> Void
    func makeNSView(context: Context) -> SeqPillDragNSView {
        let v = SeqPillDragNSView(); v.onDelta = onDelta; return v
    }
    func updateNSView(_ nsView: SeqPillDragNSView, context: Context) { nsView.onDelta = onDelta }
}

// MARK: - FPS picker options

private let fpsOptions: [(label: String, value: Float)] = [
    ("12 fps",  12),
    ("23.976 fps", 23.976),
    ("24 fps",  24),
    ("25 fps",  25),
    ("29.97 fps", 29.97),
    ("30 fps",  30),
    ("48 fps",  48),
    ("60 fps",  60),
]

// MARK: - SequenceControlsView

struct SequenceControlsView: View {

    let sequence: ImageSequenceSource
    /// Current frame's ImageData — passed each time `onFrame` fires in DocumentContentView.
    var imageData: ImageData? = nil
    /// Overrides `imageData.metadata.colorSpace` in the info row.
    var sourceSpace: String? = nil
    /// Currently selected EXR layer name ("" = default RGBA layer).
    var selectedLayer: String = ""
    /// Called when the user picks a different EXR layer.
    var onLayerChange: ((String) -> Void)? = nil
    /// Cursor hover change callback (used by DocumentContentView to suppress auto-hide).
    var onHoverChange: ((Bool) -> Void)? = nil
    /// OCIO config used by the AMF popover to show real per-stage application status.
    var ocioConfig: OCIOConfig? = nil
    /// Image manager — lets the AMF popover reflect the live Look-node toggle state.
    var imageManager: ImageManager? = nil

    /// Non-nil while the user is actively dragging the scrub slider.
    @State private var scrubIndex: Int? = nil
    @State private var showAMFPopover = false

    // Dragging state
    @State private var offset: CGSize = .zero

    var body: some View {
        VStack(spacing: 6) {

            // ── Row 1: FPS Picker | Transport | mirror spacer ─────────────────
            HStack(spacing: 0) {

                // FPS picker — left quadrant, fixed width so transport stays centred
                HStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(.system(size: 12))
                    Menu {
                        ForEach(fpsOptions, id: \.value) { opt in
                            Button(opt.label) { sequence.frameRate = opt.value }
                        }
                    } label: {
                        Text(fpsLabel(sequence.frameRate))
                            .font(.system(size: 12, weight: .medium))
                            .frame(minWidth: 60, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                }
                .foregroundStyle(.secondary)
                .frame(width: 100)

                Spacer()

                // Transport — centred
                HStack(spacing: 28) {
                    Button {
                        Task { await sequence.stepBackward() }
                    } label: {
                        Image(systemName: "backward.frame")
                            .font(.system(size: 18, weight: .medium))
                    }

                    Button {
                        sequence.isPlaying ? sequence.pause() : sequence.play()
                    } label: {
                        Image(systemName: sequence.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 26)
                    }

                    Button {
                        Task { await sequence.stepForward() }
                    } label: {
                        Image(systemName: "forward.frame")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                Spacer()

                // Mirror the FPS picker width so transport stays visually centred
                Color.clear.frame(width: 100)
            }
            .padding(.top, 10)

            // ── Row 2: Frame # | Scrub | Duration | Loop ─────────────────────
            HStack(spacing: 8) {

                // Current frame number
                Text(frameLabel(scrubIndex ?? sequence.currentIndex))
                    .monospacedDigit()
                    .frame(minWidth: 80, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { Double(scrubIndex ?? sequence.currentIndex) },
                        set: { newValue in
                            let idx = Int(newValue.rounded())
                            scrubIndex = idx
                            sequence.seek(to: idx)
                        }
                    ),
                    in: 0...Double(max(sequence.frameCount - 1, 1)),
                    onEditingChanged: { editing in
                        if !editing { scrubIndex = nil }
                    }
                )

                // Total frame count
                Text(frameLabel(sequence.frameCount - 1))
                    .monospacedDigit()
                    .frame(minWidth: 80, alignment: .leading)

                // Loop toggle
                Button {
                    sequence.isLooping.toggle()
                } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(sequence.isLooping ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, imageData != nil ? 10 : 14)

            // ── Image info row ─────────────────────────────────────────────────
            if let img = imageData {
                Divider()
                    .padding(.horizontal, -24)

                infoRow(for: img)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 9)
            }
        }
        .padding(.horizontal, 24)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            SeqPillDragOverlay { dx, dy in
                offset.width  += dx
                offset.height += dy
            }
        }
        .frame(maxWidth: 560)
        .compatGlass(in: .rect(cornerRadius: 16))
        .offset(x: offset.width, y: offset.height)
        .onHover { inside in onHoverChange?(inside) }
    }

    // MARK: - Info row

    @ViewBuilder
    private func infoRow(for img: ImageData) -> some View {
        HStack(spacing: 14) {
            infoItem(icon: "ruler",
                     label: "\(img.width) × \(img.height)")
            infoDivider()
            infoItem(icon: "square.stack.3d.up",
                     label: "\(img.channels) ch")
            infoDivider()
            infoItem(icon: "number",
                     label: "\(img.metadata.bitDepth)-bit")
            infoDivider()
            infoItem(icon: "paintpalette",
                     label: sourceSpace ?? img.metadata.colorSpace)
            if let nits = img.metadata.maxLuminance, nits > 0 {
                infoDivider()
                infoItem(icon: "lightbulb.max",
                         label: String(format: "%.0f nits", nits))
            }
            if img.metadata.layerNames.count > 1 {
                infoDivider()
                Menu {
                    ForEach(img.metadata.layerNames, id: \.self) { name in
                        Button(action: { onLayerChange?(name) }) {
                            if name == selectedLayer {
                                Label(name.isEmpty ? "RGBA" : name, systemImage: "checkmark")
                            } else {
                                Text(name.isEmpty ? "RGBA" : name)
                            }
                        }
                    }
                } label: {
                    Label(selectedLayer.isEmpty ? "RGBA" : selectedLayer,
                          systemImage: "square.stack.layers.below.rectangle")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 120)
            }
            if let amf = img.metadata.amfData {
                infoDivider()
                Button {
                    showAMFPopover.toggle()
                } label: {
                    infoItem(icon: "doc.badge.clock", label: "AMF")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAMFPopover, arrowEdge: .bottom) {
                    AMFInfoView(amf: amf, config: ocioConfig, imageManager: imageManager)
                        .frame(width: 340, height: 460)
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func infoItem(icon: String, label: String) -> some View {
        Label(label, systemImage: icon)
    }

    private func infoDivider() -> some View {
        Rectangle().fill(.separator).frame(width: 1, height: 11)
    }

    // MARK: - Label helpers

    /// Formats a frame index as a zero-padded string using the actual on-disk
    /// frame number (e.g. 1001, 1002, …) instead of the 0-based array index.
    private func frameLabel(_ index: Int) -> String {
        let num = actualFrameNumber(at: index)
        let maxNum = sequence.frameNumbers.last ?? sequence.frameCount
        let digits = max(numberOfDigits(maxNum), 4)
        return String(format: "%0\(digits)d", num)
    }

    /// Maps an array index to the actual frame number from the filename.
    private func actualFrameNumber(at index: Int) -> Int {
        guard index >= 0, index < sequence.frameNumbers.count else { return max(0, index) }
        return sequence.frameNumbers[index]
    }

    private func numberOfDigits(_ n: Int) -> Int {
        n <= 0 ? 1 : Int(log10(Double(n))) + 1
    }

    /// Returns a display string for the current frame rate, e.g. "24 fps".
    private func fpsLabel(_ fps: Float) -> String {
        // Round near-integers for display; keep decimals for fractional rates.
        let rounded = fps.rounded()
        if abs(fps - rounded) < 0.01 {
            return "\(Int(rounded)) fps"
        }
        return String(format: "%.3g fps", fps)
    }
}
