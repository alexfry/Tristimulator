//
//  ChromaticityDiagramView.swift
//  Tristimulator
//
//  CIE 1931 Yxy chromaticity diagram with GPU-rendered density overlay
//  and SwiftUI Canvas chrome (spectral locus, gamut triangles, labels).
//
//  Rendered as a draggable, resizable in-window overlay with .glassEffect()
//  so the backdrop blur stays live even during video playback.
//

import SwiftUI
import MetalKit
import AppKit

// MARK: - Floating Overlay Container

/// Draggable, resizable in-window chromaticity diagram with `.glassEffect()`.
/// Add this as an overlay in the image area ZStack.
struct ChromaticityOverlayView: View {
    let service: ChromaticityScopeService?
    let sourceColorSpace: String
    var containerSize: CGSize = .zero
    var onClose: (() -> Void)?

    /// Where the overlay sits; owned by DocumentContentView so it can be saved per image.
    @Binding var placement: ScopeOverlayPlacement
    /// Called for every mouse-down on the overlay (used to raise it).
    var onMouseDown: (TimeInterval) -> Void = { _ in }
    /// Global preference: scale scopes with the image area instead of pinning only.
    @AppStorage(TristimulatorDefaults.scopesScaleWithWindow) private var scaleWithWindow = false

    /// Placement as drawn right now (scaled in scale-with-window mode).
    private var shown: ScopeOverlayPlacement {
        placement.effective(in: containerSize, minSize: minSize, maxSize: maxSize)
    }

    private let minSize = CGSize(width: 180, height: 200)
    private let maxSize = CGSize(width: 600, height: 680)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    onClose?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("CIE 1931 Yxy")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    // Let drags on the title reach the header drag handle.
                    .allowsHitTesting(false)

                Spacer()

                Color.clear.frame(width: 12, height: 12)
            }
            // 12 pt keeps the close button clear of the top-left resize corner.
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                ScopeDragHandle(
                    onDelta: { dx, dy in
                        placement = placement.edited(in: containerSize, scaling: scaleWithWindow,
                                                     minSize: minSize, maxSize: maxSize) {
                            $0.dragged(dx: dx, dy: dy, in: containerSize)
                        }
                    },
                    onEnd: { shown.logDragEnd("Yxy", in: containerSize) }
                )
            }

            ChromaticityDiagramView(
                service: service,
                sourceColorSpace: sourceColorSpace
            )
        }
        .frame(width: shown.size.width, height: shown.size.height)
        .scopeResizeHandles(placement: $placement, container: containerSize,
                            scaling: scaleWithWindow, minSize: minSize, maxSize: maxSize)
        .compatGlass(in: .rect(cornerRadius: 12))
        .background(ScopeMouseDownObserver(onMouseDown: onMouseDown))
        .offset(x: shown.frame(in: containerSize).minX,
                 y: shown.frame(in: containerSize).minY)
        .onAppear {
            placement = placement.clampingSize(min: minSize, max: maxSize)
            settlePlacement()
        }
        // Keep the scope where it is on screen when the preference flips.
        .onChange(of: scaleWithWindow) { _, _ in settlePlacement() }
        // The first layout can arrive after onAppear with a zero-sized area.
        .onChange(of: containerSize) { _, _ in settlePlacement() }
    }

    private func settlePlacement() {
        let settled = placement.settled(in: containerSize, scaling: scaleWithWindow,
                                        minSize: minSize, maxSize: maxSize)
        if settled != placement { placement = settled }
    }
}

// MARK: - Main View

struct ChromaticityDiagramView: View {
    let service: ChromaticityScopeService?
    let sourceColorSpace: String

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // Metal density heatmap (behind Canvas)
                if let service = service, service.densityTexture != nil {
                    ChromaticityMetalView(service: service)
                }

                // SwiftUI Canvas overlay: spectral locus, gamuts, labels
                ChromaticityCanvasOverlay(
                    size: size,
                    sourceColorSpace: sourceColorSpace
                )
            }
        }
        .aspectRatio(DiagramConstants.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(6)
    }
}

// MARK: - Diagram Constants

enum DiagramConstants {
    // Diagram coordinate bounds
    static let xMin: CGFloat = 0.0
    static let xMax: CGFloat = 0.8
    static let yMin: CGFloat = 0.0
    static let yMax: CGFloat = 0.9
    static let aspectRatio: CGFloat = (xMax - xMin) / (yMax - yMin)  // ~0.889

    /// Convert CIE xy to normalized view coordinates (0...1).
    static func normalized(x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(
            x: (x - xMin) / (xMax - xMin),
            y: 1.0 - (y - yMin) / (yMax - yMin)  // flip y: top = high y
        )
    }

    /// Convert CIE xy to pixel coordinates in a given view size.
    static func point(x: CGFloat, y: CGFloat, in size: CGSize) -> CGPoint {
        let n = normalized(x: x, y: y)
        return CGPoint(x: n.x * size.width, y: n.y * size.height)
    }
}

// MARK: - Metal Density View

/// Renders the density heatmap texture as a full-frame textured quad.
struct ChromaticityMetalView: NSViewRepresentable {
    let service: ChromaticityScopeService

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = service.device
        view.delegate = context.coordinator
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        return view
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        let newTexture = service.densityTexture
        let newCounter = service.updateCounter
        let changed = newTexture !== context.coordinator.densityTexture
                   || newCounter != context.coordinator.lastUpdateCounter
        context.coordinator.densityTexture = newTexture
        context.coordinator.lastUpdateCounter = newCounter
        if changed {
            mtkView.setNeedsDisplay(mtkView.bounds)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(device: service.device)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var densityTexture: MTLTexture?
        var lastUpdateCounter: UInt = 0
        private var pipelineState: MTLRenderPipelineState?
        private var vertexBuffer: MTLBuffer?
        private var samplerState: MTLSamplerState?
        private var commandQueue: MTLCommandQueue?

        init(device: MTLDevice) {
            super.init()
            setupPipeline(device: device)
        }

        private func setupPipeline(device: MTLDevice) {
            commandQueue = device.makeCommandQueue()

            guard let library = device.makeDefaultLibrary() else { return }

            // Use the existing vertexShader from Shaders.metal
            guard let vertexFunc = library.makeFunction(name: "vertexShader"),
                  let fragFunc = library.makeFunction(name: "chromaticityDensityFragment")
            else { return }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunc
            desc.fragmentFunction = fragFunc
            desc.colorAttachments[0].pixelFormat = .rgba16Float
            // Enable alpha blending for transparent background
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            pipelineState = try? device.makeRenderPipelineState(descriptor: desc)

            // Full-screen quad vertices (matches existing Vertex struct)
            struct Vertex {
                var position: SIMD2<Float>
                var texCoord: SIMD2<Float>
            }
            let vertices: [Vertex] = [
                Vertex(position: [-1, -1], texCoord: [0, 1]),
                Vertex(position: [ 1, -1], texCoord: [1, 1]),
                Vertex(position: [-1,  1], texCoord: [0, 0]),
                Vertex(position: [ 1,  1], texCoord: [1, 0]),
            ]
            vertexBuffer = device.makeBuffer(
                bytes: vertices,
                length: MemoryLayout<Vertex>.stride * 4,
                options: .storageModeShared
            )

            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.minFilter = .linear
            samplerDesc.magFilter = .linear
            samplerDesc.sAddressMode = .clampToZero
            samplerDesc.tAddressMode = .clampToZero
            samplerState = device.makeSamplerState(descriptor: samplerDesc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipelineState,
                  let vertexBuffer,
                  let samplerState,
                  let commandQueue,
                  let densityTexture,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(densityTexture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// MARK: - Canvas Overlay

struct ChromaticityCanvasOverlay: View {
    let size: CGSize
    let sourceColorSpace: String

    var body: some View {
        Canvas { context, canvasSize in
            drawSpectralLocus(context: &context, size: canvasSize)
            drawGamutTriangles(context: &context, size: canvasSize)
            drawWhitePoint(context: &context, size: canvasSize)
            drawAxisLabels(context: &context, size: canvasSize)
            drawTickMarks(context: &context, size: canvasSize)
        }
    }

    // MARK: - Spectral Locus

    private func drawSpectralLocus(context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        let points = CIE1931SpectralLocus.points
        guard let first = points.first else { return }

        let startPt = DiagramConstants.point(x: CGFloat(first.x), y: CGFloat(first.y), in: size)
        path.move(to: startPt)

        for i in 1..<points.count {
            let pt = DiagramConstants.point(
                x: CGFloat(points[i].x),
                y: CGFloat(points[i].y),
                in: size
            )
            path.addLine(to: pt)
        }
        path.closeSubpath()

        context.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
    }

    // MARK: - Gamut Triangles

    private func drawGamutTriangles(context: inout GraphicsContext, size: CGSize) {
        // ACES AP0 (widest — draw first, behind everything)
        drawGamut(
            context: &context, size: size,
            primaries: GamutPrimaries.acesAP0,
            color: .purple.opacity(0.25),
            label: "AP0"
        )

        // ACEScg AP1
        drawGamut(
            context: &context, size: size,
            primaries: GamutPrimaries.acescgAP1,
            color: .cyan.opacity(0.35),
            label: "AP1"
        )

        // Rec.2020
        drawGamut(
            context: &context, size: size,
            primaries: GamutPrimaries.rec2020,
            color: .green.opacity(0.3),
            label: "2020"
        )

        // Display P3
        drawGamut(
            context: &context, size: size,
            primaries: GamutPrimaries.displayP3,
            color: .orange.opacity(0.5),
            label: "P3"
        )

        // sRGB / Rec.709
        drawGamut(
            context: &context, size: size,
            primaries: GamutPrimaries.sRGB,
            color: .gray.opacity(0.5),
            label: "sRGB"
        )
    }

    private func drawGamut(
        context: inout GraphicsContext,
        size: CGSize,
        primaries: (r: (x: CGFloat, y: CGFloat), g: (x: CGFloat, y: CGFloat), b: (x: CGFloat, y: CGFloat)),
        color: Color,
        label: String
    ) {
        let r = DiagramConstants.point(x: primaries.r.x, y: primaries.r.y, in: size)
        let g = DiagramConstants.point(x: primaries.g.x, y: primaries.g.y, in: size)
        let b = DiagramConstants.point(x: primaries.b.x, y: primaries.b.y, in: size)

        var path = Path()
        path.move(to: r)
        path.addLine(to: g)
        path.addLine(to: b)
        path.closeSubpath()

        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    // MARK: - White Point

    private func drawWhitePoint(context: inout GraphicsContext, size: CGSize) {
        // D65 illuminant
        drawReticle(
            context: &context, size: size,
            x: 0.3127, y: 0.3290,
            color: .white, label: "D65"
        )

        // ACES white / ~D60
        drawReticle(
            context: &context, size: size,
            x: 0.32168, y: 0.33767,
            color: .orange, label: "D60"
        )
    }

    private func drawReticle(
        context: inout GraphicsContext,
        size: CGSize,
        x: CGFloat, y: CGFloat,
        color: Color,
        label: String
    ) {
        let wp = DiagramConstants.point(x: x, y: y, in: size)
        let r: CGFloat = 3

        context.stroke(
            Path(ellipseIn: CGRect(x: wp.x - r, y: wp.y - r, width: r * 2, height: r * 2)),
            with: .color(color.opacity(0.8)),
            lineWidth: 1
        )

        var cross = Path()
        cross.move(to: CGPoint(x: wp.x - r * 1.5, y: wp.y))
        cross.addLine(to: CGPoint(x: wp.x + r * 1.5, y: wp.y))
        cross.move(to: CGPoint(x: wp.x, y: wp.y - r * 1.5))
        cross.addLine(to: CGPoint(x: wp.x, y: wp.y + r * 1.5))
        context.stroke(cross, with: .color(color.opacity(0.5)), lineWidth: 0.5)

        let text = Text(label).font(.system(size: 7)).foregroundColor(color.opacity(0.7))
        context.draw(
            context.resolve(text),
            at: CGPoint(x: wp.x + r * 2, y: wp.y - r),
            anchor: .leading
        )
    }

    // MARK: - Axis Labels & Ticks

    private func drawAxisLabels(context: inout GraphicsContext, size: CGSize) {
        // "x" label at bottom right
        let xLabel = Text("x").font(.system(size: 10)).foregroundColor(.secondary)
        context.draw(
            context.resolve(xLabel),
            at: CGPoint(x: size.width - 8, y: size.height - 8),
            anchor: .bottomTrailing
        )

        // "y" label at top left
        let yLabel = Text("y").font(.system(size: 10)).foregroundColor(.secondary)
        context.draw(
            context.resolve(yLabel),
            at: CGPoint(x: 8, y: 8),
            anchor: .topLeading
        )
    }

    private func drawTickMarks(context: inout GraphicsContext, size: CGSize) {
        let tickColor: Color = .secondary.opacity(0.4)

        // X axis ticks: 0.0, 0.1, 0.2, ..., 0.8
        for i in 0...8 {
            let xVal = CGFloat(i) * 0.1
            let pt = DiagramConstants.point(x: xVal, y: 0, in: size)
            var tick = Path()
            tick.move(to: CGPoint(x: pt.x, y: size.height))
            tick.addLine(to: CGPoint(x: pt.x, y: size.height - 4))
            context.stroke(tick, with: .color(tickColor), lineWidth: 0.5)

            if i > 0 && i < 8 {
                let label = Text(String(format: "%.1f", xVal))
                    .font(.system(size: 7))
                    .foregroundColor(.secondary.opacity(0.6))
                context.draw(
                    context.resolve(label),
                    at: CGPoint(x: pt.x, y: size.height - 1),
                    anchor: .bottom
                )
            }
        }

        // Y axis ticks: 0.0, 0.1, 0.2, ..., 0.9
        for i in 0...9 {
            let yVal = CGFloat(i) * 0.1
            let pt = DiagramConstants.point(x: 0, y: yVal, in: size)
            var tick = Path()
            tick.move(to: CGPoint(x: 0, y: pt.y))
            tick.addLine(to: CGPoint(x: 4, y: pt.y))
            context.stroke(tick, with: .color(tickColor), lineWidth: 0.5)

            if i > 0 && i < 9 {
                let label = Text(String(format: "%.1f", yVal))
                    .font(.system(size: 7))
                    .foregroundColor(.secondary.opacity(0.6))
                context.draw(
                    context.resolve(label),
                    at: CGPoint(x: 6, y: pt.y),
                    anchor: .leading
                )
            }
        }
    }
}

// MARK: - Gamut Primary Coordinates

enum GamutPrimaries {
    static let sRGB = (
        r: (x: 0.64 as CGFloat,  y: 0.33 as CGFloat),
        g: (x: 0.30 as CGFloat,  y: 0.60 as CGFloat),
        b: (x: 0.15 as CGFloat,  y: 0.06 as CGFloat)
    )

    static let displayP3 = (
        r: (x: 0.680 as CGFloat, y: 0.320 as CGFloat),
        g: (x: 0.265 as CGFloat, y: 0.690 as CGFloat),
        b: (x: 0.150 as CGFloat, y: 0.060 as CGFloat)
    )

    static let rec2020 = (
        r: (x: 0.708 as CGFloat, y: 0.292 as CGFloat),
        g: (x: 0.170 as CGFloat, y: 0.797 as CGFloat),
        b: (x: 0.131 as CGFloat, y: 0.046 as CGFloat)
    )

    static let acescgAP1 = (
        r: (x: 0.713 as CGFloat, y: 0.293 as CGFloat),
        g: (x: 0.165 as CGFloat, y: 0.830 as CGFloat),
        b: (x: 0.128 as CGFloat, y: 0.044 as CGFloat)
    )

    static let acesAP0 = (
        r: (x: 0.7347 as CGFloat, y: 0.2653 as CGFloat),
        g: (x: 0.0000 as CGFloat, y: 1.0000 as CGFloat),
        b: (x: 0.0001 as CGFloat, y: -0.0770 as CGFloat)
    )
}

// MARK: - CIE 1931 Spectral Locus Data

/// CIE 1931 2-degree standard observer chromaticity coordinates at 1 nm intervals.
/// Source: CIE 018:2019 Table 6 (DOI: 10.25039/CIE.DS.mifmy4x4).
/// 360 nm to 700 nm (341 points). Beyond 700 nm the locus is constant.
enum CIE1931SpectralLocus {
    struct Point {
        let x: Float
        let y: Float
    }

    static let points: [Point] = [
        Point(x: 0.17556, y: 0.00529),  // 360
        Point(x: 0.17548, y: 0.00529),  // 361
        Point(x: 0.17540, y: 0.00528),  // 362
        Point(x: 0.17532, y: 0.00527),  // 363
        Point(x: 0.17524, y: 0.00526),  // 364
        Point(x: 0.17516, y: 0.00526),  // 365
        Point(x: 0.17509, y: 0.00525),  // 366
        Point(x: 0.17501, y: 0.00524),  // 367
        Point(x: 0.17494, y: 0.00523),  // 368
        Point(x: 0.17488, y: 0.00522),  // 369
        Point(x: 0.17482, y: 0.00522),  // 370
        Point(x: 0.17477, y: 0.00523),  // 371
        Point(x: 0.17472, y: 0.00524),  // 372
        Point(x: 0.17466, y: 0.00524),  // 373
        Point(x: 0.17459, y: 0.00522),  // 374
        Point(x: 0.17451, y: 0.00518),  // 375
        Point(x: 0.17441, y: 0.00513),  // 376
        Point(x: 0.17431, y: 0.00507),  // 377
        Point(x: 0.17422, y: 0.00502),  // 378
        Point(x: 0.17416, y: 0.00498),  // 379
        Point(x: 0.17411, y: 0.00496),  // 380
        Point(x: 0.17409, y: 0.00496),  // 381
        Point(x: 0.17407, y: 0.00497),  // 382
        Point(x: 0.17406, y: 0.00498),  // 383
        Point(x: 0.17404, y: 0.00498),  // 384
        Point(x: 0.17401, y: 0.00498),  // 385
        Point(x: 0.17397, y: 0.00497),  // 386
        Point(x: 0.17393, y: 0.00494),  // 387
        Point(x: 0.17389, y: 0.00493),  // 388
        Point(x: 0.17384, y: 0.00492),  // 389
        Point(x: 0.17380, y: 0.00492),  // 390
        Point(x: 0.17376, y: 0.00492),  // 391
        Point(x: 0.17370, y: 0.00494),  // 392
        Point(x: 0.17366, y: 0.00494),  // 393
        Point(x: 0.17361, y: 0.00494),  // 394
        Point(x: 0.17356, y: 0.00492),  // 395
        Point(x: 0.17351, y: 0.00490),  // 396
        Point(x: 0.17347, y: 0.00486),  // 397
        Point(x: 0.17342, y: 0.00484),  // 398
        Point(x: 0.17338, y: 0.00481),  // 399
        Point(x: 0.17334, y: 0.00480),  // 400
        Point(x: 0.17329, y: 0.00479),  // 401
        Point(x: 0.17324, y: 0.00478),  // 402
        Point(x: 0.17317, y: 0.00478),  // 403
        Point(x: 0.17310, y: 0.00477),  // 404
        Point(x: 0.17302, y: 0.00478),  // 405
        Point(x: 0.17293, y: 0.00478),  // 406
        Point(x: 0.17284, y: 0.00479),  // 407
        Point(x: 0.17275, y: 0.00480),  // 408
        Point(x: 0.17266, y: 0.00480),  // 409
        Point(x: 0.17258, y: 0.00480),  // 410
        Point(x: 0.17249, y: 0.00480),  // 411
        Point(x: 0.17239, y: 0.00480),  // 412
        Point(x: 0.17230, y: 0.00480),  // 413
        Point(x: 0.17219, y: 0.00482),  // 414
        Point(x: 0.17209, y: 0.00483),  // 415
        Point(x: 0.17198, y: 0.00486),  // 416
        Point(x: 0.17187, y: 0.00489),  // 417
        Point(x: 0.17174, y: 0.00494),  // 418
        Point(x: 0.17159, y: 0.00501),  // 419
        Point(x: 0.17141, y: 0.00510),  // 420
        Point(x: 0.17121, y: 0.00521),  // 421
        Point(x: 0.17099, y: 0.00533),  // 422
        Point(x: 0.17077, y: 0.00547),  // 423
        Point(x: 0.17054, y: 0.00562),  // 424
        Point(x: 0.17030, y: 0.00579),  // 425
        Point(x: 0.17005, y: 0.00597),  // 426
        Point(x: 0.16978, y: 0.00618),  // 427
        Point(x: 0.16950, y: 0.00640),  // 428
        Point(x: 0.16920, y: 0.00664),  // 429
        Point(x: 0.16888, y: 0.00690),  // 430
        Point(x: 0.16853, y: 0.00718),  // 431
        Point(x: 0.16815, y: 0.00749),  // 432
        Point(x: 0.16775, y: 0.00782),  // 433
        Point(x: 0.16733, y: 0.00817),  // 434
        Point(x: 0.16690, y: 0.00855),  // 435
        Point(x: 0.16645, y: 0.00896),  // 436
        Point(x: 0.16598, y: 0.00940),  // 437
        Point(x: 0.16548, y: 0.00987),  // 438
        Point(x: 0.16496, y: 0.01035),  // 439
        Point(x: 0.16441, y: 0.01086),  // 440
        Point(x: 0.16383, y: 0.01138),  // 441
        Point(x: 0.16321, y: 0.01194),  // 442
        Point(x: 0.16255, y: 0.01252),  // 443
        Point(x: 0.16185, y: 0.01314),  // 444
        Point(x: 0.16111, y: 0.01379),  // 445
        Point(x: 0.16031, y: 0.01449),  // 446
        Point(x: 0.15947, y: 0.01523),  // 447
        Point(x: 0.15857, y: 0.01602),  // 448
        Point(x: 0.15763, y: 0.01684),  // 449
        Point(x: 0.15664, y: 0.01771),  // 450
        Point(x: 0.15560, y: 0.01861),  // 451
        Point(x: 0.15452, y: 0.01956),  // 452
        Point(x: 0.15340, y: 0.02055),  // 453
        Point(x: 0.15222, y: 0.02161),  // 454
        Point(x: 0.15099, y: 0.02274),  // 455
        Point(x: 0.14969, y: 0.02395),  // 456
        Point(x: 0.14834, y: 0.02525),  // 457
        Point(x: 0.14693, y: 0.02663),  // 458
        Point(x: 0.14547, y: 0.02812),  // 459
        Point(x: 0.14396, y: 0.02970),  // 460
        Point(x: 0.14241, y: 0.03139),  // 461
        Point(x: 0.14080, y: 0.03321),  // 462
        Point(x: 0.13912, y: 0.03520),  // 463
        Point(x: 0.13737, y: 0.03740),  // 464
        Point(x: 0.13550, y: 0.03988),  // 465
        Point(x: 0.13351, y: 0.04269),  // 466
        Point(x: 0.13137, y: 0.04588),  // 467
        Point(x: 0.12909, y: 0.04945),  // 468
        Point(x: 0.12666, y: 0.05343),  // 469
        Point(x: 0.12412, y: 0.05780),  // 470
        Point(x: 0.12147, y: 0.06259),  // 471
        Point(x: 0.11870, y: 0.06783),  // 472
        Point(x: 0.11581, y: 0.07358),  // 473
        Point(x: 0.11278, y: 0.07989),  // 474
        Point(x: 0.10960, y: 0.08684),  // 475
        Point(x: 0.10626, y: 0.09449),  // 476
        Point(x: 0.10278, y: 0.10286),  // 477
        Point(x: 0.09913, y: 0.11201),  // 478
        Point(x: 0.09531, y: 0.12194),  // 479
        Point(x: 0.09129, y: 0.13270),  // 480
        Point(x: 0.08708, y: 0.14432),  // 481
        Point(x: 0.08268, y: 0.15687),  // 482
        Point(x: 0.07812, y: 0.17042),  // 483
        Point(x: 0.07344, y: 0.18503),  // 484
        Point(x: 0.06871, y: 0.20072),  // 485
        Point(x: 0.06399, y: 0.21747),  // 486
        Point(x: 0.05932, y: 0.23525),  // 487
        Point(x: 0.05467, y: 0.25409),  // 488
        Point(x: 0.05003, y: 0.27400),  // 489
        Point(x: 0.04539, y: 0.29498),  // 490
        Point(x: 0.04076, y: 0.31698),  // 491
        Point(x: 0.03620, y: 0.33990),  // 492
        Point(x: 0.03176, y: 0.36360),  // 493
        Point(x: 0.02749, y: 0.38792),  // 494
        Point(x: 0.02346, y: 0.41270),  // 495
        Point(x: 0.01970, y: 0.43776),  // 496
        Point(x: 0.01627, y: 0.46295),  // 497
        Point(x: 0.01318, y: 0.48821),  // 498
        Point(x: 0.01048, y: 0.51340),  // 499
        Point(x: 0.00817, y: 0.53842),  // 500
        Point(x: 0.00628, y: 0.56307),  // 501
        Point(x: 0.00487, y: 0.58712),  // 502
        Point(x: 0.00398, y: 0.61045),  // 503
        Point(x: 0.00364, y: 0.63301),  // 504
        Point(x: 0.00386, y: 0.65482),  // 505
        Point(x: 0.00464, y: 0.67590),  // 506
        Point(x: 0.00601, y: 0.69612),  // 507
        Point(x: 0.00799, y: 0.71534),  // 508
        Point(x: 0.01060, y: 0.73341),  // 509
        Point(x: 0.01387, y: 0.75019),  // 510
        Point(x: 0.01777, y: 0.76561),  // 511
        Point(x: 0.02224, y: 0.77963),  // 512
        Point(x: 0.02727, y: 0.79211),  // 513
        Point(x: 0.03282, y: 0.80293),  // 514
        Point(x: 0.03885, y: 0.81202),  // 515
        Point(x: 0.04533, y: 0.81939),  // 516
        Point(x: 0.05218, y: 0.82516),  // 517
        Point(x: 0.05932, y: 0.82943),  // 518
        Point(x: 0.06672, y: 0.83227),  // 519
        Point(x: 0.07430, y: 0.83380),  // 520
        Point(x: 0.08205, y: 0.83409),  // 521
        Point(x: 0.08994, y: 0.83329),  // 522
        Point(x: 0.09794, y: 0.83159),  // 523
        Point(x: 0.10602, y: 0.82918),  // 524
        Point(x: 0.11416, y: 0.82621),  // 525
        Point(x: 0.12235, y: 0.82277),  // 526
        Point(x: 0.13055, y: 0.81893),  // 527
        Point(x: 0.13870, y: 0.81478),  // 528
        Point(x: 0.14677, y: 0.81040),  // 529
        Point(x: 0.15472, y: 0.80586),  // 530
        Point(x: 0.16253, y: 0.80124),  // 531
        Point(x: 0.17024, y: 0.79652),  // 532
        Point(x: 0.17785, y: 0.79169),  // 533
        Point(x: 0.18539, y: 0.78673),  // 534
        Point(x: 0.19288, y: 0.78163),  // 535
        Point(x: 0.20031, y: 0.77640),  // 536
        Point(x: 0.20769, y: 0.77105),  // 537
        Point(x: 0.21503, y: 0.76559),  // 538
        Point(x: 0.22234, y: 0.76002),  // 539
        Point(x: 0.22962, y: 0.75433),  // 540
        Point(x: 0.23689, y: 0.74852),  // 541
        Point(x: 0.24413, y: 0.74262),  // 542
        Point(x: 0.25136, y: 0.73661),  // 543
        Point(x: 0.25858, y: 0.73051),  // 544
        Point(x: 0.26578, y: 0.72432),  // 545
        Point(x: 0.27296, y: 0.71806),  // 546
        Point(x: 0.28013, y: 0.71172),  // 547
        Point(x: 0.28729, y: 0.70532),  // 548
        Point(x: 0.29445, y: 0.69884),  // 549
        Point(x: 0.30160, y: 0.69231),  // 550
        Point(x: 0.30876, y: 0.68571),  // 551
        Point(x: 0.31592, y: 0.67906),  // 552
        Point(x: 0.32306, y: 0.67237),  // 553
        Point(x: 0.33021, y: 0.66563),  // 554
        Point(x: 0.33736, y: 0.65885),  // 555
        Point(x: 0.34451, y: 0.65203),  // 556
        Point(x: 0.35167, y: 0.64517),  // 557
        Point(x: 0.35881, y: 0.63829),  // 558
        Point(x: 0.36596, y: 0.63138),  // 559
        Point(x: 0.37310, y: 0.62445),  // 560
        Point(x: 0.38024, y: 0.61750),  // 561
        Point(x: 0.38738, y: 0.61054),  // 562
        Point(x: 0.39451, y: 0.60357),  // 563
        Point(x: 0.40163, y: 0.59659),  // 564
        Point(x: 0.40873, y: 0.58961),  // 565
        Point(x: 0.41583, y: 0.58262),  // 566
        Point(x: 0.42292, y: 0.57563),  // 567
        Point(x: 0.42999, y: 0.56865),  // 568
        Point(x: 0.43704, y: 0.56167),  // 569
        Point(x: 0.44406, y: 0.55472),  // 570
        Point(x: 0.45106, y: 0.54777),  // 571
        Point(x: 0.45804, y: 0.54084),  // 572
        Point(x: 0.46499, y: 0.53393),  // 573
        Point(x: 0.47190, y: 0.52705),  // 574
        Point(x: 0.47878, y: 0.52020),  // 575
        Point(x: 0.48561, y: 0.51339),  // 576
        Point(x: 0.49241, y: 0.50661),  // 577
        Point(x: 0.49915, y: 0.49989),  // 578
        Point(x: 0.50585, y: 0.49321),  // 579
        Point(x: 0.51249, y: 0.48659),  // 580
        Point(x: 0.51907, y: 0.48003),  // 581
        Point(x: 0.52560, y: 0.47353),  // 582
        Point(x: 0.53207, y: 0.46709),  // 583
        Point(x: 0.53846, y: 0.46073),  // 584
        Point(x: 0.54479, y: 0.45443),  // 585
        Point(x: 0.55103, y: 0.44823),  // 586
        Point(x: 0.55719, y: 0.44210),  // 587
        Point(x: 0.56327, y: 0.43606),  // 588
        Point(x: 0.56926, y: 0.43010),  // 589
        Point(x: 0.57515, y: 0.42423),  // 590
        Point(x: 0.58094, y: 0.41846),  // 591
        Point(x: 0.58665, y: 0.41276),  // 592
        Point(x: 0.59222, y: 0.40719),  // 593
        Point(x: 0.59766, y: 0.40176),  // 594
        Point(x: 0.60293, y: 0.39650),  // 595
        Point(x: 0.60803, y: 0.39141),  // 596
        Point(x: 0.61298, y: 0.38648),  // 597
        Point(x: 0.61778, y: 0.38171),  // 598
        Point(x: 0.62246, y: 0.37705),  // 599
        Point(x: 0.62704, y: 0.37249),  // 600
        Point(x: 0.63152, y: 0.36803),  // 601
        Point(x: 0.63590, y: 0.36367),  // 602
        Point(x: 0.64016, y: 0.35943),  // 603
        Point(x: 0.64427, y: 0.35533),  // 604
        Point(x: 0.64823, y: 0.35140),  // 605
        Point(x: 0.65203, y: 0.34763),  // 606
        Point(x: 0.65567, y: 0.34402),  // 607
        Point(x: 0.65917, y: 0.34055),  // 608
        Point(x: 0.66253, y: 0.33722),  // 609
        Point(x: 0.66576, y: 0.33401),  // 610
        Point(x: 0.66887, y: 0.33092),  // 611
        Point(x: 0.67186, y: 0.32795),  // 612
        Point(x: 0.67472, y: 0.32509),  // 613
        Point(x: 0.67746, y: 0.32236),  // 614
        Point(x: 0.68008, y: 0.31975),  // 615
        Point(x: 0.68258, y: 0.31725),  // 616
        Point(x: 0.68497, y: 0.31486),  // 617
        Point(x: 0.68725, y: 0.31259),  // 618
        Point(x: 0.68943, y: 0.31041),  // 619
        Point(x: 0.69151, y: 0.30834),  // 620
        Point(x: 0.69349, y: 0.30637),  // 621
        Point(x: 0.69539, y: 0.30448),  // 622
        Point(x: 0.69721, y: 0.30267),  // 623
        Point(x: 0.69894, y: 0.30095),  // 624
        Point(x: 0.70061, y: 0.29930),  // 625
        Point(x: 0.70219, y: 0.29773),  // 626
        Point(x: 0.70371, y: 0.29622),  // 627
        Point(x: 0.70516, y: 0.29477),  // 628
        Point(x: 0.70656, y: 0.29338),  // 629
        Point(x: 0.70792, y: 0.29203),  // 630
        Point(x: 0.70923, y: 0.29072),  // 631
        Point(x: 0.71050, y: 0.28945),  // 632
        Point(x: 0.71173, y: 0.28823),  // 633
        Point(x: 0.71290, y: 0.28706),  // 634
        Point(x: 0.71403, y: 0.28593),  // 635
        Point(x: 0.71512, y: 0.28484),  // 636
        Point(x: 0.71616, y: 0.28380),  // 637
        Point(x: 0.71716, y: 0.28281),  // 638
        Point(x: 0.71812, y: 0.28185),  // 639
        Point(x: 0.71903, y: 0.28094),  // 640
        Point(x: 0.71991, y: 0.28006),  // 641
        Point(x: 0.72075, y: 0.27922),  // 642
        Point(x: 0.72155, y: 0.27842),  // 643
        Point(x: 0.72232, y: 0.27766),  // 644
        Point(x: 0.72303, y: 0.27695),  // 645
        Point(x: 0.72370, y: 0.27628),  // 646
        Point(x: 0.72433, y: 0.27566),  // 647
        Point(x: 0.72491, y: 0.27508),  // 648
        Point(x: 0.72547, y: 0.27453),  // 649
        Point(x: 0.72599, y: 0.27401),  // 650
        Point(x: 0.72649, y: 0.27351),  // 651
        Point(x: 0.72698, y: 0.27302),  // 652
        Point(x: 0.72743, y: 0.27257),  // 653
        Point(x: 0.72786, y: 0.27214),  // 654
        Point(x: 0.72827, y: 0.27173),  // 655
        Point(x: 0.72866, y: 0.27134),  // 656
        Point(x: 0.72902, y: 0.27098),  // 657
        Point(x: 0.72936, y: 0.27064),  // 658
        Point(x: 0.72968, y: 0.27032),  // 659
        Point(x: 0.72997, y: 0.27003),  // 660
        Point(x: 0.73023, y: 0.26977),  // 661
        Point(x: 0.73047, y: 0.26953),  // 662
        Point(x: 0.73069, y: 0.26931),  // 663
        Point(x: 0.73090, y: 0.26910),  // 664
        Point(x: 0.73109, y: 0.26891),  // 665
        Point(x: 0.73128, y: 0.26872),  // 666
        Point(x: 0.73147, y: 0.26853),  // 667
        Point(x: 0.73165, y: 0.26835),  // 668
        Point(x: 0.73183, y: 0.26817),  // 669
        Point(x: 0.73199, y: 0.26801),  // 670
        Point(x: 0.73215, y: 0.26785),  // 671
        Point(x: 0.73230, y: 0.26770),  // 672
        Point(x: 0.73244, y: 0.26756),  // 673
        Point(x: 0.73258, y: 0.26742),  // 674
        Point(x: 0.73272, y: 0.26728),  // 675
        Point(x: 0.73286, y: 0.26714),  // 676
        Point(x: 0.73300, y: 0.26700),  // 677
        Point(x: 0.73314, y: 0.26686),  // 678
        Point(x: 0.73328, y: 0.26672),  // 679
        Point(x: 0.73342, y: 0.26658),  // 680
        Point(x: 0.73355, y: 0.26645),  // 681
        Point(x: 0.73368, y: 0.26632),  // 682
        Point(x: 0.73381, y: 0.26619),  // 683
        Point(x: 0.73394, y: 0.26606),  // 684
        Point(x: 0.73405, y: 0.26595),  // 685
        Point(x: 0.73414, y: 0.26586),  // 686
        Point(x: 0.73422, y: 0.26578),  // 687
        Point(x: 0.73429, y: 0.26571),  // 688
        Point(x: 0.73434, y: 0.26566),  // 689
        Point(x: 0.73439, y: 0.26561),  // 690
        Point(x: 0.73444, y: 0.26556),  // 691
        Point(x: 0.73448, y: 0.26552),  // 692
        Point(x: 0.73452, y: 0.26548),  // 693
        Point(x: 0.73456, y: 0.26544),  // 694
        Point(x: 0.73459, y: 0.26541),  // 695
        Point(x: 0.73462, y: 0.26538),  // 696
        Point(x: 0.73465, y: 0.26535),  // 697
        Point(x: 0.73467, y: 0.26533),  // 698
        Point(x: 0.73469, y: 0.26531),  // 699
        Point(x: 0.73469, y: 0.26531),  // 700
    ]
}
