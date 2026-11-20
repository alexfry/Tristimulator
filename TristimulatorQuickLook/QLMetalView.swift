import MetalKit
import QuartzCore
import simd

// MTKView that applies the ACES 2 compute pass then composites via
// MetalEDRRenderer. Uses on-demand drawing — redraws only when the view
// resizes, the window moves to a different screen, or EDR headroom changes.
class QLMetalView: MTKView {
    private let commandQueue: MTLCommandQueue
    private let pipeline:     QLACESPipeline
    private let renderer:     MetalEDRRenderer
    private let sourceTexture: MTLTexture
    private let inputMatrix:  simd_float3x3

    private var outputTexture: MTLTexture?
    private var lastHeadroom: Float = -1

    init(frame: CGRect,
         device: MTLDevice,
         commandQueue: MTLCommandQueue,
         source: QLSourceImage,
         pipeline: QLACESPipeline) {
        self.commandQueue  = commandQueue
        self.pipeline      = pipeline
        self.renderer      = MetalEDRRenderer(device: device)
        self.sourceTexture = source.texture
        self.inputMatrix   = inputToAP0Matrix(header: source.headerInfo)

        super.init(frame: frame, device: device)

        if let layer = self.layer as? CAMetalLayer {
            layer.pixelFormat     = .rgba16Float
            layer.colorspace      = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            layer.wantsExtendedDynamicRangeContent = true
        }
        colorPixelFormat = .rgba16Float
        clearColor       = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1)
        delegate         = self
        isPaused         = true
        enableSetNeedsDisplay = true
    }

    required init(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingEDRChanges()
        needsDisplay = true
    }

    private func currentEDRHeadroom() -> Float {
        let headroom = window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        return Float(headroom)
    }

    private var screenObservation: NSObjectProtocol?

    private func startObservingEDRChanges() {
        screenObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let headroom = self.currentEDRHeadroom()
            if headroom != self.lastHeadroom {
                self.needsDisplay = true
            }
        }
    }

    deinit {
        if let obs = screenObservation {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

// MARK: - MTKViewDelegate

extension QLMetalView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Output texture is recreated lazily each draw against the current source size.
    }

    func draw(in view: MTKView) {
        guard let drawable   = view.currentDrawable,
              let rpd        = view.currentRenderPassDescriptor,
              let cmdBuf     = commandQueue.makeCommandBuffer()
        else { return }

        // Lazily allocate the output texture — same dimensions as the source EXR, not the view.
        if outputTexture == nil {
            outputTexture = pipeline.makeOutputTexture(matching: sourceTexture)
        }
        guard let output = outputTexture else { return }

        let headroom = currentEDRHeadroom()
        lastHeadroom = headroom
        let peakNits = max(100.0, headroom * 100.0)

        pipeline.encode(source:      sourceTexture,
                        output:      output,
                        peakNits:    peakNits,
                        inputMatrix: inputMatrix,
                        into:        cmdBuf)

        // Render pass: scale output into the EDR drawable via MetalEDRRenderer
        renderer.render(texture:              output,
                        commandBuffer:        cmdBuf,
                        renderPassDescriptor: rpd,
                        drawable:             drawable,
                        useBlackBackground:   true)

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
