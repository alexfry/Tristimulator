//
//  MetalEDRImageView.swift
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

import SwiftUI
import MetalKit
import Accelerate

/// A Metal-based image view that supports EDR (Extended Dynamic Range) for HDR display on macOS
struct MetalEDRImageView: NSViewRepresentable {
    var imageData: ImageData?
    var exposure: Float = 0.0
    var colorTransform: ColorTransform?
    var metalColorSpace: String = "displayP3"
    var useBlackBackground: Bool = false
    /// The compiled OCIO GPU processor from ImageManager.
    /// When non-nil and its pipeline is ready, `draw()` encodes the OCIO compute
    /// pass inline — before the render pass — using a persistent output texture.
    /// This eliminates per-frame texture allocation and async scheduling overhead.
    var gpuProcessor: OCIOGPUProcessor?
    /// The original (pre-OCIO) source texture for still images.
    /// When non-nil and `gpuProcessor.isDisplayPipelineReady`, `draw()` encodes
    /// the OCIO compute pass inline — exactly as it does for video frames —
    /// giving one GPU submission per redraw and zero per-frame allocations.
    /// Pass `originalImageData?.metalTexture` from ImageManager.
    var sourceTexture: MTLTexture? = nil
    /// Whether the view is in auto-fit (zoom-to-fit) mode.
    /// Used by ViewportOCIOHelper to choose scale vs crop strategy.
    var isAutoFitMode: Bool = true
    /// Visible region in source-pixel coordinates (for manual zoom mode).
    /// Nil in auto-fit mode.  Used by ViewportOCIOHelper to crop the OCIO input.
    var drawableVisibleRect: CGRect? = nil
    /// When `true`, a single peak-brightness measurement is dispatched on the
    /// next draw call via a GPU compute pass on the drawable texture.
    /// Channel isolation mask applied in scene-linear space (after exposure, before display transform).
    /// xyz = RGB dot weights, w = 1 means show alpha.
    var channelMask: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
    var measurePeak: Bool = false
    /// Called on the main thread with per-channel RGBA maxima once the GPU
    /// reduction completes.
    var onPeakMeasured: ((SIMD4<Float>) -> Void)? = nil

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.preferredFramesPerSecond = 60
        // On-demand rendering: draw() only runs when setNeedsDisplay() is called.
        // This eliminates continuous 60fps OCIO compute on 3840×2160 for stills,
        // and eliminates 2-3x redundant renders per video frame (60fps MTKView / 24fps video).
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
        mtkView.framebufferOnly = false
        
        // Set initial color space
        mtkView.colorspace = colorSpaceForIdentifier(metalColorSpace)
        
        // Configure pixel format for HDR
        mtkView.colorPixelFormat = .rgba16Float
        
        // IMPORTANT: Request EDR even in windowed mode
        if let layer = mtkView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        
        // In manual zoom mode the MTKView frame equals the image pixel dimensions.
        // With autoResizeDrawable the backing layer becomes frame×backingScale, which
        // on Retina can exceed Metal's 16384 max (e.g. 9420×2 = 18840).
        // Disable auto-resize and manage drawableSize explicitly in updateNSView.
        if isAutoFitMode {
            mtkView.autoResizeDrawable = true
        } else {
            mtkView.autoResizeDrawable = false
            // Initial drawable will be sized in updateNSView once the view
            // has a window and a visible rect.  Use a reasonable default.
            mtkView.drawableSize = CGSize(width: 1920, height: 1080)
        }
        
        return mtkView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
        let coord = context.coordinator

        // Detect whether any rendering-relevant input actually changed.
        var needsRedraw = false

        if coord.imageData != imageData {
            coord.imageData = imageData
            needsRedraw = true
        }
        if coord.exposure != exposure {
            coord.exposure = exposure
            needsRedraw = true
        }
        if coord.colorTransform != colorTransform {
            coord.colorTransform = colorTransform
            needsRedraw = true
        }
        if coord.useBlackBackground != useBlackBackground {
            coord.useBlackBackground = useBlackBackground
            needsRedraw = true
        }
        if coord.gpuProcessor !== gpuProcessor {
            coord.gpuProcessor = gpuProcessor
            needsRedraw = true
        }
        if coord.sourceTexture !== sourceTexture {
            coord.sourceTexture = sourceTexture
            needsRedraw = true
        }
        if coord.channelMask != channelMask {
            coord.channelMask = channelMask
            needsRedraw = true
        }
        if coord.isAutoFitMode != isAutoFitMode {
            coord.isAutoFitMode = isAutoFitMode
            needsRedraw = true
        }
        if coord.drawableVisibleRect != drawableVisibleRect {
            coord.drawableVisibleRect = drawableVisibleRect
            needsRedraw = true
        }
        coord.onPeakMeasured = onPeakMeasured

        let resolvedCS = colorSpaceForIdentifier(metalColorSpace)
            ?? CGColorSpace(name: CGColorSpace.extendedDisplayP3)!
        if coord.drawableColorSpace != resolvedCS {
            coord.drawableColorSpace = resolvedCS
            needsRedraw = true
        }
        if measurePeak { coord.measurePeakFlag = true; needsRedraw = true }

        // Update color space if it changed
        let newColorSpace = colorSpaceForIdentifier(metalColorSpace)
        if nsView.colorspace != newColorSpace {
            nsView.colorspace = newColorSpace
            needsRedraw = true
        }

        // In manual zoom mode, keep drawable size clamped to Metal's max.
        // autoResizeDrawable is disabled for manual zoom to prevent oversized drawables.
        if !isAutoFitMode {
            nsView.autoResizeDrawable = false
        } else if !nsView.autoResizeDrawable {
            nsView.autoResizeDrawable = true
        }
        if !isAutoFitMode {
            // The MTKView frame equals the full image pixel size (set by ManualZoomView).
            // The drawable matches the image at 1:1 (not ×backingScale) because:
            //  - At 1:1 zoom each image pixel maps to one screen point
            //  - Using ×scale would exceed Metal's 16384 limit for large images
            //  - The scroll view magnification handles Retina sharpness
            // Clamped to 16384 for safety.
            let maxDim: CGFloat = 16384
            let w = min(max(1, nsView.bounds.width), maxDim)
            let h = min(max(1, nsView.bounds.height), maxDim)
            let current = nsView.drawableSize
            if abs(current.width - w) > 1 || abs(current.height - h) > 1 {
                nsView.drawableSize = CGSize(width: w, height: h)
                needsRedraw = true
            }
        }

        // Only request a Metal redraw when something rendering-relevant changed.
        // This prevents continuous 60 fps GPU work when SwiftUI re-evaluates the
        // view tree due to unrelated state changes (e.g. toolbar, sidebar, timers).
        if needsRedraw {
            nsView.needsDisplay = true
        }
    }
    
    // colorSpaceForIdentifier is now a package-level free function (below this struct)
    // so it can be used by both MetalEDRImageView and ImageClipboardHelper.
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        var imageData: ImageData?
        var exposure: Float = 0.0
        var colorTransform: ColorTransform?
        var useBlackBackground: Bool = false
        var renderer: MetalEDRRenderer?
        var commandQueue: MTLCommandQueue?
        /// Lazily-initialised compute pipeline for peak measurement.
        var reductionService: PixelReductionService?
        /// Set from the main thread in `updateNSView`; consumed (and reset) in `draw()`.
        var measurePeakFlag = false
        var onPeakMeasured: ((SIMD4<Float>) -> Void)?
        /// The encoded colour space of the drawable — resolved from `metalColorSpace`
        /// and passed to PixelReductionService so it can linearise before measuring.
        var drawableColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedDisplayP3)!
        /// Channel isolation mask — set from updateNSView, passed to the OCIO compute shader.
        var channelMask: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
        /// The compiled OCIO processor — set from updateNSView, used in draw() for inline transform.
        var gpuProcessor: OCIOGPUProcessor?
        /// Original (pre-OCIO) source texture for still images.
        /// nil for movies (they use imageData.metalTexture directly).
        var sourceTexture: MTLTexture?
        /// Viewport-aware texture preparation helper.
        /// Scales or crops the source texture to match the visible region
        /// before the OCIO compute pass, reducing GPU work for large images.
        var viewportHelper: ViewportOCIOHelper?
        var isAutoFitMode: Bool = true
        var drawableVisibleRect: CGRect? = nil

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle resize if needed
        }

        func draw(in view: MTKView) {
            guard let device = view.device else { return }

            // Lazy initialize command queue (reuse it for performance!)
            if commandQueue == nil {
                commandQueue = device.makeCommandQueue()
            }

            guard let commandQueue = commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else {
                return
            }

            // Lazy initialize renderer
            if renderer == nil {
                renderer = MetalEDRRenderer(device: device)
            }

            // Unified inline OCIO path for both stills and movies:
            //   • Movies:  rawTex = imageData.metalTexture (decoded AVFoundation frame)
            //   • Stills:  rawTex = sourceTexture (originalImageData.metalTexture, pre-OCIO)
            // In both cases: one command buffer encodes compute then render — no separate
            // async processTexture call, no per-frame allocation, no extra round-trip.
            // Falls back to rendering imageData.metalTexture directly when no pipeline is ready.
            let isVideoFrame = imageData?.pixelData.isEmpty == true
            let inlineSourceTex: MTLTexture? = isVideoFrame ? imageData?.metalTexture : sourceTexture

            if let rawTex = inlineSourceTex,
               let gpu = gpuProcessor,
               gpu.isDisplayPipelineReady {

                // Viewport-aware OCIO: scale or crop the source to match the
                // visible region, then run OCIO on the smaller texture.
                if viewportHelper == nil { viewportHelper = ViewportOCIOHelper(device: device) }

                let drawableSize = CGSize(width: drawable.texture.width,
                                          height: drawable.texture.height)
                let result = viewportHelper!.prepare(
                    source: rawTex,
                    drawableSize: drawableSize,
                    isAutoFit: isAutoFitMode,
                    visibleRectInSource: drawableVisibleRect,
                    commandBuffer: commandBuffer)

                gpu.encodeTransform(into: commandBuffer,
                                    input: result.inputForOCIO,
                                    output: result.ocioOutput,
                                    exposure: exposure,
                                    channelMask: channelMask)
                renderer?.render(texture: result.ocioOutput,
                                 commandBuffer: commandBuffer,
                                 renderPassDescriptor: descriptor,
                                 drawable: drawable,
                                 useBlackBackground: useBlackBackground)

            } else if let imageData = imageData {
                renderer?.render(
                    imageData: imageData,
                    commandBuffer: commandBuffer,
                    renderPassDescriptor: descriptor,
                    drawable: drawable,
                    exposure: exposure,
                    colorTransform: colorTransform,
                    useBlackBackground: useBlackBackground
                )
            } else {
                // Clear screen when no image
                descriptor.colorAttachments[0].loadAction = .clear
                // Use black background in full screen, grey otherwise
                let grey: Double = useBlackBackground ? 0.0 : 0.17
                descriptor.colorAttachments[0].clearColor = MTLClearColor(red: grey, green: grey, blue: grey, alpha: 1.0)
                let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
                renderEncoder?.endEncoding()
            }

            // Peak measurement: one-shot compute reduction on the post-transform
            // drawable texture (framebufferOnly = false allows compute to read it).
            if measurePeakFlag {
                measurePeakFlag = false
                if reductionService == nil { reductionService = PixelReductionService(device: device) }
                if let svc = reductionService {
                    let captured = onPeakMeasured
                    let cs = drawableColorSpace
                    svc.measurePeak(
                        texture: drawable.texture,
                        device: device,
                        commandBuffer: commandBuffer,
                        sourceColorSpace: cs
                    ) { maxVal in captured?(maxVal) }
                }
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

/// Represents image data loaded from OpenImageIO
struct ImageData: Equatable {
    let width: Int
    let height: Int
    let channels: Int
    let pixelData: Data
    let metadata: ImageMetadata
    let metalTexture: MTLTexture?
    /// Monotonic tag that distinguishes frames even when the same pool texture
    /// is reused (e.g. after an EXR layer change writes new pixels into an
    /// existing MTLTexture).  Defaults to 0 for non-sequence paths.
    var contentTag: UInt = 0
    
    // Custom Equatable implementation since MTLTexture doesn't conform to Equatable.
    // metalTexture IS compared by identity so that SwiftUI's NSViewRepresentable
    // diffing calls updateNSView (and sets needsDisplay=true) whenever the texture
    // changes — new video frame, new OCIO-processed still, exposure reset, etc.
    // Without this, consecutive video frames with identical metadata were considered
    // equal and SwiftUI skipped updateNSView entirely, blocking on-demand redraws.
    static func == (lhs: ImageData, rhs: ImageData) -> Bool {
        lhs.width == rhs.width &&
        lhs.height == rhs.height &&
        lhs.channels == rhs.channels &&
        lhs.pixelData == rhs.pixelData &&
        lhs.metadata == rhs.metadata &&
        lhs.contentTag == rhs.contentTag &&
        lhs.metalTexture === rhs.metalTexture  // identity: different texture → different frame
    }
}

struct ImageMetadata: Equatable {
    let colorSpace: String
    let bitDepth: Int
    let isHDR: Bool
    let maxLuminance: Float?
    let attributes: [String: String]
    var layerNames: [String] = []
    /// ACES Metadata File sidecar, if one was found alongside the image.
    var amfData: ACESMetadataFile? = nil
}

/// Represents a color transformation using OpenColorIO
struct ColorTransform: Equatable {
    let sourceColorSpace: String
    let destinationColorSpace: String
    let display: String?
    let view: String?
    /// Signature of the AMF look transforms folded into the display shader. Carried here
    /// so that toggling a look (which changes only the looks, not source/display/view)
    /// makes `ColorTransform` compare unequal and triggers a Metal redraw.
    var amfLookSig: String = ""
    /// Signature of the source-interpretation mode (colorspace vs. inverse display).
    /// Carried here so that toggling between Color Space and Inverse Display — which
    /// recompiles the OCIO kernel but produces identical source/display/view — still
    /// changes `ColorTransform` enough to trigger a Metal redraw on paused frames.
    var sourceModeSig: String = ""
}

// MARK: - Shared Color Space Resolution

func colorSpaceForIdentifier(_ identifier: String) -> CGColorSpace? {
    switch identifier {
    case "displayP3":
        return CGColorSpace(name: CGColorSpace.displayP3)
    case "extendedDisplayP3":
        return CGColorSpace(name: CGColorSpace.extendedDisplayP3)
    case "linearDisplayP3":
        return CGColorSpace(name: CGColorSpace.linearDisplayP3)
    case "extendedLinearDisplayP3":
        return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    case "sRGB":
        return CGColorSpace(name: CGColorSpace.sRGB)
    case "extendedSRGB":
        return CGColorSpace(name: CGColorSpace.extendedSRGB)
    case "linearSRGB":
        return CGColorSpace(name: CGColorSpace.linearSRGB)
    case "extendedLinearSRGB":
        return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    case "genericRGBLinear":
        return CGColorSpace(name: CGColorSpace.genericRGBLinear)
    case "adobeRGB1998":
        return CGColorSpace(name: CGColorSpace.adobeRGB1998)
    case "dcip3":
        return CGColorSpace(name: CGColorSpace.dcip3)
    case "itur_709":
        return CGColorSpace(name: CGColorSpace.itur_709)
    case "itur_2020":
        return CGColorSpace(name: CGColorSpace.itur_2020)
    case "extendedLinearITUR_2020":
        return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
    case "itur_2100_HLG":
        return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
    case "itur_2100_PQ":
        return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
    case "bt1886":
        return createBT1886ColorSpace()
    case "p3d65":
        return createP3D65ColorSpace()
    case "rommrgb":
        return CGColorSpace(name: CGColorSpace.rommrgb)
    case "extendedGray":
        return CGColorSpace(name: CGColorSpace.extendedGray)
    case "linearGray":
        return CGColorSpace(name: CGColorSpace.linearGray)
    case "extendedLinearGray":
        return CGColorSpace(name: CGColorSpace.extendedLinearGray)
    default:
        return CGColorSpace(name: CGColorSpace.extendedDisplayP3)
    }
}

private func createBT1886ColorSpace() -> CGColorSpace? {
    let whitePoint: [CGFloat] = [0.95047, 1.0, 1.08883]
    let blackPoint: [CGFloat] = [0.0, 0.0, 0.0]
    let gamma: [CGFloat] = [2.4, 2.4, 2.4]
    let matrix: [CGFloat] = [
        0.4124564, 0.2126729, 0.0193339,
        0.3575761, 0.7151522, 0.1191920,
        0.1804375, 0.0721750, 0.9503041
    ]
    return CGColorSpace(
        calibratedRGBWhitePoint: whitePoint,
        blackPoint: blackPoint,
        gamma: gamma,
        matrix: matrix
    )
}

private func createP3D65ColorSpace() -> CGColorSpace? {
    let whitePoint: [CGFloat] = [0.95047, 1.0, 1.08883]
    let blackPoint: [CGFloat] = [0.0, 0.0, 0.0]
    let gamma: [CGFloat] = [2.6, 2.6, 2.6]
    let matrix: [CGFloat] = [
        0.4865709, 0.2289746, 0.0000000,
        0.2656677, 0.6917385, 0.0451134,
        0.1982173, 0.0792869, 1.0439444
    ]
    return CGColorSpace(
        calibratedRGBWhitePoint: whitePoint,
        blackPoint: blackPoint,
        gamma: gamma,
        matrix: matrix
    )
}
