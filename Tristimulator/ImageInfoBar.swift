//
//  ImageInfoBar.swift
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

import SwiftUI
import AppKit

struct ImageInfoBar: View {
    let imageData: ImageData
    /// When non-nil, overrides `imageData.metadata.colorSpace` in the display.
    /// Pass `document.selectedSourceSpace` so the bar always reflects the OCIO source space.
    var sourceSpace: String? = nil
    /// OCIO config used by the AMF popover to show real per-stage application status.
    var ocioConfig: OCIOConfig? = nil
    /// Image manager — lets the AMF popover reflect the live Look-node toggle state.
    var imageManager: ImageManager? = nil

    /// Currently selected EXR layer name ("" = default/unnamed RGBA layer).
    /// Only shown when `imageData.metadata.layerNames` has more than one entry.
    var selectedLayer: String = ""
    /// Called when the user picks a different layer from the menu.
    var onLayerChange: ((String) -> Void)? = nil

    // MARK: - AMF popover
    @State private var showAMFPopover = false

    // MARK: - Dragging
    @State private var storedOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    private var totalOffset: CGSize {
        CGSize(width:  storedOffset.width  + dragTranslation.width,
               height: storedOffset.height + dragTranslation.height)
    }

    var body: some View {
        HStack(spacing: 14) {
            Label("\(imageData.width) × \(imageData.height)", systemImage: "ruler")

            pillDivider()

            Label("\(imageData.channels) ch", systemImage: "square.stack.3d.up")

            pillDivider()

            Label("\(imageData.metadata.bitDepth)-bit", systemImage: "number")

            pillDivider()

            Label(sourceSpace ?? imageData.metadata.colorSpace, systemImage: "paintpalette")

            if let nits = imageData.metadata.maxLuminance, nits > 0 {
                pillDivider()
                Label(String(format: "%.0f nits", nits), systemImage: "lightbulb.max")
                    .monospacedDigit()
            }

            if let amf = imageData.metadata.amfData {
                pillDivider()
                Button {
                    showAMFPopover.toggle()
                } label: {
                    Label("AMF", systemImage: "doc.badge.clock")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAMFPopover, arrowEdge: .bottom) {
                    AMFInfoView(amf: amf, config: ocioConfig, imageManager: imageManager)
                        .frame(width: 340, height: 460)
                }
            }

            if imageData.metadata.layerNames.count > 1 {
                pillDivider()
                Menu {
                    ForEach(imageData.metadata.layerNames, id: \.self) { name in
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
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .compatGlass(in: Capsule())
        .offset(x: totalOffset.width, y: totalOffset.height)
        .gesture(
            DragGesture(minimumDistance: 2)
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    storedOffset.width  += value.translation.width
                    storedOffset.height += value.translation.height
                }
        )
        .onHover { inside in
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
    }

    private func pillDivider() -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 11)
    }
}
