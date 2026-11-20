import Cocoa
import Quartz
import Metal

class PreviewViewController: NSViewController, QLPreviewingController {

    private var imageAspect: CGFloat = 16.0 / 9.0

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let metalView = view.subviews.first else { return }
        let parentW = view.bounds.width
        let parentH = view.bounds.height
        let scale = min(parentW / imageAspect, parentH) // height if width-limited
        let fitW = scale * imageAspect
        let fitH = scale
        metalView.frame = CGRect(
            x: (parentW - fitW) / 2,
            y: (parentH - fitH) / 2,
            width: fitW,
            height: fitH
        )
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        guard let device     = MTLCreateSystemDefaultDevice(),
              let cmdQueue   = device.makeCommandQueue()
        else {
            handler(PreviewError.noMetalDevice)
            return
        }

        do {
            let source   = try loadEXR(url: url, device: device)
            let pipeline = try QLACESPipeline(device: device, commandQueue: cmdQueue)

            let imageW = CGFloat(source.texture.width)
            let imageH = CGFloat(source.texture.height)
            imageAspect = imageW / imageH
            preferredContentSize = NSSize(width: imageW, height: imageH)

            let metalView = QLMetalView(frame: view.bounds,
                                        device: device,
                                        commandQueue: cmdQueue,
                                        source: source,
                                        pipeline: pipeline)
            view.addSubview(metalView)
            viewDidLayout()

            handler(nil)
        } catch {
            handler(error)
        }
    }

    enum PreviewError: LocalizedError {
        case noMetalDevice
        var errorDescription: String? { "No Metal device available for Quick Look preview" }
    }
}
