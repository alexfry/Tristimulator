//
//  ColorPipelineNodeView.swift
//  Tristimulator
//
//  Visual node-based representation of the color pipeline
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ColorPipelineNodeView: View {
    @Bindable var imageManager: ImageManager
    
    @Binding var selectedSourceSpace: String
    @Binding var selectedDestSpace: String
    @Binding var selectedDisplay: String
    @Binding var selectedView: String
    @Binding var selectedMetalColorSpace: String
    @Binding var hasAppliedTransforms: Bool
    
    @State private var configPath: String = ""
    @State private var isLoadingConfig = false
    @State private var hasInitialized = false
    @State private var nitsEditText: String = ""
    @FocusState private var nitsFieldFocused: Bool

    /// `true` when `configPath` points inside the app bundle (bundled config).
    private var isUsingBundledConfig: Bool {
        !configPath.isEmpty && configPath.hasPrefix(Bundle.main.bundlePath)
    }

    /// Binding that shows a friendly name for the built-in config when reading,
    /// but writes the raw path so the user can always paste a custom path directly.
    private var configDisplayBinding: Binding<String> {
        Binding(
            get: {
                guard isUsingBundledConfig else { return configPath }
                let filename = URL(fileURLWithPath: configPath).deletingPathExtension().lastPathComponent
                return "Built-in: \(filename)"
            },
            set: { configPath = $0 }
        )
    }
    
    // Cache expensive OCIO queries
    @State private var cachedColorSpaces: [String] = []
    @State private var cachedFamilyTree: ColorSpaceFamilyNode = ColorSpaceFamilyNode(name: "Root")
    @State private var cachedDisplays: [String] = []
    @State private var cachedViews: [String: [String]] = [:]
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                VStack(spacing: 0) {
                    // Header
                    Text("Color Pipeline")
                        .font(.headline)
                        .padding(.top)
                    
                    // Nodes container with connectors
                    VStack(spacing: 0) {
                        // Config node
                        ColorNodeView(
                            title: "Config",
                            subtitle: "OpenColorIO Configuration"
                        ) {
                            VStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    TextField("OCIO Config Path", text: configDisplayBinding)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                        .disabled(isLoadingConfig)
                                    
                                    Button(action: browseForConfig) {
                                        Image(systemName: "folder")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(isLoadingConfig)
                                    .help("Browse for OCIO config file")
                                    
                                    Button(action: loadConfig) {
                                        if isLoadingConfig {
                                            ProgressView()
                                                .controlSize(.small)
                                                .frame(width: 16, height: 16)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.caption)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(isLoadingConfig || configPath.isEmpty)
                                    .help("Load OCIO config")
                                }
                                
                                if let config = imageManager.ocioConfig {
                                    Divider()
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                                .font(.caption2)
                                            Text("Config loaded")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        
                                        if let description = config.configInfo {
                                            Text(description)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .compatGlassInteractive(in: .rect(cornerRadius: 16))
                        
                        // Connector
                        ConnectionLine()
                        
                        // Source node
                        ColorNodeView(
                            title: "Source",
                            subtitle: "Input Color Space"
                        ) {
                            VStack(spacing: 12) {
                                // Mode selector (Colorspace vs Inverse Display)
                                GlassSegmentedPicker(
                                    selection: $imageManager.sourceTransformMode,
                                    options: [
                                        (.colorspace, "Color Space"),
                                        (.inverseDisplay, "Inverse Display"),
                                    ]
                                ) { mode in
                                    if mode == .inverseDisplay,
                                       imageManager.sourceInverseDisplay.isEmpty,
                                       let config = imageManager.ocioConfig {
                                        let defaultDisplay = config.defaultDisplay()
                                        if !defaultDisplay.isEmpty {
                                            imageManager.sourceInverseDisplay = defaultDisplay
                                            let defaultView = config.defaultView(forDisplay: defaultDisplay)
                                            if !defaultView.isEmpty {
                                                imageManager.sourceInverseView = defaultView
                                            }
                                        }
                                    }
                                    applyColorTransformAndReapplyDisplay()
                                }
                                .fixedSize()
                                
                                Divider()
                                
                                // Conditional content based on mode
                                if imageManager.sourceTransformMode == .colorspace {
                                    // Family-grouped colorspace picker
                                    FamilyColorSpaceMenu(
                                        label: "Source Space",
                                        selection: $selectedSourceSpace,
                                        familyTree: cachedFamilyTree
                                    )
                                    .onChange(of: selectedSourceSpace) { oldValue, newValue in
                                        if oldValue != newValue {
                                            applyColorTransformAndReapplyDisplay()
                                        }
                                    }
                                } else {
                                    // Inverse display mode: show display and view pickers
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Display to Invert")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        
                                        Picker("", selection: $imageManager.sourceInverseDisplay) {
                                            ForEach(cachedDisplays, id: \.self) { display in
                                                Text(display).tag(display)
                                            }
                                        }
                                        .labelsHidden()
                                        .onChange(of: imageManager.sourceInverseDisplay) { oldValue, newValue in
                                            if oldValue != newValue {
                                                // Update views for new display
                                                let views = imageManager.views(for: newValue)
                                                if !views.isEmpty {
                                                    if let config = imageManager.ocioConfig {
                                                        let defaultView = config.defaultView(forDisplay: newValue)
                                                        imageManager.sourceInverseView = !defaultView.isEmpty ? defaultView : views[0]
                                                    } else {
                                                        imageManager.sourceInverseView = views[0]
                                                    }
                                                }
                                                applyColorTransformAndReapplyDisplay()
                                            }
                                        }
                                        
                                        if !imageManager.sourceInverseDisplay.isEmpty {
                                            Text("View to Invert")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            
                                            let sourceViews = imageManager.views(for: imageManager.sourceInverseDisplay)
                                            Picker("", selection: $imageManager.sourceInverseView) {
                                                ForEach(sourceViews, id: \.self) { view in
                                                    Text(view).tag(view)
                                                }
                                            }
                                            .labelsHidden()
                                            .onChange(of: imageManager.sourceInverseView) { oldValue, newValue in
                                                if oldValue != newValue {
                                                    applyColorTransformAndReapplyDisplay()
                                                }
                                            }
                                        }
                                        
                                        // Info hint
                                        HStack(spacing: 4) {
                                            Image(systemName: "info.circle")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text("Inverts display/view transform to get scene-referred data")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.top, 4)
                                    }
                                }
                                
                                // Image metadata disclosure
                                if let metadata = imageManager.currentImage?.metadata {
                                    Divider()
                                    
                                    DisclosureGroup {
                                        ScrollView {
                                            VStack(alignment: .leading, spacing: 6) {
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
                                                        .font(.caption2)
                                                        .foregroundStyle(.tertiary)
                                                    
                                                    ForEach(Array(metadata.attributes.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                                                        MetadataRow(label: key, value: value)
                                                            .font(.caption2)
                                                    }
                                                }
                                            }
                                            .padding(.trailing, 4)
                                        }
                                        .scrollIndicators(.hidden)
                                        .frame(height: 200)
                                    } label: {
                                        Label("Image Info", systemImage: "info.circle")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .compatGlassInteractive(in: .rect(cornerRadius: 16))

                        // AMF input transform / source-space suggestion, attached to Source.
                        if let amf = imageManager.currentImage?.metadata.amfData {
                            AMFSourceAnnotation(amf: amf,
                                                imageManager: imageManager,
                                                selectedSourceSpace: $selectedSourceSpace)
                        }

                        // Connector
                        ConnectionLine()

                        // Transform node
                        ColorNodeView(
                            title: "Working Space",
                            subtitle: "Intermediate Color Space"
                        ) {
                            FamilyColorSpaceMenu(
                                label: "Working Space",
                                selection: $selectedDestSpace,
                                familyTree: cachedFamilyTree
                            )
                            .onChange(of: selectedDestSpace) { oldValue, newValue in
                                if oldValue != newValue {
                                    applyColorTransformAndReapplyDisplay()
                                }
                            }
                        }
                        .compatGlassInteractive(in: .rect(cornerRadius: 16))

                        // Connector
                        ConnectionLine()

                        // AMF look transforms — a node between Working Space and Display.
                        if let amf = imageManager.currentImage?.metadata.amfData,
                           !(amf.pipeline?.lookTransforms.isEmpty ?? true) {
                            AMFLooksNodeView(amf: amf,
                                             imageManager: imageManager,
                                             hasAppliedTransforms: $hasAppliedTransforms)
                            ConnectionLine()
                        }

                        // Display node
                        ColorNodeView(
                            title: "Display",
                            subtitle: "Output Transform"
                        ) {
                            VStack(spacing: 8) {
                                // Mode selector (Config vs ACES2)
                                GlassSegmentedPicker(
                                    selection: $imageManager.dynamicACES2Mode,
                                    options: [
                                        (false, "Config"),
                                        (true, "ACES2"),
                                    ]
                                ) { isACES2 in
                                    selectedMetalColorSpace = isACES2
                                        ? "extendedDisplayP3"
                                        : DisplaySurfaceMapping.shared.surface(forDisplay: selectedDisplay)
                                    applyDisplayTransform()
                                }
                                .fixedSize()

                                Divider()

                                if imageManager.dynamicACES2Mode {
                                    // ── Dynamic ACES2 UI ──────────────────────────────
                                    VStack(alignment: .leading, spacing: 8) {

                                        // Output gamut
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Limiting Primaries")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Picker("", selection: $imageManager.dynamicACES2Gamut) {
                                                ForEach(ACES2Gamut.allCases) { gamut in
                                                    Text(gamut.rawValue).tag(gamut)
                                                }
                                            }
                                            .labelsHidden()
                                            .onChange(of: imageManager.dynamicACES2Gamut) { _, _ in
                                                applyDisplayTransform()
                                            }
                                        }

                                        Divider()

                                        // Target nits label + editable field
                                        HStack(spacing: 6) {
                                            Image(systemName: "sun.max.fill")
                                                .foregroundStyle(.yellow)
                                                .font(.caption2)
                                            Text("Target")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            // Editable nits field — disabled in auto mode
                                            HStack(spacing: 2) {
                                                TextField("", text: $nitsEditText)
                                                    .font(.caption2.monospacedDigit())
                                                    .multilineTextAlignment(.trailing)
                                                    .frame(width: 48)
                                                    .textFieldStyle(.plain)
                                                    .focused($nitsFieldFocused)
                                                    .disabled(imageManager.dynamicACES2AutoNits)
                                                    .foregroundStyle(imageManager.dynamicACES2AutoNits ? Color.secondary : Color.primary)
                                                    .onSubmit { commitNitsEdit() }
                                                    .onChange(of: nitsFieldFocused) { _, focused in
                                                        if !focused { commitNitsEdit() }
                                                    }
                                                    .onChange(of: imageManager.dynamicACES2PeakNits) { _, v in
                                                        if !nitsFieldFocused {
                                                            nitsEditText = "\(Int(v))"
                                                        }
                                                    }
                                                    .onAppear {
                                                        nitsEditText = "\(Int(imageManager.dynamicACES2PeakNits))"
                                                    }
                                                Text("nits")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        // Auto toggle
                                        Toggle(isOn: $imageManager.dynamicACES2AutoNits) {
                                            Text("Auto from current EDR headroom")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .toggleStyle(.checkbox)
                                        .onChange(of: imageManager.dynamicACES2AutoNits) { _, _ in
                                            applyDisplayTransform()
                                        }
                                        // Log-scaled slider 100…10 000 nits with tick marks.
                                        // t = log10(nits/100)/2  →  nits = 100 × 10^(t×2)
                                        // Snap threshold: if the dragged t is within 0.04 of a
                                        // tick's t-position, pull to that tick (notchy feel).
                                        let snapTs: [Double] = [
                                            0.0,
                                            log10(2.0)  / 2.0,   // 200
                                            log10(5.0)  / 2.0,   // 500
                                            0.5,                  // 1K
                                            log10(20.0) / 2.0,   // 2K
                                            log10(40.0) / 2.0,   // 4K
                                            1.0,                  // 10K
                                        ]
                                        let logNitsBinding = Binding<Double>(
                                            get: {
                                                let nits = Double(imageManager.dynamicACES2AutoNits
                                                    ? imageManager.dynamicACES2PeakNits
                                                    : imageManager.dynamicACES2TargetNits)
                                                return log10(max(nits, 100) / 100.0) / 2.0
                                            },
                                            set: { t in
                                                // Snap to nearest tick if within threshold
                                                let snapped: Double
                                                if let nearest = snapTs.min(by: { abs($0 - t) < abs($1 - t) }),
                                                   abs(nearest - t) < 0.04 {
                                                    snapped = nearest
                                                } else {
                                                    snapped = t
                                                }
                                                let nits = Float((100.0 * pow(10.0, snapped * 2.0)).rounded())
                                                imageManager.dynamicACES2TargetNits = min(10000, max(100, nits))
                                                nitsEditText = "\(Int(nits))"
                                            }
                                        )
                                        // Tick positions on the 0…1 log scale
                                        let ticks: [(t: Double, label: String)] = [
                                            (snapTs[0], "100"),
                                            (snapTs[1], "200"),
                                            (snapTs[2], "500"),
                                            (snapTs[3], "1K"),
                                            (snapTs[4], "2K"),
                                            (snapTs[5], "4K"),
                                            (snapTs[6], "10K"),
                                        ]
                                        VStack(spacing: 0) {
                                            Slider(value: logNitsBinding, in: 0...1) {
                                                EmptyView()
                                            } onEditingChanged: { editing in
                                                if !editing { applyDisplayTransform() }
                                            }
                                            .disabled(imageManager.dynamicACES2AutoNits)
                                            // Tick marks overlay
                                            GeometryReader { geo in
                                                let inset = 10.5
                                                let usable = geo.size.width - inset * 2
                                                ZStack(alignment: .topLeading) {
                                                    ForEach(ticks, id: \.label) { tick in
                                                        VStack(spacing: 1) {
                                                            Rectangle()
                                                                .frame(width: 1, height: 4)
                                                                .foregroundStyle(Color.secondary.opacity(0.4))
                                                            Text(tick.label)
                                                                .font(.system(size: 7))
                                                                .foregroundStyle(.tertiary)
                                                        }
                                                        .frame(width: 1)
                                                        .offset(x: inset + usable * tick.t)
                                                    }
                                                }
                                            }
                                            .frame(height: 20)
                                        }

                                        // Display EDR capacity (informational)
                                        let headroom = (imageManager.currentScreen ?? NSScreen.main)?
                                            .maximumExtendedDynamicRangeColorComponentValue ?? 1.0
                                        HStack(spacing: 4) {
                                            Text("Current EDR headroom:")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            Text(String(format: "~%.0f nits  (×%.1f)",
                                                        headroom * 100, headroom))
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                } else {
                                    // ── Config-based display transform ─────────────────
                                    Picker("Display", selection: $selectedDisplay) {
                                        ForEach(cachedDisplays, id: \.self) { display in
                                            Text(display).tag(display)
                                        }
                                    }
                                    .labelsHidden()
                                    .onChange(of: selectedDisplay) { oldValue, newValue in
                                        if oldValue != newValue {
                                            // Update cached views for this display
                                            let views = imageManager.views(for: newValue)
                                            cachedViews[newValue] = views

                                            if !views.isEmpty {
                                                if let config = imageManager.ocioConfig {
                                                    let defaultView = config.defaultView(forDisplay: newValue)
                                                    if !defaultView.isEmpty {
                                                        selectedView = defaultView
                                                    } else {
                                                        selectedView = views[0]
                                                    }
                                                } else {
                                                    selectedView = views[0]
                                                }
                                            }
                                            selectedMetalColorSpace = DisplaySurfaceMapping.shared.surface(forDisplay: newValue)
                                            applyDisplayTransform()
                                        }
                                    }

                                    if !selectedDisplay.isEmpty {
                                        Picker("View", selection: $selectedView) {
                                            ForEach(cachedViews[selectedDisplay] ?? [], id: \.self) { view in
                                                Text(view).tag(view)
                                            }
                                        }
                                        .labelsHidden()
                                        .onChange(of: selectedView) { oldValue, newValue in
                                            if oldValue != newValue {
                                                applyDisplayTransform()
                                            }
                                        }
                                    }
                                }

                                Divider()

                                // CPU / GPU render path toggle
                                // Disabled for video frames: no CPU pixel buffer is available.
                                Button {
                                    imageManager.useCPURenderPath.toggle()
                                    applyDisplayTransform()
                                } label: {
                                    Label(
                                        imageManager.useCPURenderPath ? "CPU" : "GPU",
                                        systemImage: imageManager.useCPURenderPath ? "cpu" : "cpu.fill"
                                    )
                                    .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(nil)
                                .controlSize(.small)
                                .disabled(imageManager.isVideoFrame)
                                .help(imageManager.isVideoFrame
                                    ? "CPU path unavailable for video — frames are GPU-only (no pixel buffer)"
                                    : imageManager.useCPURenderPath
                                        ? "OCIO CPU reference path — click to switch to Metal GPU"
                                        : "Metal GPU path — click to switch to OCIO CPU reference")
                            }
                        }
                        .compatGlassInteractive(in: .rect(cornerRadius: 16))

                        // AMF output transform — drives this Display node's display/view.
                        if let amf = imageManager.currentImage?.metadata.amfData,
                           amf.pipeline?.outputTransform != nil {
                            AMFOutputMatchView(amf: amf,
                                               imageManager: imageManager,
                                               selectedDisplay: $selectedDisplay,
                                               selectedView: $selectedView,
                                               onMatch: { applyDisplayTransform() })
                        }

                        // Connector to output
                        ConnectionLine()

                        // Output indicator
                        ColorNodeView(
                            title: "Screen",
                            subtitle: "Metal Surface Output"
                        ) {
                            VStack(spacing: 8) {
                                Picker("Metal Color Space", selection: $selectedMetalColorSpace) {
                                    Text("Display P3").tag("displayP3")
                                    Text("Display P3 (Extended)").tag("extendedDisplayP3")
                                    Text("Display P3 (Linear)").tag("linearDisplayP3")
                                    Text("Display P3 (Extended Linear)").tag("extendedLinearDisplayP3")
                                    Text("sRGB").tag("sRGB")
                                    Text("sRGB (Extended)").tag("extendedSRGB")
                                    Text("sRGB (Linear)").tag("linearSRGB")
                                    Text("sRGB (Extended Linear)").tag("extendedLinearSRGB")
                                    Text("Generic RGB Linear").tag("genericRGBLinear")
                                    Text("Adobe RGB (1998)").tag("adobeRGB1998")
                                    Text("DCI-P3").tag("dcip3")
                                    Text("BT.1886 (Gamma 2.4)").tag("bt1886")
                                    Text("P3-D65 (Gamma 2.6)").tag("p3d65")
                                    Text("ITU-R BT.709").tag("itur_709")
                                    Text("Core Media BT.709").tag("coreMedia709")
                                    Text("ITU-R BT.2020").tag("itur_2020")
                                    Text("ITU-R BT.2100 (HLG)").tag("itur_2100_HLG")
                                    Text("ITU-R BT.2100 (PQ)").tag("itur_2100_PQ")
                                    Text("ROMM RGB").tag("rommrgb")
                                    Text("Gray (Extended)").tag("extendedGray")
                                    Text("Gray (Linear)").tag("linearGray")
                                    Text("Gray (Extended Linear)").tag("extendedLinearGray")
                                }
                                .labelsHidden()
                                
                                HStack {
                                    Image(systemName: "display")
                                        .font(.title3)
                                    Text("Metal Surface")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .compatGlass(in: .rect(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    // AMF stages are now folded into the node chain above
                    // (Source / Look Transforms / Display); full per-op detail
                    // remains available in the AMF popover (AMFInfoView).
                }
            }
        }
        .onAppear {
            // Only initialize once
            guard !hasInitialized else { return }
            
            // Restore config path: prefer the currently loaded path, then fall back to
            // whatever the user had last stored in the settings store.
            if configPath.isEmpty {
                if let loaded = imageManager.loadedConfigPath {
                    // A config is already in memory — just show its path in the UI.
                    configPath = loaded
                } else if let stored = OCIOSettingsStore.shared.customConfigPath {
                    configPath = stored
                    // Only reload if the stored path is different from what is already
                    // loaded (avoids overwriting the bundled/env config on every launch).
                    if stored != imageManager.loadedConfigPath {
                        loadConfig()
                    }
                }
            }
            setupDefaultsAndApply()
            hasInitialized = true
        }
        // Keep the config path text field in sync when the loaded config changes
        // (e.g. after "Revert to Built-in Config").
        .onChange(of: imageManager.loadedConfigPath) { _, newPath in
            configPath = newPath ?? ""
        }
        .onChange(of: imageManager.currentImage?.width) { oldValue, newValue in
            if newValue != nil && oldValue != newValue {
                // Reset initialization flag when image changes
                hasInitialized = false
                hasAppliedTransforms = false
                
                // Update cached values for the new image
                cachedColorSpaces = imageManager.availableColorSpaces()
                cachedFamilyTree = imageManager.colorSpaceFamilyTree()
                cachedDisplays = imageManager.availableDisplays()
                
                hasInitialized = true
                
                // ContentView will handle applying transforms
                print("🖼️ ColorPipelineNodeView: New image detected, cache updated")
            }
        }
    }
    
    /// Find the best matching OCIO color space for a given image metadata color space string
    private func findBestMatchingColorSpace(_ imageColorSpace: String, in availableSpaces: [String]) -> String? {
        print("🔍 Trying to match image color space: '\(imageColorSpace)'")
        print("   Available spaces: \(availableSpaces.prefix(5).joined(separator: ", "))...")
        
        let normalizedImageSpace = imageColorSpace.lowercased().replacingOccurrences(of: "_", with: "")
        print("   Normalized to: '\(normalizedImageSpace)'")
        
        // Special case: "Linear" alone is too ambiguous - default to scene-linear role
        if normalizedImageSpace == "linear" {
            print("   ⚠️ 'Linear' is too ambiguous, will fall back to scene-linear role")
            return nil
        }
        
        // Strategy 1: Exact match (case-insensitive, ignoring underscores)
        if let exactMatch = availableSpaces.first(where: { 
            $0.lowercased().replacingOccurrences(of: "_", with: "") == normalizedImageSpace 
        }) {
            print("   ✅ Found exact match: '\(exactMatch)'")
            return exactMatch
        }
        
        // Strategy 2: Common OCIO aliases with equivalency groups
        // These groups represent the SAME color space with different naming conventions
        let aliasGroups: [[String]] = [
            // ACES AP0 / ACES2065-1 - all these refer to the same space
            ["lin_ap0", "lin_ap0_scene", "linear_ap0_scene", "linap0scene", "linap0", "aces2065-1", "aces20651", "aces", "aces2065_1"],
            // ACES AP1 / ACEScg
            ["lin_ap1", "lin_ap1_scene", "linear_ap1_scene", "linap1scene", "linap1", "acescg"],
            // sRGB variations
            ["srgb", "srgb_tx", "srgb_texture", "srgbtexture", "srgb_rec709", "srgb_encoded_rec709"],
            // Rec.709 variations
            ["rec709", "rec.709", "rec_709", "linear_rec709", "lin_rec709"],
            // Rec.2020 variations
            ["rec2020", "rec.2020", "rec_2020", "linear_rec2020", "lin_rec2020"],
        ]
        
        // Normalize the image space fully
        let fullyNormalizedImageSpace = normalizedImageSpace
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        
        // Check if the image space matches any alias in a group
        for group in aliasGroups {
            let normalizedGroup = group.map { 
                $0.replacingOccurrences(of: "_", with: "")
                  .replacingOccurrences(of: ".", with: "")
                  .replacingOccurrences(of: " ", with: "")
                  .replacingOccurrences(of: "-", with: "")
            }
            
            if normalizedGroup.contains(fullyNormalizedImageSpace) {
                print("   🔄 Matched to alias group: [\(group.prefix(3).joined(separator: ", "))...]")
                
                // Try to find ANY space from this group in available spaces
                for alias in group {
                    let normalizedAlias = alias
                        .replacingOccurrences(of: "_", with: "")
                        .replacingOccurrences(of: ".", with: "")
                        .replacingOccurrences(of: " ", with: "")
                        .replacingOccurrences(of: "-", with: "")
                    
                    if let match = availableSpaces.first(where: {
                        let normalizedSpace = $0.lowercased()
                            .replacingOccurrences(of: "_", with: "")
                            .replacingOccurrences(of: ".", with: "")
                            .replacingOccurrences(of: " ", with: "")
                            .replacingOccurrences(of: "-", with: "")
                        return normalizedSpace.contains(normalizedAlias) || normalizedAlias.contains(normalizedSpace)
                    }) {
                        print("   ✅ Found OCIO space: '\(match)'")
                        return match
                    }
                }
                
                print("   ⚠️ Matched alias group but no corresponding space found in config")
            }
        }
        
        print("   ❌ No match found")
        return nil
    }
    
    private func setupDefaultsAndApply() {
        // Cache the expensive OCIO queries
        cachedColorSpaces = imageManager.availableColorSpaces()
        cachedFamilyTree = imageManager.colorSpaceFamilyTree()
        cachedDisplays = imageManager.availableDisplays()
        
        if !cachedColorSpaces.isEmpty {
            // Try to match the image's color space metadata to an OCIO space for the SOURCE
            // Only set if not already configured
            if selectedSourceSpace.isEmpty {
                print("🔍 [Setup] selectedSourceSpace is empty, looking for match...")
                
                if let metadata = imageManager.currentImage?.metadata {
                    print("   📊 Image metadata exists")
                    let imageColorSpace = metadata.colorSpace
                    
                    if !imageColorSpace.isEmpty {
                        print("   🎨 Image color space from metadata: '\(imageColorSpace)'")
                        
                        if let matchedSpace = findBestMatchingColorSpace(imageColorSpace, in: cachedColorSpaces) {
                            selectedSourceSpace = matchedSpace
                            print("🎯 Matched image color space '\(imageColorSpace)' to OCIO source space '\(matchedSpace)'")
                        } else {
                            print("   ⚠️ No match found for '\(imageColorSpace)', falling back to scene-linear")
                        }
                    } else {
                        print("   ⚠️ Image metadata exists but colorSpace is empty string")
                    }
                } else {
                    print("   ⚠️ No image metadata available")
                }
                
                // If we still don't have a source space, use fallbacks
                if selectedSourceSpace.isEmpty {
                    if let sceneLinear = imageManager.ocioConfig?.sceneLinearColorSpace() {
                        selectedSourceSpace = sceneLinear
                        print("   📌 Using scene-linear role: \(sceneLinear)")
                    } else if let defaultSpace = imageManager.ocioConfig?.defaultColorSpace() {
                        selectedSourceSpace = defaultSpace
                        print("   📌 Using default color space: \(defaultSpace)")
                    } else {
                        selectedSourceSpace = cachedColorSpaces[0]
                        print("   📌 Using first available space: \(selectedSourceSpace)")
                    }
                }
            } else {
                print("🔍 [Setup] selectedSourceSpace already set to: '\(selectedSourceSpace)', skipping match")
            }
            
            // Working space defaults to scene-linear (independent of source)
            // Only set it if it hasn't been set yet
            if selectedDestSpace.isEmpty {
                if let sceneLinear = imageManager.ocioConfig?.sceneLinearColorSpace() {
                    selectedDestSpace = sceneLinear
                } else if let defaultSpace = imageManager.ocioConfig?.defaultColorSpace() {
                    selectedDestSpace = defaultSpace
                } else {
                    selectedDestSpace = cachedColorSpaces[0]
                }
            }
        }
        
        if !cachedDisplays.isEmpty {
            // Only set if not already configured
            if selectedDisplay.isEmpty {
                if let config = imageManager.ocioConfig {
                    let defaultDisplay = config.defaultDisplay()
                    if !defaultDisplay.isEmpty {
                        selectedDisplay = defaultDisplay
                    } else {
                        selectedDisplay = cachedDisplays[0]
                    }
                } else {
                    selectedDisplay = cachedDisplays[0]
                }
            }
            
            // Cache views for the selected display
            let views = imageManager.views(for: selectedDisplay)
            cachedViews[selectedDisplay] = views
            
            if !views.isEmpty && selectedView.isEmpty {
                if let config = imageManager.ocioConfig {
                    let defaultView = config.defaultView(forDisplay: selectedDisplay)
                    if !defaultView.isEmpty {
                        selectedView = defaultView
                    } else {
                        selectedView = views[0]
                    }
                } else {
                    selectedView = views[0]
                }
            }
        }
        
        // Sync Metal Surface Output with the current display mode
        if imageManager.dynamicACES2Mode {
            selectedMetalColorSpace = "extendedDisplayP3"
        } else if !selectedDisplay.isEmpty {
            selectedMetalColorSpace = DisplaySurfaceMapping.shared.surface(forDisplay: selectedDisplay)
        }

        // DO NOT apply transforms here - ContentView handles that
        // This function only sets up the UI state
        print("📋 ColorPipelineNodeView: Setup complete, no transforms applied")
    }
    
    private func commitNitsEdit() {
        // Parse the typed value, clamp to valid range, round to integer
        let stripped = nitsEditText.trimmingCharacters(in: .whitespaces)
        if let parsed = Float(stripped) {
            let clamped = min(10000, max(100, parsed.rounded()))
            imageManager.dynamicACES2TargetNits = clamped
            nitsEditText = "\(Int(clamped))"
            applyDisplayTransform()
        } else {
            // Revert display to the current model value on bad input
            nitsEditText = "\(Int(imageManager.dynamicACES2TargetNits))"
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
        applyDisplayTransform()
    }
    
    private func applyDisplayTransform() {
        guard imageManager.currentImage != nil else { return }

        // Both CPU and GPU paths handle the full chain from selectedSourceSpace.
        let inputSpace = selectedSourceSpace

        // Dynamic ACES2: bypass config display/view selectors
        if imageManager.dynamicACES2Mode {
            guard !inputSpace.isEmpty else { return }
            Task {
                do {
                    try await imageManager.applyDynamicACES2Transform(sourceSpace: inputSpace)
                } catch {
                    print("Error applying dynamic ACES2 transform: \(error)")
                }
            }
            return
        }

        // Config-based display transform
        guard !selectedDisplay.isEmpty && !selectedView.isEmpty else { return }
        Task {
            do {
                try await imageManager.applyDisplayTransform(
                    from: inputSpace,
                    display: selectedDisplay,
                    view: selectedView
                )
            } catch {
                print("Error applying display transform: \(error)")
            }
        }
    }
    
    private func browseForConfig() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        // Create a custom UTType for .ocio files
        // We'll allow .ocio, .yaml, .yml, and .xml files
        if let ocioType = UTType(filenameExtension: "ocio") {
            panel.allowedContentTypes = [ocioType, .yaml, .xml]
        } else {
            // Fallback if custom type creation fails
            panel.allowedContentTypes = [.yaml, .xml]
        }
        
        // Also allow all files as a fallback
        panel.allowsOtherFileTypes = true
        
        panel.message = "Select an OpenColorIO configuration file"
        
        // Try to start in a common OCIO location
        if let ocioEnv = ProcessInfo.processInfo.environment["OCIO"] {
            let ocioURL = URL(fileURLWithPath: ocioEnv)
            panel.directoryURL = ocioURL.deletingLastPathComponent()
        }
        
        if panel.runModal() == .OK, let url = panel.url {
            configPath = url.path
            loadConfig()
        }
    }
    
    private func loadConfig() {
        guard !configPath.isEmpty else { return }
        
        isLoadingConfig = true
        
        Task {
            do {
                try await imageManager.loadOCIOConfig(from: configPath)
                
                await MainActor.run {
                    isLoadingConfig = false
                    // Reset selections when config changes
                    selectedSourceSpace = ""
                    selectedDestSpace = ""
                    selectedDisplay = ""
                    selectedView = ""
                    // Reset initialization flag when config changes
                    hasInitialized = false
                    hasAppliedTransforms = false
                    // Re-initialize with new config
                    setupDefaultsAndApply()
                    hasInitialized = true
                    
                    // Persist the custom config path so it survives app relaunches
                    OCIOSettingsStore.shared.saveCustomConfigPath(configPath)
                    
                    // Notify ContentView that the OCIO config changed
                    NotificationCenter.default.post(name: .ocioConfigChanged, object: nil)
                }
            } catch {
                await MainActor.run {
                    isLoadingConfig = false
                    showError(error)
                }
            }
        }
    }
    
    @MainActor
    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error Loading OCIO Config"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - AMF integration into the Color Pipeline node graph
//
// When an AMF sidecar is loaded its stages are folded into the existing node chain:
//   • AMFSourceAnnotation  — IDT badge + source-space suggestion, under the Source node
//   • AMFLooksNodeView     — look transforms as a node between Working Space and Display
//   • AMFOutputMatchView   — output transform "Match" control under the Display node
// Full per-operator detail still lives in the AMF popover (`AMFInfoView`).

/// IDT status + source-space suggestion, shown attached to the Source node.
struct AMFSourceAnnotation: View {
    let amf: ACESMetadataFile
    @Bindable var imageManager: ImageManager
    @Binding var selectedSourceSpace: String

    private var inputStatus: AMFStageStatus? {
        imageManager.ocioConfig.flatMap {
            AMFOCIOPipelineBuilder.applicationStatus(for: amf, config: $0).input
        }
    }

    private var suggestion: String? {
        guard let s = AMFOCIOMapper.suggestSourceSpace(
            from: amf, availableSpaces: imageManager.availableColorSpaces()),
              s != selectedSourceSpace else { return nil }
        return s
    }

    var body: some View {
        let input = amf.pipeline?.inputTransform
        if input != nil || suggestion != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let input {
                    HStack(spacing: 6) {
                        Image(systemName: "camera").font(.caption2).foregroundStyle(.secondary)
                        Text("AMF Input Transform").font(.caption2.weight(.semibold))
                        Spacer()
                        if let s = inputStatus { AMFStageStatusBadge(status: s) }
                    }
                    if let id = input.transformId {
                        Text(humanReadableTransformId(id))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            .help(id)
                    }
                }
                if let suggestion {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars").font(.caption2).foregroundStyle(.secondary)
                        Text("Suggests source space:").font(.caption2).foregroundStyle(.secondary)
                        Text(suggestion).font(.caption2.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Button("Apply") { selectedSourceSpace = suggestion }
                            .font(.caption2).buttonStyle(.borderedProminent).controlSize(.mini)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }
}

/// AMF look transforms as a pipeline node between Working Space and Display.
/// - A node-level enable switch (header accessory) toggles all resolvable looks at once.
/// - Each look row: a disclosure triangle (full per-step detail), the look name, and the
///   "Applied" status marker which doubles as that look's enable toggle.
/// The enabled looks are folded into the GPU display shader, so they apply on load and
/// persist across frames; toggling rebuilds the shader.
struct AMFLooksNodeView: View {
    let amf: ACESMetadataFile
    @Bindable var imageManager: ImageManager
    @Binding var hasAppliedTransforms: Bool

    @State private var expanded: Set<Int> = []

    private var looks: [AMFLookTransform] { amf.pipeline?.lookTransforms ?? [] }
    private var status: AMFApplicationStatus? {
        imageManager.ocioConfig.map { AMFOCIOPipelineBuilder.applicationStatus(for: amf, config: $0) }
    }

    private var globallyEnabled: Bool { imageManager.amfLooksGloballyEnabled }

    var body: some View {
        ColorNodeView(title: "Look Transforms", subtitle: "AMF Looks / CLF") {
            VStack(spacing: 6) {
                ForEach(looks.indices, id: \.self) { i in
                    lookRow(i)
                }
            }
            .opacity(globallyEnabled ? 1 : 0.6)
        } accessory: {
            Toggle("", isOn: Binding(
                get: { imageManager.amfLooksGloballyEnabled },
                set: { on in
                    hasAppliedTransforms = true
                    imageManager.setAMFLooksGloballyEnabled(on)
                }))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            .help("Enable or disable the whole Look Transforms node (preserves each look's state)")
        }
        .compatGlassInteractive(in: .rect(cornerRadius: 16))
        .task(id: amf.sourceURL) { imageManager.ensureAMFEnabledLooksInitialized() }
    }

    @ViewBuilder
    private func lookRow(_ i: Int) -> some View {
        let s = (status?.looks.indices.contains(i) == true) ? status?.looks[i] : nil
        let resolvable = (s == .applied)
        let enabled = imageManager.amfEnabledLooks.indices.contains(i) ? imageManager.amfEnabledLooks[i] : false
        let active = resolvable && enabled && globallyEnabled   // actually affecting the image
        let isOpen = expanded.contains(i)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if isOpen { expanded.remove(i) } else { expanded.insert(i) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .buttonStyle(.plain)

                Text(lookName(looks[i]))
                    .font(.caption2.weight(.medium)).lineLimit(1)
                    .opacity(active ? 1 : 0.55)
                    .help(lookFullName(looks[i]))

                Spacer()

                lookStatusToggle(index: i, status: s, resolvable: resolvable, enabled: enabled)
            }

            if isOpen {
                AMFLookBody(look: looks[i])
                    .padding(.leading, 18)
                    .padding(.top, 2)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// The status marker, doubling as the per-look enable toggle for resolvable looks.
    /// Text reflects each look's own enabled state ("Applied" / "Off"); the colour is green
    /// only when the look is actually affecting the image (enabled AND node globally on) —
    /// otherwise grey, so a globally-off node greys the markers but keeps their labels.
    @ViewBuilder
    private func lookStatusToggle(index i: Int, status s: AMFStageStatus?, resolvable: Bool, enabled: Bool) -> some View {
        if resolvable {
            let active = enabled && globallyEnabled
            Button {
                guard imageManager.amfEnabledLooks.indices.contains(i) else { return }
                imageManager.amfEnabledLooks[i].toggle()
                hasAppliedTransforms = true
                Task { await imageManager.reapplyAMFLooks() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    Text(enabled ? "Applied" : "Off")
                }
                .font(.caption2)
                .foregroundStyle(active ? Color.green : Color.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((active ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(enabled ? "Look enabled — click to disable" : "Look disabled — click to enable")
        } else if let s {
            // Non-resolvable looks (Skipped / Baked in): show the status, not a toggle.
            AMFStageStatusBadge(status: s)
        }
    }

    /// Short label shown in the row (may truncate).
    private func lookName(_ look: AMFLookTransform) -> String {
        if let f = look.clfFile { return URL(fileURLWithPath: f).lastPathComponent }
        if let id = look.transformId { return humanReadableTransformId(id) }
        if look.cdl != nil { return "Embedded CDL" }
        return "Look"
    }

    /// Full, untruncated identifier for the hover tooltip.
    private func lookFullName(_ look: AMFLookTransform) -> String {
        if let f = look.clfFile { return f }
        if let id = look.transformId { return id }
        if look.cdl != nil { return "Embedded CDL" }
        return "Look"
    }
}

/// AMF output transform "Match" control, shown attached to the Display node. Drives the
/// display/view selection toward the AMF's intended output without replacing the node.
struct AMFOutputMatchView: View {
    let amf: ACESMetadataFile
    @Bindable var imageManager: ImageManager
    @Binding var selectedDisplay: String
    @Binding var selectedView: String
    let onMatch: () -> Void

    private var target: (display: String, view: String)? {
        imageManager.ocioConfig.flatMap { AMFOCIOPipelineBuilder.outputDisplayView(for: amf, config: $0) }
    }

    var body: some View {
        if let target {
            let matches = (selectedDisplay == target.display && selectedView == target.view)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "display").font(.caption2).foregroundStyle(.secondary)
                    Text("AMF Output Transform").font(.caption2.weight(.semibold))
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: matches ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        Text(matches ? "Matches" : "Differs")
                    }
                    .font(.caption2).foregroundStyle(matches ? Color.green : Color.orange)
                }
                Text("\(target.display) · \(target.view)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    .help("\(target.display) · \(target.view)")
                if !matches {
                    HStack {
                        Spacer()
                        Button("Match AMF") {
                            selectedDisplay = target.display
                            selectedView = target.view
                            onMatch()
                        }
                        .font(.caption2).buttonStyle(.borderedProminent).controlSize(.mini)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }
}

/// Individual node in the color pipeline
struct ColorNodeView<Content: View, Accessory: View>: View {
    let title: String
    let subtitle: String
    let content: Content
    /// Optional trailing control rendered to the right of the title (e.g. a node-level
    /// enable switch).
    let accessory: Accessory

    init(title: String, subtitle: String,
         @ViewBuilder content: () -> Content,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                accessory
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Content
            content
                .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

extension ColorNodeView where Accessory == EmptyView {
    /// Convenience initialiser for nodes without a header accessory (the common case).
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, content: content, accessory: { EmptyView() })
    }
}

/// Visual connector between nodes
struct ConnectionLine: View {
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
            
            Rectangle()
                .fill(.secondary.opacity(0.6))
                .frame(width: 3, height: 24)
        }
        .frame(height: 36)
    }
}

/// Metadata row for displaying image information
struct MetadataRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

/// A menu-based color space picker with hierarchical submenus based on OCIO family paths.
struct FamilyColorSpaceMenu: View {
    let label: String
    @Binding var selection: String
    let familyTree: ColorSpaceFamilyNode

    /// True when the tree is trivially flat (no families at all).
    private var isFlat: Bool {
        familyTree.children.isEmpty
    }

    var body: some View {
        Menu {
            if isFlat {
                // No family hierarchy — flat list
                ForEach(familyTree.colorSpaces, id: \.self) { space in
                    spaceButton(space)
                }
            } else {
                // Render root-level color spaces first (those with empty family)
                ForEach(familyTree.colorSpaces, id: \.self) { space in
                    spaceButton(space)
                }
                // Then render each family as a submenu
                ForEach(familyTree.children) { child in
                    nodeMenu(child)
                }
            }
        } label: {
            Text(selection.isEmpty ? label : selection)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.button)
    }

    /// Recursively build nested menus for a family node.
    private func nodeMenu(_ node: ColorSpaceFamilyNode) -> AnyView {
        AnyView(
            Menu(node.name) {
                ForEach(node.colorSpaces, id: \.self) { space in
                    spaceButton(space)
                }
                ForEach(node.children) { child in
                    nodeMenu(child)
                }
            }
        )
    }

    @ViewBuilder
    private func spaceButton(_ space: String) -> some View {
        Button {
            selection = space
        } label: {
            if space == selection {
                Label(space, systemImage: "checkmark")
            } else {
                Text(space)
            }
        }
    }
}

#Preview {
    ColorPipelineNodeView(
        imageManager: ImageManager(),
        selectedSourceSpace: .constant(""),
        selectedDestSpace: .constant(""),
        selectedDisplay: .constant(""),
        selectedView: .constant(""),
        selectedMetalColorSpace: .constant("displayP3"),
        hasAppliedTransforms: .constant(false)
    )
    .frame(width: 400, height: 700)
}
