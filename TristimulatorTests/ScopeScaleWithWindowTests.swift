//
//  ScopeScaleWithWindowTests.swift
//  TristimulatorTests
//
//  "Scale scopes with window" mode: proportional scaling of scope placements
//  and switching the mode without scopes jumping.
//

import Testing
import Foundation
import CoreGraphics
@testable import Tristimulator

@Suite("Scope scale with window")
struct ScopeScaleWithWindowTests {
    let minSize = CGSize(width: 200, height: 230)
    let maxSize = CGSize(width: 600, height: 640)
    let ref = CGSize(width: 1000, height: 800)

    func scaled(_ p: ScopeOverlayPlacement = ScopeKind.jmh.defaultPlacement) -> ScopeOverlayPlacement {
        var p = p
        p.referenceSize = ref
        return p
    }

    @Test func noReferenceMeansAbsolute() {
        let p = ScopeKind.jmh.defaultPlacement
        let e = p.effective(in: CGSize(width: 1500, height: 1200), minSize: minSize, maxSize: maxSize)
        #expect(e == p)
    }

    @Test func doublingTheAreaDoublesInsetsAndSize() {
        let p = scaled(ScopeOverlayPlacement(edge: .trailing, edgeInset: 20, verticalEdge: .top,
                                             verticalInset: 30, size: CGSize(width: 250, height: 280)))
        let e = p.effective(in: CGSize(width: 2000, height: 1600), minSize: minSize, maxSize: maxSize)
        #expect(e.edgeInset == 40 && e.verticalInset == 60)
        #expect(e.size == CGSize(width: 500, height: 560))
        #expect(e.referenceSize == nil)
        // Stored values are untouched.
        #expect(p.size == CGSize(width: 250, height: 280))
    }

    @Test func sizeScalesUniformlyBySmallerFactor() {
        let p = scaled(ScopeOverlayPlacement(edge: .leading, edgeInset: 100, verticalEdge: .bottom,
                                             verticalInset: 40, size: CGSize(width: 300, height: 300)))
        // Twice as wide, 1.25x as tall: insets per axis, size by 1.25 (aspect kept).
        let e = p.effective(in: CGSize(width: 2000, height: 1000), minSize: minSize, maxSize: maxSize)
        #expect(e.edgeInset == 200 && e.verticalInset == 50)
        #expect(e.size == CGSize(width: 375, height: 375))
    }

    @Test func scaledSizeRespectsMinAndMax() {
        let p = scaled()
        let tiny = p.effective(in: CGSize(width: 250, height: 200), minSize: minSize, maxSize: maxSize)
        #expect(tiny.size == minSize)
        let huge = p.effective(in: CGSize(width: 5000, height: 4000), minSize: minSize, maxSize: maxSize)
        #expect(huge.size == maxSize)
        // Back at the reference size it is exactly as stored.
        let same = p.effective(in: ref, minSize: minSize, maxSize: maxSize)
        #expect(same.size == p.size && same.edgeInset == p.edgeInset)
    }

    @Test func rightPinnedScopeKeepsRelativeGap() {
        let p = scaled()   // JMh: right inset 20, 340 wide
        let small = p.effective(in: CGSize(width: 500, height: 400), minSize: minSize, maxSize: maxSize)
            .frame(in: CGSize(width: 500, height: 400))
        #expect(small.maxX == 490)            // inset 20 → 10
        #expect(small.width == 200)           // 340 * 0.5 = 170, held at min 200
    }

    @Test func turningScalingOnDoesNotMoveTheScope() {
        let area = CGSize(width: 1200, height: 900)
        let p = ScopeKind.jmh.defaultPlacement
        let before = p.effective(in: area, minSize: minSize, maxSize: maxSize).frame(in: area)
        let on = p.settled(in: area, scaling: true, minSize: minSize, maxSize: maxSize)
        #expect(on.referenceSize == area)
        let after = on.effective(in: area, minSize: minSize, maxSize: maxSize).frame(in: area)
        #expect(after == before)
    }

    @Test func turningScalingOffBakesWhatIsOnScreen() {
        let area = CGSize(width: 1500, height: 1200)
        let p = scaled()
        let before = p.effective(in: area, minSize: minSize, maxSize: maxSize).frame(in: area)
        let off = p.settled(in: area, scaling: false, minSize: minSize, maxSize: maxSize)
        #expect(off.referenceSize == nil)
        #expect(off.frame(in: area) == before)
        // And it is now fixed-size again when the window changes.
        #expect(off.frame(in: CGSize(width: 2000, height: 1600)).size == before.size)
    }

    @Test func settledIsStableAndIgnoresUnknownArea() {
        let p = scaled()
        #expect(p.settled(in: CGSize(width: 1300, height: 700), scaling: true,
                          minSize: minSize, maxSize: maxSize) == p)
        #expect(p.settled(in: .zero, scaling: false, minSize: minSize, maxSize: maxSize) == p)
    }

    @Test func editWhileScalingRecordsCurrentArea() {
        let area = CGSize(width: 2000, height: 1600)
        let p = scaled()
        let shown = p.effective(in: area, minSize: minSize, maxSize: maxSize).frame(in: area)
        let moved = p.edited(in: area, scaling: true, minSize: minSize, maxSize: maxSize) {
            $0.dragged(dx: -10, dy: 5, in: area)
        }
        #expect(moved.referenceSize == area)
        let now = moved.effective(in: area, minSize: minSize, maxSize: maxSize).frame(in: area)
        #expect(now.minX == shown.minX - 10 && now.minY == shown.minY + 5)
        #expect(now.size == shown.size)
    }

    @Test func editWithoutScalingIsAbsolute() {
        let area = CGSize(width: 1000, height: 800)
        let moved = ScopeKind.jmh.defaultPlacement.edited(in: area, scaling: false,
                                                          minSize: minSize, maxSize: maxSize) {
            $0.resized(corner: .bottomLeading, dx: -20, dy: 20, minSize: minSize, maxSize: maxSize, in: area)
        }
        #expect(moved.referenceSize == nil)
        #expect(moved.size == CGSize(width: 360, height: 390))
    }

    @Test func referenceSizeIsSavedAndOldPlacementsDecode() throws {
        let p = scaled()
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(ScopeOverlayPlacement.self, from: data) == p)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "referenceSize")
        let old = try JSONDecoder().decode(ScopeOverlayPlacement.self,
                                           from: try JSONSerialization.data(withJSONObject: json))
        #expect(old.referenceSize == nil)
        #expect(old.size == p.size)
    }
}
