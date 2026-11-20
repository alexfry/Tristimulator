//
//  ImageToolbar.swift
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

import SwiftUI

struct ImageToolbar: View {
    @Binding var exposure: Float
    @Binding var showScopes: Bool
    @Binding var showPipelinePopover: Bool
    
    @Bindable var imageManager: ImageManager
    @Binding var selectedSourceSpace: String
    @Binding var selectedDestSpace: String
    @Binding var selectedDisplay: String
    @Binding var selectedView: String
    @Binding var selectedMetalColorSpace: String
    @Binding var hasAppliedTransforms: Bool
    
    let onOpenImage: () -> Void
    let onSaveImage: () -> Void
    
    // EDR info popover state
    @Binding var showEDRInfoPopover: Bool
    @Binding var isHDRAvailable: Bool
    @Binding var peakPixelResult: SIMD4<Float>?
    
    // Channel isolation
    @Binding var channelMode: ChannelMode
    
    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            
            // Invisible counterweight so the capsule stays centered
            ChannelIndicator(mode: channelMode)
                .fixedSize()
                .opacity(0)
                .padding(.trailing, 6)
            
            // Exposure control pill
            HStack(spacing: 8) {
                Text("Exposure:")
                    .font(.caption)
                
                ExposureSlider(value: $exposure)
                    .frame(width: 200, height: 24)
                
                Text(String(format: "%.1f", exposure))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 35, alignment: .trailing)
                
                Button(action: { exposure = 0 }) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Reset exposure")
                
                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)
                
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
                .buttonStyle(.borderless)
                .help(isHDRAvailable ? "Extended Dynamic Range available" : "Standard Dynamic Range")
                .popover(isPresented: $showEDRInfoPopover, arrowEdge: .bottom) {
                    EDRInfoView(peakPixelResult: peakPixelResult)
                        .frame(width: 400)
                        .padding()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .compatGlass(in: Capsule())
            
            // Visible channel indicator
            ChannelIndicator(mode: channelMode)
                .fixedSize()
                .opacity(channelMode != .normal ? 1 : 0)
                .padding(.leading, 6)
            
            Spacer()
            
            // Right side: OCIO button
            HStack(spacing: 12) {
                Button(action: {
                    showPipelinePopover.toggle()
                }) {
                    Image("opencolorio-icon-white")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.borderless)
                .help("Show color pipeline")
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
            .padding(.trailing, 8)
        }
        .padding(.horizontal, 12)
        .animation(.easeInOut(duration: 0.25), value: channelMode)
    }
}

// Custom slider with tick marks at every 1.0 stop
struct ExposureSlider: NSViewRepresentable {
    @Binding var value: Float
    
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: -10.0, maxValue: 10.0, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        
        // Enable continuous updates while dragging
        slider.isContinuous = true
        
        // Set neutral value to 0.0 so the fill draws from center
        if #available(macOS 26, *) {
            slider.neutralValue = 0.0
        }
        
        // Configure tick marks - 21 marks from -10 to +10 (every 1.0)
        slider.numberOfTickMarks = 21
        slider.allowsTickMarkValuesOnly = false
        slider.tickMarkPosition = .below
        
        return slider
    }
    
    func updateNSView(_ nsView: NSSlider, context: Context) {
        if abs(nsView.doubleValue - Double(value)) > 0.001 {
            nsView.doubleValue = Double(value)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }
    
    class Coordinator: NSObject {
        var value: Binding<Float>
        
        init(value: Binding<Float>) {
            self.value = value
        }
        
        @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = Float(sender.doubleValue)
        }
    }
}

// MARK: - Channel Indicator

struct ChannelIndicator: View {
    let mode: ChannelMode

    private var label: String {
        switch mode {
        case .normal:    return ""
        case .red:       return "R"
        case .green:     return "G"
        case .blue:      return "B"
        case .luminance: return "Y"
        case .alpha:     return "A"
        }
    }

    private var tintColor: Color {
        switch mode {
        case .red:       return .red
        case .green:     return .green
        case .blue:      return .blue
        case .luminance: return .white
        case .alpha:     return .white
        case .normal:    return .clear
        }
    }

    private var labelColor: Color {
        mode == .luminance ? .black : .primary
    }

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(labelColor)
            .frame(width: 28, height: 28)
            .compatGlassTintedCircle(tint: tintColor)
    }
}

#Preview {
    ImageToolbar(
        exposure: .constant(0.0),
        showScopes: .constant(true),
        showPipelinePopover: .constant(false),
        imageManager: ImageManager(),
        selectedSourceSpace: .constant(""),
        selectedDestSpace: .constant(""),
        selectedDisplay: .constant(""),
        selectedView: .constant(""),
        selectedMetalColorSpace: .constant("displayP3"),
        hasAppliedTransforms: .constant(false),
        onOpenImage: {},
        onSaveImage: {},
        showEDRInfoPopover: .constant(false),
        isHDRAvailable: .constant(true),
        peakPixelResult: .constant(nil),
        channelMode: .constant(.red)
    )
    .frame(height: 44)
}
