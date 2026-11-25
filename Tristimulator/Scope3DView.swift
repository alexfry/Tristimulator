//
//  Scope3DView.swift
//  Tristimulator
//
//  Minimal 3D view for the Yxy and JMh scopes.
//
//  The compute kernels (chromaticityPoints / jmhPoints) write one point per
//  sample in *scope space*:
//      Yxy: (x, log2 Y, y)          — vertical axis in stops, 0 = scene-linear 1.0 (SDR white)
//      JMh: (M·cos h, J, M·sin h)   — vertical axis linear J
//  A per-scope model matrix maps scope space into a ~[-1, 1] world box; the
//  orbit camera's view-projection is folded in and passed to every shader as
//  a single 64-byte float4x4 at buffer(1), updated per frame.
//
//  Markers (locus, gamut triangles, axes, ticks, JMh rings) are built once
//  into a cached line buffer and drawn in the same render pass as thick
//  screen-space quads. Labels are rendered once with Core Text into a small
//  atlas and drawn as camera-facing quads after the geometry, with depth
//  testing off and alpha faded by distance. Both are rebuilt only when the
//  `Scope3DMarkerSpec` (scope kind, colour space, JMh range, vertical scale)
//  or the backing scale changes.
//
//  Interaction (3D mode only; the SwiftUI Canvas overlays are hidden):
//      drag          orbit (yaw / pitch)
//      scroll/pinch  zoom
//      double-click  reset view
//  The scope's own move (title bar) and resize (corner) handles sit outside
//  or above the Metal view, so a plain drag in the diagram area orbits and
//  never moves the overlay; no modifier key is needed.
//

import SwiftUI
import MetalKit
import AppKit
import CoreText
import simd

// MARK: - GPU layouts (must match Scope3D.metal)

enum Scope3DGPU {
    /// Byte stride of one point (float4 position + float4 colour).
    static let pointStride = 32

    struct Line {
        var a: SIMD4<Float>
        var b: SIMD4<Float>
        var color: SIMD4<Float>
        var params: SIMD4<Float>   // x = width in points (scaled to pixels at build)
    }

    struct Label {
        var anchor: SIMD4<Float>
        var color: SIMD4<Float>
        var uvRect: SIMD4<Float>
        var sizeOffset: SIMD4<Float>
    }

    struct ViewUniforms {
        var viewportSize: SIMD2<Float>
        var pointSize: Float
        var cameraDistance: Float
    }
}

// MARK: - Marker spec

/// Everything the cached marker geometry depends on. The renderer rebuilds its
/// line buffer and label atlas only when this changes.
struct Scope3DMarkerSpec: Equatable {
    enum Kind: Equatable {
        /// Vertical axis in stops of Y.
        case yxy(stopsMin: Float, stopsMax: Float)
        /// Floor radius maxM, vertical axis 0…jTop (linear J).
        case jmh(maxM: Float, jTop: Float)
    }
    var kind: Kind
    /// Source colour space name; its gamut is drawn highlighted (Yxy).
    var sourceColorSpace: String

    /// Scope space → world box (~[-1, 1] horizontally, [-0.8, 0.8] vertically).
    var modelMatrix: simd_float4x4 {
        switch kind {
        case let .yxy(stopsMin, stopsMax):
            // x ∈ [0, 0.8] → X, y ∈ [0, 0.9] → −Z, stops → Y
            let k: Float = 1.0 / 0.45
            let vs: Float = 1.6 / max(stopsMax - stopsMin, 1e-3)
            return simd_float4x4(columns: (
                SIMD4<Float>(k, 0, 0, 0),
                SIMD4<Float>(0, vs, 0, 0),
                SIMD4<Float>(0, 0, -k, 0),
                SIMD4<Float>(-0.4 * k, -stopsMin * vs - 0.8, 0.45 * k, 1)
            ))
        case let .jmh(maxM, jTop):
            // M·cos h → X, M·sin h → −Z, J → Y
            let k: Float = 1.0 / max(maxM, 1e-3)
            let vs: Float = 1.6 / max(jTop, 1e-3)
            return simd_float4x4(columns: (
                SIMD4<Float>(k, 0, 0, 0),
                SIMD4<Float>(0, vs, 0, 0),
                SIMD4<Float>(0, 0, -k, 0),
                SIMD4<Float>(0, -0.8, 0, 1)
            ))
        }
    }

    /// Top of the JMh vertical axis: at least 100, otherwise the content's max J
    /// rounded up, capped so a few extreme outliers cannot flatten the cloud.
    static func jmhTop(forMaxJ maxJ: Float) -> Float {
        guard maxJ.isFinite, maxJ > 100 else { return 100 }
        return min((maxJ / 25).rounded(.up) * 25, 400)
    }
}

// MARK: - Marker geometry

/// A label to place in the atlas and draw as a camera-facing quad.
private struct Scope3DLabelRequest {
    var text: String
    var anchor: SIMD3<Float>
    var color: SIMD4<Float>
    /// Fraction of the label size to shift left/down (0 = anchor at left/bottom, 0.5 = centred).
    var align: SIMD2<Float> = [0, 0.5]
    /// Extra offset in points.
    var offset: SIMD2<Float> = [4, 0]
    var fontSize: CGFloat = 9
}

private struct Scope3DMarkerBuilder {
    var lines: [Scope3DGPU.Line] = []
    var labels: [Scope3DLabelRequest] = []

    mutating func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ color: SIMD4<Float>, width: Float = 1) {
        lines.append(Scope3DGPU.Line(a: SIMD4(a, 1), b: SIMD4(b, 1), color: color,
                                     params: SIMD4(width, 0, 0, 0)))
    }

    mutating func polyline(_ pts: [SIMD3<Float>], _ color: SIMD4<Float>, width: Float = 1, closed: Bool = false) {
        guard pts.count > 1 else { return }
        for i in 1..<pts.count { line(pts[i - 1], pts[i], color, width: width) }
        if closed, let first = pts.first, let last = pts.last { line(last, first, color, width: width) }
    }

    mutating func label(_ text: String, at anchor: SIMD3<Float>, _ color: SIMD4<Float>,
                        align: SIMD2<Float> = [0, 0.5], offset: SIMD2<Float> = [4, 0], size: CGFloat = 9) {
        labels.append(Scope3DLabelRequest(text: text, anchor: anchor, color: color,
                                          align: align, offset: offset, fontSize: size))
    }

    // MARK: Yxy

    static func yxy(stopsMin: Float, stopsMax: Float, sourceColorSpace: String) -> Scope3DMarkerBuilder {
        var b = Scope3DMarkerBuilder()
        // Scope space is (x, stops, y).
        func p(_ x: CGFloat, _ y: CGFloat, _ s: Float) -> SIMD3<Float> { [Float(x), s, Float(y)] }
        let floor = stopsMin, top = stopsMax
        let grey: SIMD4<Float> = [0.75, 0.75, 0.75, 0.6]

        // Spectral locus on the floor, plus a faint copy at SDR white (0 stops).
        let locus = Swift.stride(from: 0, to: CIE1931SpectralLocus.points.count, by: 4)
            .map { CIE1931SpectralLocus.points[$0] }
            + [CIE1931SpectralLocus.points[CIE1931SpectralLocus.points.count - 1]]
        b.polyline(locus.map { p(CGFloat($0.x), CGFloat($0.y), floor) }, [1, 1, 1, 0.7], width: 1.5, closed: true)
        if floor < 0 && top > 0 {
            b.polyline(locus.map { p(CGFloat($0.x), CGFloat($0.y), 0) }, [1, 1, 1, 0.15], width: 1, closed: true)
        }

        // Gamut triangles on the floor with vertical lines up from the primaries.
        typealias Prims = (r: (x: CGFloat, y: CGFloat), g: (x: CGFloat, y: CGFloat), b: (x: CGFloat, y: CGFloat))
        let gamuts: [(name: String, prims: Prims, color: SIMD4<Float>, keys: [String])] = [
            ("AP0",  GamutPrimaries.acesAP0,   [0.70, 0.40, 0.90, 0.45], ["aces2065", "ap0"]),
            ("AP1",  GamutPrimaries.acescgAP1, [0.30, 0.85, 0.95, 0.55], ["acescg", "ap1"]),
            ("2020", GamutPrimaries.rec2020,   [0.35, 0.85, 0.40, 0.55], ["2020"]),
            ("P3",   GamutPrimaries.displayP3, [1.00, 0.65, 0.20, 0.65], ["p3"]),
            ("sRGB", GamutPrimaries.sRGB,      [0.70, 0.70, 0.70, 0.65], ["srgb", "709"]),
        ]
        let source = sourceColorSpace.lowercased()
        for g in gamuts {
            let isSource = g.keys.contains { source.contains($0) }
            var color = g.color
            if isSource { color.w = 0.95 }
            let width: Float = isSource ? 2.0 : 1.0
            let corners = [g.prims.r, g.prims.g, g.prims.b]
            b.polyline(corners.map { p($0.x, $0.y, floor) }, color, width: width, closed: true)
            var riser = color
            riser.w *= 0.45
            for c in corners { b.line(p(c.x, c.y, floor), p(c.x, c.y, top), riser, width: 1) }
            b.label(g.name, at: p(g.prims.r.x, g.prims.r.y, floor), color, offset: [5, -6], size: 8)
        }

        // D65 neutral axis.
        b.line(p(0.3127, 0.3290, floor), p(0.3127, 0.3290, top), [1, 1, 1, 0.35], width: 1)
        b.label("D65", at: p(0.3127, 0.3290, floor), [1, 1, 1, 0.7], offset: [5, -5], size: 8)

        // Axes: x and y along the floor, Y vertical at the origin.
        b.line(p(0, 0, floor), p(0.8, 0, floor), grey, width: 1)
        b.line(p(0, 0, floor), p(0, 0.9, floor), grey, width: 1)
        b.line(p(0, 0, floor), p(0, 0, top), grey, width: 1.25)
        for i in 1...8 {
            let v = CGFloat(i) * 0.1
            b.line(p(v, 0, floor), p(v, -0.015, floor), grey, width: 1)
            if i <= 7 { b.line(p(0, v, floor), p(-0.015, v, floor), grey, width: 1) }
            if i % 2 == 0 {
                let t = String(format: "%.1f", Double(v))
                b.label(t, at: p(v, -0.02, floor), grey, align: [0.5, 1], offset: [0, -2], size: 7)
                if i <= 8 { b.label(t, at: p(-0.02, v, floor), grey, align: [1, 0.5], offset: [-3, 0], size: 7) }
            }
        }
        b.label("x", at: p(0.8, 0, floor), [1, 1, 1, 0.8], offset: [5, 0], size: 10)
        b.label("y", at: p(0, 0.9, floor), [1, 1, 1, 0.8], offset: [5, 0], size: 10)
        b.label("Y (stops)", at: p(0, 0, top), [1, 1, 1, 0.8], align: [0.5, 0], offset: [0, 6], size: 10)

        // Vertical ticks at whole stops; SDR white (0 stops, Y = 1.0) emphasised.
        let labelEvery = (top - floor) > 10 ? 2 : 1
        for s in Int(floor.rounded(.up))...Int(top.rounded(.down)) {
            let sf = Float(s)
            if s == 0 {
                b.line(p(0, 0, 0), p(0.06, 0, 0), [1, 1, 1, 0.95], width: 2)
                b.line(p(0, 0, 0), p(0, 0.06, 0), [1, 1, 1, 0.95], width: 2)
                b.label("0  SDR white", at: p(-0.02, 0, 0), [1, 1, 1, 0.95], align: [1, 0.5], offset: [-3, 0], size: 8)
            } else {
                b.line(p(0, 0, sf), p(0.025, 0, sf), grey, width: 1)
                if s % labelEvery == 0 {
                    b.label(s > 0 ? "+\(s)" : "\(s)", at: p(-0.02, 0, sf), grey,
                            align: [1, 0.5], offset: [-3, 0], size: 7)
                }
            }
        }
        return b
    }

    // MARK: JMh

    static func jmh(maxM: Float, jTop: Float) -> Scope3DMarkerBuilder {
        var b = Scope3DMarkerBuilder()
        // Scope space is (M·cos h, J, M·sin h).
        func p(_ m: Float, _ hDeg: Float, _ j: Float) -> SIMD3<Float> {
            let h = hDeg * .pi / 180
            return [m * cos(h), j, m * sin(h)]
        }
        let ringColor: SIMD4<Float> = [0.6, 0.6, 0.6, 0.45]
        let axisColor: SIMD4<Float> = [0.4, 0.9, 0.5, 0.7]
        let grey: SIMD4<Float> = [0.75, 0.75, 0.75, 0.7]

        // Floor grid: M rings and hue spokes at J = 0.
        let step = Self.niceStep(for: maxM)
        var m = step
        var rings: [Float] = []
        while m <= maxM + 1e-3 { rings.append(m); m += step }
        if rings.last.map({ abs($0 - maxM) > 1e-3 }) ?? true { rings.append(maxM) }
        for r in rings {
            let pts = (0..<96).map { p(r, Float($0) * 360 / 96, 0) }
            b.polyline(pts, r == maxM ? axisColor : ringColor, width: r == maxM ? 1.25 : 1, closed: true)
            b.label(String(format: "%.0f", r), at: p(r, 90, 0), grey, offset: [3, 4], size: 7)
        }
        for deg in Swift.stride(from: 0, to: 360, by: 30) {
            let major = deg % 90 == 0
            b.line(p(0, Float(deg), 0), p(maxM, Float(deg), 0), major ? axisColor : ringColor, width: 1)
        }
        for deg in [0, 90, 180, 270] {
            b.label("h \(deg)", at: p(maxM * 1.06, Float(deg), 0), axisColor, align: [0.5, 0.5], offset: [0, 0], size: 8)
        }
        b.label("M", at: p(maxM, 90, 0), axisColor, offset: [3, 14], size: 9)

        // Vertical J axis with ticks; J = 100 emphasised.
        b.line(p(0, 0, 0), p(0, 0, jTop), [1, 1, 1, 0.8], width: 1.25)
        let jStep: Float = jTop <= 150 ? 10 : (jTop <= 300 ? 25 : 50)
        let tickLen = maxM * 0.04
        var j: Float = jStep
        while j <= jTop + 1e-3 {
            let is100 = abs(j - 100) < 1e-3
            b.line(p(0, 0, j), p(is100 ? tickLen * 2 : tickLen, 0, j),
                   is100 ? [1, 1, 1, 0.95] : grey, width: is100 ? 2 : 1)
            let showLabel = is100 || Int(j) % Int(jStep * 2) == 0
            if showLabel {
                b.label(String(format: "%.0f", j), at: p(0, 0, j), is100 ? [1, 1, 1, 0.95] : grey,
                        align: [1, 0.5], offset: [-4, 0], size: is100 ? 8 : 7)
            }
            j += jStep
        }
        if jTop > 100 + 1e-3 {
            // Faint ring at J = 100 to show where SDR-ish lightness ends.
            b.polyline((0..<64).map { p(maxM * 0.15, Float($0) * 360 / 64, 100) },
                       [1, 1, 1, 0.3], width: 1, closed: true)
        }
        b.label("J", at: p(0, 0, jTop), [1, 1, 1, 0.9], align: [0.5, 0], offset: [0, 6], size: 10)
        return b
    }

    static func niceStep(for maxM: Float) -> Float {
        let raw = maxM / 4
        let mag = pow(10, floor(log10(max(raw, 1e-3))))
        let norm = raw / mag
        let nice: Float = norm < 1.5 ? 1 : (norm < 3.5 ? 2 : (norm < 7.5 ? 5 : 10))
        return nice * mag
    }
}

// MARK: - Label atlas

private enum Scope3DLabelAtlas {
    /// Renders every label once with Core Text into an A8-in-RGBA atlas and
    /// returns the texture plus one GPU instance per label.
    static func build(device: MTLDevice, requests: [Scope3DLabelRequest],
                      scale: CGFloat) -> (MTLTexture?, [Scope3DGPU.Label]) {
        guard !requests.isEmpty else { return (nil, []) }

        struct Measured { let line: CTLine; let w: Int; let h: Int; let descent: CGFloat }
        let measured: [Measured] = requests.map { req in
            let font = NSFont.systemFont(ofSize: req.fontSize * scale, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: req.text, attributes: attrs))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            return Measured(line: line, w: Int(ceil(width)) + 2, h: Int(ceil(ascent + descent)) + 2,
                            descent: descent)
        }

        // Shelf-pack into a fixed-width atlas.
        let pad = 2
        let atlasW = 1024
        var placements: [(x: Int, y: Int)] = []   // y measured from the top
        var x = pad, y = pad, rowH = 0
        for m in measured {
            if x + m.w + pad > atlasW { x = pad; y += rowH + pad; rowH = 0 }
            placements.append((x, y))
            x += m.w + pad
            rowH = max(rowH, m.h)
        }
        let atlasH = max(4, y + rowH + pad)

        guard let ctx = CGContext(data: nil, width: atlasW, height: atlasH, bitsPerComponent: 8,
                                  bytesPerRow: atlasW * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return (nil, []) }
        ctx.setShouldAntialias(true)
        ctx.textMatrix = .identity
        for (m, pl) in zip(measured, placements) {
            // CG origin is bottom-left; atlas rows count from the top.
            let baseY = CGFloat(atlasH - pl.y - m.h) + m.descent + 1
            ctx.textPosition = CGPoint(x: CGFloat(pl.x) + 1, y: baseY)
            CTLineDraw(m.line, ctx)
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: atlasW,
                                                            height: atlasH, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return (nil, []) }
        texture.label = "Scope3D label atlas"
        texture.replace(region: MTLRegionMake2D(0, 0, atlasW, atlasH), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: atlasW * 4)

        let s = Float(scale)
        let instances: [Scope3DGPU.Label] = zip(zip(requests, measured), placements).map { pair, pl in
            let (req, m) = pair
            let size = SIMD2<Float>(Float(m.w), Float(m.h))
            let offset = req.offset * s - req.align * size
            return Scope3DGPU.Label(
                anchor: SIMD4(req.anchor, 1),
                color: req.color,
                uvRect: SIMD4(Float(pl.x) / Float(atlasW), Float(pl.y) / Float(atlasH),
                              Float(m.w) / Float(atlasW), Float(m.h) / Float(atlasH)),
                sizeOffset: SIMD4(size.x, size.y, offset.x, offset.y))
        }
        return (texture, instances)
    }
}

// MARK: - SwiftUI wrapper

/// MTKView-backed 3D scope. Replaces the 2D density quad + Canvas overlays
/// when a scope is in 3D mode.
struct Scope3DView: NSViewRepresentable {
    let device: MTLDevice
    let pointBuffer: MTLBuffer?
    let pointCount: Int
    let pointsVersion: UInt
    let spec: Scope3DMarkerSpec

    func makeNSView(context: Context) -> Scope3DMTKView {
        let view = Scope3DMTKView()
        view.device = device
        view.delegate = context.coordinator
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.colorPixelFormat = .rgba16Float
        view.depthStencilPixelFormat = .depth32Float
        view.clearDepth = 1.0
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        return view
    }

    func updateNSView(_ view: Scope3DMTKView, context: Context) {
        let r = context.coordinator
        var changed = false
        if r.pointBuffer !== pointBuffer || r.pointCount != pointCount || r.pointsVersion != pointsVersion {
            r.pointBuffer = pointBuffer
            r.pointCount = pointCount
            r.pointsVersion = pointsVersion
            changed = true
        }
        if r.spec != spec {
            r.spec = spec
            changed = true
        }
        if changed { view.setNeedsDisplay(view.bounds) }
    }

    func makeCoordinator() -> Scope3DRenderer {
        Scope3DRenderer(device: device)
    }
}

// MARK: - Orbit view

/// MTKView with orbit-camera mouse handling. Redraws continuously while a drag
/// is in progress and on demand otherwise.
final class Scope3DMTKView: MTKView {
    static let defaultYaw: Float = 0.6
    static let defaultPitch: Float = 0.45
    static let defaultDistance: Float = 3.6

    var yaw: Float = Scope3DMTKView.defaultYaw
    var pitch: Float = Scope3DMTKView.defaultPitch
    var distance: Float = Scope3DMTKView.defaultDistance
    private var lastDragPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func resetCamera() {
        yaw = Self.defaultYaw
        pitch = Self.defaultPitch
        distance = Self.defaultDistance
        setNeedsDisplay(bounds)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetCamera()
            return
        }
        lastDragPoint = convert(event.locationInWindow, from: nil)
        // Continuous redraw while orbiting.
        enableSetNeedsDisplay = false
        isPaused = false
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let last = lastDragPoint else { lastDragPoint = pt; return }
        let dx = Float(pt.x - last.x), dy = Float(pt.y - last.y)
        lastDragPoint = pt
        yaw -= dx * 0.01
        pitch = min(max(pitch - dy * 0.01, -1.45), 1.45)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        isPaused = true
        enableSetNeedsDisplay = true
        setNeedsDisplay(bounds)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
        zoom(by: exp(-delta))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 / max(Float(1 + event.magnification), 0.1))
    }

    private func zoom(by factor: Float) {
        distance = min(max(distance * factor, 2.0), 10.0)
        setNeedsDisplay(bounds)
    }

    /// Projection × view for the current orbit state.
    func viewProjection(aspect: Float) -> simd_float4x4 {
        let eye = SIMD3<Float>(distance * cos(pitch) * sin(yaw),
                               distance * sin(pitch),
                               distance * cos(pitch) * cos(yaw))
        return Scope3DMath.perspective(fovY: 35 * .pi / 180, aspect: aspect, near: 0.05, far: 50)
            * Scope3DMath.lookAt(eye: eye, target: .zero, up: [0, 1, 0])
    }
}

// MARK: - Renderer

final class Scope3DRenderer: NSObject, MTKViewDelegate {
    var pointBuffer: MTLBuffer?
    var pointCount = 0
    var pointsVersion: UInt = 0
    var spec: Scope3DMarkerSpec?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private var pointPipeline: MTLRenderPipelineState?
    private var linePipeline: MTLRenderPipelineState?
    private var labelPipeline: MTLRenderPipelineState?
    private var pointDepth: MTLDepthStencilState?
    private var lineDepth: MTLDepthStencilState?
    private var labelDepth: MTLDepthStencilState?

    // Cached marker geometry
    private var builtSpec: Scope3DMarkerSpec?
    private var builtScale: CGFloat = 0
    private var lineBuffer: MTLBuffer?
    private var lineCount = 0
    private var labelBuffer: MTLBuffer?
    private var labelCount = 0
    private var labelAtlas: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        super.init()
        setupPipelines()
    }

    private func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else { return }

        func pipeline(_ vertexName: String, _ fragmentName: String, premultiplied: Bool) -> MTLRenderPipelineState? {
            guard let v = library.makeFunction(name: vertexName),
                  let f = library.makeFunction(name: fragmentName) else { return nil }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = v
            desc.fragmentFunction = f
            desc.colorAttachments[0].pixelFormat = .rgba16Float
            desc.depthAttachmentPixelFormat = .depth32Float
            if premultiplied {
                desc.colorAttachments[0].isBlendingEnabled = true
                desc.colorAttachments[0].sourceRGBBlendFactor = .one
                desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                desc.colorAttachments[0].sourceAlphaBlendFactor = .one
                desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: desc)
        }
        pointPipeline = pipeline("scope3DPointVertex", "scope3DPointFragment", premultiplied: false)
        linePipeline = pipeline("scope3DLineVertex", "scope3DLineFragment", premultiplied: true)
        labelPipeline = pipeline("scope3DLabelVertex", "scope3DLabelFragment", premultiplied: true)

        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)
        }
        pointDepth = depth(.less, write: true)
        lineDepth = depth(.lessEqual, write: false)
        labelDepth = depth(.always, write: false)
    }

    /// Rebuilds the line buffer and label atlas only when the spec or backing scale changed.
    private func rebuildMarkersIfNeeded(scale: CGFloat) {
        guard let spec, spec != builtSpec || scale != builtScale else { return }
        builtSpec = spec
        builtScale = scale

        var builder: Scope3DMarkerBuilder
        switch spec.kind {
        case let .yxy(stopsMin, stopsMax):
            builder = .yxy(stopsMin: stopsMin, stopsMax: stopsMax, sourceColorSpace: spec.sourceColorSpace)
        case let .jmh(maxM, jTop):
            builder = .jmh(maxM: maxM, jTop: jTop)
        }
        // Line widths are given in points; convert to pixels.
        for i in builder.lines.indices { builder.lines[i].params.x *= Float(scale) }

        lineCount = builder.lines.count
        lineBuffer = lineCount > 0 ? device.makeBuffer(
            bytes: builder.lines, length: MemoryLayout<Scope3DGPU.Line>.stride * lineCount,
            options: .storageModeShared) : nil

        let (atlas, labels) = Scope3DLabelAtlas.build(device: device, requests: builder.labels, scale: scale)
        labelAtlas = atlas
        labelCount = labels.count
        labelBuffer = labelCount > 0 ? device.makeBuffer(
            bytes: labels, length: MemoryLayout<Scope3DGPU.Label>.stride * labelCount,
            options: .storageModeShared) : nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandQueue,
              let spec,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let scale = view.window?.backingScaleFactor ?? 2
        rebuildMarkersIfNeeded(scale: scale)

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.clearDepth = 1.0
        descriptor.depthAttachment.storeAction = .dontCare

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let orbit = view as? Scope3DMTKView
        let viewProj = orbit?.viewProjection(aspect: aspect) ?? matrix_identity_float4x4
        // 64-byte camera uniform, updated every frame.
        var mvp = viewProj * spec.modelMatrix
        var uniforms = Scope3DGPU.ViewUniforms(
            viewportSize: SIMD2(Float(size.width), Float(size.height)),
            pointSize: Float(2.0 * scale),
            cameraDistance: orbit?.distance ?? Scope3DMTKView.defaultDistance)

        // 1. Point cloud (depth tested + written)
        if let pointPipeline, let pointBuffer, pointCount > 0 {
            encoder.setRenderPipelineState(pointPipeline)
            encoder.setDepthStencilState(pointDepth)
            encoder.setVertexBuffer(pointBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.size, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Scope3DGPU.ViewUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
        }

        // 2. Marker lines (depth tested against the cloud, not written)
        if let linePipeline, let lineBuffer, lineCount > 0 {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setDepthStencilState(lineDepth)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.size, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Scope3DGPU.ViewUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lineCount)
        }

        // 3. Labels (after geometry, depth test off, faded by distance in the shader)
        if let labelPipeline, let labelBuffer, let labelAtlas, labelCount > 0 {
            encoder.setRenderPipelineState(labelPipeline)
            encoder.setDepthStencilState(labelDepth)
            encoder.setVertexBuffer(labelBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.size, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Scope3DGPU.ViewUniforms>.stride, index: 2)
            encoder.setFragmentTexture(labelAtlas, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: labelCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - Matrix helpers

enum Scope3DMath {
    /// Right-handed look-at view matrix.
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }

    /// Right-handed perspective projection with Metal's [0, 1] clip depth.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / max(aspect, 1e-3)
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }
}

// MARK: - 2D / 3D toggle

/// Small cube button in a scope's title bar that switches between the 2D
/// density view and the 3D point cloud.
struct Scope3DToggleButton: View {
    let is3D: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: is3D ? "cube.fill" : "cube")
                .font(.system(size: 11))
                .foregroundStyle(is3D ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .frame(width: 14, height: 12)
        .help(is3D ? "Show 2D scope" : "Show 3D scope (drag to orbit, scroll to zoom, double-click to reset)")
    }
}
