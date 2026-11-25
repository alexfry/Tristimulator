//
//  ScopeViewState.swift
//  Tristimulator
//
//  App-wide (UserDefaults) view state for the Yxy, u'v' and JMh scopes:
//  2D/3D mode, the 3D camera, and the JMh M range. Unlike the per-image
//  scope layout (visibility / placement / stacking, saved with the OCIO
//  settings in ScopeLayout.swift), these are global preferences that apply
//  to every window and survive relaunch.
//

import Foundation
import simd

/// Saved 3D orbit camera for one scope.
struct Scope3DCamera: Codable, Equatable {
    var yaw: Float
    var pitch: Float
    var distance: Float
    var targetX: Float
    var targetY: Float
    var targetZ: Float

    static let pitchLimit: Float = 1.45
    static let distanceRange: ClosedRange<Float> = 2.0...10.0
    static let maxPan: Float = 3.0

    static let `default` = Scope3DCamera(yaw: 0.6, pitch: 0.45, distance: 3.6,
                                         targetX: 0, targetY: 0, targetZ: 0)

    var target: SIMD3<Float> { [targetX, targetY, targetZ] }

    init(yaw: Float, pitch: Float, distance: Float, targetX: Float, targetY: Float, targetZ: Float) {
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.targetX = targetX
        self.targetY = targetY
        self.targetZ = targetZ
    }

    init(yaw: Float, pitch: Float, distance: Float, target: SIMD3<Float>) {
        self.init(yaw: yaw, pitch: pitch, distance: distance,
                  targetX: target.x, targetY: target.y, targetZ: target.z)
    }

    /// The same camera with every value forced into the range the view allows
    /// (non-finite values fall back to the default).
    var clamped: Scope3DCamera {
        func finite(_ v: Float, _ fallback: Float) -> Float { v.isFinite ? v : fallback }
        let d = Self.default
        var t = SIMD3<Float>(finite(targetX, 0), finite(targetY, 0), finite(targetZ, 0))
        let len = simd_length(t)
        if len > Self.maxPan { t *= Self.maxPan / len }
        // Keep yaw in (-π, π] so it can't grow without bound across sessions.
        var y = finite(yaw, d.yaw)
        y = atan2(sin(y), cos(y))
        return Scope3DCamera(
            yaw: y,
            pitch: min(max(finite(pitch, d.pitch), -Self.pitchLimit), Self.pitchLimit),
            distance: min(max(finite(distance, d.distance), Self.distanceRange.lowerBound),
                          Self.distanceRange.upperBound),
            target: t)
    }
}

/// Reads and writes the scope view state in UserDefaults.
/// Keys are listed in `TristimulatorDefaults`.
enum ScopeViewDefaults {
    static let jmhMaxMDefault: Float = 100
    static let jmhMaxMRange: ClosedRange<Float> = 5...200

    static func is3D(_ kind: ScopeKind, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: TristimulatorDefaults.scopeIs3D(kind))
    }

    static func setIs3D(_ value: Bool, for kind: ScopeKind, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: TristimulatorDefaults.scopeIs3D(kind))
    }

    /// Saved camera, clamped; the default camera when nothing (or garbage) is saved.
    static func camera(_ kind: ScopeKind, in defaults: UserDefaults = .standard) -> Scope3DCamera {
        guard let data = defaults.data(forKey: TristimulatorDefaults.scope3DCamera(kind)),
              let camera = try? JSONDecoder().decode(Scope3DCamera.self, from: data)
        else { return .default }
        return camera.clamped
    }

    static func setCamera(_ camera: Scope3DCamera, for kind: ScopeKind, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(camera.clamped) else { return }
        defaults.set(data, forKey: TristimulatorDefaults.scope3DCamera(kind))
    }

    /// Saved JMh M range, clamped to the slider's range and snapped to its step of 5.
    static func jmhMaxM(in defaults: UserDefaults = .standard) -> Float {
        guard defaults.object(forKey: TristimulatorDefaults.scopeJmhMaxM) != nil else { return jmhMaxMDefault }
        let v = defaults.float(forKey: TristimulatorDefaults.scopeJmhMaxM)
        guard v.isFinite else { return jmhMaxMDefault }
        let snapped = (v / 5).rounded() * 5
        return min(max(snapped, jmhMaxMRange.lowerBound), jmhMaxMRange.upperBound)
    }

    static func setJmhMaxM(_ value: Float, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: TristimulatorDefaults.scopeJmhMaxM)
    }
}
