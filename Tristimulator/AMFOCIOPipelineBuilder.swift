//
//  AMFOCIOPipelineBuilder.swift
//  Tristimulator
//
//  Resolves an ACESMetadataFile's colour pipeline into an ordered array of
//  OCIO step descriptors that can be chained into an OCIOProcessor group transform.
//

import Foundation
import simd

// MARK: - Stage status

/// What Tristimulator actually does with a single AMF pipeline stage. This is distinct
/// from the AMF `applied` flag (which only records whether the *authoring* tool already
/// baked the transform into the pixels).
enum AMFStageStatus: Equatable {
    /// Tristimulator applies this stage as part of the look group transform.
    case applied
    /// The AMF marks the stage `applied="true"` — already baked into the source pixels,
    /// so Tristimulator does not re-apply it.
    case bakedIntoSource
    /// Handled elsewhere in the pipeline (e.g. the IDT / output transform are realised
    /// by the GPU display/view pass, not the look group transform).
    case deferredToDisplay
    /// Tristimulator could not apply this stage (e.g. no matching OCIO look / missing CLF).
    case skipped(String)
    /// Resolvable, but currently disabled by the user (per-look toggle off, or the Look
    /// Transforms node globally bypassed). Distinct from `.skipped` (which can't be applied).
    case disabled
}

/// Per-stage application status aligned with an AMF pipeline, for UI display.
struct AMFApplicationStatus: Equatable {
    var input: AMFStageStatus?
    /// One entry per `pipeline.lookTransforms`, in order.
    var looks: [AMFStageStatus]
    var output: AMFStageStatus?
}

// MARK: - Build result

struct AMFPipelineBuildResult {
    /// Ordered step dictionaries for OCIOProcessor.makeGroupTransformProcessor.
    let steps: [[String: String]]
    /// Display resolved from the AMF output transform (nil if no match found).
    let suggestedDisplay: String?
    /// View resolved from the AMF output transform (nil if no match found).
    let suggestedView: String?
    /// Human-readable issues logged during step construction.
    let warnings: [String]
    /// Per-stage application status (what Tristimulator did with each stage).
    let status: AMFApplicationStatus

    var isEmpty: Bool { steps.isEmpty }
}

/// How a single unapplied look transform resolves to a pipeline step. Pure (no I/O) so
/// it can be reused for both step-building and UI status without side effects.
private enum LookResolution {
    case clfFile(String)
    case ocioLook(name: String, src: String)
    case embeddedCDL
    case unresolved(String)
}

// MARK: - Builder

enum AMFOCIOPipelineBuilder {

    /// Construct an ordered list of OCIO transform steps from the active AMF pipeline.
    ///
    /// Steps cover only transforms whose `applied` flag is `false`. Already-baked
    /// transforms are skipped. The caller should pass the group-processor result to
    /// `OCIOProcessor.makeGroupTransformProcessor(config:steps:)`.
    ///
    /// - Parameters:
    ///   - amf:                Parsed ACES Metadata File.
    ///   - config:             OCIO config used to resolve color-space / look names.
    ///   - currentSourceSpace: Fallback source space when the AMF IDT cannot be mapped.
    ///   - currentDisplay:     Fallback display when the AMF output transform cannot be mapped.
    ///   - currentView:        Fallback view when the AMF output transform cannot be mapped.
    /// - Parameter enabledLookIndices: when non-nil, only look transforms whose index
    ///   (into `pipeline.lookTransforms`) is in the set emit a step. Looks excluded by
    ///   this filter are still reported in `status` by their resolvability — the filter
    ///   only controls whether they are applied. `nil` = apply all unapplied looks.
    static func buildSteps(
        from amf: ACESMetadataFile,
        config: OCIOConfig,
        currentSourceSpace: String,
        currentDisplay: String,
        currentView: String,
        enabledLookIndices: Set<Int>? = nil
    ) -> AMFPipelineBuildResult {
        guard let pipeline = amf.pipeline else {
            return AMFPipelineBuildResult(steps: [],
                                          suggestedDisplay: nil,
                                          suggestedView: nil,
                                          warnings: ["AMF has no active pipeline"],
                                          status: AMFApplicationStatus(input: nil, looks: [], output: nil))
        }

        var steps:    [[String: String]] = []
        var warnings: [String]           = []

        let ocioLooks       = config.lookNames()
        let amfDir          = amf.sourceURL.deletingLastPathComponent()
        let workingSpace    = resolveWorkingSpace(for: pipeline, config: config)

        // ── 1. Input Transform (IDT) ────────────────────────────────────────────
        // Deferred — the GPU display pipeline already handles the source color space.
        var inputStatus: AMFStageStatus? = nil
        if let input = pipeline.inputTransform {
            inputStatus = input.applied ? .bakedIntoSource : .deferredToDisplay
            print("ℹ️ [AMF] IDT '\(input.transformId ?? "unknown")' — deferred to GPU display pipeline")
        }

        // ── 2. Look Transforms ──────────────────────────────────────────────────
        var lookStatuses: [AMFStageStatus] = []
        for (idx, look) in pipeline.lookTransforms.enumerated() {
            if look.applied {
                lookStatuses.append(.bakedIntoSource)
                print("ℹ️ [AMF] Look '\(look.transformId ?? "unknown")' already applied — skipping")
                continue
            }
            let enabled = enabledLookIndices?.contains(idx) ?? true
            switch resolveLook(look, amfDir: amfDir, workingSpace: workingSpace, ocioLooks: ocioLooks) {
            case .clfFile(let path):
                lookStatuses.append(.applied)
                if enabled {
                    steps.append(["type": "file", "path": path])
                    print("🎬 [AMF] Look (CLF): '\(look.clfFile ?? path)'")
                } else {
                    print("⏸️ [AMF] Look (CLF) disabled: '\(look.clfFile ?? path)'")
                }
            case .ocioLook(let name, let src):
                lookStatuses.append(.applied)
                if enabled {
                    steps.append(["type": "look", "src": src, "name": name])
                    print("🎬 [AMF] Look (OCIO): '\(name)' in '\(src)'")
                } else {
                    print("⏸️ [AMF] Look (OCIO) disabled: '\(name)'")
                }
            case .embeddedCDL:
                if enabled {
                    if let tempPath = writeTempCLF(for: look) {
                        steps.append(["type": "file", "path": tempPath])
                        lookStatuses.append(.applied)
                        print("🎬 [AMF] Look (embedded CDL → temp CLF): '\(tempPath)'")
                    } else {
                        let why = "Embedded CDL for '\(look.transformId ?? "unknown look")' could not be serialised"
                        warnings.append(why + " — skipped")
                        lookStatuses.append(.skipped(why))
                    }
                } else {
                    // Resolvable (it's a CDL) — just disabled by the toggle.
                    lookStatuses.append(.applied)
                    print("⏸️ [AMF] Look (embedded CDL) disabled")
                }
            case .unresolved(let why):
                warnings.append(why + " — skipped")
                lookStatuses.append(.skipped(why))
            }
        }

        // ── 3. Output Transform ─────────────────────────────────────────────────
        // Deferred — the GPU display/view pass applies the output transform so the
        // user's current display/view selection is respected.
        let suggestedDisplay: String? = nil
        let suggestedView:    String? = nil
        var outputStatus: AMFStageStatus? = nil
        if let output = pipeline.outputTransform {
            outputStatus = output.applied ? .bakedIntoSource : .deferredToDisplay
            let tid = output.rrtodtTransformId ?? output.odtTransformId ?? "unknown"
            print("ℹ️ [AMF] Output '\(tid)' — deferred to GPU display pipeline")
        }

        if steps.isEmpty {
            let hasInput  = pipeline.inputTransform != nil
            let hasOutput = pipeline.outputTransform != nil
            let lookCount = pipeline.lookTransforms.count
            print("⚠️ [AMF] No steps produced. Pipeline state: "
                  + "input=\(hasInput ? (pipeline.inputTransform!.applied ? "applied" : "unapplied") : "none"), "
                  + "looks=\(lookCount) (\(pipeline.lookTransforms.filter { $0.applied }.count) applied), "
                  + "output=\(hasOutput ? (pipeline.outputTransform!.applied ? "applied" : "unapplied") : "none")")
        }

        return AMFPipelineBuildResult(steps: steps,
                                      suggestedDisplay: suggestedDisplay,
                                      suggestedView: suggestedView,
                                      warnings: warnings,
                                      status: AMFApplicationStatus(input: inputStatus,
                                                                   looks: lookStatuses,
                                                                   output: outputStatus))
    }

    // MARK: - Application status (UI)

    /// Compute the per-stage application status for display, without building a processor
    /// or writing any temp files. Mirrors the resolution logic used by `buildSteps`.
    static func applicationStatus(for amf: ACESMetadataFile, config: OCIOConfig) -> AMFApplicationStatus {
        guard let pipeline = amf.pipeline else {
            return AMFApplicationStatus(input: nil, looks: [], output: nil)
        }
        let ocioLooks    = config.lookNames()
        let amfDir       = amf.sourceURL.deletingLastPathComponent()
        let workingSpace = resolveWorkingSpace(for: pipeline, config: config)

        let inputStatus: AMFStageStatus? = pipeline.inputTransform.map {
            $0.applied ? .bakedIntoSource : .deferredToDisplay
        }
        let lookStatuses: [AMFStageStatus] = pipeline.lookTransforms.map { look in
            if look.applied { return .bakedIntoSource }
            switch resolveLook(look, amfDir: amfDir, workingSpace: workingSpace, ocioLooks: ocioLooks) {
            case .clfFile, .ocioLook, .embeddedCDL: return .applied
            case .unresolved(let why):              return .skipped(why)
            }
        }
        let outputStatus: AMFStageStatus? = pipeline.outputTransform.map {
            $0.applied ? .bakedIntoSource : .deferredToDisplay
        }
        return AMFApplicationStatus(input: inputStatus, looks: lookStatuses, output: outputStatus)
    }

    // MARK: - Resolution helpers

    /// Working space entering look transforms — scene_linear unless the AMF declares a
    /// `workingLocation` that maps to an available colour space (e.g. ACEScct for CDLs).
    private static func resolveWorkingSpace(for pipeline: AMFPipeline, config: OCIOConfig) -> String {
        let sceneLinear = config.sceneLinearColorSpace() ?? "ACES2065-1"
        guard let wl = pipeline.workingLocation, !wl.isEmpty,
              let hint = AMFOCIOMapper.ocioSpaceHint(for: wl) else { return sceneLinear }
        let availableSpaces = config.colorSpaceNames()
        let matched = availableSpaces.first(where: { $0.lowercased() == hint.lowercased() })
                   ?? availableSpaces.first(where: { $0.lowercased().contains(hint.lowercased()) })
        return matched ?? sceneLinear
    }

    /// Resolve a single *unapplied* look transform to a pipeline step descriptor.
    /// Pure — performs no file I/O — so it is safe to call for UI status.
    private static func resolveLook(_ look: AMFLookTransform,
                                    amfDir: URL,
                                    workingSpace: String,
                                    ocioLooks: [String]) -> LookResolution {
        if let relativePath = look.clfFile {
            return .clfFile(amfDir.appendingPathComponent(relativePath).path)
        }
        if let tid = look.transformId, let matched = matchLookName(tid, in: ocioLooks) {
            return .ocioLook(name: matched, src: workingSpace)
        }
        if look.cdl != nil {
            return .embeddedCDL
        }
        return .unresolved("Look '\(look.transformId ?? "unknown")' has no CLF file or matching OCIO look")
    }

    // MARK: - Helpers

    /// Extract the human-readable suffix from an ACES transform ID URN.
    /// `"urn:ampas:aces:transformId:v2.0:Look.Academy.RGC.a2.v1"` → `"Look.Academy.RGC.a2.v1"`
    private static func urnSuffix(_ urn: String) -> String {
        if let r = urn.range(of: ":transformId:") {
            let after = urn[r.upperBound...]
            if let v = after.range(of: ":") { return String(after[v.upperBound...]) }
            return String(after)
        }
        return urn
    }

    /// Try to match an AMF look transform ID against the OCIO config's look names.
    private static func matchLookName(_ transformId: String, in ocioLooks: [String]) -> String? {
        let suffix = urnSuffix(transformId)
        let sl     = suffix.lowercased()
        // Exact, then case-insensitive, then suffix-in-look, then look-in-suffix
        if let m = ocioLooks.first(where: { $0 == suffix })                    { return m }
        if let m = ocioLooks.first(where: { $0.lowercased() == sl })           { return m }
        if let m = ocioLooks.first(where: { sl.contains($0.lowercased()) })    { return m }
        if let m = ocioLooks.first(where: { $0.lowercased().contains(sl) })    { return m }
        // Normalised-core fallback: strip org / version noise and non-letters, then
        // containment either way. Lets the ACES 2.0 RGC URN
        // ("Look.Academy.ReferenceGamutCompress.a2.v1") match the config's 1.3 look
        // ("ACES 1.3 Reference Gamut Compression"), which is the same algorithm.
        let core = normalizedLookCore(suffix)
        if !core.isEmpty {
            if let m = ocioLooks.first(where: {
                let lc = normalizedLookCore($0)
                return !lc.isEmpty && (lc.contains(core) || core.contains(lc))
            }) {
                print("ℹ️ [AMF] Look '\(suffix)' matched OCIO look '\(m)' via normalised name "
                      + "(version/wording differs)")
                return m
            }
        }
        return nil
    }

    /// Reduce a look name to a comparable core: lowercase, drop org/version noise
    /// tokens, keep only letters. e.g. "Look.Academy.ReferenceGamutCompress.a2.v1"
    /// and "ACES 1.3 Reference Gamut Compression" both → "referencegamutcompress…".
    private static func normalizedLookCore(_ s: String) -> String {
        var t = s.lowercased()
        for noise in ["aces", "academy", "look", ".a2", ".a1", ".v1", ".v2"] {
            t = t.replacingOccurrences(of: noise, with: " ")
        }
        return String(t.unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) })
    }

    /// Map the AMF's output transform to an OCIO display/view pair, if one can be
    /// resolved. Used by the Display node to offer "Match AMF" (set display + view to the
    /// AMF's intended output). Returns nil when the AMF has no output transform or no
    /// display/view matches.
    static func outputDisplayView(for amf: ACESMetadataFile,
                                  config: OCIOConfig) -> (display: String, view: String)? {
        guard let output = amf.pipeline?.outputTransform else { return nil }
        let (d, v) = resolveOutputTransform(output, config: config)
        guard let display = d, let view = v else { return nil }
        return (display, view)
    }

    /// Try to map an AMF output transform ID to an OCIO display/view pair.
    private static func resolveOutputTransform(
        _ output: AMFOutputTransform,
        config: OCIOConfig
    ) -> (String?, String?) {
        let tid = output.rrtodtTransformId ?? output.odtTransformId ?? ""
        guard !tid.isEmpty else { return (nil, nil) }
        let suffix = urnSuffix(tid).lowercased()

        let displays = config.displayNames()
        for display in displays {
            let views = config.viewNames(forDisplay: display)
            for view in views {
                let vl = view.lowercased()
                let dl = display.lowercased()
                if suffix.contains(vl) || vl.contains(suffix) { return (display, view) }
                if suffix.contains(dl) && suffix.contains(vl)  { return (display, view) }
            }
        }
        return (nil, nil)
    }

    /// Write an embedded CDL (from an AMFLookTransform) to a temp CLF file.
    /// Returns the absolute path of the temp file, or nil on failure.
    private static func writeTempCLF(for look: AMFLookTransform) -> String? {
        guard let cdl = look.cdl else { return nil }

        func v3(_ v: SIMD3<Double>) -> String { "\(v.x) \(v.y) \(v.z)" }

        let id  = look.transformId ?? UUID().uuidString
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ProcessList id="\(id)" compCLFversion="3">
            <ASC_CDL id="cdl" inBitDepth="32f" outBitDepth="32f" style="FWD">
                <SOPNode>
                    <Slope>\(v3(cdl.slope))</Slope>
                    <Offset>\(v3(cdl.offset))</Offset>
                    <Power>\(v3(cdl.power))</Power>
                </SOPNode>
                <SatNode>
                    <Saturation>\(cdl.saturation)</Saturation>
                </SatNode>
            </ASC_CDL>
        </ProcessList>
        """

        // Stable temp path derived from CDL values so identical CDLs share a file
        let hash = "\(cdl.slope)\(cdl.offset)\(cdl.power)\(cdl.saturation)".hashValue
        let path = NSTemporaryDirectory() + "tristimulator_cdl_\(abs(hash)).clf"
        do {
            try xml.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            print("❌ [AMF] Failed to write temp CDL CLF: \(error)")
            return nil
        }
    }
}
