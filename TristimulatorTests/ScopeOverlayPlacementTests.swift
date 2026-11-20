//
//  ScopeOverlayPlacementTests.swift
//  TristimulatorTests
//
//  Horizontal and vertical edge pinning, dragging and two-corner resizing of the floating scope overlays.
//

import Testing
import CoreGraphics
@testable import Tristimulator

@Suite("Scope overlay placement")
struct ScopeOverlayPlacementTests {
    let minSize = CGSize(width: 200, height: 230)
    let maxSize = CGSize(width: 600, height: 640)

    func trailing(inset: CGFloat = 20, top: CGFloat = 20,
                  size: CGSize = CGSize(width: 340, height: 370)) -> ScopeOverlayPlacement {
        ScopeOverlayPlacement(edge: .trailing, edgeInset: inset, verticalInset: top, size: size)
    }

    @Test func trailingOverlayStaysPinnedWhenContainerResizes() {
        let p = trailing()
        let small = p.frame(in: CGSize(width: 1000, height: 800))
        let large = p.frame(in: CGSize(width: 1600, height: 800))
        #expect(small.maxX == 980)
        #expect(large.maxX == 1580)
        #expect(small.minY == 20 && large.minY == 20)
    }

    @Test func leadingOverlayKeepsLeftOffset() {
        let p = ScopeOverlayPlacement(edge: .leading, edgeInset: 20, verticalInset: 380,
                                      size: CGSize(width: 300, height: 310))
        #expect(p.frame(in: CGSize(width: 1000, height: 800)).minX == 20)
        #expect(p.frame(in: CGSize(width: 1600, height: 800)).minX == 20)
    }

    @Test func frameIsClampedInsideSmallContainer() {
        let p = trailing(top: 900)
        let f = p.frame(in: CGSize(width: 300, height: 500))
        #expect(f.minX == 0)
        #expect(f.minY == 500 - ScopeOverlayPlacement.visibleTitleHeight)
    }

    @Test func draggingToLeftHalfRepinsToLeadingEdge() {
        let container = CGSize(width: 1000, height: 800)
        let p = trailing().dragged(dx: -600, dy: 10, in: container)
        #expect(p.edge == .leading)
        #expect(p.edgeInset == 40)
        #expect(p.verticalEdge == .top && p.verticalInset == 30)
        // Pinned left now, so widening the window leaves it where it is.
        #expect(p.frame(in: CGSize(width: 1400, height: 800)).minX == 40)
    }

    @Test func draggingWithinRightHalfStaysTrailing() {
        let container = CGSize(width: 1000, height: 800)
        let p = trailing().dragged(dx: -50, dy: 0, in: container)
        #expect(p.edge == .trailing)
        #expect(p.edgeInset == 70)
    }

    @Test func draggingPastEdgeIsClamped() {
        let container = CGSize(width: 1000, height: 800)
        let p = trailing().dragged(dx: 500, dy: -100, in: container)
        #expect(p.edgeInset == 0)
        #expect(p.verticalEdge == .top && p.verticalInset == 0)
    }

    @Test func bottomLeadingResizeKeepsRightEdgeFixed() {
        let container = CGSize(width: 1000, height: 800)
        let before = trailing().frame(in: container)
        let p = trailing().resized(corner: .bottomLeading, dx: -60, dy: 30,
                                   minSize: minSize, maxSize: maxSize, in: container)
        let after = p.frame(in: container)
        #expect(after.maxX == before.maxX)
        #expect(after.width == 400)
        #expect(after.height == 400)
        #expect(after.minY == before.minY)
        #expect(p.edge == .trailing && p.edgeInset == 20)
    }

    @Test func bottomTrailingResizeKeepsLeftEdgeFixed() {
        let container = CGSize(width: 1600, height: 800)
        let before = trailing().frame(in: container)
        let p = trailing().resized(corner: .bottomTrailing, dx: 10, dy: -20,
                                   minSize: minSize, maxSize: maxSize, in: container)
        let after = p.frame(in: container)
        #expect(after.minX == before.minX)
        #expect(after.width == 350 && after.height == 350)
    }

    @Test func resizeRespectsMinAndMaxSize() {
        let container = CGSize(width: 2000, height: 1200)
        let shrunk = trailing().resized(corner: .bottomLeading, dx: 500, dy: -500,
                                        minSize: minSize, maxSize: maxSize, in: container)
        #expect(shrunk.size == minSize)
        let grown = trailing().resized(corner: .bottomLeading, dx: -900, dy: 900,
                                       minSize: minSize, maxSize: maxSize, in: container)
        #expect(grown.size == maxSize)
    }

    @Test func bottomLeadingResizeStopsAtContainerLeftEdge() {
        let container = CGSize(width: 500, height: 800)
        let p = trailing().resized(corner: .bottomLeading, dx: -400, dy: 0,
                                   minSize: minSize, maxSize: maxSize, in: container)
        let f = p.frame(in: container)
        #expect(f.minX == 0)
        #expect(f.maxX == 480)
    }

    // MARK: Vertical pinning

    func bottomPinned(inset: CGFloat = 20, size: CGSize = CGSize(width: 340, height: 370)) -> ScopeOverlayPlacement {
        ScopeOverlayPlacement(edge: .trailing, edgeInset: 20,
                              verticalEdge: .bottom, verticalInset: inset, size: size)
    }

    @Test func bottomPinnedOverlayFollowsBottomEdge() {
        let p = bottomPinned()
        let short = p.frame(in: CGSize(width: 1000, height: 800))
        let tall = p.frame(in: CGSize(width: 1000, height: 1200))
        #expect(short.maxY == 780)
        #expect(tall.maxY == 1180)
    }

    @Test func topPinnedOverlayIgnoresHeightChange() {
        let p = trailing(top: 20)
        #expect(p.frame(in: CGSize(width: 1000, height: 800)).minY == 20)
        #expect(p.frame(in: CGSize(width: 1000, height: 1200)).minY == 20)
    }

    @Test func draggingToBottomHalfRepinsToBottomEdge() {
        let container = CGSize(width: 1000, height: 800)
        // Frame starts at y 20…390 (centre 205); move down 300 → 320…690 (centre 505).
        let p = trailing().dragged(dx: 0, dy: 300, in: container)
        #expect(p.verticalEdge == .bottom)
        #expect(p.verticalInset == 110)
        #expect(p.frame(in: CGSize(width: 1000, height: 1000)).maxY == 890)
    }

    @Test func draggingBackToTopHalfRepinsToTop() {
        let container = CGSize(width: 1000, height: 800)
        let p = bottomPinned().dragged(dx: 0, dy: -300, in: container)
        #expect(p.verticalEdge == .top)
        #expect(p.verticalInset == 110)
    }

    @Test func bottomPinnedClampingSurvivesShrinkAndGrow() {
        let p = bottomPinned()
        // Too short to fit: top clamps to 0 at render time only.
        #expect(p.frame(in: CGSize(width: 1000, height: 300)).minY == 0)
        #expect(p.verticalInset == 20)
        #expect(p.frame(in: CGSize(width: 1000, height: 800)).maxY == 780)
    }

    @Test func bottomPinnedResizeMovesBottomEdgeAndUpdatesInset() {
        let container = CGSize(width: 1000, height: 800)
        let before = bottomPinned().frame(in: container)   // y 410…780
        let p = bottomPinned().resized(corner: .bottomLeading, dx: -10, dy: 15,
                                       minSize: minSize, maxSize: maxSize, in: container)
        let after = p.frame(in: container)
        #expect(after.minY == before.minY)
        #expect(after.maxY == before.maxY + 15)
        #expect(p.verticalEdge == .bottom && p.verticalInset == 5)
        #expect(after.maxX == before.maxX)
    }

    @Test func resizeStopsAtContainerBottom() {
        let container = CGSize(width: 1000, height: 800)
        let p = bottomPinned().resized(corner: .bottomTrailing, dx: 0, dy: 100,
                                       minSize: minSize, maxSize: maxSize, in: container)
        #expect(p.frame(in: container).maxY == 800)
        #expect(p.verticalInset == 0)
    }

    // MARK: Centre-vs-midline rule

    @Test func dropJustBelowMidlinePinsBottomJustAbovePinsTop() {
        // Image area 1000 x 748 (window content minus a 52 pt toolbar), JMh 370 tall.
        let container = CGSize(width: 1000, height: 748)
        // Top 20 → 190: centre 375, one point below the 374 midline.
        let below = trailing().dragged(dx: 0, dy: 170, in: container)
        #expect(below.verticalEdge == .bottom)
        // Top 20 → 188: centre 373, one point above.
        let above = trailing().dragged(dx: 0, dy: 168, in: container)
        #expect(above.verticalEdge == .top)
    }

    @Test func dropLeftOrRightOfCentreLinePicksThatSide() {
        let container = CGSize(width: 1000, height: 748)
        // Right edge inset 20, 340 wide: x 640…980, centre 810. Centre to 499 / 501.
        #expect(trailing().dragged(dx: -311, dy: 0, in: container).edge == .leading)
        #expect(trailing().dragged(dx: -309, dy: 0, in: container).edge == .trailing)
    }

    // MARK: Top corners

    @Test func topLeadingResizeKeepsBottomRightFixed() {
        let container = CGSize(width: 1000, height: 800)
        let start = trailing(top: 200)
        let before = start.frame(in: container)
        let p = start.resized(corner: .topLeading, dx: -30, dy: -40,
                              minSize: minSize, maxSize: maxSize, in: container)
        let after = p.frame(in: container)
        #expect(after.maxX == before.maxX && after.maxY == before.maxY)
        #expect(after.width == 370 && after.height == 410)
        #expect(after.minY == 160)
    }

    @Test func topTrailingResizeKeepsBottomLeftFixed() {
        let container = CGSize(width: 1600, height: 800)
        let start = trailing(top: 200)
        let before = start.frame(in: container)
        let p = start.resized(corner: .topTrailing, dx: 10, dy: 30,
                              minSize: minSize, maxSize: maxSize, in: container)
        let after = p.frame(in: container)
        #expect(after.minX == before.minX && after.maxY == before.maxY)
        #expect(after.width == 350 && after.height == 340)
    }

    @Test func topResizeStopsAtContainerTopAndMinSize() {
        let container = CGSize(width: 1000, height: 800)
        let start = trailing(top: 50)
        let grown = start.resized(corner: .topLeading, dx: 0, dy: -200,
                                  minSize: minSize, maxSize: maxSize, in: container)
        #expect(grown.frame(in: container).minY == 0)
        #expect(grown.frame(in: container).maxY == 420)
        let shrunk = start.resized(corner: .topTrailing, dx: -500, dy: 500,
                                   minSize: minSize, maxSize: maxSize, in: container)
        #expect(shrunk.size == minSize)
        #expect(shrunk.frame(in: container).maxY == 420)
    }

    @Test func clampingSizeLimitsSavedValues() {
        let p = trailing(size: CGSize(width: 5000, height: 10))
            .clampingSize(min: minSize, max: maxSize)
        #expect(p.size == CGSize(width: 600, height: 230))
    }
}

