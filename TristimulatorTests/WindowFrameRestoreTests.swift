//
//  WindowFrameRestoreTests.swift
//  TristimulatorTests
//
//  Per-image main window frame: saved with the OCIO settings, tolerant of
//  older/malformed settings, and clamped onto a visible screen on restore.
//

import Testing
import Foundation
import AppKit
@testable import Tristimulator

@Suite("Window frame restore")
struct WindowFrameRestoreTests {
    let main = NSRect(x: 0, y: 0, width: 1512, height: 949)
    let right = NSRect(x: 1512, y: 0, width: 2560, height: 1415)

    @Test func frameInsideScreenIsUnchanged() {
        let f = WindowFrame(NSRect(x: 100, y: 120, width: 900, height: 600))
        #expect(f.clamped(toVisibleFrames: [main]) == f.nsRect)
    }

    @Test func frameHangingOffScreenIsMovedOn() {
        let f = WindowFrame(NSRect(x: 1200, y: 700, width: 900, height: 600))
        let r = f.clamped(toVisibleFrames: [main])
        #expect(r == NSRect(x: 1512 - 900, y: 949 - 600, width: 900, height: 600))
    }

    @Test func frameLargerThanScreenIsShrunk() {
        let f = WindowFrame(NSRect(x: -50, y: -50, width: 3000, height: 2000))
        #expect(f.clamped(toVisibleFrames: [main]) == main)
    }

    @Test func frameOnSecondScreenStaysThere() {
        let f = WindowFrame(NSRect(x: 2000, y: 300, width: 1200, height: 800))
        #expect(f.clamped(toVisibleFrames: [main, right]) == f.nsRect)
    }

    @Test func frameOnDisconnectedScreenMovesToMain() {
        let f = WindowFrame(NSRect(x: 5000, y: 300, width: 1200, height: 800))
        let r = f.clamped(toVisibleFrames: [main])
        #expect(r == NSRect(x: 1512 - 1200, y: 949 - 800, width: 1200, height: 800))
    }

    @Test func degenerateFramesOrNoScreensAreIgnored() {
        #expect(WindowFrame(NSRect(x: 0, y: 0, width: 0, height: 500)).clamped(toVisibleFrames: [main]) == nil)
        #expect(WindowFrame(NSRect(x: 10, y: 10, width: 500, height: 500)).clamped(toVisibleFrames: []) == nil)
    }

    @Test func windowFrameRoundTripsInSettings() throws {
        let frame = WindowFrame(NSRect(x: 40, y: 60, width: 1100, height: 720))
        let s = OCIOPipelineSettings(sourceSpace: "ACEScg", windowFrame: frame)
        let decoded = try JSONDecoder().decode(OCIOPipelineSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.windowFrame == frame)
    }

    @Test func settingsWithoutWindowFrameStillDecode() throws {
        let data = try JSONEncoder().encode(OCIOPipelineSettings(sourceSpace: "ACEScg"))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "windowFrame")
        let decoded = try JSONDecoder().decode(OCIOPipelineSettings.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.sourceSpace == "ACEScg")
        #expect(decoded.windowFrame == nil)
    }

    @Test func malformedWindowFrameDoesNotLoseColourSettings() throws {
        let data = try JSONEncoder().encode(OCIOPipelineSettings(sourceSpace: "ACEScg"))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["windowFrame"] = ["x": "wide"]
        let decoded = try JSONDecoder().decode(OCIOPipelineSettings.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.sourceSpace == "ACEScg")
        #expect(decoded.windowFrame == nil)
    }
}
