//
//  AMFPipelineStatusTests.swift
//  TristimulatorTests
//
//  Verifies AMFOCIOPipelineBuilder resolves AMF pipeline stages correctly and reports
//  accurate per-stage application status — in particular that the ACES 2.0 Reference
//  Gamut Compress look (URN `Look.Academy.ReferenceGamutCompress.a2.v1`) matches the
//  bundled studio-config's "ACES 1.3 Reference Gamut Compression" look rather than being
//  silently skipped.
//
//  Fixture: TristimulatorTests/Fixtures/AMF/studio_export.amf (+ its two CorrectorNode CLFs),
//  a DaVinci Resolve Studio AMF export for the ACES_OT_VWG sample clip.
//

import Testing
import Foundation
@testable import Tristimulator

@Suite("AMF pipeline status")
struct AMFPipelineStatusTests {

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AMF")
    }

    private var configPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // TristimulatorTests/
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("OCIO/studio-config-v4.0.0_aces-v2.0_ocio-v2.5.ocio")
            .path
    }

    private func loadConfig() throws -> OCIOConfig {
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw TestSkip.missing("OCIO config at \(configPath)")
        }
        guard let config = try? OCIOConfig(path: configPath) else {
            throw TestSkip.missing("OCIO config failed to load")
        }
        return config
    }

    private enum TestSkip: Error { case missing(String) }

    private func loadAMF() throws -> ACESMetadataFile {
        let url = fixturesDir.appendingPathComponent("studio_export.amf")
        return try ACESAMFParser.parse(url: url)
    }

    // MARK: Tests

    /// The studio AMF declares: RGC look (transformId) + 2 CLF-file looks + an output
    /// transform. Tristimulator should apply all three looks and defer the output transform.
    @Test func studioPipelineStagesAllResolve() throws {
        let config: OCIOConfig
        do { config = try loadConfig() }
        catch { print("⚠️ skipping: \(error)"); return }

        let amf = try loadAMF()
        let status = AMFOCIOPipelineBuilder.applicationStatus(for: amf, config: config)

        #expect(amf.pipeline?.lookTransforms.count == 3, "expected RGC + 2 CLF looks")
        #expect(status.looks.count == 3)

        // RGC look (first) must resolve — this is the 2.0-URN → 1.3-look matching fix.
        #expect(status.looks.first == .applied,
                "RGC look should resolve to .applied (got \(String(describing: status.looks.first)))")
        // All look stages apply.
        #expect(status.looks.allSatisfy { $0 == .applied },
                "all looks should be .applied (got \(status.looks))")
        // Output transform is handled by the display/view pass.
        #expect(status.output == .deferredToDisplay)
        // This AMF has no input transform.
        #expect(status.input == nil)
    }

    /// buildSteps should emit one step per look (1 OCIO look + 2 file transforms), with
    /// no skipped looks recorded as warnings.
    @Test func studioPipelineBuildsThreeSteps() throws {
        let config: OCIOConfig
        do { config = try loadConfig() }
        catch { print("⚠️ skipping: \(error)"); return }

        let amf = try loadAMF()
        let result = AMFOCIOPipelineBuilder.buildSteps(
            from: amf, config: config,
            currentSourceSpace: "ACES2065-1",
            currentDisplay: "sRGB - Display",
            currentView: "ACES 2.0 - SDR 100 nits (Rec.709)")

        #expect(result.steps.count == 3, "expected 1 look + 2 file steps, got \(result.steps.count)")
        // First look resolves to an OCIO look step (the RGC match), the other two to files.
        #expect(result.steps.first?["type"] == "look")
        #expect(result.steps.filter { $0["type"] == "file" }.count == 2)
        #expect(result.status.looks.allSatisfy { $0 == .applied })
    }

    /// The per-stage enable filter omits disabled looks from the emitted steps, while
    /// `status` continues to report each look's resolvability regardless of the filter.
    @Test func enabledLookIndicesFiltersSteps() throws {
        let config: OCIOConfig
        do { config = try loadConfig() }
        catch { print("⚠️ skipping: \(error)"); return }

        let amf = try loadAMF()
        func build(_ enabled: Set<Int>?) -> AMFPipelineBuildResult {
            AMFOCIOPipelineBuilder.buildSteps(
                from: amf, config: config,
                currentSourceSpace: "ACES2065-1",
                currentDisplay: "sRGB - Display",
                currentView: "ACES 2.0 - SDR 100 nits (Rec.709)",
                enabledLookIndices: enabled)
        }

        // Enable only looks 0 (RGC) and 2 (second CLF): 1 look + 1 file = 2 steps.
        let subset = build([0, 2])
        #expect(subset.steps.count == 2, "expected 2 steps, got \(subset.steps.count)")

        // Empty set → nothing enabled → no steps.
        #expect(build([]).steps.isEmpty)

        // nil → all looks (matches the no-filter path).
        #expect(build(nil).steps.count == 3)

        // Status reflects resolvability, not the enable filter.
        #expect(subset.status.looks.allSatisfy { $0 == .applied })
    }
}
