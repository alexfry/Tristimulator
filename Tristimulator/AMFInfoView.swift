//
//  AMFInfoView.swift
//  Tristimulator
//
//  Displays the contents of an ACES Metadata File sidecar.
//

import SwiftUI

// MARK: - Main view

struct AMFInfoView: View {
    let amf: ACESMetadataFile
    /// OCIO config used to resolve which AMF stages Tristimulator can actually apply.
    /// When nil, badges fall back to the AMF's own `applied` (baked) flag.
    var config: OCIOConfig? = nil
    /// When provided, badges reflect the live Look-node toggle state (enabled looks show
    /// "Applied", disabled ones "Off"), keeping the popover in sync with the node.
    var imageManager: ImageManager? = nil

    private var status: AMFApplicationStatus? {
        if let mgr = imageManager, let s = mgr.effectiveAMFStatus(for: amf) { return s }
        let cfg = config ?? imageManager?.ocioConfig
        return cfg.map { AMFOCIOPipelineBuilder.applicationStatus(for: amf, config: $0) }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // ── Clip ─────────────────────────────────────────────────────
                if let clip = amf.clipId {
                    AMFNodeView(title: "Clip", systemImage: "film") {
                        AMFClipSection(clip: clip)
                    }
                }

                // ── Active pipeline ───────────────────────────────────────────
                if let pipeline = amf.pipeline {
                    AMFPipelineSection(pipeline: pipeline, status: status)
                }

                // ── Archived pipelines ────────────────────────────────────────
                if !amf.archivedPipelines.isEmpty {
                    AMFArchivedSection(pipelines: amf.archivedPipelines)
                }

                // ── File info ─────────────────────────────────────────────────
                AMFNodeView(title: "AMF File", systemImage: "doc.text") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let desc = amf.description {
                            AMFMetaRow(label: "Description", value: desc)
                        }
                        if let author = amf.author {
                            if let name = author.name { AMFMetaRow(label: "Author", value: name) }
                            if let email = author.emailAddress { AMFMetaRow(label: "Email", value: email) }
                        }
                        if let uuid = amf.uuid { AMFMetaRow(label: "UUID", value: shortUUID(uuid)) }
                        AMFMetaRow(label: "File", value: amf.sourceURL.lastPathComponent)
                    }
                }
            }
            .padding(.bottom)
        }
    }
}

// MARK: - Clip section

private struct AMFClipSection: View {
    let clip: AMFClipId
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = clip.clipName { AMFMetaRow(label: "Name", value: name) }
            if let seq  = clip.sequencePattern { AMFMetaRow(label: "Sequence", value: seq) }
            if let uri  = clip.fileURI { AMFMetaRow(label: "URI", value: uri) }
            if let uuid = clip.uuid { AMFMetaRow(label: "UUID", value: shortUUID(uuid)) }
        }
    }
}

// MARK: - Pipeline section

private struct AMFPipelineSection: View {
    let pipeline: AMFPipeline
    var isArchived: Bool = false
    /// Tristimulator's per-stage application status (nil for archived pipelines or when
    /// no OCIO config is available — falls back to the AMF baked flag).
    var status: AMFApplicationStatus? = nil

    /// Status to show for a stage: prefer the computed status, else derive a baked /
    /// not-baked indication from the AMF's own `applied` flag.
    private func stageStatus(_ computed: AMFStageStatus?, fallbackApplied: Bool) -> AMFStageStatus {
        computed ?? (fallbackApplied ? .bakedIntoSource : .deferredToDisplay)
    }

    var body: some View {
        Group {
            // ── Input Transform ───────────────────────────────────────────
            if let input = pipeline.inputTransform {
                AMFConnector()
                AMFNodeView(
                    title: "Input Transform",
                    systemImage: "camera",
                    status: stageStatus(status?.input, fallbackApplied: input.applied)
                ) {
                    AMFTransformBody(
                        id: input.transformId,
                        description: input.description
                    )
                }
            }

            // ── Look Transforms ───────────────────────────────────────────
            ForEach(Array(pipeline.lookTransforms.enumerated()), id: \.offset) { idx, look in
                AMFConnector()
                AMFNodeView(
                    title: "Look Transform",
                    systemImage: "wand.and.stars",
                    status: stageStatus(status?.looks.indices.contains(idx) == true ? status?.looks[idx] : nil,
                                        fallbackApplied: look.applied)
                ) {
                    AMFLookBody(look: look)
                }
            }

            // ── Output Transform ──────────────────────────────────────────
            if let output = pipeline.outputTransform {
                AMFConnector()
                AMFNodeView(
                    title: "Output Transform",
                    systemImage: "display",
                    status: stageStatus(status?.output, fallbackApplied: output.applied)
                ) {
                    AMFOutputBody(output: output)
                }
            }

            // ── Pipeline metadata ─────────────────────────────────────────
            Divider().padding(.horizontal).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if let ver = pipeline.systemVersion {
                        Text("ACES system v\(ver)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let uuid = pipeline.uuid {
                        Text(shortUUID(uuid))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let author = pipeline.author, let name = author.name {
                    Text("by \(name)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let wl = pipeline.workingLocation, !wl.isEmpty {
                    Text("Working space: \(humanReadableTransformId(wl))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Archived pipelines

private struct AMFArchivedSection: View {
    let pipelines: [AMFPipeline]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Archived Pipelines (\(pipelines.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(Array(pipelines.enumerated()), id: \.offset) { idx, pipeline in
                    Divider().padding(.horizontal)
                    Text("Archive \(idx + 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 6)
                    AMFPipelineSection(pipeline: pipeline, isArchived: true)
                }
            }
        }
    }
}

// MARK: - Transform body helpers

private struct AMFTransformBody: View {
    let id: String?
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let desc = description {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            if let rawId = id {
                Text(humanReadableTransformId(rawId))
                    .font(.caption.monospaced())
                    .foregroundStyle(description != nil ? .secondary : .primary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Detailed body for one AMF look transform (id/CLF reference, parsed CLF operators,
/// embedded CDL). Shared by the AMF popover and the Look Transforms node's disclosure.
struct AMFLookBody: View {
    let look: AMFLookTransform

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Transform ID or CLF file reference
            if let id = look.transformId {
                AMFTransformBody(id: id, description: look.description)
            } else if let file = look.clfFile {
                VStack(alignment: .leading, spacing: 2) {
                    if let desc = look.description {
                        Text(desc).font(.caption).foregroundStyle(.primary)
                    }
                    Label(file, systemImage: "doc.text")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Parsed CLF content
            if let clf = look.clf {
                Divider()
                CLFOperatorsView(clf: clf)
            }

            // Inline CDL (embedded directly in AMF, not via CLF)
            if let cdl = look.cdl {
                Divider()
                AMFCDLView(cdl: cdl, workingSpaceId: look.cdlWorkingSpaceId)
            }
        }
    }
}

private struct AMFOutputBody: View {
    let output: AMFOutputTransform

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let desc = output.description {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            // Combined RRTODT
            if let id = output.rrtodtTransformId {
                Text(humanReadableTransformId(id))
                    .font(.caption.monospaced())
                    .foregroundStyle(output.description != nil ? .secondary : .primary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            // Separate RRT + ODT
            if let rrt = output.rrtTransformId {
                AMFMetaRow(label: "RRT", value: humanReadableTransformId(rrt))
            }
            if let odt = output.odtTransformId {
                AMFMetaRow(label: "ODT", value: humanReadableTransformId(odt))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - CDL display

private struct AMFCDLView: View {
    let cdl: AMFCDL
    let workingSpaceId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ASC CDL")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    Text("Slope").font(.caption2).foregroundStyle(.secondary)
                    cdlTripleText(cdl.slope)
                }
                GridRow {
                    Text("Offset").font(.caption2).foregroundStyle(.secondary)
                    cdlTripleText(cdl.offset)
                }
                GridRow {
                    Text("Power").font(.caption2).foregroundStyle(.secondary)
                    cdlTripleText(cdl.power)
                }
                GridRow {
                    Text("Sat").font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "%.4g", cdl.saturation))
                        .font(.caption2.monospaced())
                }
            }

            if let wsId = workingSpaceId {
                Text("Working space: \(humanReadableTransformId(wsId))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private func cdlTripleText(_ v: SIMD3<Double>) -> some View {
        Text(String(format: "%.4g  %.4g  %.4g", v.x, v.y, v.z))
            .font(.caption2.monospaced())
    }
}

// MARK: - Structural helpers

private struct AMFNodeView<Content: View>: View {
    let title: String
    let systemImage: String
    var status: AMFStageStatus? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let status = status {
                    AMFStageStatusBadge(status: status)
                }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }
}

private struct AMFConnector: View {
    var body: some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(.secondary.opacity(0.4))
                .frame(width: 2, height: 10)
            Image(systemName: "arrow.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(.secondary.opacity(0.4))
                .frame(width: 2, height: 10)
        }
        .frame(height: 30)
    }
}

/// Compact badge for an AMF pipeline stage's application status. Shared by the AMF
/// popover (`AMFInfoView`) and the integrated Color Pipeline node graph.
struct AMFStageStatusBadge: View {
    let status: AMFStageStatus

    private var label: String {
        switch status {
        case .applied:          return "Applied"
        case .bakedIntoSource:  return "Baked in"
        case .deferredToDisplay: return "Applied (display)"
        case .skipped:          return "Skipped"
        case .disabled:         return "Off"
        }
    }

    private var systemImage: String {
        switch status {
        case .applied:           return "checkmark.circle.fill"
        case .bakedIntoSource:   return "lock.circle.fill"
        case .deferredToDisplay: return "checkmark.circle"
        case .skipped:           return "exclamationmark.triangle.fill"
        case .disabled:          return "circle"
        }
    }

    private var tint: Color {
        switch status {
        case .applied, .deferredToDisplay: return .green
        case .bakedIntoSource:             return .secondary
        case .skipped:                     return .orange
        case .disabled:                    return .secondary
        }
    }

    private var help: String {
        switch status {
        case .applied:           return "Tristimulator applies this stage in the look pipeline."
        case .bakedIntoSource:   return "Already baked into the source pixels by the authoring tool; not re-applied."
        case .deferredToDisplay: return "Applied as part of the display/view (output) pass."
        case .skipped(let why):  return why
        case .disabled:          return "Resolvable, but currently disabled in the Look Transforms node."
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .help(help)
    }
}

private struct AMFMetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label + ":")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - CLF operator display

struct CLFOperatorsView: View {
    let clf: CLFDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // CLF header
            HStack(spacing: 4) {
                Image(systemName: "lasso.and.sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(clf.name ?? clf.id ?? clf.sourceURL.lastPathComponent)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let v = clf.clfVersion {
                    Text("CLF v\(v)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !clf.descriptions.isEmpty {
                Text(clf.descriptions.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            ForEach(Array(clf.operators.enumerated()), id: \.offset) { _, op in
                CLFOperatorRow(op: op)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CLFOperatorRow: View {
    let op: CLFOperator
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(op.typeName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let desc = op.description {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let id = op.id {
                        Text(id)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded {
                CLFOperatorDetail(op: op)
                    .padding(.leading, 14)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct CLFOperatorDetail: View {
    let op: CLFOperator

    var body: some View {
        switch op {
        case .cdl(let o):       CDLDetail(op: o)
        case .lut1d(let o):     LUTDetail(op: o)
        case .lut3d(let o):     LUTDetail(op: o)
        case .matrix(let o):    MatrixDetail(op: o)
        case .log(let o):       LogDetail(op: o)
        case .exponent(let o):  ExponentDetail(op: o)
        case .range(let o):     RangeDetail(op: o)
        case .reference(let o): ReferenceDetail(op: o)
        case .unknown:          EmptyView()
        }
    }

    // CDL
    private struct CDLDetail: View {
        let op: CLFCDLOp
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                if let style = op.style { clfRow("Style", style) }
                bitDepthRow(op.inBitDepth, op.outBitDepth)
                Divider().padding(.vertical, 2)
                clfTriple("Slope",  op.slope)
                clfTriple("Offset", op.offset)
                clfTriple("Power",  op.power)
                clfRow("Sat", String(format: "%.6g", op.saturation))
            }
        }
    }

    // LUT
    private struct LUTDetail: View {
        let op: CLFLUTOp
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                bitDepthRow(op.inBitDepth, op.outBitDepth)
                if let interp = op.interpolation { clfRow("Interpolation", interp) }
                if let s3 = op.size3 {
                    clfRow("Size", "\(s3.x) × \(s3.y) × \(s3.z)")
                } else if let s = op.size {
                    clfRow("Size", "\(s)")
                }
                if op.halfDomain { clfRow("Half domain", "yes") }
            }
        }
    }

    // Matrix
    private struct MatrixDetail: View {
        let op: CLFMatrixOp
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                bitDepthRow(op.inBitDepth, op.outBitDepth)
                clfRow("Dimensions", "\(op.dim.rows)×\(op.dim.cols)")
                if !op.values.isEmpty {
                    Text(matrixString(op.values, rows: op.dim.rows, cols: op.dim.cols))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }
        }

        private func matrixString(_ v: [Double], rows: Int, cols: Int) -> String {
            var lines: [String] = []
            for r in 0..<rows {
                let row = (0..<cols).compactMap { c -> String? in
                    let i = r * cols + c
                    guard i < v.count else { return nil }
                    return String(format: "%9.6f", v[i])
                }
                lines.append("[ " + row.joined(separator: "  ") + " ]")
            }
            return lines.joined(separator: "\n")
        }
    }

    // Log
    private struct LogDetail: View {
        let op: CLFLogOp
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                if let style = op.style { clfRow("Style", style) }
                bitDepthRow(op.inBitDepth, op.outBitDepth)
                ForEach(Array(op.params.enumerated()), id: \.offset) { _, p in
                    let ch = p.channel ?? "RGB"
                    if let b = p.base           { clfRow("\(ch) base",     String(format: "%.4g", b)) }
                    if let v = p.logSideSlope   { clfRow("\(ch) logSlope", String(format: "%.6g", v)) }
                    if let v = p.logSideOffset  { clfRow("\(ch) logOffset",String(format: "%.6g", v)) }
                    if let v = p.linSideSlope   { clfRow("\(ch) linSlope", String(format: "%.6g", v)) }
                    if let v = p.linSideOffset  { clfRow("\(ch) linOffset",String(format: "%.6g", v)) }
                    if let v = p.linearSlope    { clfRow("\(ch) linSlope", String(format: "%.6g", v)) }
                    if let v = p.linBreak       { clfRow("\(ch) linBreak", String(format: "%.6g", v)) }
                    if let v = p.logBreak       { clfRow("\(ch) logBreak", String(format: "%.6g", v)) }
                }
            }
        }
    }

    // Exponent
    private struct ExponentDetail: View {
        let op: CLFExponentOp
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                if let style = op.style { clfRow("Style", style) }
                bitDepthRow(op.inBitDepth, op.outBitDepth)
                ForEach(Array(op.params.enumerated()), id: \.offset) { _, p in
                    let ch = p.channel ?? "RGB"
                    if let v = p.exponent    { clfRow("\(ch) exponent",    String(format: "%.6g", v)) }
                    if let v = p.gamma       { clfRow("\(ch) gamma",       String(format: "%.6g", v)) }
                    if let v = p.offset      { clfRow("\(ch) offset",      String(format: "%.6g", v)) }
                    if let v = p.linearSlope { clfRow("\(ch) linearSlope", String(format: "%.6g", v)) }
                }
            }
        }
    }

    // Range
    private struct RangeDetail: View {
        let op: CLFRangeOp
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                if let style = op.style { clfRow("Style", style) }
                bitDepthRow(op.inBitDepth, op.outBitDepth)
                if let v = op.minInValue  { clfRow("minIn",  String(format: "%.6g", v)) }
                if let v = op.maxInValue  { clfRow("maxIn",  String(format: "%.6g", v)) }
                if let v = op.minOutValue { clfRow("minOut", String(format: "%.6g", v)) }
                if let v = op.maxOutValue { clfRow("maxOut", String(format: "%.6g", v)) }
            }
        }
    }

    // Reference
    private struct ReferenceDetail: View {
        let op: CLFReferenceOp
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                if let style = op.style { clfRow("Style", style) }
                if let path  = op.path  { clfRow("Path",  path) }
                ForEach(op.aliases, id: \.self) { alias in
                    clfRow("Alias", alias)
                }
            }
        }
    }

    // Shared helpers (free functions captured by nested structs)
    fileprivate static func clfRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label + ":")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .trailing)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    fileprivate static func clfTriple(_ label: String, _ v: SIMD3<Double>) -> some View {
        clfRow(label, String(format: "%.6g  %.6g  %.6g", v.x, v.y, v.z))
    }

    fileprivate static func bitDepthRow(_ inBD: String?, _ outBD: String?) -> some View {
        Group {
            if let i = inBD, let o = outBD {
                clfRow("Bit depth", "\(i) → \(o)")
            }
        }
    }
}

// Free function wrappers so nested structs can call them without CLFOperatorDetail. prefix
private func clfRow(_ label: String, _ value: String) -> some View {
    CLFOperatorDetail.clfRow(label, value)
}
private func clfTriple(_ label: String, _ v: SIMD3<Double>) -> some View {
    CLFOperatorDetail.clfTriple(label, v)
}
private func bitDepthRow(_ i: String?, _ o: String?) -> some View {
    CLFOperatorDetail.bitDepthRow(i, o)
}

// MARK: - Utility

/// Strips the URN prefix and returns just the meaningful identifier portion.
/// e.g. "urn:ampas:aces:transformId:v1.5:IDT.ARRI.Alexa.v3.EI800.a1.v1"
///      → "IDT.ARRI.Alexa.v3.EI800.a1.v1"
func humanReadableTransformId(_ id: String) -> String {
    // Strip leading "urn:ampas:aces:transformId:v1.5:" or similar prefix.
    if let lastColon = id.lastIndex(of: ":") {
        let candidate = String(id[id.index(after: lastColon)...])
        if !candidate.isEmpty { return candidate }
    }
    return id
}

private func shortUUID(_ uuid: String) -> String {
    // "urn:uuid:xxxxxxxx-xxxx-..." → "xxxxxxxx-..."
    if uuid.hasPrefix("urn:uuid:") {
        return String(uuid.dropFirst("urn:uuid:".count))
    }
    return uuid
}
