//
//  ScriptingPreferencesView.swift
//  Tristimulator
//
//  macOS Settings window with sidebar navigation.
//  Opened via Cmd+, or the app menu.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Preference Panes

enum PreferencePane: String, CaseIterable, Identifiable {
    case general   = "General"
    case ocio      = "OCIO"
    case scripting = "Scripting"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:   return "gearshape"
        case .ocio:      return "opencolorio-icon-white"
        case .scripting: return "applescript"
        }
    }

    var usesSystemImage: Bool {
        switch self {
        case .ocio: return false
        default:    return true
        }
    }
}

// MARK: - Settings Command (Cmd+,)

struct SettingsCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

// MARK: - Root Preferences View

struct PreferencesView: View {
    @State private var selectedPane: PreferencePane = .general

    var body: some View {
        NavigationSplitView {
            List(PreferencePane.allCases, selection: $selectedPane) { pane in
                Label {
                    Text(pane.rawValue)
                } icon: {
                    if pane.usesSystemImage {
                        Image(systemName: pane.icon)
                    } else {
                        Image(pane.icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            switch selectedPane {
            case .general:
                GeneralPreferencesPane()
            case .ocio:
                OCIOPreferencesPane()
            case .scripting:
                ScriptingPreferencesPane()
            }
        }
        .toolbar(removing: .sidebarToggle)
    }
}

// MARK: - General Pane

struct GeneralPreferencesPane: View {
    @AppStorage(TristimulatorDefaults.showDebugMenu) private var showDebugMenu = false
    @AppStorage(TristimulatorDefaults.scopesScaleWithWindow) private var scopesScaleWithWindow = false

    var body: some View {
        Form {
            Section("About") {
                Text("Tristimulator")
                    .font(.headline)
            }
            Section("Scopes") {
                Toggle("Scale scopes with window", isOn: $scopesScaleWithWindow)
                Text("When on, scope overlays grow, shrink and move proportionally as you resize the window. When off, they keep their size and stay pinned to the nearest edges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Advanced") {
                Toggle("Show Debug Menu", isOn: $showDebugMenu)
                Text("Shows the Debug menu in the menu bar. Hold the Option key to reveal it until you release the key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

// MARK: - OCIO Pane

enum OCIOConfigMode: String {
    case builtIn     = "builtIn"
    case environment = "environment"
    case custom      = "custom"
}

struct OCIOPreferencesPane: View {

    @State private var configMode: OCIOConfigMode = .builtIn
    @State private var customPath = ""

    private let builtInName = "studio-config-v4.0.0_aces-v2.0_ocio-v2.5.ocio"

    private var envVarPath: String? {
        ProcessInfo.processInfo.environment["OCIO"]
    }

    var body: some View {
        Form {
            Section("Default Configuration") {
                Picker("Source", selection: $configMode) {
                    Text("Built-in Config").tag(OCIOConfigMode.builtIn)
                    Text("Environment Variable ($OCIO)").tag(OCIOConfigMode.environment)
                    Text("Custom Path").tag(OCIOConfigMode.custom)
                }
                .onChange(of: configMode) { _, _ in applyMode() }

                switch configMode {
                case .builtIn:
                    Text(builtInName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                case .environment:
                    if let path = envVarPath {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Label("$OCIO is not set", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Set the OCIO environment variable before launching Tristimulator, or choose a different source.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .custom:
                    HStack(spacing: 6) {
                        if customPath.isEmpty {
                            Text("No config selected")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(customPath)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(customPath)
                        }
                        Spacer()
                        Button("Browse…", action: browseForConfig)
                    }

                    if !customPath.isEmpty && !FileManager.default.fileExists(atPath: customPath) {
                        Label("File not found", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Text("The default config for newly opened images. Per-window overrides in the color pipeline take precedence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("OCIO")
        .onAppear { loadFromStore() }
    }

    // MARK: - Persistence

    private func loadFromStore() {
        let stored = UserDefaults.standard.string(forKey: "ocio.configMode") ?? OCIOConfigMode.builtIn.rawValue
        configMode = OCIOConfigMode(rawValue: stored) ?? .builtIn
        customPath = OCIOSettingsStore.shared.customConfigPath ?? ""
    }

    private func applyMode() {
        UserDefaults.standard.set(configMode.rawValue, forKey: "ocio.configMode")

        switch configMode {
        case .builtIn:
            OCIOSettingsStore.shared.saveCustomConfigPath(nil)
        case .environment:
            OCIOSettingsStore.shared.saveCustomConfigPath(envVarPath)
        case .custom:
            let path = customPath.isEmpty ? nil : customPath
            OCIOSettingsStore.shared.saveCustomConfigPath(path)
        }
    }

    private func browseForConfig() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "ocio"),
            UTType(filenameExtension: "yaml"),
            UTType(filenameExtension: "xml"),
        ].compactMap { $0 }
        panel.message = "Select an OCIO config file"

        if let envDir = envVarPath.map({ ($0 as NSString).deletingLastPathComponent }) {
            panel.directoryURL = URL(fileURLWithPath: envDir)
        }

        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            applyMode()
        }
    }
}

// MARK: - Scripting Pane

struct ScriptingPreferencesPane: View {

    @State private var enabled      = false
    @State private var scriptPath   = ""
    @State private var interpPath   = ""
    @State private var testOutput   = ""
    @State private var isTestRunning = false

    private var engine: ScriptingEngine { ScriptingEngine.shared }

    var body: some View {
        Form {
            Section("Scripting") {
                Toggle("Enable OCIO scripting rules", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in applySettings() }
                Text("When enabled, Tristimulator calls your script each time an image opens and applies any settings it returns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Script File") {
                HStack(spacing: 6) {
                    if scriptPath.isEmpty {
                        Text("No script selected")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(scriptPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(scriptPath)
                    }
                    Spacer()
                    Button("Browse…", action: browseForScript)
                    Button("Create…", action: createStarterScript)
                        .help("Write a starter template and open it in your default editor")
                }
                .disabled(!enabled)
            }

            Section("Python Interpreter") {
                HStack(spacing: 6) {
                    Text(interpPath.isEmpty ? "/usr/bin/env python3" : interpPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(interpPath)
                    Spacer()
                    Button("Browse…", action: browseForInterpreter)
                    Button("Reset") {
                        interpPath = "/usr/bin/env python3"
                        applySettings()
                    }
                    .help("Restore the default interpreter path")
                }
                .disabled(!enabled)
                Text("Use the default to respect pyenv/conda shims, or set an absolute path for a specific installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                HStack(spacing: 8) {
                    statusIndicator
                    Text(statusLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if case .running = engine.daemonStatus {
                        Button("Reload Script") { engine.reloadScript() }
                            .help("Re-read the script file without restarting the daemon")
                    }
                    Button("Restart Daemon") { engine.startDaemon() }
                        .disabled(!enabled || scriptPath.isEmpty)
                }

                if let err = engine.lastError {
                    Text(err)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }

            Section("Test") {
                Button(isTestRunning ? "Testing…" : "Test with Current Image") {
                    runTest()
                }
                .disabled(!enabled || scriptPath.isEmpty || isTestRunning
                          || engine.daemonStatus != .running)

                Text("Runs evaluate() against the frontmost open image and shows the returned settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !testOutput.isEmpty {
                    Text(testOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(testOutput.hasPrefix("⚠️") ? Color.red : Color.primary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Scripting")
        .onAppear {
            enabled    = engine.isEnabled
            scriptPath = engine.scriptPath
            interpPath = engine.interpreterPath
        }
    }

    // MARK: - Status indicator

    @ViewBuilder
    private var statusIndicator: some View {
        switch engine.daemonStatus {
        case .running:  Circle().fill(Color.green).frame(width: 8, height: 8)
        case .starting: Circle().fill(Color.yellow).frame(width: 8, height: 8)
        case .stopped:  Circle().fill(Color.gray).frame(width: 8, height: 8)
        case .error:    Circle().fill(Color.red).frame(width: 8, height: 8)
        }
    }

    private var statusLabel: String {
        switch engine.daemonStatus {
        case .running:        return "Daemon running"
        case .starting:       return "Starting…"
        case .stopped:        return "Stopped"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    // MARK: - Actions

    private func applySettings() {
        engine.updateSettings(
            enabled:         enabled,
            scriptPath:      scriptPath,
            interpreterPath: interpPath
        )
    }

    private func browseForScript() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        if let pyType = UTType(filenameExtension: "py") {
            panel.allowedContentTypes = [pyType]
        }
        panel.message = "Select your OCIO rules script (.py)"
        if panel.runModal() == .OK, let url = panel.url {
            scriptPath = url.path
            applySettings()
        }
    }

    private func browseForInterpreter() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes  = []
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        panel.message = "Select a Python interpreter binary"
        if panel.runModal() == .OK, let url = panel.url {
            interpPath = url.path
            applySettings()
        }
    }

    private func createStarterScript() {
        let panel = NSSavePanel()
        if let pyType = UTType(filenameExtension: "py") {
            panel.allowedContentTypes = [pyType]
        }
        panel.nameFieldStringValue = "tristimulator_rules.py"
        panel.message = "Save OCIO rules script"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ScriptingEngine.starterScriptTemplate.write(to: url, atomically: true, encoding: .utf8)
            scriptPath = url.path
            applySettings()
            NSWorkspace.shared.open(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func runTest() {
        guard let doc = ScriptingEngine.shared.activeDocument,
              let fileURL = doc.fileURL
        else {
            testOutput = "⚠️ No image open — open an image first, then test."
            return
        }

        isTestRunning = true
        testOutput    = ""

        Task {
            let ctx = ScriptingContext(
                fileURL:            fileURL,
                imageData:          doc.imageManager.currentImage,
                loadedConfigPath:   doc.imageManager.loadedConfigPath,
                currentSourceSpace: doc.selectedSourceSpace,
                currentDisplay:     doc.selectedDisplay,
                currentView:        doc.selectedView
            )
            if let result = await engine.evaluate(context: ctx) {
                testOutput = formatResult(result, for: fileURL)
            } else if let err = engine.lastError {
                testOutput = "⚠️ \(err)"
            } else {
                testOutput = "evaluate() returned None — Tristimulator defaults will be used."
            }
            isTestRunning = false
        }
    }

    private func formatResult(_ r: ScriptingResult, for url: URL) -> String {
        var lines = ["Result for \(url.lastPathComponent):"]
        if let v = r.ocioConfig          { lines.append("  ocioConfig:          \(v)") }
        if let v = r.sourceSpace         { lines.append("  sourceSpace:         \(v)") }
        if let v = r.display             { lines.append("  display:             \(v)") }
        if let v = r.view                { lines.append("  view:                \(v)") }
        if let v = r.exposure            { lines.append("  exposure:            \(v)") }
        if let v = r.selectedEXRLayer    { lines.append("  selectedEXRLayer:    \(v)") }
        if let v = r.sourceTransformMode { lines.append("  sourceTransformMode: \(v)") }
        if lines.count == 1 { lines.append("  (no overrides — defaults will be used)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Previews

#Preview("General Settings") {
    GeneralPreferencesPane()
        .frame(width: 450, height: 300)
}
