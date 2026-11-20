//
//  AMFParserTests.swift
//  TristimulatorTests
//
//  Verifies ACESAMFParser correctly parses the AMF data model from inline XML.
//  No OCIO dependency — pure data-model assertions.
//

import Testing
import Foundation
@testable import Tristimulator

// MARK: - Helpers

/// Write `xml` to a temp file, parse it with ACESAMFParser, and return the result.
private func parseAMF(_ xml: String, clfDir: URL? = nil) throws -> ACESMetadataFile {
    let dir   = clfDir ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let url   = dir.appendingPathComponent("test_\(Int.random(in: 1_000...9_999)).amf")
    try xml.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    return try ACESAMFParser.parse(url: url)
}

// MARK: - Fixtures

private let minimalAMF = """
<?xml version="1.0" encoding="UTF-8"?>
<acesMetadataFile xmlns="urn:ampas:aces:amf:v2.0">
  <amfInfo>
    <uuid>test-uuid-1234</uuid>
    <description>Minimal test AMF</description>
    <dateTime>
      <creationDateTime>2025-01-01T00:00:00</creationDateTime>
    </dateTime>
  </amfInfo>
</acesMetadataFile>
"""

private let amfWithCLFLook = """
<?xml version="1.0" encoding="UTF-8"?>
<acesMetadataFile xmlns="urn:ampas:aces:amf:v2.0">
  <amfInfo>
    <uuid>clf-look-uuid</uuid>
  </amfInfo>
  <pipeline>
    <inputTransform applied="false">
      <transformId>urn:ampas:aces:transformId:v2.0:IDT.ARRI.Alexa35_LogC4.a2.v1</transformId>
    </inputTransform>
    <lookTransform applied="false">
      <transformId>urn:ampas:aces:transformId:v2.0:Look.Academy.ReferenceGamutCompress.a2.v1</transformId>
      <file>grade.clf</file>
    </lookTransform>
    <lookTransform applied="true">
      <transformId>already-applied-look</transformId>
      <file>baked.clf</file>
    </lookTransform>
    <outputTransform applied="false">
      <transformId>urn:ampas:aces:transformId:v2.0:Output.Academy.P3-D65_1000nit_in_P3-D65_ST2084.a2.v1</transformId>
    </outputTransform>
  </pipeline>
</acesMetadataFile>
"""

private let amfWithEmbeddedCDL = """
<?xml version="1.0" encoding="UTF-8"?>
<acesMetadataFile xmlns="urn:ampas:aces:amf:v2.0">
  <amfInfo><uuid>cdl-uuid</uuid></amfInfo>
  <pipeline>
    <lookTransform applied="false">
      <transformId>cdl-look-1</transformId>
      <SOPNode>
        <Slope>1.1 0.9 1.0</Slope>
        <Offset>0.02 -0.01 0.0</Offset>
        <Power>1.0 1.0 1.0</Power>
      </SOPNode>
      <SatNode>
        <Saturation>0.85</Saturation>
      </SatNode>
    </lookTransform>
  </pipeline>
</acesMetadataFile>
"""

private let amfWithWorkingLocation = """
<?xml version="1.0" encoding="UTF-8"?>
<acesMetadataFile xmlns="urn:ampas:aces:amf:v2.0">
  <amfInfo><uuid>wl-uuid</uuid></amfInfo>
  <pipeline>
    <workingLocation>urn:ampas:aces:transformId:v2.0:CSC.Academy.ACES_to_ACEScct.a1.v1</workingLocation>
    <lookTransform applied="false">
      <transformId>look-in-acescct</transformId>
      <file>grade.clf</file>
    </lookTransform>
  </pipeline>
</acesMetadataFile>
"""

private let amfWithArchivedPipeline = """
<?xml version="1.0" encoding="UTF-8"?>
<acesMetadataFile xmlns="urn:ampas:aces:amf:v2.0">
  <amfInfo><uuid>arch-uuid</uuid></amfInfo>
  <pipeline>
    <lookTransform applied="false">
      <transformId>current-look</transformId>
    </lookTransform>
  </pipeline>
  <archivedPipeline>
    <lookTransform applied="true">
      <transformId>old-look</transformId>
    </lookTransform>
  </archivedPipeline>
</acesMetadataFile>
"""

// MARK: - Tests

@Suite("AMF Parser")
struct AMFParserTests {

    // MARK: Minimal

    @Test func minimalParses() throws {
        let amf = try parseAMF(minimalAMF)
        #expect(amf.uuid == "test-uuid-1234")
        #expect(amf.description == "Minimal test AMF")
        #expect(amf.creationDateTime == "2025-01-01T00:00:00")
        #expect(amf.pipeline == nil)
        #expect(amf.archivedPipelines.isEmpty)
    }

    // MARK: Look transforms with CLF reference

    @Test func clfLookTransforms() throws {
        let amf = try parseAMF(amfWithCLFLook)
        let pipeline = try #require(amf.pipeline)

        // IDT
        let idt = try #require(pipeline.inputTransform)
        #expect(idt.applied == false)
        #expect(idt.transformId?.contains("ARRI") == true)

        // Looks — two total
        #expect(pipeline.lookTransforms.count == 2)

        let unapplied = pipeline.lookTransforms.filter { !$0.applied }
        let applied   = pipeline.lookTransforms.filter {  $0.applied }
        #expect(unapplied.count == 1)
        #expect(applied.count   == 1)

        #expect(unapplied[0].clfFile == "grade.clf")
        #expect(unapplied[0].transformId?.contains("ReferenceGamutCompress") == true)

        // Output transform
        let output = try #require(pipeline.outputTransform)
        #expect(output.applied == false)
        #expect(output.rrtodtTransformId?.contains("P3-D65") == true)
    }

    // MARK: Embedded CDL

    @Test func embeddedCDL() throws {
        let amf = try parseAMF(amfWithEmbeddedCDL)
        let pipeline = try #require(amf.pipeline)
        #expect(pipeline.lookTransforms.count == 1)

        let look = pipeline.lookTransforms[0]
        #expect(look.applied == false)
        #expect(look.clfFile == nil)

        let cdl = try #require(look.cdl)
        #expect(abs(cdl.slope.x - 1.1) < 1e-6)
        #expect(abs(cdl.slope.y - 0.9) < 1e-6)
        #expect(abs(cdl.offset.x - 0.02) < 1e-6)
        #expect(abs(cdl.power.x - 1.0) < 1e-6)
        #expect(abs(cdl.saturation - 0.85) < 1e-6)
    }

    // MARK: Working location

    @Test func workingLocation() throws {
        let amf = try parseAMF(amfWithWorkingLocation)
        let pipeline = try #require(amf.pipeline)
        let wl = try #require(pipeline.workingLocation)
        #expect(wl.contains("ACEScct"))
    }

    // MARK: Archived pipeline

    @Test func archivedPipeline() throws {
        let amf = try parseAMF(amfWithArchivedPipeline)
        let pipeline = try #require(amf.pipeline)
        #expect(pipeline.lookTransforms.count == 1)
        #expect(pipeline.lookTransforms[0].transformId == "current-look")

        #expect(amf.archivedPipelines.count == 1)
        let archived = amf.archivedPipelines[0]
        #expect(archived.lookTransforms[0].applied == true)
        #expect(archived.lookTransforms[0].transformId == "old-look")
    }

    // MARK: Applied-flag filtering (mirrors AMFOCIOPipelineBuilder logic)

    @Test func appliedFlagFiltering() throws {
        let amf = try parseAMF(amfWithCLFLook)
        let pipeline = try #require(amf.pipeline)

        // Only unapplied looks should be fed to the OCIO pipeline
        let toProcess = pipeline.lookTransforms.filter { !$0.applied }
        #expect(toProcess.count == 1)
        #expect(toProcess[0].clfFile == "grade.clf")
    }

    // MARK: Error handling

    @Test func notAnAMFFileThrows() {
        #expect(throws: AMFParseError.self) {
            try parseAMF("<?xml version=\"1.0\"?><notAmf/>")
        }
    }

    @Test func invalidXMLThrows() {
        #expect(throws: AMFParseError.self) {
            try parseAMF("this is not xml <<>>")
        }
    }
}
