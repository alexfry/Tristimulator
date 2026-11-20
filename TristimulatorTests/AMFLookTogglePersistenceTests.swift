//
//  AMFLookTogglePersistenceTests.swift
//  TristimulatorTests
//
//  Verifies the AMF Look Transforms toggle state round-trips through
//  OCIOPipelineSettings, decodes from older settings without AMF data, and is matched
//  to looks by stable key when the AMF's look list changes.
//

import Testing
import Foundation
@testable import Tristimulator

private func look(id: String? = nil, clf: String? = nil, desc: String? = nil) -> AMFLookTransform {
    AMFLookTransform(applied: false, description: desc, transformId: id, hashValue: nil,
                     hashAlgorithm: nil, clfFile: clf, clf: nil, cdlWorkingSpaceId: nil, cdl: nil)
}

@Suite("AMF look toggle persistence")
@MainActor
struct AMFLookTogglePersistenceTests {

    private func roundTrip(_ s: OCIOPipelineSettings) throws -> OCIOPipelineSettings {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(OCIOPipelineSettings.self, from: enc.encode(s))
    }

    @Test func settingsRoundTripAMFToggles() throws {
        var s = OCIOPipelineSettings(sourceSpace: "ACES2065-1")
        s.amfLookStates = ["id:a": false, "clf:grade.clf": true]
        s.amfLooksGloballyEnabled = false
        let d = try roundTrip(s)
        #expect(d.amfLookStates == ["id:a": false, "clf:grade.clf": true])
        #expect(d.amfLooksGloballyEnabled == false)
    }

    @Test func legacySettingsWithoutAMFDecode() throws {
        let json = """
        {"sourceSpace":"a","destSpace":"b","display":"c","view":"d",
         "metalColorSpace":"extendedDisplayP3","useCPURenderPath":false,"exposure":0,
         "lastOpened":"2026-01-01T00:00:00Z","dynamicACES2Mode":true,
         "dynamicACES2AutoNits":true,"dynamicACES2Gamut":"\(ACES2Gamut.p3d65.rawValue)",
         "dynamicACES2TargetNits":1000}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let d = try dec.decode(OCIOPipelineSettings.self, from: Data(json.utf8))
        #expect(d.amfLookStates == nil)
        #expect(d.amfLooksGloballyEnabled == nil)
    }

    @Test func keysAreStableAndDistinct() {
        let keys = AMFLookToggleState.keys(for: [
            look(id: "urn:x"), look(clf: "g.clf"), look(id: "urn:x"), look(desc: "Grade"), look()
        ])
        #expect(keys == ["id:urn:x", "clf:g.clf", "id:urn:x#2", "desc:Grade", "look[4]"])
    }

    @Test func mergeMatchesByKeyAfterLookListChanges() {
        // Saved when the AMF had looks A, B (B turned off). The AMF now has C, B, A.
        let saved = ["id:A": true, "id:B": false, "id:gone": false]
        let keys = AMFLookToggleState.keys(for: [look(id: "C"), look(id: "B"), look(id: "A")])
        let merged = AMFLookToggleState.merge(defaults: [true, true, true], keys: keys,
                                              resolvable: [true, true, true], saved: saved)
        #expect(merged == [true, false, true])   // new look C keeps its default
    }

    @Test func mergeNeverEnablesUnresolvableLooks() {
        let keys = AMFLookToggleState.keys(for: [look(id: "A"), look(id: "B")])
        let merged = AMFLookToggleState.merge(defaults: [false, true], keys: keys,
                                              resolvable: [false, true],
                                              saved: ["id:A": true, "id:B": false])
        #expect(merged == [false, false])
    }

    @Test func mergeWithoutSavedStateUsesDefaults() {
        let keys = AMFLookToggleState.keys(for: [look(id: "A")])
        #expect(AMFLookToggleState.merge(defaults: [true], keys: keys,
                                         resolvable: [true], saved: nil) == [true])
    }
}
