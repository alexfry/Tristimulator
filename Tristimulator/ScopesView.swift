//
//  ScopesView.swift
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

import SwiftUI
import Charts

struct ScopesView: View {
    let imageData: ImageData?
    @Binding var selectedScope: ScopeType

    @State private var histogramData: HistogramData?
    @State private var waveformData: WaveformData?
    @State private var vectorscopeData: VectorscopeData?

    var body: some View {
        VStack(spacing: 0) {
            // Scope selector
            HStack {
                Text("Scope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Scope", selection: $selectedScope) {
                    ForEach(ScopeType.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            // Scope display
            Group {
                if imageData != nil {
                    switch selectedScope {
                    case .histogram:
                        HistogramView(data: histogramData)
                    case .waveform:
                        WaveformView(data: waveformData)
                    case .vectorscope:
                        VectorscopeView(data: vectorscopeData)
                    case .parade:
                        RGBParadeView(data: waveformData)
                    case .chromaticity:
                        // Chromaticity lives in the floating panel; show a hint here.
                        ContentUnavailableView(
                            "CIE Yxy",
                            systemImage: "circle.dotted",
                            description: Text("Shown as a floating panel over the image")
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "No Image",
                        systemImage: "photo",
                        description: Text("Open an image to view scopes")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
        .task(id: imageData) {
            await updateScopes()
        }
    }

    private func updateScopes() async {
        guard let imageData = imageData else {
            histogramData = nil
            waveformData = nil
            vectorscopeData = nil
            return
        }

        // Generate scope data using Python colour bridge
        let bridge = PythonColourBridge.shared

        do {
            async let histogram = bridge.generateHistogram(
                imageData: imageData.pixelData,
                width: imageData.width,
                height: imageData.height
            )

            async let waveform = bridge.generateWaveform(
                imageData: imageData.pixelData,
                width: imageData.width,
                height: imageData.height
            )

            async let vectorscope = bridge.generateVectorscope(
                imageData: imageData.pixelData,
                width: imageData.width,
                height: imageData.height
            )

            histogramData = try await histogram
            waveformData = try await waveform
            vectorscopeData = try await vectorscope
        } catch {
            print("Error generating scope data: \(error)")
        }
    }
}

struct HistogramView: View {
    let data: HistogramData?
    
    var body: some View {
        if let data = data {
            Chart {
                ForEach(Array(data.red.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Level", index),
                        y: .value("Count", value)
                    )
                    .foregroundStyle(.red.opacity(0.6))
                }
                
                ForEach(Array(data.green.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Level", index),
                        y: .value("Count", value)
                    )
                    .foregroundStyle(.green.opacity(0.6))
                }
                
                ForEach(Array(data.blue.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Level", index),
                        y: .value("Count", value)
                    )
                    .foregroundStyle(.blue.opacity(0.6))
                }
            }
            .chartXAxis {
                AxisMarks(values: [0, 64, 128, 192, 255])
            }
            .chartLegend(.hidden)
            .padding()
        } else {
            ProgressView()
        }
    }
}

struct WaveformView: View {
    let data: WaveformData?
    
    var body: some View {
        if data != nil {
            // Simplified waveform - in production this would be a custom Metal view
            VStack {
                Text("Waveform")
                    .font(.headline)
                Text("Luminance distribution")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView()
        }
    }
}

struct VectorscopeView: View {
    let data: VectorscopeData?
    
    var body: some View {
        if let data = data {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 20
                
                // Draw circle
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(.secondary),
                    lineWidth: 1
                )
                
                // Draw crosshairs
                context.stroke(
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: center.y))
                        path.addLine(to: CGPoint(x: size.width, y: center.y))
                        path.move(to: CGPoint(x: center.x, y: 0))
                        path.addLine(to: CGPoint(x: center.x, y: size.height))
                    },
                    with: .color(.secondary.opacity(0.5)),
                    lineWidth: 1
                )
                
                // Plot points
                for point in data.points {
                    let x = center.x + CGFloat(point.u) * radius
                    let y = center.y + CGFloat(point.v) * radius
                    let color = Color.white.opacity(Double(point.intensity))
                    
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                        with: .color(color)
                    )
                }
            }
            .background(.black)
            .padding()
        } else {
            ProgressView()
        }
    }
}

struct RGBParadeView: View {
    let data: WaveformData?
    
    var body: some View {
        if data != nil {
            HStack(spacing: 2) {
                // Red channel
                Rectangle()
                    .fill(.red.opacity(0.3))
                    .overlay(Text("R").font(.caption))
                
                // Green channel
                Rectangle()
                    .fill(.green.opacity(0.3))
                    .overlay(Text("G").font(.caption))
                
                // Blue channel
                Rectangle()
                    .fill(.blue.opacity(0.3))
                    .overlay(Text("B").font(.caption))
            }
            .padding()
        } else {
            ProgressView()
        }
    }
}

#Preview {
    ScopesView(imageData: nil, selectedScope: .constant(.histogram))
        .frame(width: 400, height: 400)
}
