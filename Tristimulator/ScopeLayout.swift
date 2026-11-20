//
//  ScopeLayout.swift
//  Tristimulator
//
//  Which floating scopes are open, where they sit and which is in front.
//  Saved per image with the OCIO settings so scopes reopen as they were left.
//

import Foundation
import CoreGraphics

/// The floating scope overlays.
enum ScopeKind: String, Codable, CaseIterable {
    case yxy, uv, jmh

    /// Where a scope opens when the image has no saved placement for it.
    var defaultPlacement: ScopeOverlayPlacement {
        switch self {
        case .yxy:
            return ScopeOverlayPlacement(edge: .leading, edgeInset: 20, verticalEdge: .top,
                                         verticalInset: 20, size: CGSize(width: 300, height: 340))
        case .uv:
            return ScopeOverlayPlacement(edge: .leading, edgeInset: 20, verticalEdge: .top,
                                         verticalInset: 380, size: CGSize(width: 300, height: 310))
        case .jmh:
            return ScopeOverlayPlacement(edge: .trailing, edgeInset: 20, verticalEdge: .top,
                                         verticalInset: 20, size: CGSize(width: 340, height: 370))
        }
    }
}

/// Stacking order of the scopes, back to front. Always holds every kind once.
struct ScopeZOrder: Equatable {
    private(set) var backToFront: [ScopeKind]

    /// Order from a saved list: duplicates are dropped and missing kinds are
    /// put at the back in their default order.
    init(_ saved: [ScopeKind]? = nil) {
        var seen = Set<ScopeKind>()
        let known = (saved ?? []).filter { seen.insert($0).inserted }
        backToFront = ScopeKind.allCases.filter { !seen.contains($0) } + known
    }

    /// Order from saved raw values; unknown values are ignored.
    init(rawValues: [String]?) {
        self.init(rawValues?.compactMap(ScopeKind.init(rawValue:)))
    }

    /// SwiftUI `zIndex` for `kind`; higher is in front.
    func zIndex(_ kind: ScopeKind) -> Double {
        Double(backToFront.firstIndex(of: kind) ?? 0)
    }

    mutating func bringToFront(_ kind: ScopeKind) {
        backToFront.removeAll { $0 == kind }
        backToFront.append(kind)
    }

    /// The front-most of `kinds`, or nil when it is empty.
    func frontmost(of kinds: Set<ScopeKind>) -> ScopeKind? {
        backToFront.last { kinds.contains($0) }
    }
}

/// Turns mouse-down reports from overlapping scopes into a single raise.
/// Every scope under the click reports the same event (same timestamp); only
/// the one that was front-most when the click started is brought forward,
/// so clicking where two scopes overlap raises the one you can see.
struct ScopeClickResolver {
    private var timestamp: TimeInterval?
    private var orderAtClick = ScopeZOrder()
    private var candidates = Set<ScopeKind>()

    /// Registers that `kind` saw the mouse-down at `timestamp` and returns the
    /// new stacking order.
    mutating func mouseDown(on kind: ScopeKind, at timestamp: TimeInterval,
                            current: ScopeZOrder) -> ScopeZOrder {
        if timestamp != self.timestamp {
            self.timestamp = timestamp
            orderAtClick = current
            candidates = []
        }
        candidates.insert(kind)
        var order = orderAtClick
        if let front = orderAtClick.frontmost(of: candidates) { order.bringToFront(front) }
        return order
    }
}

/// Saved state of one scope.
struct ScopeOverlayState: Codable, Equatable {
    var visible: Bool
    var placement: ScopeOverlayPlacement?

    init(visible: Bool, placement: ScopeOverlayPlacement?) {
        self.visible = visible
        self.placement = placement
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? false
        placement = try? c.decodeIfPresent(ScopeOverlayPlacement.self, forKey: .placement)
    }
}

/// Saved state of all scopes for one image, stored in `OCIOPipelineSettings`.
/// Keyed by `ScopeKind` raw value so unknown scopes in newer files are ignored.
struct ScopeLayoutState: Codable, Equatable {
    var scopes: [String: ScopeOverlayState] = [:]
    /// Back-to-front `ScopeKind` raw values.
    var zOrder: [String]?

    init(visible: [ScopeKind: Bool], placements: [ScopeKind: ScopeOverlayPlacement],
         zOrder: ScopeZOrder) {
        for kind in ScopeKind.allCases {
            scopes[kind.rawValue] = ScopeOverlayState(visible: visible[kind] ?? false,
                                                      placement: placements[kind])
        }
        self.zOrder = zOrder.backToFront.map(\.rawValue)
    }

    func state(for kind: ScopeKind) -> ScopeOverlayState? { scopes[kind.rawValue] }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scopes = try c.decodeIfPresent([String: ScopeOverlayState].self, forKey: .scopes) ?? [:]
        zOrder = try c.decodeIfPresent([String].self, forKey: .zOrder)
    }
}
