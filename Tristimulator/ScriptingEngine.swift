//
//  ScriptingEngine.swift
//  Tristimulator
//
//  Manages a persistent Python daemon process that evaluates user-defined
//  OCIO config rules for each opened image. Communication uses newline-
//  delimited JSON over the process's stdin/stdout pipes.
//
//  The daemon (tristimulator_daemon.py) is launched once at app start and kept
//  alive for the session, so the per-image overhead is only the IPC round-
//  trip (~2–5 ms) rather than a full Python interpreter startup (~150 ms).
//

import Foundation
import Observation

// MARK: - Public types

/// All image-open context sent to the user's evaluate() function.
struct ScriptingContext {
    let fileURL:            URL
    let imageData:          ImageData?
    let loadedConfigPath:   String?
    let currentSourceSpace: String
    let currentDisplay:     String
    let currentView:        String
}

/// The subset of pipeline settings the script may override.
struct ScriptingResult {
    let ocioConfig:          String?
    let sourceSpace:         String?
    let display:             String?
    let view:                String?
    let exposure:            Float?
    let selectedEXRLayer:    String?
    let sourceTransformMode: String?
}

// MARK: - Engine

@Observable
final class ScriptingEngine {

    static let shared = ScriptingEngine()

    // MARK: Observed state (read by SwiftUI views)

    private(set) var isEnabled:       Bool   = false
    private(set) var scriptPath:      String = ""
    private(set) var interpreterPath: String = "/usr/bin/env python3"

    enum DaemonStatus: Equatable {
        case stopped, starting, running
        case error(String)
    }
    private(set) var daemonStatus: DaemonStatus = .stopped
    private(set) var lastError:    String?       = nil

    // MARK: Private state

    private var process:      Process?
    private var stdinHandle:  FileHandle?
    private var stdoutHandle: FileHandle?
    private var lineBuffer = ""

    /// All daemon I/O runs here; reads and writes must never interleave.
    private let ioQueue = DispatchQueue(label: "com.tristimulator.scripting.io", qos: .userInitiated)
    /// Serialises concurrent evaluate() calls so only one is in-flight at a time.
    private let ioLock  = NSLock()

    // Weak reference to the most recently active document window's document.
    // Updated by DocumentContentView; used by ScriptingPreferencesView for test runs.
    // @ObservationIgnored keeps @Observable from wrapping a weak property.
    @ObservationIgnored
    weak var activeDocument: ImageDocument?

    // MARK: UserDefaults keys

    private enum UDKey {
        static let enabled         = "scripting.enabled"
        static let scriptPath      = "scripting.scriptPath"
        static let interpreterPath = "scripting.interpreterPath"
    }

    // MARK: Init

    private init() {
        let ud = UserDefaults.standard
        isEnabled       = ud.bool(forKey: UDKey.enabled)
        scriptPath      = ud.string(forKey: UDKey.scriptPath) ?? ""
        let stored      = ud.string(forKey: UDKey.interpreterPath) ?? ""
        interpreterPath = stored.isEmpty ? "/usr/bin/env python3" : stored

        if isEnabled && !scriptPath.isEmpty {
            startDaemon()
        }
    }

    // MARK: - Settings API

    func updateSettings(enabled: Bool, scriptPath: String, interpreterPath: String) {
        let interp = interpreterPath.trimmingCharacters(in: .whitespaces)
        let ud = UserDefaults.standard
        ud.set(enabled,    forKey: UDKey.enabled)
        ud.set(scriptPath, forKey: UDKey.scriptPath)
        ud.set(interp,     forKey: UDKey.interpreterPath)

        self.isEnabled       = enabled
        self.scriptPath      = scriptPath
        self.interpreterPath = interp.isEmpty ? "/usr/bin/env python3" : interp

        if enabled && !scriptPath.isEmpty {
            startDaemon()
        } else {
            stopDaemon()
        }
    }

    // MARK: - Daemon lifecycle

    func startDaemon() {
        stopDaemon()
        guard !scriptPath.isEmpty else { return }
        guard let daemonPath = Bundle.main.path(forResource: "tristimulator_daemon", ofType: "py") else {
            daemonStatus = .error("tristimulator_daemon.py not found in app bundle")
            return
        }

        daemonStatus = .starting

        let p      = Process()
        let stdin  = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        // Split "env python3" style paths into executable + leading args.
        let parts = interpreterPath.components(separatedBy: " ").filter { !$0.isEmpty }
        p.executableURL = URL(fileURLWithPath: parts[0])
        p.arguments     = Array(parts.dropFirst()) + [daemonPath, scriptPath]
        p.standardInput  = stdin
        p.standardOutput = stdout
        p.standardError  = stderr

        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.daemonStatus != .stopped else { return }
                self.daemonStatus = .error("Daemon exited unexpectedly")
                self.stdinHandle  = nil
                self.stdoutHandle = nil
                self.process      = nil
            }
        }

        do {
            try p.run()
            process      = p
            stdinHandle  = stdin.fileHandleForWriting
            stdoutHandle = stdout.fileHandleForReading
            lineBuffer   = ""
            daemonStatus = .running
            print("🐍 [Scripting] Daemon started (pid \(p.processIdentifier))")
        } catch {
            daemonStatus = .error("Failed to launch Python: \(error.localizedDescription)")
            print("⚠️ [Scripting] \(daemonStatus)")
        }
    }

    func stopDaemon() {
        process?.terminate()
        process      = nil
        stdinHandle  = nil
        stdoutHandle = nil
        lineBuffer   = ""
        daemonStatus = .stopped
        lastError    = nil
    }

    func reloadScript() {
        guard case .running = daemonStatus, let stdinHandle else { return }
        let msg = "{\"_command\":\"reload\"}\n"
        guard let data = msg.data(using: .utf8) else { return }
        ioQueue.async { stdinHandle.write(data) }
        print("🔄 [Scripting] Reload command sent")
    }

    // MARK: - Python availability check

    func checkPythonAvailable() async -> Bool {
        let parts = interpreterPath.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !parts.isEmpty else { return false }
        return await withCheckedContinuation { cont in
            ioQueue.async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: parts[0])
                p.arguments     = Array(parts.dropFirst()) + ["--version"]
                p.standardOutput = Pipe()
                p.standardError  = Pipe()
                do {
                    try p.run(); p.waitUntilExit()
                    cont.resume(returning: p.terminationStatus == 0)
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Evaluate

    func evaluate(context: ScriptingContext) async -> ScriptingResult? {
        guard isEnabled, !scriptPath.isEmpty else { return nil }

        // Auto-restart the daemon if it was killed by a previous timeout or crash.
        if case .running = daemonStatus {} else {
            startDaemon()
            guard case .running = daemonStatus else { return nil }
        }

        guard let stdinHandle, let stdoutHandle else { return nil }
        guard let jsonLine = buildContextJSON(context) else { return nil }

        guard let responseLine = await sendAndReceive(
            jsonLine, stdin: stdinHandle, stdout: stdoutHandle
        ) else { return nil }

        return parseResult(responseLine)
    }

    // MARK: - Private: IPC

    /// Write one JSON line to the daemon and read one JSON line back.
    /// A 5-second wall-clock timeout terminates the daemon (which unblocks
    /// the blocking `availableData` read) and returns nil.
    private func sendAndReceive(_ line: String, stdin: FileHandle, stdout: FileHandle) async -> String? {
        await withCheckedContinuation { [weak self] continuation in
            guard let self else { continuation.resume(returning: nil); return }

            // Only one resume may fire; guard with a lock so timeout and IO don't race.
            let onceLock = NSLock()
            var resumed  = false
            func resumeOnce(_ value: String?) {
                onceLock.lock(); defer { onceLock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }

            // Timeout: kill the daemon after 5 s — this makes availableData return EOF,
            // unblocking the IO path below so neither path leaks indefinitely.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.process?.terminate()
                Task { @MainActor [weak self] in
                    self?.daemonStatus = .error("Script timed out (5 s)")
                    self?.lastError    = "Script evaluation timed out after 5 seconds"
                }
                resumeOnce(nil)
            }

            // Blocking I/O on the dedicated queue.
            self.ioQueue.async { [weak self] in
                guard let self else { resumeOnce(nil); return }
                self.ioLock.lock(); defer { self.ioLock.unlock() }

                guard let data = (line + "\n").data(using: .utf8) else {
                    resumeOnce(nil); return
                }
                stdin.write(data)

                // Buffer until we have at least one complete line.
                while !self.lineBuffer.contains("\n") {
                    let chunk = stdout.availableData          // blocks until data or EOF
                    if chunk.isEmpty { resumeOnce(nil); return }
                    self.lineBuffer += String(data: chunk, encoding: .utf8) ?? ""
                }

                if let idx = self.lineBuffer.firstIndex(of: "\n") {
                    let result = String(self.lineBuffer[..<idx])
                    self.lineBuffer = String(self.lineBuffer[self.lineBuffer.index(after: idx)...])
                    resumeOnce(result)
                } else {
                    resumeOnce(nil)
                }
            }
        }
    }

    // MARK: - Private: JSON helpers

    private func buildContextJSON(_ ctx: ScriptingContext) -> String? {
        let url  = ctx.fileURL
        let meta = ctx.imageData?.metadata

        var envDict: [String: Any] = [:]
        if let v = ProcessInfo.processInfo.environment["OCIO"] { envDict["OCIO"] = v }
        if let h = Host.current().name                          { envDict["HOST"] = h }

        let dict: [String: Any] = [
            "path":      url.path,
            "filename":  url.lastPathComponent,
            "extension": url.pathExtension.lowercased(),
            "directory": url.deletingLastPathComponent().path,
            "image": [
                "width":      ctx.imageData?.width    ?? 0,
                "height":     ctx.imageData?.height   ?? 0,
                "channels":   ctx.imageData?.channels ?? 0,
                "bitDepth":   meta?.bitDepth    ?? 0,
                "isHDR":      meta?.isHDR       ?? false,
                "colorSpace": meta?.colorSpace  ?? "",
                "layerNames": meta?.layerNames  ?? [],
                "attributes": meta?.attributes  ?? [:]
            ] as [String: Any],
            "env": envDict,
            "current": [
                "ocioConfig":  ctx.loadedConfigPath as Any,
                "sourceSpace": ctx.currentSourceSpace,
                "display":     ctx.currentDisplay,
                "view":        ctx.currentView
            ] as [String: Any]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func parseResult(_ line: String) -> ScriptingResult? {
        guard let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Ignore daemon control responses that aren't evaluate results.
        if dict["_pong"] != nil || dict["_reloaded"] != nil { return nil }

        if let err = dict["_error"] as? String {
            Task { @MainActor in self.lastError = err }
            print("⚠️ [Scripting] \(err)")
            return nil
        }

        if dict.isEmpty { return nil }

        let exposure: Float? = (dict["exposure"] as? NSNumber).map { Float(truncating: $0) }
        return ScriptingResult(
            ocioConfig:          dict["ocioConfig"]          as? String,
            sourceSpace:         dict["sourceSpace"]         as? String,
            display:             dict["display"]             as? String,
            view:                dict["view"]                as? String,
            exposure:            exposure,
            selectedEXRLayer:    dict["selectedEXRLayer"]    as? String,
            sourceTransformMode: dict["sourceTransformMode"] as? String
        )
    }
}

// MARK: - Starter script template

extension ScriptingEngine {
    static let starterScriptTemplate = """
# Tristimulator OCIO rules script
#
# Called each time an image is opened. Return a dict of settings to apply,
# or None to use Tristimulator defaults. First match wins.
#
# Context keys available in ctx:
#   ctx["path"]                     — full file path
#   ctx["filename"]                 — filename only  e.g. "beauty.0001.exr"
#   ctx["extension"]                — lowercase extension  e.g. "exr"
#   ctx["directory"]                — containing directory path
#   ctx["image"]["width"]           — pixel width
#   ctx["image"]["height"]          — pixel height
#   ctx["image"]["isHDR"]           — bool
#   ctx["image"]["colorSpace"]      — colorspace string from file metadata
#   ctx["image"]["layerNames"]      — list of EXR layer names
#   ctx["image"]["attributes"]      — dict of all embedded metadata (OIIO)
#   ctx["env"]["OCIO"]              — $OCIO environment variable (may be absent)
#   ctx["env"]["HOST"]              — hostname
#   ctx["current"]["ocioConfig"]    — currently loaded config path (None = built-in)
#   ctx["current"]["sourceSpace"]   — current source colour space name
#   ctx["current"]["display"]       — current display name
#   ctx["current"]["view"]          — current view name
#
# Returnable keys:
#   ocioConfig          — path to an .ocio file to load
#   sourceSpace         — source colour space name
#   display             — display device name
#   view                — view transform name
#   exposure            — exposure in stops (float)
#   selectedEXRLayer    — EXR layer to select on open
#   sourceTransformMode — "Color Space" or "Inverse Display"

import re


def evaluate(ctx):
    path  = ctx["path"]
    attrs = ctx["image"]["attributes"]

    # Example: use a per-project OCIO config based on folder name
    # if "/jobs/myproject/" in path:
    #     return {
    #         "ocioConfig": "/configs/myproject/config.ocio",
    #         "sourceSpace": "ACES - ACEScg",
    #     }

    # Example: trust colorspace metadata embedded in the file by the renderer
    # embedded_cs = attrs.get("colorspace") or attrs.get("ColorSpace")
    # if embedded_cs:
    #     return {"sourceSpace": embedded_cs}

    # Example: auto-select the beauty layer for multi-layer EXR files
    # if "beauty" in ctx["image"]["layerNames"]:
    #     return {"selectedEXRLayer": "beauty"}

    return None  # no opinion — use Tristimulator defaults
"""
}
