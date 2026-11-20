//
//  ImageSequenceSource.swift
//  Tristimulator
//
//  Manages a numbered image sequence as a time-based source, analogous to
//  MovieSource for video.  Reads frames through OpenImageIO so every format
//  the app supports (EXR, DPX, TIFF, etc.) works natively.
//
//  ── Sequence discovery ───────────────────────────────────────────────────────
//  Given any member file (e.g. "beauty.0042.exr") the parent directory is
//  scanned for siblings sharing the same alpha-prefix and extension, sorted
//  numerically by their frame-number suffix.  Common VFX naming styles are
//  handled correctly:
//    "shot_0042.exr"  → prefix "shot_",   frame 42
//    "beauty.0001.exr"→ prefix "beauty.", frame 1
//    "render1080.dpx" → prefix "render",  frame 1080
//
//  ── Caching (asymmetric look-ahead ring buffer) ───────────────────────────
//  • "Hot window":  [currentIndex − N_BEHIND … currentIndex + N_AHEAD]
//  • A background Task pre-fetches the next N_AHEAD frames ahead of the
//    playhead so forward scrubbing and playback stall as little as possible.
//  • Texture entries outside the hot window are evicted after each movement.
//  • All reads dispatch to DispatchQueue.global — blocking C/C++ work stays
//    off Swift's cooperative thread pool.
//  • N_AHEAD is auto-tuned in loadMetadata based on frame resolution:
//    4K (≥3840×2160): 4 frames  (~252 MB total)
//    2K (≥2048×1080): 8 frames  (~144 MB total)
//    HD and below:   16 frames  (~130 MB total)
//  • EXR sequences reuse a fixed pool of MTLTextures (N_BEHIND+N_AHEAD+2)
//    to avoid IOKit round-trips on every cache miss.
//
//  ── Playback ─────────────────────────────────────────────────────────────────
//  • A Task loop fires every 1/frameRate seconds and advances the playhead.
//  • If the next frame is already in cache, delivery is instantaneous.
//  • If not, the loop waits for the decode to finish before advancing
//    (cache-as-you-play — no wrong frames, brief stall instead).
//

import Foundation
import Metal

// MARK: - GCD bridge
// OIIO decodes are long-running blocking work (disk I/O + decompression).
// Running them on Swift's cooperative thread pool (Task.detached) starves other
// async work and limits parallelism to the pool's thread count (~CPU cores).
// GCD's global queue uses a separate, elastic pool that parks extra threads
// for blocking work — the correct primitive for bridging C/C++ into async Swift.
private func decodeOnGCD<T: Sendable>(
    _ work: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}

/// High-priority serial queue for scrub decodes.  Serial ensures only one
/// scrub frame is decompressing at a time; .userInteractive QoS gives it
/// scheduling priority over the .userInitiated prefetch/playback work.
private let scrubQueue = DispatchQueue(label: "com.tristimulator.scrub",
                                       qos: .userInteractive)

// MARK: - CachedFrame

private struct CachedFrame {
    let texture:   MTLTexture
    let imageData: ImageData   // full OIIO metadata; pixelData intentionally empty
}

// MARK: - ImageSequenceSource

@Observable
final class ImageSequenceSource {

    // MARK: - Published state

    /// All frame URLs that form the sequence, sorted by numeric frame number.
    private(set) var frames:       [URL]  = []
    private(set) var frameCount:   Int    = 0
    private(set) var currentIndex: Int    = 0

    /// The actual frame numbers extracted from filenames (e.g. [1001, 1002, ...]).
    /// Parallel to `frames` — `frameNumbers[i]` is the on-disk frame number for `frames[i]`.
    private(set) var frameNumbers: [Int]  = []

    /// Frames per second — controls playback timing and timecode display.
    /// Changing this while playing restarts the playback loop at the new rate.
    var frameRate: Float = 24 {
        didSet { if isPlaying { startPlaybackLoop() } }
    }

    private(set) var isPlaying: Bool = false
    private(set) var isLoaded:  Bool = false
    var isLooping: Bool = true

    /// EXR layer to read ("" = default RGBA layer).
    /// Changing this flushes the texture cache and re-seeks to the current frame.
    var selectedLayer: String = "" {
        didSet {
            guard selectedLayer != oldValue else { return }
            // Clear caches and cancel any in-flight prefetch work so the
            // new layer starts from a clean slate.
            cache.removeAll()
            // Note: we intentionally keep sequenceMetadata — dimensions, color
            // space, and bit depth don't change between layers.  Keeping it
            // ensures the fast multi-part-aware EXR path is used for the
            // re-read instead of falling back to the OIIO path.
            prefetchTask?.cancel()
            // Collect the set of frame indices whose GCD decode may still
            // be running.  Their pool textures are potentially mid-write
            // and must NOT be returned to freeTextures.
            let busyIndices = Set(inFlight.keys)
            for key in inFlight.keys {
                inFlight[key]?.cancel()
                inFlight.removeValue(forKey: key)
            }
            // Return pool textures that are safe (completed decodes) to
            // freeTextures.  Leave textures for busy indices — they may
            // still be mid-write on a GCD thread.
            for (key, tex) in textureForFrame {
                if !busyIndices.contains(key) {
                    freeTextures.append(tex)
                }
            }
            textureForFrame.removeAll()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let frame = await self.loadFrameTexture(at: self.currentIndex) {
                    self.onFrame?(frame.texture, frame.imageData)
                }
                self.kickPrefetch(around: self.currentIndex)
            }
        }
    }

    // MARK: - Derived convenience

    /// Current playhead position in seconds.
    var currentTime: Double { Double(currentIndex) / Double(max(frameRate, 1)) }
    /// Total sequence duration in seconds.
    var duration:    Double { Double(frameCount)   / Double(max(frameRate, 1)) }

    // MARK: - Frame callback

    /// Called on the main actor whenever the displayed frame changes.
    /// Passes the decoded Metal texture plus the full OIIO ImageData for the frame.
    @ObservationIgnored var onFrame: ((MTLTexture, ImageData) -> Void)?

    // MARK: - Private

    private let device: MTLDevice
    private var N_AHEAD:  Int
    private let N_BEHIND: Int = 4

    /// Texture cache keyed by frame index.  Only accessed from the main actor.
    @ObservationIgnored private var cache: [Int: CachedFrame] = [:]
    @ObservationIgnored private var inFlight: [Int: Task<CachedFrame?, Never>] = [:]

    // ── Texture pool (EXR sequences only) ────────────────────────────────────
    // Pre-allocate a fixed set of MTLTextures and reuse them across frames,
    // avoiding the IOKit round-trip of newTextureWithDescriptor: on every
    // cache miss.  textureForFrame tracks which pool texture is held by each
    // frame index so we can return it to freeTextures on eviction.
    @ObservationIgnored private var freeTextures:   [MTLTexture] = []
    @ObservationIgnored private var textureForFrame: [Int: MTLTexture] = [:]

    /// Metadata shared across all frames (width/height/colorSpace/layerNames).
    /// Populated from the first decoded frame and reused for subsequent frames,
    /// avoiding a full OIIOImage alloc+pixel-copy on every cache miss.
    @ObservationIgnored private var sequenceMetadata: ImageMetadata? = nil

    /// Canonical layer name list established during loadMetadata() by probing
    /// both the first and middle frames.  Survives selectedLayer changes
    /// (which nil-out sequenceMetadata) so the layer picker never loses entries.
    @ObservationIgnored private var canonicalLayerNames: [String]? = nil
    @ObservationIgnored private var sequenceWidth:  Int = 0
    @ObservationIgnored private var sequenceHeight: Int = 0
    @ObservationIgnored private var sequenceChannels: Int = 4

    @ObservationIgnored private var playbackTask: Task<Void, Never>? = nil
    @ObservationIgnored private var prefetchTask: Task<Void, Never>? = nil
    @ObservationIgnored private var seekTask:     Task<Void, Never>? = nil

    /// Monotonically increasing tag included in every `ImageData` so that
    /// pool-texture reuse (same `MTLTexture` identity, different pixel content)
    /// still produces an unequal `ImageData`, forcing SwiftUI to call
    /// `updateNSView` and redraw.  Bumped on every decode.
    @ObservationIgnored private var contentTagCounter: UInt = 0

    /// Monotonically increasing counter bumped on every seek().  Used to
    /// discard stale frame deliveries when the user is dragging the scrubber
    /// faster than frames can decode.
    @ObservationIgnored private var seekGeneration: UInt = 0

    /// True while a scrub decode is in progress on the scrub queue.
    /// Used to coalesce rapid seek() calls — only the latest target is kept.
    @ObservationIgnored private var scrubDecoding: Bool = false

    /// When non-nil, a new seek target arrived while a scrub decode was already
    /// in progress.  The current decode finishes, then this target is decoded.
    @ObservationIgnored private var pendingScrubTarget: Int? = nil

    /// The previous seek target, used to infer scrub direction so prefetch
    /// can speculatively decode frames in the direction of travel.
    @ObservationIgnored private var lastSeekTarget: Int? = nil

    /// Frames-per-pixel of the scrub slider, used as the prefetch stride so
    /// speculative decodes land on frames the slider can actually reach.
    /// Computed from the known fixed layout: container maxWidth 560,
    /// minus padding (48), frame labels (160), loop button (~20), spacing (24)
    /// ≈ 308 px of slider track.
    private var scrubStride: Int {
        max(1, frameCount / 308)
    }

    // MARK: - Init

    /// Create a sequence source from any representative member frame.
    ///
    /// - Parameters:
    ///   - representativeURL: Any numbered file belonging to the sequence.
    ///   - device:            Metal device for texture creation.
    ///   - cacheHorizon:      Initial look-ahead depth.  Overridden automatically
    ///                        by loadMetadata() based on frame resolution (4K→4,
    ///                        2K→8, HD→16).  Pass a smaller value to force a
    ///                        tighter window before metadata is loaded.
    init(representativeURL: URL, device: MTLDevice, cacheHorizon: Int = 16) {
        self.device   = device
        self.N_AHEAD  = max(1, cacheHorizon)   // auto-tuned by resolution in loadMetadata
        self.frames      = ImageSequenceSource.discoverSequence(from: representativeURL)
        self.frameCount  = self.frames.count
        self.frameNumbers = self.frames.map { ImageSequenceSource.frameNumber(of: $0) }
    }


    // MARK: - Sequence discovery

    /// Scan the parent directory of `url` for all files sharing the same
    /// alpha-prefix and extension, returning them sorted by numeric frame suffix.
    ///
    /// The alpha-prefix is defined as the leading non-digit characters of the
    /// file stem (everything before the trailing run of digits).
    static func discoverSequence(from url: URL) -> [URL] {
        let dir      = url.deletingLastPathComponent()
        let ext      = url.pathExtension.lowercased()
        let stem     = url.deletingPathExtension().lastPathComponent
        let prefix   = alphaPrefix(of: stem)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [url] }

        let matches = contents.filter { candidate in
            guard candidate.pathExtension.lowercased() == ext else { return false }
            let cStem   = candidate.deletingPathExtension().lastPathComponent
            let cPrefix = alphaPrefix(of: cStem)
            guard cPrefix == prefix else { return false }
            let suffix  = String(cStem.dropFirst(prefix.count))
            return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
        }

        let sorted = matches.sorted { frameNumber(of: $0) < frameNumber(of: $1) }
        return sorted.isEmpty ? [url] : sorted
    }

    // MARK: - Metadata load

    /// Decode and deliver the first frame; sets `isLoaded = true` on success.
    /// Call this once after construction before showing the controls.
    @MainActor
    func loadMetadata() async {
        guard !frames.isEmpty else { return }
        if let frame = await loadFrameTexture(at: 0) {
            currentIndex = 0
            onFrame?(frame.texture, frame.imageData)

            // ── Probe the middle frame for extra EXR layers ──────────────────
            // Slate frames at the start of a sequence often lack additional
            // layers (e.g. depth, motion vectors) present in the body.
            // Compare the first frame's layers against the middle frame's
            // and adopt whichever set is larger, so the layer picker shows
            // all available layers even when the slate is sparse.
            if frames.count > 2 {
                let midIndex = frames.count / 2
                let midURL   = frames[midIndex]
                let firstLayers = sequenceMetadata?.layerNames ?? []
                let midLayers: [String] = await decodeOnGCD {
                    (try? OpenImageIOBridge.layerNames(atPath: midURL.path)) ?? []
                }
                if midLayers.count > firstLayers.count {
                    canonicalLayerNames = midLayers
                    sequenceMetadata?.layerNames = midLayers
                    // Re-deliver the first frame with the updated layer list so
                    // the UI layer picker reflects all available layers.
                    contentTagCounter &+= 1
                    let updatedData = ImageData(
                        width: frame.imageData.width,
                        height: frame.imageData.height,
                        channels: frame.imageData.channels,
                        pixelData: frame.imageData.pixelData,
                        metadata: sequenceMetadata!,
                        metalTexture: frame.imageData.metalTexture,
                        contentTag: contentTagCounter
                    )
                    onFrame?(frame.texture, updatedData)
                } else if !firstLayers.isEmpty {
                    canonicalLayerNames = firstLayers
                }
            }

            // Auto-tune N_AHEAD based on frame resolution.
            // Large frames have high decode cost and memory cost per frame,
            // so keep fewer in flight to avoid memory pressure and GCD oversubscription.
            let pixels = sequenceWidth * sequenceHeight
            if pixels >= 3840 * 2160      { N_AHEAD = 4  }   // 4K: ~63 MB/frame
            else if pixels >= 2048 * 1080 { N_AHEAD = 8  }   // 2K: ~18 MB/frame
            else                          { N_AHEAD = 16 }   // HD and below

            // Build the reusable texture pool for EXR sequences.
            if frames.first?.pathExtension.lowercased() == "exr" {
                buildTexturePool(width: sequenceWidth, height: sequenceHeight)
            }

            // Warm the cache immediately — don't wait for the first
            // play() call, which would otherwise stall on frame 1.
            kickPrefetch(around: 0)
            isLoaded = true
        } else {
            isLoaded = false
        }
    }

    // MARK: - Transport controls

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        // Cancel any in-flight scrub work so it doesn't compete with
        // playback for pool textures or restart prefetch unexpectedly.
        seekTask?.cancel()
        seekTask = nil
        scrubDecoding = false
        pendingScrubTarget = nil
        lastSeekTarget = nil
        // Scrubbing uses ensureFreeTexture (minimal eviction) instead of
        // trimCache, so pool textures may be spread across many cached frames.
        // Trim now to reclaim them for the playback window.
        trimCache(around: currentIndex)
        // Re-kick prefetch and start immediately.  The idle-after-scrub
        // prefetch should have already warmed the forward cache.
        kickPrefetch(around: currentIndex, direction: 1)
        startPlaybackLoop()
    }

    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    /// Seek to a frame index (clamped to valid range).  Fire-and-forget;
    /// delivery is async — the playback loop handles the update.
    ///
    /// Uses a "latest wins" coalescing strategy: only one decode runs on the
    /// high-priority scrub queue at a time.  If new seeks arrive while a decode
    /// is in progress, only the latest target is kept — intermediates are
    /// discarded.  This prevents the serial scrub queue from backing up with
    /// stale work during fast drags.
    func seek(to index: Int) {
        let clamped = max(0, min(frameCount - 1, index))
        currentIndex = clamped

        // Infer scrub direction and stride from consecutive seek() calls.
        let direction: Int   // -1 backward, 0 unknown, +1 forward
        if let prev = lastSeekTarget {
            let delta = clamped - prev
            direction = delta > 0 ? 1 : (delta < 0 ? -1 : 0)
        
        } else {
            direction = 0
        }
        lastSeekTarget = clamped

        // Fast path — frame is already cached; deliver immediately.
        if let hit = cache[clamped] {
            seekGeneration &+= 1
            pendingScrubTarget = nil  // no need to decode; cancel any pending
            trimCache(around: clamped)
            onFrame?(hit.texture, hit.imageData)
            kickPrefetch(around: clamped, direction: direction, stride: scrubStride)
            return
        }

        // Bump generation so stale deliveries are discarded.
        seekGeneration &+= 1

        // Cancel prefetch to free GCD threads for scrub work.
        prefetchTask?.cancel()
        prefetchTask = nil

        // Instead of a full trimCache (which aggressively evicts frames that
        // are useful when reversing scrub direction), only ensure a pool
        // texture is available for the upcoming decode.  This preserves
        // cached frames in both directions so reversing a scrub is fast.
        ensureFreeTexture(around: clamped)

        // If a scrub decode is already running, just record this as the
        // pending target — the completion handler will pick it up.
        if scrubDecoding {
            pendingScrubTarget = clamped
            return
        }

        // No decode in progress — start one now.
        startScrubDecode(for: clamped)
    }

    /// Kick off a single scrub decode for `target` on the high-priority
    /// scrub queue.  When it finishes, checks `pendingScrubTarget` and
    /// chains into the next decode if the user continued dragging.
    private func startScrubDecode(for target: Int) {
        guard target < frames.count else { return }

        scrubDecoding = true
        pendingScrubTarget = nil

        let myGeneration = seekGeneration
        let url   = frames[target]
        let layer = selectedLayer
        let isEXR = url.pathExtension.lowercased() == "exr"
        let meta  = sequenceMetadata
        let w = sequenceWidth, h = sequenceHeight, ch = sequenceChannels

        seekTask?.cancel()
        seekTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let frame: CachedFrame? = await { [weak self] in
                guard let self else { return nil }
                if isEXR, let meta, let tex = self.freeTextures.popLast() {
                    let ok: Bool = await withCheckedContinuation { cont in
                        scrubQueue.async {
                            cont.resume(returning:
                                OpenImageIOBridge.readEXR(atPath: url.path,
                                                          layer: layer,
                                                          into: tex))
                        }
                    }
                    guard ok else {
                        self.freeTextures.append(tex)
                        // Fall back to allocating path (e.g. dimension mismatch).
                        return await self.loadFrameTexture(at: target)
                    }
                    self.textureForFrame[target] = tex
                    self.contentTagCounter &+= 1
                    let imgData = ImageData(width: w, height: h, channels: ch,
                                           pixelData: Data(), metadata: meta,
                                           metalTexture: tex,
                                           contentTag: self.contentTagCounter)
                    return CachedFrame(texture: tex, imageData: imgData)
                } else {
                    return await self.loadFrameTexture(at: target)
                }
            }()

            self.scrubDecoding = false

            // Only deliver if this is still the latest generation.
            if myGeneration == self.seekGeneration, let frame {
                self.cache[target] = frame
                self.onFrame?(frame.texture, frame.imageData)
            } else if frame != nil {
                // Stale decode — return the pool texture so it isn't leaked.
                if let poolTex = self.textureForFrame.removeValue(forKey: target) {
                    self.freeTextures.append(poolTex)
                }
            }

            // If playback started while we were decoding, don't interfere
            // with its prefetch — just bail out.
            guard !self.isPlaying else { return }

            // Infer direction for prefetch.
            let dir: Int
            if let prev = self.lastSeekTarget, target != prev {
                dir = target > prev ? 1 : -1
            } else {
                dir = 0
            }

            // If a newer target arrived while we were decoding, start it now.
            if let next = self.pendingScrubTarget {
                self.pendingScrubTarget = nil
                // Check cache first — may have been prefetched.
                if let hit = self.cache[next] {
                    self.seekGeneration &+= 1
                    self.onFrame?(hit.texture, hit.imageData)
                    self.kickPrefetch(around: next, direction: dir, stride: self.scrubStride)
                } else {
                    self.startScrubDecode(for: next)
                }
            } else {
                // No more pending seeks — user stopped scrubbing.  Prefetch
                // forward at stride 1 so the cache is warm if they hit play.
                self.kickPrefetch(around: self.currentIndex, direction: 1)
            }
        }
    }

    /// Seek to a time in seconds (nearest frame).
    func seek(toTime seconds: Double) {
        seek(to: Int((seconds * Double(max(frameRate, 1))).rounded()))
    }

    func stepForward() async {
        let next = isLooping
            ? (currentIndex + 1) % max(frameCount, 1)
            : min(currentIndex + 1, frameCount - 1)
        await deliverFrame(at: next)
    }

    func stepBackward() async {
        let prev = isLooping
            ? (currentIndex - 1 + frameCount) % max(frameCount, 1)
            : max(currentIndex - 1, 0)
        await deliverFrame(at: prev)
    }

    // MARK: - Frame delivery (internal)

    /// Load frame at `index`, update `currentIndex`, and call `onFrame`.
    @MainActor
    private func deliverFrame(at index: Int) async {
        if let f = await loadFrameTexture(at: index) {
            currentIndex = index
            trimCache(around: index)
            kickPrefetch(around: index)
            onFrame?(f.texture, f.imageData)
        }
    }

    // MARK: - Playback loop

    private func startPlaybackLoop() {
        playbackTask?.cancel()
        let fps    = Double(max(frameRate, 1))
        let tick   = Duration.seconds(1.0 / fps)
        let clock  = ContinuousClock()
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var deadline = clock.now
            while !Task.isCancelled, self.isPlaying {
                deadline = deadline + tick          // fixed-rate heartbeat
                // Advance to next frame index.
                let next: Int
                if self.currentIndex + 1 >= self.frameCount {
                    guard self.isLooping else { self.isPlaying = false; break }
                    next = 0
                } else {
                    next = self.currentIndex + 1
                }
                await self.deliverFrame(at: next)
                // Sleep until the next absolute deadline.  If delivery overran
                // (cache miss / slow decode), this yields immediately and we keep
                // pushing frames as fast as possible until we catch up.
                try? await Task.sleep(until: deadline, clock: clock)
            }
        }
    }

    // MARK: - Texture pool

    /// Allocate the reusable texture pool for EXR sequence playback.
    /// Called once from loadMetadata after resolution is known.
    /// Pool size = N_BEHIND + N_AHEAD + 2 (a full hot-window plus two spares).
    private func buildTexturePool(width: Int, height: Int) {
        guard freeTextures.isEmpty else { return }  // already built
        let count = N_BEHIND + N_AHEAD + 2
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage       = .shaderRead
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        for _ in 0..<count {
            if let tex = device.makeTexture(descriptor: desc) {
                freeTextures.append(tex)
            }
        }
    }

    // MARK: - Cache

    /// Return a cached frame, or decode it from disk if not already cached.
    /// All cache mutations happen on the main actor; the heavy OIIO read is
    /// dispatched to a detached background task and awaited.
    ///
    /// - Parameter trim: When `true` (the default), evict stale cache entries
    ///   after caching the new frame.  Prefetch callers pass `false` to avoid
    ///   evicting frames near the playhead when the prefetch window is ahead.
    @MainActor
    private func loadFrameTexture(at index: Int, trim: Bool = true) async -> CachedFrame? {
        // Fast path — already cached.
        if let hit = cache[index] { return hit }
        // Join an in-flight decode if one exists.
        if let task = inFlight[index] { return await task.value }
        guard index < frames.count else { return nil }

        let url    = frames[index]
        let device = self.device
        let layer  = self.selectedLayer
        contentTagCounter &+= 1
        let tag    = contentTagCounter

        // Create a Task that performs the decode.  Concurrent callers will
        // await the same Task's value rather than starting duplicate work.
        let task: Task<CachedFrame?, Never>
        if let meta = sequenceMetadata {
            let w = sequenceWidth, h = sequenceHeight, ch = sequenceChannels
            let isEXR = url.pathExtension.lowercased() == "exr"

            if isEXR, let preallocTex = freeTextures.popLast() {
                // ── Pool fast path ────────────────────────────────────────────
                // Reuse a pre-allocated texture: no IOKit round-trip, no
                // zero-init overhead from std::vector.
                textureForFrame[index] = preallocTex
                task = Task { @MainActor [weak self] in
                    let ok: Bool = await decodeOnGCD {
                        OpenImageIOBridge.readEXR(atPath: url.path,
                                                  layer: layer,
                                                  into: preallocTex)
                    }
                    guard ok, let self else {
                        self?.freeTextures.append(preallocTex)
                        self?.textureForFrame.removeValue(forKey: index)
                        // Pool write failed (e.g. dimension mismatch) — fall
                        // back to the allocating path so the frame still loads.
                        if let tex: MTLTexture = await decodeOnGCD({
                            try? OpenImageIOBridge.readTexture(atPath: url.path,
                                                              layer: layer,
                                                              device: device)
                        }) {
                            let imgData = ImageData(width: tex.width, height: tex.height,
                                                   channels: ch, pixelData: Data(),
                                                   metadata: meta, metalTexture: tex,
                                                   contentTag: tag)
                            return CachedFrame(texture: tex, imageData: imgData)
                        }
                        return nil
                    }
                    let imgData = ImageData(width: w, height: h, channels: ch,
                                           pixelData: Data(), metadata: meta,
                                           metalTexture: preallocTex,
                                           contentTag: tag)
                    return CachedFrame(texture: preallocTex, imageData: imgData)
                }
            } else {
                // ── Allocating fallback (pool exhausted or non-EXR) ───────────
                task = Task { @MainActor in
                    let result: MTLTexture? = await decodeOnGCD {
                        try? OpenImageIOBridge.readTexture(atPath: url.path,
                                                          layer: layer,
                                                          device: device)
                    }
                    guard let tex = result else { return nil }
                    let imgData = ImageData(width: w, height: h, channels: ch,
                                           pixelData: Data(), metadata: meta,
                                           metalTexture: tex)
                    return CachedFrame(texture: tex, imageData: imgData)
                }
            }
        } else {
            task = Task { @MainActor in
                let result: CachedFrame? = await decodeOnGCD {
                    guard let oiio = try? (layer.isEmpty
                                            ? OpenImageIOBridge.readImage(atPath: url.path)
                                            : OpenImageIOBridge.readImage(atPath: url.path, layer: layer)),
                          let tex  = oiio.createMetalTexture(device) else { return nil }
                    let spec       = oiio.spec
                    let layerNames = (spec.layerNames as [String])
                    var meta = ImageMetadata(
                        colorSpace:   spec.colorSpace,
                        bitDepth:     Int(spec.bitDepth),
                        isHDR:        spec.isHDR,
                        maxLuminance: spec.maxLuminance > 0 ? spec.maxLuminance : nil,
                        attributes:   (spec.attributes as? [String: String]) ?? [:]
                    )
                    meta.layerNames = layerNames
                    meta.amfData = AMFSidecarLocator.findAMF(for: url)
                        .flatMap { try? ACESAMFParser.parse(url: $0) }
                    let imgData = ImageData(
                        width:       Int(spec.width),
                        height:      Int(spec.height),
                        channels:    Int(spec.channels),
                        pixelData:   Data(),
                        metadata:    meta,
                        metalTexture: tex,
                        contentTag:  tag
                    )
                    return CachedFrame(texture: tex, imageData: imgData)
                }
                return result
            }
        }

        inFlight[index] = task
        let frame = await task.value
        inFlight.removeValue(forKey: index)

        guard let frame = frame else { return nil }
        // Cache metadata for all subsequent frames.
        if sequenceMetadata == nil {
            sequenceMetadata = frame.imageData.metadata
            // Restore the canonical layer list so the layer picker never
            // loses entries when metadata is re-read from a sparse frame
            // (e.g. a slate that lacks layers present in the body).
            if let canonical = canonicalLayerNames {
                sequenceMetadata?.layerNames = canonical
            }
            sequenceWidth    = frame.imageData.width
            sequenceHeight   = frame.imageData.height
            sequenceChannels = frame.imageData.channels
        }
        cache[index] = frame
        if trim { trimCache(around: index) }
        return frame
    }

    /// Evict entries outside `[index − N_BEHIND … index + N_AHEAD]`.
    private func trimCache(around index: Int) {
        let lo = index - N_BEHIND
        let hi = index + N_AHEAD
        // Remove cached textures outside the hot window.
        for key in cache.keys where key < lo || key > hi {
            cache.removeValue(forKey: key)
            // Return the pool texture so it can be reused.
            if let poolTex = textureForFrame.removeValue(forKey: key) {
                freeTextures.append(poolTex)
            }
        }
        // Cancel any in-flight decodes outside the hot window.
        for key in inFlight.keys where key < lo || key > hi {
            inFlight[key]?.cancel()
            inFlight.removeValue(forKey: key)
            // Also return any pool texture reserved but not yet cached.
            if let poolTex = textureForFrame.removeValue(forKey: key) {
                freeTextures.append(poolTex)
            }
        }
        // Reclaim any orphaned pool textures (e.g. from stale scrub decodes)
        // that are registered in textureForFrame but not in cache or inFlight.
        for key in textureForFrame.keys where key < lo || key > hi {
            if cache[key] == nil && inFlight[key] == nil {
                if let poolTex = textureForFrame.removeValue(forKey: key) {
                    freeTextures.append(poolTex)
                }
            }
        }
    }

    /// Ensure at least one pool texture is free for an upcoming scrub decode.
    /// Unlike trimCache, this doesn't evict the entire window — it only
    /// reclaims the single frame furthest from `target`, preserving cached
    /// frames in both directions for responsive forward/backward scrubbing.
    private func ensureFreeTexture(around target: Int) {
        guard freeTextures.isEmpty else { return }   // already have one
        // Find the cached frame furthest from the scrub target and evict it.
        var worstKey: Int? = nil
        var worstDist = 0
        for key in cache.keys {
            let dist = abs(key - target)
            if dist > worstDist {
                worstDist = dist
                worstKey = key
            }
        }
        if let key = worstKey {
            cache.removeValue(forKey: key)
            if let poolTex = textureForFrame.removeValue(forKey: key) {
                freeTextures.append(poolTex)
            }
        }
    }

    /// Cancel any existing pre-fetch task and launch a new one that decodes
    /// frames **in parallel** on GCD's global queue.
    ///
    /// - Parameters:
    ///   - direction: Scrub/playback direction.
    ///     `+1` (default) prefetches forward only — standard for playback.
    ///     `-1` prefetches backward only — used during backward scrubbing.
    ///     `0`  prefetches in both directions (half window each way).
    ///   - stride: Step size between prefetch targets.  During playback this
    ///     is 1 (every frame).  During scrubbing it matches the observed
    ///     slider step so prefetch targets land on frames the user can reach.
    private func kickPrefetch(around index: Int, direction: Int = 1, stride: Int = 1) {
        let step = max(1, abs(stride))  // ensure positive, at least 1
        prefetchTask?.cancel()
        prefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Build target list based on direction of travel.
            var targets: [Int] = []
            if direction >= 0 {
                // Forward targets.
                let count = direction == 0 ? self.N_AHEAD / 2 : self.N_AHEAD
                for i in 1...count {
                    let t = index + i * step
                    if t < self.frameCount && self.cache[t] == nil && self.inFlight[t] == nil {
                        targets.append(t)
                    }
                }
            }
            if direction <= 0 {
                // Backward targets.
                let count = direction == 0 ? self.N_AHEAD / 2 : self.N_AHEAD
                for i in 1...count {
                    let t = index - i * step
                    if t >= 0 && self.cache[t] == nil && self.inFlight[t] == nil {
                        targets.append(t)
                    }
                }
            }
            guard !targets.isEmpty else { return }
            // Launch decodes concurrently. Use discarding task group
            // because child tasks return Void (side-effects only).
            await withDiscardingTaskGroup { group in
                for target in targets {
                    guard !Task.isCancelled else { return }
                    group.addTask { @MainActor in
                        _ = await self.loadFrameTexture(at: target, trim: false)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Leading non-digit characters of `s`, e.g. "shot_" from "shot_0042".
    /// Returns everything up to (but not including) the trailing run of digits.
    /// e.g. "shot_v078_lt.0955" → "shot_v078_lt."
    ///      "SampleFrames.0001"  → "SampleFrames."
    private static func alphaPrefix(of s: String) -> String {
        let trailingDigits = s.reversed().prefix(while: { $0.isNumber })
        return String(s.dropLast(trailingDigits.count))
    }

    /// Numeric frame number from `url`'s stem suffix (for sort ordering).
    private static func frameNumber(of url: URL) -> Int {
        let stem   = url.deletingPathExtension().lastPathComponent
        let digits = String(stem.reversed().prefix(while: { $0.isNumber }).reversed())
        return Int(digits) ?? 0
    }

    deinit {
        playbackTask?.cancel()
        prefetchTask?.cancel()
        seekTask?.cancel()
    }
}
