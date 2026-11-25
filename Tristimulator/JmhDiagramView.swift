//
//  JmhDiagramView.swift
//  Tristimulator
//
//  JMh (Hellwig 2022) polar scope displayed as a draggable, resizable
//  in-window overlay with .glassEffect().
//
//  h (hue angle, 0–360°) maps to the angular axis.
//  M (colourfulness) maps radially from the centre.
//  J (lightness) is collapsed in this 2D projection.
//

import SwiftUI
import MetalKit
import AppKit

// MARK: - Floating Overlay Container

struct JmhOverlayView: View {
    let service: JmhScopeService?
    let sourceColorSpace: String
    var containerSize: CGSize = .zero
    var onClose: (() -> Void)?
    var onMaxMChanged: (() -> Void)?
    /// Called after the 2D/3D toggle flips so the owner can recompute the scope.
    var onModeChanged: (() -> Void)?

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
    /// Starts from the saved app-wide M range so it survives closing the scope and relaunching.
    @State private var maxM: Float = ScopeViewDefaults.jmhMaxM()
    @State private var isHovering = false

    private let minSize = CGSize(width: 200, height: 230)
    private let maxSize = CGSize(width: 600, height: 640)

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

                Text("JMh")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    // Let drags on the title reach the header drag handle.
                    .allowsHitTesting(false)

                Spacer()

                Scope3DToggleButton(is3D: service?.is3D ?? false, isEnabled: service != nil) {
                    guard let service else { return }
                    service.is3D.toggle()
                    ScopeViewDefaults.setIs3D(service.is3D, for: .jmh)
                    onModeChanged?()
                }
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
                    onEnd: { shown.logDragEnd("JMh", in: containerSize) }
                )
            }

            HStack(spacing: 4) {
                Text("M")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Slider(value: $maxM, in: 5...200, step: 5)
                    .controlSize(.mini)
                    .onChange(of: maxM) {
                        service?.maxM = maxM
                        ScopeViewDefaults.setJmhMaxM(maxM)
                        onMaxMChanged?()
                    }
                Text("\(Int(maxM))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .opacity(isHovering ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.2), value: isHovering)

            JmhDiagramView(
                service: service,
                sourceColorSpace: sourceColorSpace,
                maxM: CGFloat(maxM)
            )
        }
        .frame(width: shown.size.width, height: shown.size.height)
        .scopeResizeHandles(placement: $placement, container: containerSize,
                            scaling: scaleWithWindow, minSize: minSize, maxSize: maxSize)
        .onHover { hovering in
            isHovering = hovering
        }
        // An existing service may hold an M range set before this overlay
        // (re)opened, e.g. from another window; follow the saved slider value.
        .onAppear {
            if let service, service.maxM != maxM {
                service.maxM = maxM
                onMaxMChanged?()
            }
        }
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

struct JmhDiagramView: View {
    let service: JmhScopeService?
    let sourceColorSpace: String
    var maxM: CGFloat = 50.0

    var body: some View {
        if let service, service.is3D {
            // 3D point cloud; markers are drawn in Metal, Canvas overlays hidden.
            // Fills the whole content area under the title bar (no 2D aspect
            // frame); the projection follows the view's actual aspect.
            Scope3DView(
                device: service.device,
                cameraKind: .jmh,
                pointBuffer: service.pointBuffer,
                pointCount: service.pointCount,
                pointsVersion: service.pointsVersion,
                spec: Scope3DMarkerSpec(
                    kind: .jmh(maxM: Float(maxM),
                               jTop: Scope3DMarkerSpec.jmhTop(forMaxJ: service.observedMaxJ)),
                    sourceColorSpace: sourceColorSpace)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(6)
        } else {
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    // Metal density heatmap
                    if let service = service, service.densityTexture != nil {
                        JmhMetalView(service: service)
                    }
                    // Canvas overlay: circles, radial lines, labels
                    JmhCanvasOverlay(size: size, maxM: maxM)
                }
            }
            .aspectRatio(1.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(6)
        }
    }
}

// MARK: - Metal Density View

struct JmhMetalView: NSViewRepresentable {
    let service: JmhScopeService

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

            guard let vertexFunc = library.makeFunction(name: "vertexShader"),
                  let fragFunc = library.makeFunction(name: "chromaticityDensityFragment")
            else { return }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunc
            desc.fragmentFunction = fragFunc
            desc.colorAttachments[0].pixelFormat = .rgba16Float
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            pipelineState = try? device.makeRenderPipelineState(descriptor: desc)

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

struct JmhCanvasOverlay: View {
    let size: CGSize
    var maxM: CGFloat = 50.0

    /// Colourfulness ring values, computed from maxM.
    private var mRings: [CGFloat] {
        let step = Self.niceStep(for: maxM)
        var rings: [CGFloat] = []
        var v = step
        while v <= maxM {
            rings.append(v)
            v += step
        }
        return rings
    }

    /// Pick a clean step size for the concentric rings.
    private static func niceStep(for maxM: CGFloat) -> CGFloat {
        if maxM <= 10 { return 2 }
        if maxM <= 25 { return 5 }
        if maxM <= 60 { return 10 }
        if maxM <= 120 { return 20 }
        return 50
    }

    var body: some View {
        Canvas { context, canvasSize in
            drawConcentricCircles(context: &context, size: canvasSize)
            drawRadialLines(context: &context, size: canvasSize)
            drawHueLabels(context: &context, size: canvasSize)
            drawMLabels(context: &context, size: canvasSize)
        }
    }

    /// Centre of the diagram in pixel coordinates.
    private func centre(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Radius in pixels for a given M value.
    private func radius(forM m: CGFloat, in size: CGSize) -> CGFloat {
        let maxRadius = min(size.width, size.height) / 2
        return m / maxM * maxRadius
    }

    // MARK: - Concentric M circles

    private func drawConcentricCircles(context: inout GraphicsContext, size: CGSize) {
        let c = centre(in: size)
        let ringColor: Color = .gray.opacity(0.3)

        for m in mRings {
            let r = radius(forM: m, in: size)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(ringColor),
                style: StrokeStyle(lineWidth: 0.5, dash: [4, 3])
            )
        }
    }

    // MARK: - Radial hue lines (every 30°)

    private func drawRadialLines(context: inout GraphicsContext, size: CGSize) {
        let c = centre(in: size)
        let outerR = radius(forM: maxM, in: size)
        let lineColor: Color = .gray.opacity(0.2)

        for deg in stride(from: 0, to: 360, by: 30) {
            let rad = CGFloat(deg) * .pi / 180
            let endX = c.x + outerR * cos(rad)
            // Canvas y is flipped (down = positive), but our histogram already
            // maps sin(h) to the +y texture direction which gets flipped in the
            // Metal view.  The canvas overlay should match the Metal texture
            // orientation: h=0 → right, h=90 → top.
            let endY = c.y - outerR * sin(rad)
            var line = Path()
            line.move(to: c)
            line.addLine(to: CGPoint(x: endX, y: endY))
            context.stroke(line, with: .color(lineColor), lineWidth: 0.5)
        }
    }

    // MARK: - Hue labels at cardinal directions

    private func drawHueLabels(context: inout GraphicsContext, size: CGSize) {
        let c = centre(in: size)
        let outerR = radius(forM: maxM, in: size) + 8

        // (angle in degrees, label, position relative to centre)
        let labels: [(deg: CGFloat, label: String)] = [
            (0,   "h: 0"),
            (90,  "h: 90"),
            (180, "h: 180"),
            (270, "h: 270"),
        ]

        for entry in labels {
            let rad = entry.deg * .pi / 180
            let x = c.x + outerR * cos(rad)
            let y = c.y - outerR * sin(rad)

            let anchor: UnitPoint
            switch Int(entry.deg) {
            case 0:   anchor = .leading
            case 90:  anchor = .bottom
            case 180: anchor = .trailing
            case 270: anchor = .top
            default:  anchor = .center
            }

            let text = Text(entry.label)
                .font(.system(size: 8))
                .foregroundColor(.green.opacity(0.7))
            context.draw(
                context.resolve(text),
                at: CGPoint(x: x, y: y),
                anchor: anchor
            )
        }
    }

    // MARK: - M value labels along top radius (h ≈ 90°, upward)

    private func drawMLabels(context: inout GraphicsContext, size: CGSize) {
        let c = centre(in: size)

        for m in mRings {
            let r = radius(forM: m, in: size)
            // Place labels along the upward direction (h = 90° → top of diagram)
            let labelPt = CGPoint(x: c.x + 2, y: c.y - r + 2)
            let text = Text(String(format: "%.0f", m))
                .font(.system(size: 7))
                .foregroundColor(.secondary.opacity(0.6))
            context.draw(
                context.resolve(text),
                at: labelPt,
                anchor: .topLeading
            )
        }

        // "M:" label at the top near the outer ring
        let topR = radius(forM: maxM, in: size)
        let mLabel = Text("M:\(Int(maxM))")
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(.green.opacity(0.7))
        context.draw(
            context.resolve(mLabel),
            at: CGPoint(x: c.x, y: c.y - topR - 2),
            anchor: .bottom
        )
    }
}
