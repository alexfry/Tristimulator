//
//  UCSDiagramView.swift
//  Tristimulator
//
//  CIE 1976 UCS u'v' chromaticity diagram, implemented as a draggable
//  in-window overlay with .glassEffect() — same pattern as the Yxy diagram.
//

import SwiftUI
import MetalKit
import AppKit

// MARK: - Floating Overlay Container

/// Draggable, resizable in-window CIE 1976 u'v' diagram with `.glassEffect()`.
struct UCSOverlayView: View {
    let service: ChromaticityScopeService?
    let sourceColorSpace: String
    var containerSize: CGSize = .zero
    var onClose: (() -> Void)?
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

    private let minSize = CGSize(width: 180, height: 185)
    private let maxSize = CGSize(width: 600, height: 620)

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

                Text("CIE 1976 u\u{2032}v\u{2032}")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    // Let drags on the title reach the header drag handle.
                    .allowsHitTesting(false)

                Spacer()

                Scope3DToggleButton(is3D: service?.is3D ?? false, isEnabled: service != nil) {
                    guard let service else { return }
                    service.is3D.toggle()
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
                    onEnd: { shown.logDragEnd("u'v'", in: containerSize) }
                )
            }

            UCSDiagramView(
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

struct UCSDiagramView: View {
    let service: ChromaticityScopeService?
    let sourceColorSpace: String

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if let service, service.is3D {
                // 3D point cloud; markers are drawn in Metal, Canvas overlays hidden.
                Scope3DView(
                    device: service.device,
                    pointBuffer: service.pointBuffer,
                    pointCount: service.pointCount,
                    pointsVersion: service.pointsVersion,
                    spec: Scope3DMarkerSpec(
                        kind: .chromaticity(.uv,
                                            stopsMin: ChromaticityScopeService.stopsMin3D,
                                            stopsMax: ChromaticityScopeService.stopsMax3D),
                        sourceColorSpace: sourceColorSpace)
                )
            } else {
                ZStack {
                    if let service = service, service.densityTexture != nil {
                        ChromaticityMetalView(service: service)
                    }
                    UCSCanvasOverlay(
                        size: size,
                        sourceColorSpace: sourceColorSpace
                    )
                }
            }
        }
        .aspectRatio(UCSConstants.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(6)
    }
}

// MARK: - Diagram Constants

enum UCSConstants {
    static let uMin: CGFloat = 0.0
    static let uMax: CGFloat = 0.7
    static let vMin: CGFloat = 0.0
    static let vMax: CGFloat = 0.65
    static let aspectRatio: CGFloat = (uMax - uMin) / (vMax - vMin)  // ~1.077

    /// Convert CIE u'v' to normalized view coordinates (0...1).
    static func normalized(u: CGFloat, v: CGFloat) -> CGPoint {
        CGPoint(
            x: (u - uMin) / (uMax - uMin),
            y: 1.0 - (v - vMin) / (vMax - vMin)  // flip y
        )
    }

    /// Convert CIE u'v' to pixel coordinates in a given view size.
    static func point(u: CGFloat, v: CGFloat, in size: CGSize) -> CGPoint {
        let n = normalized(u: u, v: v)
        return CGPoint(x: n.x * size.width, y: n.y * size.height)
    }

    /// Convert CIE 1931 xy → CIE 1976 u'v'.
    static func xyToUV(x: CGFloat, y: CGFloat) -> (u: CGFloat, v: CGFloat) {
        let denom = -2.0 * x + 12.0 * y + 3.0
        guard denom > 1e-10 else { return (0, 0) }
        return (4.0 * x / denom, 9.0 * y / denom)
    }
}

// MARK: - Canvas Overlay

struct UCSCanvasOverlay: View {
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

        let firstUV = UCSConstants.xyToUV(x: CGFloat(first.x), y: CGFloat(first.y))
        let startPt = UCSConstants.point(u: firstUV.u, v: firstUV.v, in: size)
        path.move(to: startPt)

        for i in 1..<points.count {
            let uv = UCSConstants.xyToUV(x: CGFloat(points[i].x), y: CGFloat(points[i].y))
            let pt = UCSConstants.point(u: uv.u, v: uv.v, in: size)
            path.addLine(to: pt)
        }
        path.closeSubpath()

        context.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
    }

    // MARK: - Gamut Triangles

    private func drawGamutTriangles(context: inout GraphicsContext, size: CGSize) {
        drawGamut(context: &context, size: size, primaries: GamutPrimaries.acesAP0,
                  color: .purple.opacity(0.25), label: "AP0")
        drawGamut(context: &context, size: size, primaries: GamutPrimaries.acescgAP1,
                  color: .cyan.opacity(0.35), label: "AP1")
        drawGamut(context: &context, size: size, primaries: GamutPrimaries.rec2020,
                  color: .green.opacity(0.3), label: "2020")
        drawGamut(context: &context, size: size, primaries: GamutPrimaries.displayP3,
                  color: .orange.opacity(0.5), label: "P3")
        drawGamut(context: &context, size: size, primaries: GamutPrimaries.sRGB,
                  color: .gray.opacity(0.5), label: "sRGB")
    }

    private func drawGamut(
        context: inout GraphicsContext,
        size: CGSize,
        primaries: (r: (x: CGFloat, y: CGFloat), g: (x: CGFloat, y: CGFloat), b: (x: CGFloat, y: CGFloat)),
        color: Color,
        label: String
    ) {
        let rUV = UCSConstants.xyToUV(x: primaries.r.x, y: primaries.r.y)
        let gUV = UCSConstants.xyToUV(x: primaries.g.x, y: primaries.g.y)
        let bUV = UCSConstants.xyToUV(x: primaries.b.x, y: primaries.b.y)

        let r = UCSConstants.point(u: rUV.u, v: rUV.v, in: size)
        let g = UCSConstants.point(u: gUV.u, v: gUV.v, in: size)
        let b = UCSConstants.point(u: bUV.u, v: bUV.v, in: size)

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
        drawReticle(context: &context, size: size,
                    x: 0.3127, y: 0.3290, color: .white, label: "D65")
        // ACES ~D60 white
        drawReticle(context: &context, size: size,
                    x: 0.32168, y: 0.33767, color: .orange, label: "D60")
    }

    private func drawReticle(
        context: inout GraphicsContext, size: CGSize,
        x: CGFloat, y: CGFloat, color: Color, label: String
    ) {
        let uv = UCSConstants.xyToUV(x: x, y: y)
        let wp = UCSConstants.point(u: uv.u, v: uv.v, in: size)
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
        context.draw(context.resolve(text),
                     at: CGPoint(x: wp.x + r * 2, y: wp.y - r), anchor: .leading)
    }

    // MARK: - Axis Labels & Ticks

    private func drawAxisLabels(context: inout GraphicsContext, size: CGSize) {
        let uLabel = Text("u\u{2032}").font(.system(size: 10)).foregroundColor(.secondary)
        context.draw(
            context.resolve(uLabel),
            at: CGPoint(x: size.width - 8, y: size.height - 8),
            anchor: .bottomTrailing
        )

        let vLabel = Text("v\u{2032}").font(.system(size: 10)).foregroundColor(.secondary)
        context.draw(
            context.resolve(vLabel),
            at: CGPoint(x: 8, y: 8),
            anchor: .topLeading
        )
    }

    private func drawTickMarks(context: inout GraphicsContext, size: CGSize) {
        let tickColor: Color = .secondary.opacity(0.4)

        // U axis ticks: 0.0, 0.1, ..., 0.7
        for i in 0...7 {
            let uVal = CGFloat(i) * 0.1
            let pt = UCSConstants.point(u: uVal, v: 0, in: size)
            var tick = Path()
            tick.move(to: CGPoint(x: pt.x, y: size.height))
            tick.addLine(to: CGPoint(x: pt.x, y: size.height - 4))
            context.stroke(tick, with: .color(tickColor), lineWidth: 0.5)

            if i > 0 && i < 7 {
                let label = Text(String(format: "%.1f", uVal))
                    .font(.system(size: 7))
                    .foregroundColor(.secondary.opacity(0.6))
                context.draw(
                    context.resolve(label),
                    at: CGPoint(x: pt.x, y: size.height - 1),
                    anchor: .bottom
                )
            }
        }

        // V axis ticks: 0.0, 0.1, ..., 0.6
        for i in 0...6 {
            let vVal = CGFloat(i) * 0.1
            let pt = UCSConstants.point(u: 0, v: vVal, in: size)
            var tick = Path()
            tick.move(to: CGPoint(x: 0, y: pt.y))
            tick.addLine(to: CGPoint(x: 4, y: pt.y))
            context.stroke(tick, with: .color(tickColor), lineWidth: 0.5)

            if i > 0 && i <= 6 {
                let label = Text(String(format: "%.1f", vVal))
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
