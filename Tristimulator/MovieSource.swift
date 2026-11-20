//
//  MovieSource.swift
//  Tristimulator
//
//  Wraps AVPlayer + AVPlayerItemVideoOutput + CVMetalTextureCache to vend
//  decoded video frames as MTLTextures, ready to be fed into the normal
//  OCIO GPU pipeline.
//
//  Pixel format negotiation (highest quality first):
//    1. kCVPixelFormatType_128RGBAFloat  → .rgba32Float  (32-bit float, not all codecs)
//    2. kCVPixelFormatType_64RGBALE      → .rgba16Unorm  (16-bit linear LE, ProRes etc.)
//    3. kCVPixelFormatType_32BGRA        → .bgra8Unorm   (8-bit, universal fallback)
//
//  The actual color-space interpretation (e.g. "Rec.709", "ACEScg") is chosen
//  manually via the existing OCIO source-space picker in the main UI.
//

import AVFoundation
import CoreVideo
import Metal
import Combine

// Aggregated (format, MTLPixelFormat) pair used for negotiation.
private struct PixelFormatSpec {
    let cvFormat: OSType
    let mtlFormat: MTLPixelFormat
    var description: String {
        switch cvFormat {
        case kCVPixelFormatType_128RGBAFloat: return "128RGBAFloat"
        case kCVPixelFormatType_64RGBALE:    return "64RGBALE"
        case kCVPixelFormatType_32BGRA:      return "32BGRA"
        default:                             return "unknown(\(cvFormat))"
        }
    }
}

private let candidateFormats: [PixelFormatSpec] = [
    PixelFormatSpec(cvFormat: kCVPixelFormatType_128RGBAFloat, mtlFormat: .rgba32Float),
    PixelFormatSpec(cvFormat: kCVPixelFormatType_64RGBALE,    mtlFormat: .rgba16Unorm),
    PixelFormatSpec(cvFormat: kCVPixelFormatType_32BGRA,      mtlFormat: .bgra8Unorm),
]

@Observable
final class MovieSource {

    // MARK: - Published state

    private(set) var duration: Double = 0       // seconds
    private(set) var currentTime: Double = 0    // seconds
    private(set) var frameRate: Float = 24
    private(set) var naturalSize: CGSize = .zero
    private(set) var isPlaying: Bool = false
    private(set) var isLoaded: Bool = false
    /// Whether playback loops back to the beginning when the clip ends. Default: on.
    var isLooping: Bool = true
    /// Playback volume 0…1. Synced to the underlying AVPlayer.
    var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

    // MARK: - Frame callback

    /// Called on the main actor with every new decoded frame texture.
    @ObservationIgnored
    var onFrame: ((MTLTexture, Double) -> Void)?

    // MARK: - Private AV stack

    private let device: MTLDevice
    private let asset: AVURLAsset
    private let playerItem: AVPlayerItem
    private let player: AVPlayer
    private var videoOutput: AVPlayerItemVideoOutput
    private var textureCache: CVMetalTextureCache?
    /// Command queue used exclusively for blit-copy of decoded frames into private textures.
    private var commandQueue: MTLCommandQueue?
    /// The Metal pixel format matched to the successfully negotiated CV format.
    private var activeMTLFormat: MTLPixelFormat = .rgba32Float

    // MARK: - Frame-extraction observers (replace old Task polling loop)
    /// Periodic time observer token — fires at every video frame during playback.
    @ObservationIgnored private var periodicTimeObserver: Any?
    /// Notification observer token — fires whenever the player time jumps (seek while paused).
    @ObservationIgnored private var timeJumpObserver: NSObjectProtocol?
    /// KVO cancellable that keeps `isPlaying` in sync with the actual player rate.
    @ObservationIgnored private var rateCancellable: AnyCancellable?
    /// Notification observer token — fires when the clip plays to its end (for loop support).
    @ObservationIgnored private var endTimeObserver: NSObjectProtocol?
    /// Incremented on every seek(to:) call.  The timeJumpedNotification async
    /// task captures this value at entry and bails out if a newer seek has
    /// arrived before it finishes polling, preventing stale-position jumps.
    @ObservationIgnored private var seekGeneration: Int = 0

    // MARK: - Init

    init(url: URL, device: MTLDevice) {
        self.device = device

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache
        self.commandQueue = device.makeCommandQueue()

        self.asset = AVURLAsset(url: url)
        self.playerItem = AVPlayerItem(asset: asset)
        self.player = AVPlayer(playerItem: playerItem)
        self.player.volume = 1.0

        // Start with the highest-quality format; retry with lower ones if decode fails.
        let attrs = MovieSource.buildPixelBufferAttrs(cvFormat: candidateFormats[0].cvFormat)
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        self.activeMTLFormat = candidateFormats[0].mtlFormat
        self.playerItem.add(self.videoOutput)

        // Keep isPlaying in sync with the actual player rate so AVPlayerView-initiated
        // play/pause events are reflected without requiring our own play()/pause() calls.
        rateCancellable = player.publisher(for: \.rate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in self?.isPlaying = rate > 0 }
    }

    private static func buildPixelBufferAttrs(cvFormat: OSType) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: cvFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
    }

    // MARK: - Metadata

    /// Load duration, frame rate, and frame dimensions from the asset tracks.
    /// Waits for AVPlayerItem.status == .readyToPlay before returning so that
    /// seekAndCapture never races the decoder initialisation.
    func loadMetadata() async {
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return }

        let size  = (try? await track.load(.naturalSize)) ?? .zero
        let fps   = (try? await track.load(.nominalFrameRate)) ?? 24
        let cmDur = (try? await asset.load(.duration)) ?? .zero

        await MainActor.run {
            self.naturalSize = size
            self.frameRate   = fps
            self.duration    = CMTimeGetSeconds(cmDur)
        }

        // Wait up to 5 s for the player item to finish loading before signalling ready.
        await waitForReadyToPlay(timeout: 5.0)

        await MainActor.run { self.isLoaded = true }
    }

    // MARK: - Seek + capture

    /// Seek the player to `time` (seconds) and return the decoded frame texture.
    /// Falls back through progressively more compatible pixel formats if the
    /// current format cannot be produced by the codec.
    func seekAndCapture(to time: Double) async -> MTLTexture? {
        let tol    = CMTime(value: 1, timescale: 600)  // ±1/600 s — avoids stalls on I-frames
        let target = CMTime(seconds: time, preferredTimescale: 600)

        await player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol)
        await MainActor.run { self.currentTime = time }

        // Poll up to ~300 ms (larger file / first decode can be slow).
        // Exit early if this seek was cancelled by a newer scrub position.
        for _ in 0..<60 {
            if videoOutput.hasNewPixelBuffer(forItemTime: target) { break }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }

        if let buf = videoOutput.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil),
           let tex = metalTexture(from: buf) {
            return tex
        }

        // The player may have landed slightly off — try actual current time.
        let actual = player.currentTime()
        if let buf = videoOutput.copyPixelBuffer(forItemTime: actual, itemTimeForDisplay: nil),
           let tex = metalTexture(from: buf) {
            return tex
        }

        // Still nothing — the codec can't produce the requested pixel format.
        // Swap the video output to the next-lower format and retry.
        return await retryWithFallbackFormat(target: target)
    }

    /// Step one frame forward and return the texture.
    func stepForward() async -> MTLTexture? {
        await seekAndCapture(to: min(currentTime + 1.0 / Double(max(frameRate, 1)), duration))
    }

    /// Step one frame backward and return the texture.
    func stepBackward() async -> MTLTexture? {
        await seekAndCapture(to: max(currentTime - 1.0 / Double(max(frameRate, 1)), 0))
    }

    // MARK: - Playback

    func play() {
        player.play()
        // isPlaying updated by the rateCancellable KVO observer.
    }

    func pause() {
        player.pause()
        // isPlaying updated by the rateCancellable KVO observer.
    }

    /// Fire-and-forget seek to `time` (seconds).  The `timeJumpedNotification`
    /// observer in `startFrameExtraction` handles frame delivery asynchronously,
    /// so there is no need to poll here.
    func seek(to time: Double) {
        seekGeneration &+= 1   // wrapping increment — overflow safe
        let target = CMTime(seconds: time, preferredTimescale: 600)
        let tol    = CMTime(value: 1, timescale: 600)
        player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol)
        currentTime = time
    }

    // MARK: - Frame extraction lifecycle

    /// Start the observers that feed decoded frames into `onFrame`.
    /// Call this once after `loadMetadata()` completes, before the user starts playback.
    ///
    /// Two sources are covered:
    ///  • **Playing**: `addPeriodicTimeObserver` fires at every video frame.
    ///  • **Paused scrubbing** (via AVPlayerView or `seekAndCapture`): 
    ///    `AVPlayerItem.timeJumpedNotification` fires whenever the player time jumps
    ///     discontinuously; we poll briefly for the new pixel buffer.
    func startFrameExtraction() {
        stopFrameExtraction()  // idempotent; cleans up any stale observers

        let interval = CMTime(seconds: 1.0 / Double(max(frameRate, 1)),
                              preferredTimescale: 600)
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] cmTime in
            guard let self else { return }
            let sec = CMTimeGetSeconds(cmTime)
            self.currentTime = sec
            guard self.videoOutput.hasNewPixelBuffer(forItemTime: cmTime),
                  let buf = self.videoOutput.copyPixelBuffer(forItemTime: cmTime,
                                                             itemTimeForDisplay: nil),
                  let tex = self.metalTexture(from: buf) else { return }
            self.onFrame?(tex, sec)
            if let cache = self.textureCache { CVMetalTextureCacheFlush(cache, 0) }
        }

        timeJumpObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // During active playback the periodicTimeObserver handles frame
            // delivery.  The jump notification also fires when playback starts
            // (first discontinuous jump from 0); acting on it here would snap
            // currentTime back to a stale position.
            guard self.player.rate == 0 else { return }
            let cmNow = self.player.currentTime()
            // Capture the generation so we can discard this task if a newer
            // seek arrives while we're polling for the pixel buffer.
            let gen = self.seekGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Poll up to ~200 ms for the decoder to produce the new buffer.
                for _ in 0..<40 {
                    if Task.isCancelled { return }
                    if self.videoOutput.hasNewPixelBuffer(forItemTime: cmNow) { break }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                // Bail if a newer seek superseded this one while we were polling.
                guard self.seekGeneration == gen else { return }
                let sec = CMTimeGetSeconds(cmNow)
                self.currentTime = sec
                guard let buf = self.videoOutput.copyPixelBuffer(forItemTime: cmNow,
                                                                  itemTimeForDisplay: nil),
                      let tex = self.metalTexture(from: buf) else { return }
                self.onFrame?(tex, sec)
                if let cache = self.textureCache { CVMetalTextureCacheFlush(cache, 0) }
            }
        }

        // Loop: seek back to 0 and resume when the clip reaches its end.
        endTimeObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isLooping else { return }
            self.seek(to: 0)
            self.play()
        }
    }

    /// Remove all frame-extraction observers.  Safe to call more than once.
    func stopFrameExtraction() {
        if let obs = periodicTimeObserver {
            player.removeTimeObserver(obs)
            periodicTimeObserver = nil
        }
        if let obs = timeJumpObserver {
            NotificationCenter.default.removeObserver(obs)
            timeJumpObserver = nil
        }
        if let obs = endTimeObserver {
            NotificationCenter.default.removeObserver(obs)
            endTimeObserver = nil
        }
    }

    // MARK: - Private helpers

    /// Poll `playerItem.status` at 50 ms intervals until ready or `timeout` expires.
    private func waitForReadyToPlay(timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while playerItem.status != .readyToPlay {
            if playerItem.status == .failed {
                print("❌ MovieSource: playerItem failed — \(playerItem.error?.localizedDescription ?? "unknown")")
                return
            }
            if Date() > deadline {
                print("⚠️ MovieSource: playerItem not ready after \(timeout)s (status=\(playerItem.status.rawValue))")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Replace the video output with the next-lower pixel format and seek again.
    private func retryWithFallbackFormat(target: CMTime) async -> MTLTexture? {
        guard let currentIdx = candidateFormats.firstIndex(where: {
            $0.mtlFormat == activeMTLFormat
        }), currentIdx + 1 < candidateFormats.count else {
            print("❌ MovieSource: all pixel formats exhausted for t=\(CMTimeGetSeconds(target))s")
            return nil
        }

        let next = candidateFormats[currentIdx + 1]
        print("⚠️ MovieSource: \(candidateFormats[currentIdx].description) failed — retrying with \(next.description)")

        playerItem.remove(videoOutput)
        let newOutput = AVPlayerItemVideoOutput(
            pixelBufferAttributes: MovieSource.buildPixelBufferAttrs(cvFormat: next.cvFormat)
        )
        playerItem.add(newOutput)
        videoOutput      = newOutput
        activeMTLFormat  = next.mtlFormat

        let tol = CMTime(value: 1, timescale: 600)
        await player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol)
        for _ in 0..<60 {
            if videoOutput.hasNewPixelBuffer(forItemTime: target) { break }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }

        if let buf = videoOutput.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil) {
            return metalTexture(from: buf)
        }
        // Recurse to try the next tier (e.g. 64RGBALE → 32BGRA).
        return await retryWithFallbackFormat(target: target)
    }

    /// Convert a `CVPixelBuffer` to a standalone `MTLTexture` whose pixel data is
    /// **copied** into a private Metal texture via a blit encoder.
    ///
    /// IMPORTANT: `CVMetalTextureCacheCreateTextureFromImage` returns a texture that
    /// is *backed* by the CVPixelBuffer — the buffer stays locked until both the
    /// CVMetalTexture wrapper AND the MTLTexture are released.  AVFoundation uses a
    /// fixed pool of ~3 buffers for 4K content.  If the caller holds the texture for
    /// more than one frame (e.g. storing it in coordinator.imageData across draw()
    /// calls) the pool drains immediately, producing the
    /// `FigFilePlayer -12860` / `VRP -12852` errors.
    ///
    /// Copying into a private GPU texture with a blit pass decouples the lifetime: the
    /// CVPixelBuffer is released as soon as the blit command encoder ends, letting
    /// AVFoundation reclaim it immediately.  The blit is a DMA copy on the GPU — it
    /// costs almost nothing and completes before the first compute pass reads the texture.
    private func metalTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache,
              let commandQueue = commandQueue else { return nil }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        let cvFmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let mtlFmt: MTLPixelFormat
        switch cvFmt {
        case kCVPixelFormatType_128RGBAFloat: mtlFmt = .rgba32Float
        case kCVPixelFormatType_64RGBALE:    mtlFmt = .rgba16Unorm
        case kCVPixelFormatType_32BGRA:      mtlFmt = .bgra8Unorm
        default:
            print("⚠️ MovieSource: unexpected CV format \(cvFmt) — using \(activeMTLFormat)")
            mtlFmt = activeMTLFormat
        }

        // Step 1: wrap the CVPixelBuffer — this does NOT copy, just creates a view.
        var cvTexture: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, mtlFmt, w, h, 0, &cvTexture
        )
        guard r == kCVReturnSuccess, let cvTex = cvTexture,
              let srcTex = CVMetalTextureGetTexture(cvTex) else {
            print("❌ CVMetalTextureCacheCreateTextureFromImage: err=\(r) fmt=\(mtlFmt)")
            return nil
        }

        // Step 2: allocate a private destination texture and blit-copy into it.
        // This releases the pixelBuffer lock at the end of this function.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mtlFmt, width: w, height: h, mipmapped: false)
        desc.usage        = [.shaderRead, .shaderWrite]
        desc.storageMode  = .private
        guard let dstTex = device.makeTexture(descriptor: desc),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit   = cmdBuf.makeBlitCommandEncoder() else { return nil }

        blit.copy(from: srcTex,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize:   MTLSize(width: w, height: h, depth: 1),
                  to: dstTex,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmdBuf.commit()
        // MUST wait: the command buffer retains srcTex (and thus cvTexture and pixelBuffer)
        // until GPU execution completes.  Without this, the CVPixelBuffer stays locked
        // in AVFoundation's pool and -12860 errors flood immediately.
        // A DMA blit of one 4K frame takes ~1ms — well within the 41ms frame budget.
        cmdBuf.waitUntilCompleted()

        // srcTex / cvTex go out of scope here → pixelBuffer is unlocked immediately.
        return dstTex
    }
}
