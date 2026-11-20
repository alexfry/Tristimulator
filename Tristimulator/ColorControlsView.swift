//
//  ColorControlsView.swift
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

import SwiftUI

struct ColorControlsView: View {
    @Bindable var imageManager: ImageManager
    
    @State private var selectedSourceSpace = ""
    @State private var selectedDestSpace = ""
    @State private var selectedDisplay = ""
    @State private var selectedView = ""
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Color Management")
                    .font(.headline)
                    .padding(.horizontal)
                
                // Color space transformation
                GroupBox("Color Space Transform") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Source Space", selection: $selectedSourceSpace) {
                            ForEach(imageManager.availableColorSpaces(), id: \.self) { space in
                                Text(space).tag(space)
                            }
                        }
                        .labelsHidden()
                        .help("Source color space")
                        .onChange(of: selectedSourceSpace) { oldValue, newValue in
                            // Auto-apply when source space changes
                            applyColorTransformAndReapplyDisplay()
                        }
                        
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.down")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        
                        Picker("Destination Space", selection: $selectedDestSpace) {
                            ForEach(imageManager.availableColorSpaces(), id: \.self) { space in
                                Text(space).tag(space)
                            }
                        }
                        .labelsHidden()
                        .help("Destination color space")
                        .onChange(of: selectedDestSpace) { oldValue, newValue in
                            // Auto-apply when destination space changes
                            applyColorTransformAndReapplyDisplay()
                        }
                    }
                }
                .padding(.horizontal)
                
                // Display transform
                GroupBox("Display Transform") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Display", selection: $selectedDisplay) {
                            ForEach(imageManager.availableDisplays(), id: \.self) { display in
                                Text(display).tag(display)
                            }
                        }
                        .onChange(of: selectedDisplay) { oldValue, newValue in
                            // Update views when display changes
                            let views = imageManager.views(for: newValue)
                            if !views.isEmpty {
                                if let defaultView = imageManager.ocioConfig?.defaultView(forDisplay: newValue) {
                                    selectedView = defaultView
                                } else {
                                    selectedView = views[0]
                                }
                            }
                            // Auto-apply when selection changes
                            applyDisplayTransform()
                        }
                        
                        if !selectedDisplay.isEmpty {
                            Picker("View", selection: $selectedView) {
                                ForEach(imageManager.views(for: selectedDisplay), id: \.self) { view in
                                    Text(view).tag(view)
                                }
                            }
                            .onChange(of: selectedView) { oldValue, newValue in
                                // Auto-apply when view changes
                                applyDisplayTransform()
                            }
                        }
                    }
                }
                .padding(.horizontal)
                
                // Image metadata
                if let metadata = imageManager.currentImage?.metadata {
                    GroupBox("Image Metadata") {
                        VStack(alignment: .leading, spacing: 8) {
                            MetadataRow(label: "Color Space", value: metadata.colorSpace)
                            MetadataRow(label: "Bit Depth", value: "\(metadata.bitDepth)-bit")
                            MetadataRow(label: "HDR", value: metadata.isHDR ? "Yes" : "No")
                            
                            if let maxLuminance = metadata.maxLuminance {
                                MetadataRow(label: "Max Luminance", value: String(format: "%.0f nits", maxLuminance))
                            }
                            
                            if !metadata.attributes.isEmpty {
                                Divider()
                                    .padding(.vertical, 4)
                                
                                Text("Attributes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                ForEach(Array(metadata.attributes.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                                    MetadataRow(label: key, value: value)
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(.regularMaterial)
        .onAppear {
            setupDefaultsAndApply()
        }
        .onChange(of: imageManager.currentImage?.width) { oldValue, newValue in
            // Only reset when dimensions change (i.e., a new image was loaded)
            // Not when the same image is transformed
            if newValue != nil && oldValue != newValue {
                setupDefaultsAndApply()
            }
        }
    }
    
    private func setupDefaultsAndApply() {
        // Set default color spaces using OCIO roles
        let colorSpaces = imageManager.availableColorSpaces()
        if !colorSpaces.isEmpty {
            // Use OCIO roles for defaults
            if let sceneLinear = imageManager.ocioConfig?.sceneLinearColorSpace() {
                selectedSourceSpace = sceneLinear
            } else if let defaultSpace = imageManager.ocioConfig?.defaultColorSpace() {
                selectedSourceSpace = defaultSpace
            } else {
                selectedSourceSpace = colorSpaces[0]
            }
            
            // For destination, use a reasonable default
            // In a proper workflow, this would often be the same as source
            // or a specific working space
            selectedDestSpace = selectedSourceSpace
        }
        
        // Set default display and view
        let displays = imageManager.availableDisplays()
        if !displays.isEmpty {
            // Use default display from OCIO config
            if let defaultDisplay = imageManager.ocioConfig?.defaultDisplay(), !defaultDisplay.isEmpty {
                selectedDisplay = defaultDisplay
            } else {
                selectedDisplay = displays[0]
            }
            
            let views = imageManager.views(for: selectedDisplay)
            if !views.isEmpty {
                // Use default view for this display
                if let defaultView = imageManager.ocioConfig?.defaultView(forDisplay: selectedDisplay), !defaultView.isEmpty {
                    selectedView = defaultView
                } else {
                    selectedView = views[0]
                }
            }
        }
        
        // Automatically apply display transform if we have an image
        if imageManager.currentImage != nil {
            applyDisplayTransform()
        }
    }
    
    private func applyColorTransform() {
        do {
            try imageManager.applyColorTransform(
                from: selectedSourceSpace,
                to: selectedDestSpace
            )
        } catch {
            print("Error applying color transform: \(error)")
        }
    }
    
    private func applyColorTransformAndReapplyDisplay() {
        // First apply the color space transform
        applyColorTransform()
        
        // Then reapply the display transform to ensure proper viewing
        // This is necessary because the color transform changes the pixel data
        applyDisplayTransform()
    }
    
    private func applyDisplayTransform() {
        guard imageManager.currentImage != nil else { return }
        guard !selectedDisplay.isEmpty && !selectedView.isEmpty else { return }

        Task { @MainActor in
            do {
                try await imageManager.applyDisplayTransform(
                    from: selectedSourceSpace,
                    display: selectedDisplay,
                    view: selectedView
                )
            } catch {
                print("Error applying display transform: \(error)")
            }
        }
    }
}

#Preview {
    ColorControlsView(imageManager: ImageManager())
        .frame(width: 400, height: 600)
}
