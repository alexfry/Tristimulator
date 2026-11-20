//
//  ScopeLayoutTests.swift
//  TristimulatorTests
//
//  Scope stacking order, click resolution and per-image persistence of the
//  scope overlay layout in OCIOPipelineSettings.
//

import Testing
import Foundation
import CoreGraphics
@testable import Tristimulator

@Suite("Scope layout")
struct ScopeLayoutTests {

    // MARK: Z-order

    @Test func defaultOrderHasEveryScopeOnce() {
        #expect(ScopeZOrder().backToFront == [.yxy, .uv, .jmh])
    }

    @Test func bringToFrontMovesScopeToTop() {
        var order = ScopeZOrder()
        order.bringToFront(.yxy)
        #expect(order.backToFront == [.uv, .jmh, .yxy])
        #expect(order.zIndex(.yxy) > order.zIndex(.jmh))
    }

    @Test func savedOrderIgnoresUnknownAndDuplicatesAndFillsMissing() {
        let order = ScopeZOrder(rawValues: ["jmh", "bogus", "jmh", "yxy"])
        #expect(order.backToFront == [.uv, .jmh, .yxy])
    }

    @Test func clickOnOverlapRaisesTheVisibleScope() {
        var resolver = ScopeClickResolver()
        let start = ScopeZOrder([.yxy, .uv, .jmh])   // jmh in front
        // One click over yxy and uv: uv was in front of yxy, so uv comes forward.
        var order = resolver.mouseDown(on: .yxy, at: 1, current: start)
        order = resolver.mouseDown(on: .uv, at: 1, current: order)
        #expect(order.backToFront == [.yxy, .jmh, .uv])
        // Reported in the other order, same answer.
        var r2 = ScopeClickResolver()
        var o2 = r2.mouseDown(on: .uv, at: 1, current: start)
        o2 = r2.mouseDown(on: .yxy, at: 1, current: o2)
        #expect(o2.backToFront == [.yxy, .jmh, .uv])
    }

    @Test func separateClicksEachRaiseTheirScope() {
        var resolver = ScopeClickResolver()
        var order = resolver.mouseDown(on: .yxy, at: 1, current: ScopeZOrder())
        order = resolver.mouseDown(on: .uv, at: 2, current: order)
        #expect(order.backToFront == [.jmh, .yxy, .uv])
    }

    // MARK: Persistence

    func sampleLayout() -> ScopeLayoutState {
        var order = ScopeZOrder()
        order.bringToFront(.uv)
        let jmh = ScopeOverlayPlacement(edge: .trailing, edgeInset: 35, verticalEdge: .bottom,
                                        verticalInset: 12, size: CGSize(width: 410, height: 450))
        return ScopeLayoutState(visible: [.jmh: true, .uv: true],
                                placements: [.jmh: jmh], zOrder: order)
    }

    @Test func layoutRoundTripsThroughSettings() throws {
        let settings = OCIOPipelineSettings(sourceSpace: "ACEScg", scopeLayout: sampleLayout())
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OCIOPipelineSettings.self, from: data)
        let layout = try #require(decoded.scopeLayout)
        #expect(layout == sampleLayout())
        #expect(layout.state(for: .jmh)?.visible == true)
        #expect(layout.state(for: .yxy)?.visible == false)
        #expect(layout.state(for: .jmh)?.placement?.verticalEdge == .bottom)
        #expect(ScopeZOrder(rawValues: layout.zOrder).backToFront.last == .uv)
    }

    @Test func settingsWithoutScopeLayoutStillDecode() throws {
        let data = try JSONEncoder().encode(OCIOPipelineSettings(sourceSpace: "ACEScg"))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "scopeLayout")
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(OCIOPipelineSettings.self, from: old)
        #expect(decoded.sourceSpace == "ACEScg")
        #expect(decoded.scopeLayout == nil)
    }

    @Test func malformedScopeLayoutDoesNotLoseColourSettings() throws {
        let data = try JSONEncoder().encode(OCIOPipelineSettings(sourceSpace: "ACEScg"))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["scopeLayout"] = ["scopes": "not a dictionary"]
        let bad = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(OCIOPipelineSettings.self, from: bad)
        #expect(decoded.sourceSpace == "ACEScg")
        #expect(decoded.scopeLayout == nil)
    }

    @Test func unknownScopesAndBadPlacementAreTolerated() throws {
        let json = """
        {"scopes": {"jmh": {"visible": true, "placement": {"edge": "sideways"}},
                    "future": {"visible": true}},
         "zOrder": ["future", "jmh"]}
        """
        let layout = try JSONDecoder().decode(ScopeLayoutState.self, from: Data(json.utf8))
        #expect(layout.state(for: .jmh)?.visible == true)
        #expect(layout.state(for: .jmh)?.placement == nil)
        #expect(ScopeZOrder(rawValues: layout.zOrder).backToFront == [.yxy, .uv, .jmh])
    }
}
