//
//  InverseDisplaySelectionTests.swift
//  TristimulatorTests
//
//  Verifies which display/view InverseDisplaySelection picks for a display-referred
//  colour space. Uses an in-memory model of the ACES studio config's displays, so no OCIO.
//

import Testing
import Foundation
@testable import Tristimulator

private struct FakeDisplay {
    let name: String
    let encoding: String
    /// (view name, view transform; "" for a plain colour space view, display colour space or nil for USE_DISPLAY_NAME)
    let views: [(String, String, String?)]
}

private func query(_ displays: [FakeDisplay],
                   sceneSpaces: Set<String> = ["ACEScg", "sRGB Encoded Rec.709 (sRGB)"]) -> InverseDisplayConfigQuery {
    let byName = Dictionary(uniqueKeysWithValues: displays.map { ($0.name, $0) })
    return InverseDisplayConfigQuery(
        displays: displays.map(\.name),
        views: { byName[$0]?.views.map(\.0) ?? [] },
        defaultView: { byName[$0]?.views.first?.0 ?? "" },
        displayColorSpace: { d, v in
            guard let view = byName[d]?.views.first(where: { $0.0 == v }) else { return nil }
            return view.2 ?? d
        },
        viewTransform: { d, v in byName[d]?.views.first(where: { $0.0 == v })?.1 ?? "" },
        isDisplayReferred: { byName[$0] != nil && !sceneSpaces.contains($0) },
        encoding: { byName[$0]?.encoding ?? "" })
}

private let sdr709 = "ACES 2.0 - SDR 100 nits (Rec.709)"
private let sdrP3  = "ACES 2.0 - SDR 100 nits (P3 D65)"
private let hdr1000 = "ACES 2.0 - HDR 1000 nits (P3 D65)"

private func shared(_ first: String...) -> [(String, String, String?)] {
    first.map { ($0, $0, nil) } + [("Un-tone-mapped", "Un-tone-mapped", nil),
                                   ("Video (colorimetric)", "Video (colorimetric)", nil),
                                   ("Raw", "", "Raw")]
}

private let studio = query([
    FakeDisplay(name: "sRGB - Display", encoding: "sdr-video", views: shared(sdr709)),
    FakeDisplay(name: "Display P3 - Display", encoding: "sdr-video", views: shared(sdrP3)),
    FakeDisplay(name: "Display P3 HDR - Display", encoding: "edr-video", views: shared(hdr1000, sdr709)),
    FakeDisplay(name: "Gamma 2.2 Rec.709 - Display", encoding: "sdr-video", views: shared(sdr709)),
    FakeDisplay(name: "Rec.1886 Rec.709 - Display", encoding: "sdr-video", views: shared(sdr709)),
    FakeDisplay(name: "Rec.2100-PQ - Display", encoding: "hdr-video", views: shared(hdr1000, sdr709)),
    FakeDisplay(name: "Rec.2100-HLG - Display", encoding: "hdr-video", views: shared(hdr1000)),
])

@Suite("Inverse display selection")
@MainActor
struct InverseDisplaySelectionTests {

    @Test func sRGBDisplayInvertsSDR709() {
        #expect(InverseDisplaySelection.target(for: "sRGB - Display", in: studio)
                == InverseDisplayTarget(display: "sRGB - Display", view: sdr709))
    }

    @Test func displayP3InvertsSDRP3() {
        #expect(InverseDisplaySelection.target(for: "Display P3 - Display", in: studio)
                == InverseDisplayTarget(display: "Display P3 - Display", view: sdrP3))
    }

    @Test func rec709DisplayVariantsInvertSDR709() {
        for d in ["Gamma 2.2 Rec.709 - Display", "Rec.1886 Rec.709 - Display"] {
            #expect(InverseDisplaySelection.target(for: d, in: studio)
                    == InverseDisplayTarget(display: d, view: sdr709))
        }
    }

    @Test func hdrEncodingsStayInColorSpaceMode() {
        for d in ["Display P3 HDR - Display", "Rec.2100-PQ - Display", "Rec.2100-HLG - Display"] {
            #expect(InverseDisplaySelection.target(for: d, in: studio) == nil)
        }
    }

    @Test func sceneReferredSpacesStayInColorSpaceMode() {
        #expect(InverseDisplaySelection.target(for: "ACEScg", in: studio) == nil)
        #expect(InverseDisplaySelection.target(for: "sRGB Encoded Rec.709 (sRGB)", in: studio) == nil)
        #expect(InverseDisplaySelection.target(for: "", in: studio) == nil)
    }

    @Test func noSDRViewFallsBackToDefaultViewElseNil() {
        let onlyUntoned = query([
            FakeDisplay(name: "Custom - Display", encoding: "sdr-video",
                        views: [("Filmic", "Filmic", nil), ("Raw", "", "Raw")]),
        ])
        #expect(InverseDisplaySelection.target(for: "Custom - Display", in: onlyUntoned)
                == InverseDisplayTarget(display: "Custom - Display", view: "Filmic"))

        let onlyHDRView = query([
            FakeDisplay(name: "Odd - Display", encoding: "sdr-video",
                        views: [(hdr1000, hdr1000, nil), ("Raw", "", "Raw")]),
        ])
        #expect(InverseDisplaySelection.target(for: "Odd - Display", in: onlyHDRView) == nil)
    }

    @Test func missingEncodingUsesNameHeuristic() {
        let legacy = query([
            FakeDisplay(name: "sRGB", encoding: "", views: [("Film", "Film", nil)]),
            FakeDisplay(name: "Rec.2100 PQ", encoding: "", views: [("Film", "Film", nil)]),
        ])
        #expect(InverseDisplaySelection.target(for: "sRGB", in: legacy)
                == InverseDisplayTarget(display: "sRGB", view: "Film"))
        #expect(InverseDisplaySelection.target(for: "Rec.2100 PQ", in: legacy) == nil)
    }

    @Test func preferenceDefaultsOff() {
        let defaults = UserDefaults(suiteName: "InverseDisplaySelectionTests.\(UUID().uuidString)")!
        #expect(defaults.bool(forKey: InverseDisplaySelection.preferenceKey) == false)
    }
}
