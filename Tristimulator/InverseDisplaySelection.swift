//
//  InverseDisplaySelection.swift
//  Tristimulator
//
//  Picks the display/view to invert for a display-referred source image, used
//  when the "inverse output transform for display-referred images" preference
//  is on. Only an SDR display colour space with an SDR view is ever chosen, so
//  HDR, PQ and HLG encodings stay in Color Space mode.
//

import Foundation

/// The display/view pair whose output transform is inverted to bring a
/// display-referred image into scene-linear.
struct InverseDisplayTarget: Equatable {
    let display: String
    let view: String
}

/// Read-only view of the OCIO config, so the selection logic can be tested without OCIO.
struct InverseDisplayConfigQuery {
    var displays: [String]
    var views: (_ display: String) -> [String]
    var defaultView: (_ display: String) -> String
    /// Display colour space a display/view renders into (`<USE_DISPLAY_NAME>` already resolved).
    var displayColorSpace: (_ display: String, _ view: String) -> String?
    /// View transform name, or "" when the view has none.
    var viewTransform: (_ display: String, _ view: String) -> String
    var isDisplayReferred: (_ colorSpace: String) -> Bool
    var encoding: (_ colorSpace: String) -> String
}

extension InverseDisplayConfigQuery {
    init(config: OCIOConfig) {
        self.init(
            displays: config.displayNames(),
            views: { config.viewNames(forDisplay: $0) },
            defaultView: { config.defaultView(forDisplay: $0) },
            displayColorSpace: { config.displayColorSpace(forDisplay: $0, view: $1) },
            viewTransform: { config.viewTransform(forDisplay: $0, view: $1) },
            isDisplayReferred: { config.isDisplayReferredColorSpace($0) },
            encoding: { config.encoding(forColorSpace: $0) })
    }
}

enum InverseDisplaySelection {

    /// UserDefaults key for the preference. Default (missing) is off.
    static let preferenceKey = TristimulatorDefaults.inverseDisplayForDisplayReferred

    /// Returns the display/view to invert for `colorSpace`, or nil to stay in Color Space mode.
    ///
    /// - `colorSpace` must be display-referred with an SDR encoding.
    /// - The display must render into `colorSpace` through a view that has a view transform.
    /// - View preference: SDR 100 nits ACES 2.0, then any SDR 100 nits, then any SDR,
    ///   then the display's default view. A view whose name says HDR is never chosen.
    static func target(for colorSpace: String, in config: InverseDisplayConfigQuery) -> InverseDisplayTarget? {
        guard !colorSpace.isEmpty, config.isDisplayReferred(colorSpace) else { return nil }
        guard isSDREncoding(config.encoding(colorSpace), name: colorSpace) else { return nil }

        for display in config.displays {
            let candidates = config.views(display).filter { view in
                config.displayColorSpace(display, view) == colorSpace
                    && !config.viewTransform(display, view).isEmpty
                    && !looksHDR(view)
            }
            guard !candidates.isEmpty else { continue }

            if let view = pickView(candidates, defaultView: config.defaultView(display)) {
                return InverseDisplayTarget(display: display, view: view)
            }
        }
        return nil
    }

    private static func pickView(_ candidates: [String], defaultView: String) -> String? {
        let lower = { (s: String) in s.lowercased() }
        if let v = candidates.first(where: { lower($0).contains("aces 2.0") && lower($0).contains("sdr") && lower($0).contains("100 nits") }) {
            return v
        }
        if let v = candidates.first(where: { lower($0).contains("sdr") && lower($0).contains("100 nits") }) {
            return v
        }
        if let v = candidates.first(where: { lower($0).contains("sdr") }) {
            return v
        }
        return candidates.contains(defaultView) ? defaultView : nil
    }

    /// Only "sdr-video" qualifies. A colour space with no encoding qualifies unless its name
    /// looks HDR, so older configs without encodings still work.
    static func isSDREncoding(_ encoding: String, name: String) -> Bool {
        let enc = encoding.lowercased()
        if enc.isEmpty { return !looksHDR(name) }
        return enc == "sdr-video"
    }

    static func looksHDR(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["hdr", "pq", "hlg", "2100", "st2084", "st-2084"].contains { n.contains($0) }
    }
}
