//
//  CLFParserTests.swift
//  TristimulatorTests
//
//  Verifies CLFParser correctly parses every operator type in the ACES CLF test suite.
//  No OCIO dependency — pure data-model assertions.
//

import Testing
import Foundation
@testable import Tristimulator

// MARK: - Fixtures

private var clfFixturesDir: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CLF")
}

private func clfURL(_ name: String) -> URL {
    clfFixturesDir.appendingPathComponent(name + ".clf")
}

// MARK: - Tests

@Suite("CLF Parser")
struct CLFParserTests {

    // MARK: CDL

    @Test func cdlAllStyles() throws {
        let doc = try CLFParser.parse(url: clfURL("cdl_all_styles"))
        #expect(doc.clfVersion == "3.0")
        #expect(doc.operators.count == 4)

        guard case .cdl(let first) = doc.operators[0] else {
            Issue.record("Expected CDL op"); return
        }
        #expect(first.style == "Fwd")
        #expect(first.inBitDepth == "16f")
        #expect(first.outBitDepth == "10i")
        #expect(first.slope.z ≈ 0.8)
        #expect(first.offset.x ≈ -0.02)
        #expect(first.power.x ≈ 1.05)
        #expect(first.saturation ≈ 0.75)

        guard case .cdl(let rev) = doc.operators[1] else {
            Issue.record("Expected CDL op"); return
        }
        #expect(rev.style == "Rev")

        guard case .cdl(let fwdNoClamp) = doc.operators[2] else {
            Issue.record("Expected CDL op"); return
        }
        #expect(fwdNoClamp.style == "FwdNoClamp")
    }

    // MARK: LUT 1D

    @Test func lut1dExample() throws {
        let doc = try CLFParser.parse(url: clfURL("lut1d_example"))
        #expect(doc.operators.count == 1)

        guard case .lut1d(let lut) = doc.operators[0] else {
            Issue.record("Expected LUT1D op"); return
        }
        #expect(lut.dimensions == 1)
        #expect(lut.size == 65)
        #expect(lut.inBitDepth == "8i")
        #expect(lut.outBitDepth == "12i")
        #expect(lut.halfDomain == false)
    }

    // MARK: Log

    @Test func logAllStyles() throws {
        let doc = try CLFParser.parse(url: clfURL("log_all_styles"))
        let logOps = doc.operators.filter {
            if case .log = $0 { return true }; return false
        }
        #expect(logOps.count == 10)

        guard case .log(let first) = doc.operators[0] else {
            Issue.record("Expected Log op"); return
        }
        #expect(first.style == "antiLog2")
        #expect(first.inBitDepth == "16f")

        // linToLog with params
        guard case .log(let linToLog) = doc.operators[2] else {
            Issue.record("Expected Log op"); return
        }
        #expect(linToLog.style == "linToLog")
        #expect(linToLog.params.count == 1)
        #expect(linToLog.params[0].logSideSlope ≈ 0.29325513196)
        #expect(linToLog.params[0].base ≈ 10.0)

        // Per-channel params
        guard case .log(let perChannel) = doc.operators[9] else {
            Issue.record("Expected Log op"); return
        }
        #expect(perChannel.params.count == 3)
        #expect(perChannel.params[0].channel == "R")
        #expect(perChannel.params[1].channel == "G")
        #expect(perChannel.params[2].channel == "B")
    }

    // MARK: Exponent

    @Test func exponentAllStyles() throws {
        let doc = try CLFParser.parse(url: clfURL("exponent_all_styles"))
        let expOps = doc.operators.filter {
            if case .exponent = $0 { return true }; return false
        }
        #expect(expOps.count == 11)

        guard case .exponent(let basicFwd) = doc.operators[0] else {
            Issue.record("Expected Exponent op"); return
        }
        #expect(basicFwd.style == "basicFwd")
        #expect(basicFwd.params.count == 1)
        #expect(basicFwd.params[0].exponent ≈ 2.4)

        guard case .exponent(let basicRev) = doc.operators[1] else {
            Issue.record("Expected Exponent op"); return
        }
        #expect(basicRev.style == "basicRev")
        #expect(basicRev.params.count == 3)
        #expect(basicRev.params[0].channel == "R")

        guard case .exponent(let moncurve) = doc.operators[2] else {
            Issue.record("Expected Exponent op"); return
        }
        #expect(moncurve.style == "monCurveFwd")
        #expect(moncurve.params[0].offset ≈ 0.099)
    }

    // MARK: Range

    @Test func rangeParsed() throws {
        let doc = try CLFParser.parse(url: clfURL("range"))
        #expect(doc.operators.count == 1)

        guard case .range(let r) = doc.operators[0] else {
            Issue.record("Expected Range op"); return
        }
        #expect(r.style == nil)   // no style = clamp
        #expect(r.inBitDepth == "16i")
        #expect(r.minInValue ≈ 16320)
        #expect(r.maxInValue ≈ 32640)
        #expect(r.minOutValue ≈ 16320)
        #expect(r.maxOutValue ≈ 32640)

        #expect(doc.inputDescriptors == ["RGB"])
        #expect(doc.outputDescriptors == ["RGB"])
    }

    // MARK: Matrix

    @Test func matrix3x4() throws {
        let doc = try CLFParser.parse(url: clfURL("matrix_3x4_example"))
        #expect(doc.operators.count == 1)

        guard case .matrix(let m) = doc.operators[0] else {
            Issue.record("Expected Matrix op"); return
        }
        #expect(m.dim.rows == 3)
        #expect(m.dim.cols == 4)
        #expect(m.values.count == 12)
        #expect(m.values[0] ≈ 3.6)
        #expect(m.values[3] ≈ 0.3)   // offset column
        #expect(m.inBitDepth == "10i")
        #expect(m.outBitDepth == "12i")
    }

    @Test func matrixUtf8() throws {
        let doc = try CLFParser.parse(url: clfURL("matrix_example_utf8"))
        #expect(doc.operators.count == 1)

        guard case .matrix(let m) = doc.operators[0] else {
            Issue.record("Expected Matrix op"); return
        }
        #expect(m.dim.rows == 3)
        #expect(m.dim.cols == 3)
        #expect(m.values.count == 9)
        #expect(m.values[0] ≈ 0.66067963)
        #expect(m.inBitDepth == "32f")
    }

    // MARK: Multiple ops

    @Test func multipleOps() throws {
        let doc = try CLFParser.parse(url: clfURL("multiple_ops"))
        // CDL, LUT1D, Range, Range, Range, Log, Matrix, Exponent, LUT3D
        #expect(doc.operators.count == 9)

        guard case .cdl = doc.operators[0] else { Issue.record("op 0 not CDL"); return }
        guard case .lut1d = doc.operators[1] else { Issue.record("op 1 not LUT1D"); return }
        guard case .range = doc.operators[2] else { Issue.record("op 2 not Range"); return }
        guard case .range = doc.operators[3] else { Issue.record("op 3 not Range"); return }
        guard case .range = doc.operators[4] else { Issue.record("op 4 not Range"); return }
        guard case .log = doc.operators[5] else { Issue.record("op 5 not Log"); return }
        guard case .matrix = doc.operators[6] else { Issue.record("op 6 not Matrix"); return }
        guard case .exponent = doc.operators[7] else { Issue.record("op 7 not Exponent"); return }
        guard case .lut3d = doc.operators[8] else { Issue.record("op 8 not LUT3D"); return }
    }

    // MARK: Error handling

    @Test func invalidXMLThrows() throws {
        let badURL = URL(fileURLWithPath: NSTemporaryDirectory() + "bad_\(Int.random(in: 1000...9999)).clf")
        try "not xml at all <<>>".write(to: badURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: badURL) }
        #expect(throws: CLFParseError.self) {
            try CLFParser.parse(url: badURL)
        }
    }

    @Test func wrongRootElementThrows() throws {
        let badURL = URL(fileURLWithPath: NSTemporaryDirectory() + "wrongroot_\(Int.random(in: 1000...9999)).clf")
        try "<?xml version=\"1.0\"?><NotAProcessList/>".write(to: badURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: badURL) }
        #expect(throws: CLFParseError.self) {
            try CLFParser.parse(url: badURL)
        }
    }
}

// MARK: - Approx equality helper

infix operator ≈: ComparisonPrecedence
private func ≈ (lhs: Double?, rhs: Double) -> Bool {
    guard let lhs else { return false }
    return abs(lhs - rhs) < 1e-6
}
private func ≈ (lhs: Double, rhs: Double) -> Bool {
    abs(lhs - rhs) < 1e-6
}
