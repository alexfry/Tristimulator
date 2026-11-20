//
//  ViewportOCIOHelper.swift
//  Tristimulator
//
//  Viewport-aware texture preparation for OCIO GPU processing.
//  Reduces GPU work by scaling or cropping the source texture to
//  match the visible region before the OCIO compute pass.
//

import Metal
import MetalPerformanceShaders

/// Manages viewport-aware texture preparation for the OCIO compute pass.
///
/// Given the full-resolution source texture and the drawable size, produces
/// a smaller "work texture" that contains only the pixels needed for display.
/// The OCIO compute kernel then runs on this smaller texture, dramatically
/// reducing GPU work for large images.
///
/// Uses MPS bilinear downscale when the source is larger than the drawable.
/// Textures are persistent and reused across frames; only reallocated when
/// dimensions change.
final class ViewportOCIOHelper {

    struct PrepareResult {
        /// Feed this to `encodeTransform(input:...)`
        let inputForOCIO: MTLTexture
        /// Feed this to `encodeTransform(output:...)`
        let ocioOutput: MTLTexture
        /// True when the optimisation is active (smaller textures).
        let isOptimized: Bool
    }

    private let device: MTLDevice
    private lazy var scaler = MPSImageBilinearScale(device: device)

    /// Persistent work texture (downscaled or cropped source).
    private var workTexture: MTLTexture?
    /// Persistent OCIO output texture (sized to match workTexture).
    private var ocioOutput: MTLTexture?
    /// Full-res fallback OCIO output (only allocated when needed).
    private var fullResOutput: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Public API

    /// Determine the optimal processing mode and prepare the work texture.
    ///
    /// Encodes any necessary blit/scale pre-passes into `commandBuffer`.
    /// Returns textures sized for the OCIO compute pass.
    ///
    /// - Parameters:
    ///   - source: The full-resolution source texture (originalImageData.metalTexture).
    ///   - drawableSize: The current drawable dimensions in pixels.
    ///   - isAutoFit: True when the view is in auto-fit (zoom-to-fit) mode.
    ///   - visibleRectInSource: For manual zoom, the visible region in source-pixel coords. Nil in auto-fit.
    ///   - commandBuffer: The active command buffer to encode pre-passes into.
    func prepare(
        source: MTLTexture,
        drawableSize: CGSize,
        isAutoFit: Bool,
        visibleRectInSource: CGRect?,
        commandBuffer: MTLCommandBuffer
    ) -> PrepareResult {

        // Both auto-fit and manual zoom use the same scale-down strategy.
        // In auto-fit the drawable matches the window; in manual zoom the drawable
        // is the image size clamped to Metal's 16384 limit.  Either way, if the
        // source is larger than the drawable, we downscale before OCIO.
        let targetWidth  = min(source.width,  Int(drawableSize.width  * 1.1))
        let targetHeight = min(source.height, Int(drawableSize.height * 1.1))

        // Skip optimisation if savings < 20%.
        let sourcePixels = source.width * source.height
        let targetPixels = max(1, targetWidth) * max(1, targetHeight)
        if targetPixels > Int(Double(sourcePixels) * 0.8) {
            return fullResFallback(source: source)
        }

        // Clamp to at least 1×1.
        let w = max(1, targetWidth)
        let h = max(1, targetHeight)

        // Ensure persistent textures exist at target dimensions.
        ensureTexture(&workTexture, width: w, height: h,
                      format: source.pixelFormat,
                      usage: [.shaderRead, .shaderWrite])
        ensureTexture(&ocioOutput, width: w, height: h,
                      format: .rgba16Float,
                      usage: [.shaderRead, .shaderWrite])

        guard let work = workTexture, let output = ocioOutput else {
            return fullResFallback(source: source)
        }

        // MPS bilinear downscale: source (full res) → work (drawable res).
        scaler.encode(commandBuffer: commandBuffer,
                      sourceTexture: source,
                      destinationTexture: work)

        return PrepareResult(inputForOCIO: work, ocioOutput: output, isOptimized: true)
    }

    // MARK: - Private

    private func fullResFallback(source: MTLTexture) -> PrepareResult {
        ensureTexture(&fullResOutput, width: source.width, height: source.height,
                      format: .rgba16Float,
                      usage: [.shaderRead, .shaderWrite])
        guard let output = fullResOutput else {
            // Last-resort: return source as both input and output (won't happen in practice).
            return PrepareResult(inputForOCIO: source, ocioOutput: source, isOptimized: false)
        }
        return PrepareResult(inputForOCIO: source, ocioOutput: output, isOptimized: false)
    }

    private func ensureTexture(_ tex: inout MTLTexture?,
                               width: Int, height: Int,
                               format: MTLPixelFormat,
                               usage: MTLTextureUsage) {
        // Clamp to Metal's maximum texture dimension to prevent crashes
        // (e.g. on Retina, autoResizeDrawable can request 2× image width).
        let maxDim = 16384
        let w = min(max(1, width), maxDim)
        let h = min(max(1, height), maxDim)

        if let existing = tex,
           existing.width == w,
           existing.height == h,
           existing.pixelFormat == format {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: w,
            height: h,
            mipmapped: false)
        desc.usage = usage
        desc.storageMode = .private
        tex = device.makeTexture(descriptor: desc)
    }
}
