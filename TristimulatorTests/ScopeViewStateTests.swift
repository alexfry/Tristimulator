//
//  ScopeViewStateTests.swift
//  TristimulatorTests
//
//  App-wide scope view state: 2D/3D mode, 3D camera and JMh M range
//  round-trip through UserDefaults and are clamped on load.
//

import Testing
import Foundation
@testable import Tristimulator

@Suite("Scope view state")
struct ScopeViewStateTests {
    /// A throwaway defaults domain so tests never touch the app's settings.
    func freshDefaults() -> UserDefaults {
        let name = "ScopeViewStateTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func keysAreDistinctAndDotFree() {
        let keys = ScopeKind.allCases.flatMap {
            [TristimulatorDefaults.scopeIs3D($0), TristimulatorDefaults.scope3DCamera($0)]
        } + [TristimulatorDefaults.scopeJmhMaxM]
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { !$0.contains(".") })
        #expect(TristimulatorDefaults.scopeIs3D(.yxy) == "ScopeIs3DYxy")
        #expect(TristimulatorDefaults.scope3DCamera(.jmh) == "Scope3DCameraJmh")
    }

    @Test func modeDefaultsTo2DAndRoundTripsPerScope() {
        let d = freshDefaults()
        #expect(ScopeKind.allCases.allSatisfy { !ScopeViewDefaults.is3D($0, in: d) })
        ScopeViewDefaults.setIs3D(true, for: .uv, in: d)
        #expect(ScopeViewDefaults.is3D(.uv, in: d))
        #expect(!ScopeViewDefaults.is3D(.yxy, in: d))
        #expect(!ScopeViewDefaults.is3D(.jmh, in: d))
    }

    @Test func cameraRoundTripsPerScope() {
        let d = freshDefaults()
        #expect(ScopeViewDefaults.camera(.yxy, in: d) == .default)
        let cam = Scope3DCamera(yaw: -1.2, pitch: 0.8, distance: 5.5, targetX: 0.3, targetY: -0.2, targetZ: 0.1)
        ScopeViewDefaults.setCamera(cam, for: .jmh, in: d)
        #expect(ScopeViewDefaults.camera(.jmh, in: d) == cam)
        #expect(ScopeViewDefaults.camera(.yxy, in: d) == .default)
    }

    @Test func cameraIsClampedOnLoad() {
        let d = freshDefaults()
        let wild = Scope3DCamera(yaw: 7 * .pi, pitch: 3, distance: 50, targetX: 10, targetY: 0, targetZ: 0)
        let json = try! JSONEncoder().encode(wild)
        d.set(json, forKey: TristimulatorDefaults.scope3DCamera(.uv))
        let c = ScopeViewDefaults.camera(.uv, in: d)
        #expect(c.pitch == Scope3DCamera.pitchLimit)
        #expect(c.distance == Scope3DCamera.distanceRange.upperBound)
        #expect(abs(c.targetX - Scope3DCamera.maxPan) < 1e-4)
        #expect(c.yaw > -.pi - 1e-4 && c.yaw <= .pi + 1e-4)
    }

    @Test func garbageCameraFallsBackToDefault() {
        let d = freshDefaults()
        d.set(Data("not json".utf8), forKey: TristimulatorDefaults.scope3DCamera(.yxy))
        #expect(ScopeViewDefaults.camera(.yxy, in: d) == .default)
        let nan = Scope3DCamera(yaw: .nan, pitch: .infinity, distance: .nan, targetX: .nan, targetY: 0, targetZ: 0)
        #expect(nan.clamped.pitch == Scope3DCamera.pitchLimit || nan.clamped.pitch == Scope3DCamera.default.pitch)
        #expect(nan.clamped.distance == Scope3DCamera.default.distance)
        #expect(nan.clamped.yaw.isFinite && nan.clamped.targetX == 0)
    }

    @Test func jmhMaxMDefaultsRoundTripsAndClamps() {
        let d = freshDefaults()
        #expect(ScopeViewDefaults.jmhMaxM(in: d) == 100)
        ScopeViewDefaults.setJmhMaxM(45, in: d)
        #expect(ScopeViewDefaults.jmhMaxM(in: d) == 45)
        ScopeViewDefaults.setJmhMaxM(999, in: d)
        #expect(ScopeViewDefaults.jmhMaxM(in: d) == 200)
        ScopeViewDefaults.setJmhMaxM(1, in: d)
        #expect(ScopeViewDefaults.jmhMaxM(in: d) == 5)
        ScopeViewDefaults.setJmhMaxM(62, in: d)
        #expect(ScopeViewDefaults.jmhMaxM(in: d) == 60)
    }
}
