//
//  OCIOGPUProcessor.swift
//  Tristimulator
//
//  GPU-accelerated OCIO color transformation using Metal
//

import Foundation
import Metal
import AppKit

class OCIOGPUProcessor {
    private let device: MTLDevice
    private var commandQueue: MTLCommandQueue?

    // MARK: - Compiled pipeline state (thread-safe)
    //
    // Setup runs on background compile threads while the MTKView draw callback reads the
    // pipeline on its own thread. The compute pipeline, its LUT textures (in binding order)
    // and the parameters it was built for therefore travel together as one immutable
    // snapshot, swapped under `stateLock`. Readers take one snapshot and use only that, so
    // they see the complete old pipeline, the complete new one, or nil — never a torn pair.
    // See GitHub issue #1 and P0-3 in CODEBASE_ASSESSMENT.md.

    /// What a compiled pipeline was built for. Replaces the old per-field `cached*` vars;
    /// a setup call is a cache hit when the current snapshot's key equals its own.
    private enum PipelineKey: Equatable {
        case uncached
        case linearize(sourceSpace: String)
        case display(sourceSpace: String, display: String, view: String)
        /// `lookSig` is the signature of the AMF look steps folded into the display shader.
        case combined(sourceSpace: String, display: String, view: String, lookSig: String)
        case combinedInverse(syntheticSource: String, display: String, view: String)
        /// Combined Dynamic ACES2 pass (normal or inverse-display source).
        case aces2(sourceSpace: String, peakNits: Float, gamutTag: String, lookSig: String)
    }

    private struct PipelineSnapshot {
        let pipelineState: MTLComputePipelineState
        /// LUT textures in kernel binding order.
        let textures: [MTLTexture]
        /// Same textures with their OCIO names (for debug readback).
        let textureInfos: [TextureInfo]
        var key: PipelineKey = .uncached
    }

    /// Guards `_snapshot` and `setupGeneration`. Held only for pointer-sized swaps.
    private let stateLock = NSLock()
    private var _snapshot: PipelineSnapshot?
    private var setupGeneration: UInt64 = 0
    /// Held for the whole of a setup call: at most one compile at a time per processor,
    /// and the cache check is atomic with the compile it guards.
    private let compileLock = NSLock()
    /// Retired snapshots (and their Metal LUT textures) are released here, on one serial
    /// queue, once nothing — including in-flight command buffers — still references them.
    private static let releaseQueue = DispatchQueue(label: "Tristimulator.OCIOGPUProcessor.release",
                                                    qos: .utility)

    private var currentSnapshot: PipelineSnapshot? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _snapshot
    }

    /// Atomically install `new` (or nil) and hand the previous snapshot to `releaseQueue`.
    private func publish(_ new: PipelineSnapshot?) {
        stateLock.lock()
        let old = _snapshot
        _snapshot = new
        stateLock.unlock()
        if let old { OCIOGPUProcessor.retire(old) }
    }

    private static func retire(_ snapshot: PipelineSnapshot) {
        releaseQueue.async { withExtendedLifetime(snapshot) {} }
    }

    /// Keep `snapshot` alive until the GPU has finished `commandBuffer`, then release it
    /// on `releaseQueue`. Must be called before the command buffer is committed.
    private func retainUntilCompleted(_ snapshot: PipelineSnapshot, by commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { _ in OCIOGPUProcessor.retire(snapshot) }
    }

    /// Run one pipeline setup request.
    ///
    /// - Only one setup runs at a time per processor (`compileLock`).
    /// - Requests that pile up behind a running compile are coalesced: only the most
    ///   recently issued one runs; older ones return without compiling because a newer
    ///   request supersedes them. The latest request is never dropped.
    /// - While a compile runs, readers keep using the previous snapshot. If setup throws,
    ///   the pipeline is cleared, as before.
    /// - Returns: `false` if this request was superseded and nothing was compiled. The
    ///   caller should then not commit state for it; the newer request will.
    @discardableResult
    private func runSetup(_ name: String, _ body: () throws -> Void) throws -> Bool {
        stateLock.lock()
        setupGeneration &+= 1
        let ticket = setupGeneration
        stateLock.unlock()

        compileLock.lock()
        defer { compileLock.unlock() }

        stateLock.lock()
        let superseded = ticket != setupGeneration
        stateLock.unlock()
        if superseded {
            print("⏭️ \(name): superseded by a newer setup request, skipping compile")
            return false
        }

        do {
            try body()
            return true
        } catch {
            publish(nil)
            throw error
        }
    }

    // Raw float data from OCIO for each 1D LUT — used by CPU-side LUT sampling
    // to verify what the GPU shader should be computing.
    struct RawLUT {
        let name: String
        let floats: [Float]   // interleaved RGB (or R) per texel
        let width: Int
        let channels: Int
    }
    private(set) var rawLUTs: [RawLUT] = []

    /// Swift re-implementation of the shader's `ocio_reach_m_table_0_sample(h)` and
    /// the equivalent `.r` accessor for any 1D LUT — samples the raw float array using
    /// the same floor+1 / floor+2 interp logic the OCIO Metal shader generates.
    func sampleLUT1D_R(named name: String, h: Float) -> Float? {
        guard let lut = rawLUTs.first(where: { $0.name == name }) else { return nil }
        let iBase = floorf(h)
        let iLo = max(0, min(lut.width - 1, Int(iBase) + 1))
        let iHi = max(0, min(lut.width - 1, iLo + 1))
        let lo = lut.floats[iLo * lut.channels]        // .r component
        let hi = lut.floats[iHi * lut.channels]
        let t  = h - iBase
        return lo + t * (hi - lo)
    }

    /// Blit-based readback of `count` consecutive texels starting at `startIndex`
    /// from a named LUT texture (works for .private storage).
    /// Returns interleaved RGBA floats (4 per texel) regardless of storage format.
    func readLUTTexels(named name: String, startIndex: Int, count: Int) -> [Float]? {
        guard let info = currentSnapshot?.textureInfos.first(where: { $0.name == name }) else { return nil }
        let tex = info.texture
        // Always read back as RGBA (all LUT textures are rgba32Float after the upload fix)
        let bytesPerTexel = 4 * MemoryLayout<Float>.size
        let totalBytes = count * bytesPerTexel
        guard let queue = commandQueue,
              let buf = queue.makeCommandBuffer(),
              let blit = buf.makeBlitCommandEncoder(),
              let readback = device.makeBuffer(length: totalBytes, options: .storageModeShared)
        else { return nil }
        blit.copy(
            from: tex,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: startIndex, y: 0, z: 0),
            sourceSize:   MTLSize(width: count, height: 1, depth: 1),
            to: readback, destinationOffset: 0,
            destinationBytesPerRow: totalBytes,
            destinationBytesPerImage: totalBytes
        )
        blit.endEncoding()
        buf.commit()
        buf.waitUntilCompleted()
        let ptr = readback.contents().bindMemory(to: Float.self, capacity: count * 4)
        return Array(UnsafeBufferPointer(start: ptr, count: count * 4))
    }
    
    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()
    }
    
    deinit {
        // Metal resources are automatically cleaned up
    }

    
    /// Set up a GPU pass that converts `sourceSpace` → scene_linear.
    /// Returns the name of the resolved scene-linear color space (the output space).
    /// This is the first pass of the two-pass exposure pipeline for video frames.
    func setupLinearizeTransform(config: OCIOConfig, sourceSpace: String) throws -> String {
        guard let linearSpaceName = config.sceneLinearColorSpace() else {
            throw OCIOGPUError.shaderCompilationFailed(
                "No scene_linear role in OCIO config — cannot build linearize pre-pass")
        }

        let key = PipelineKey.linearize(sourceSpace: sourceSpace)
        try runSetup("Linearize") {
            if currentSnapshot?.key == key { return }

            print("🔧 Setting up linearize GPU pass: \(sourceSpace) → \(linearSpaceName)")
            rawLUTs.removeAll()

            let (processor, _) = try OCIOProcessor.makeLinearizeProcessor(
                config: config, sourceSpace: sourceSpace)
            var snapshot = try setupWithOCIOProcessor(processor)
            snapshot.key = key
            publish(snapshot)

            print("✅ Linearize GPU pass ready: \(sourceSpace) → \(linearSpaceName)")
        }
        return linearSpaceName
    }

    /// Setup GPU processor for a specific OCIO display transform
    func setupDisplayTransform(
        config: OCIOConfig,
        sourceSpace: String,
        display: String,
        view: String
    ) throws {
        let key = PipelineKey.display(sourceSpace: sourceSpace, display: display, view: view)
        try runSetup("Display transform") {
            // Check if we already have this transform cached
            if currentSnapshot?.key == key { return }

            print("🔧 Setting up Metal OCIO GPU transform...")
            rawLUTs.removeAll()

            // Create OCIO processor for display transform
            let processor = try OCIOProcessor.makeDisplayProcessor(
                config: config,
                sourceSpace: sourceSpace,
                display: display,
                view: view
            )

            // Shared extraction + compilation
            var snapshot = try setupWithOCIOProcessor(processor)
            snapshot.key = key
            publish(snapshot)

            print("✅ Metal OCIO GPU transform ready")
        }
    }

    /// Setup the GPU pipeline from an already-created OCIOProcessor.
    /// Used by both `setupDisplayTransform` (via OCIO display/view) and
    /// `setupDynamicACES2Transform` (via a programmatic GroupTransform).
    /// Clears rawLUTs before extracting shader + textures.
    func setupDynamicACES2Transform(_ processor: OCIOProcessor) throws {
        try runSetup("Dynamic ACES2") {
            print("🔧 Setting up Metal ACES2 dynamic GPU transform...")
            rawLUTs.removeAll()
            // Never cache: peak nits can change every call
            let snapshot = try setupWithOCIOProcessor(processor)
            publish(snapshot)
            print("✅ Metal ACES2 dynamic GPU transform ready")
        }
    }

    /// Setup combined GPU pipeline for Dynamic ACES2:
    /// source → scene_linear → ×exp2(exposure) → ACES2 output.
    /// Recompiles only when `sourceSpace`, `peakNits`, or `gamutTag` changes.
    /// The caller must create `aces2Processor` starting from `sceneLinearSpace`,
    /// not from `sourceSpace`.
    /// - Parameter lookSteps: optional AMF look steps (ACES2065-1 in/out) inserted as a
    ///   middle pass (scene_linear → ACES2065-1 → looks → scene_linear) before the ACES2
    ///   output transform, so AMF looks apply in Dynamic ACES2 mode and persist per-frame.
    @discardableResult
    func setupCombinedACES2Transform(config: OCIOConfig,
                                     sourceSpace: String,
                                     peakNits: Float,
                                     gamutTag: String,
                                     aces2Processor: OCIOProcessor,
                                     lookSteps: [[String: String]] = []) throws -> Bool {
        return try runSetup("Combined ACES2") {
            try setupCombinedACES2TransformLocked(config: config, sourceSpace: sourceSpace,
                                                  peakNits: peakNits, gamutTag: gamutTag,
                                                  aces2Processor: aces2Processor, lookSteps: lookSteps)
        }
    }

    private func setupCombinedACES2TransformLocked(config: OCIOConfig,
                                                   sourceSpace: String,
                                                   peakNits: Float,
                                                   gamutTag: String,
                                                   aces2Processor: OCIOProcessor,
                                                   lookSteps: [[String: String]]) throws {
        let lookSig = lookSteps.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|") }
            .joined(separator: ";")
        let key = PipelineKey.aces2(sourceSpace: sourceSpace, peakNits: peakNits,
                                    gamutTag: gamutTag, lookSig: lookSig)
        // Cache hit: same source space, peak nits, gamut and looks — already compiled.
        if currentSnapshot?.key == key { return }

        print("🔧 Setting up combined ACES2 GPU transform: \(sourceSpace) → [linear] → ACES2"
              + (lookSteps.isEmpty ? "" : " (+\(lookSteps.count) AMF look step(s))"))
        rawLUTs.removeAll()

        let (linProc, linSpace) = try OCIOProcessor.makeLinearizeProcessor(
            config: config, sourceSpace: sourceSpace)

        var linShaderNS: NSString?; var linTexNS: NSArray?
        try linProc.getGPUShaderAndTextures(&linShaderNS, texturesData: &linTexNS)
        guard let linCode = linShaderNS as? String else {
            throw OCIOGPUError.shaderCompilationFailed("No linearise Metal shader for ACES2 combined pass")
        }

        var a2ShaderNS: NSString?; var a2TexNS: NSArray?
        try aces2Processor.getGPUShaderAndTextures(&a2ShaderNS, texturesData: &a2TexNS)
        guard let dispCode = a2ShaderNS as? String else {
            throw OCIOGPUError.shaderCompilationFailed("No ACES2 Metal shader for combined pass")
        }

        let linInfos  = extractTextureInfos(from: linTexNS as? [[String: Any]] ?? [], shaderCode: linCode)
        let dispInfos = extractTextureInfos(from: a2TexNS  as? [[String: Any]] ?? [], shaderCode: dispCode)
        let reoLin    = reorderTexturesForOCIO(shaderCode: linCode,  textureInfos: linInfos)
        let reoDisp   = reorderTexturesForOCIO(shaderCode: dispCode, textureInfos: dispInfos)

        // Optional AMF look pass: scene_linear → ACES2065-1 → looks → scene_linear.
        var lookCode: String? = nil
        var reoLook: [TextureInfo] = []
        if !lookSteps.isEmpty {
            let acesSpace = config.colorSpace(forRole: "aces_interchange") ?? "ACES2065-1"
            var steps: [[String: String]] = [["type": "colorspace", "src": linSpace, "dst": acesSpace]]
            steps += lookSteps
            steps += [["type": "colorspace", "src": acesSpace, "dst": linSpace]]
            let lookProc = try OCIOProcessor.makeGroupTransformProcessor(config: config, steps: steps)
            var lookShaderNS: NSString?; var lookTexNS: NSArray?
            try lookProc.getGPUShaderAndTextures(&lookShaderNS, texturesData: &lookTexNS)
            if let lc = lookShaderNS as? String {
                lookCode = lc
                let lookInfos = extractTextureInfos(from: lookTexNS as? [[String: Any]] ?? [], shaderCode: lc)
                reoLook = reorderTexturesForOCIO(shaderCode: lc, textureInfos: lookInfos)
            }
        }

        var snapshot: PipelineSnapshot
        do {
            snapshot = try compileCombinedShader(linCode: linCode, dispCode: dispCode,
                                                 linTextures: reoLin, dispTextures: reoDisp,
                                                 lookCode: lookCode, lookTextures: reoLook)
        } catch {
            // Never leave the pipeline blank because a look-shader failed to build —
            // fall back to the no-look ACES2 pass so the image still renders.
            print("⚠️ ACES2 look-shader compile failed (\(error)); falling back to no-look ACES2 pass")
            snapshot = try compileCombinedShader(linCode: linCode, dispCode: dispCode,
                                                 linTextures: reoLin, dispTextures: reoDisp)
        }
        snapshot.key = key
        publish(snapshot)
        print("✅ Combined ACES2 GPU pass ready: \(sourceSpace) → \(linSpace) → ACES2 (\(snapshot.textures.count) LUTs)")
    }

    /// Extract shader + textures from `processor`, build Metal textures, compile the
    /// compute pipeline. Returns it unpublished.  Called by both display-transform and dynamic-ACES2 paths.
    private func setupWithOCIOProcessor(_ processor: OCIOProcessor) throws -> PipelineSnapshot {
        // Extract shader text AND all texture data in ONE call — both come from the same
        // GpuShaderDesc, guaranteeing they are consistent with each other.
        var shaderNSString: NSString?
        var texturesDataArray: NSArray?

        do {
            try processor.getGPUShaderAndTextures(&shaderNSString, texturesData: &texturesDataArray)
        } catch {
            throw OCIOGPUError.shaderCompilationFailed("Failed to get Metal shader/textures: \(error.localizedDescription)")
        }

        guard let metalShaderCode = shaderNSString as? String else {
            throw OCIOGPUError.shaderCompilationFailed("No Metal shader code generated")
        }

        let rawInfos = extractTextureInfos(
            from: texturesDataArray as? [[String: Any]] ?? [],
            shaderCode: metalShaderCode)

        // Recompile shader with correct texture order
        return try compileMetalShader(shaderCode: metalShaderCode, textureInfos: rawInfos)
    }

    // MARK: - Texture extraction helper

    /// Build Metal `TextureInfo` objects from the raw dictionary array that
    /// `getGPUShaderAndTextures` returns.  The `shaderCode` is needed to detect
    /// the 1-channel LUT over-read case.
    private func extractTextureInfos(from texturesData: [[String: Any]],
                                     shaderCode: String) -> [TextureInfo] {
        var infos: [TextureInfo] = []

        for textureInfo in texturesData {
            guard let type = textureInfo["type"] as? String,
                  let data = textureInfo["data"] as? Data,
                  let name = textureInfo["name"] as? String else { continue }

            if type == "3D", let edgeLength = textureInfo["edgeLength"] as? Int {
                if let tex = createMetal3DLUTTexture(data: data, edgeLength: edgeLength) {
                    infos.append(TextureInfo(name: name, type: "3D", texture: tex))
                }
            } else if type == "2D",
                      let width    = textureInfo["width"]    as? Int,
                      let height   = textureInfo["height"]   as? Int,
                      let channels = textureInfo["channels"] as? Int {
                if let tex = createMetal2DLUTTexture(data: data, width: width, height: height, channels: channels) {
                    infos.append(TextureInfo(name: name, type: "2D", texture: tex))
                }
            } else if type == "1D",
                      let width = textureInfo["width"] as? Int,
                      var channels = textureInfo["channels"] as? Int {
                let channelType = textureInfo["channelType"] as? String ?? "unknown"
                // OCIO over-reports 3 channels for some 1D LUTs that the shader samples as .r only.
                if channels == 3 && !shaderSamplesRGB(textureName: name, shaderCode: shaderCode) {
                    print("  ⚠️  \(name): OCIO says 3ch but shader uses .r only — overriding to 1ch")
                    channels = 1
                }
                let floatArray = data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> [Float] in
                    Array(p.bindMemory(to: Float.self).prefix(width * channels))
                }
                rawLUTs.append(RawLUT(name: name, floats: floatArray, width: width, channels: channels))
                if let tex = createMetal1DLUTTexture(data: data, width: width, channels: channels) {
                    infos.append(TextureInfo(name: name, type: "1D", texture: tex))
                }
            }
        }
        return infos
    }

    // MARK: - Combined single-pass transform (video frames)

    /// Set up a single Metal compute kernel that performs the full pipeline:
    ///   source → scene_linear  (OCIO linearise pass)
    ///   × exp2(exposure)       (applied in genuine scene-linear space)
    ///   scene_linear → display/view  (OCIO display pass)
    ///
    /// The two OCIO-generated shader functions are embedded in one kernel with
    /// their helper identifiers prefixed to avoid name collisions.
    /// `processTexture(input:exposure:)` works unchanged as the dispatch entry point.
    /// - Parameter lookSteps: optional AMF look-transform steps (ACES2065-1 in/out) to
    ///   fold into the display stage. When present the display processor becomes a group
    ///   `scene_linear → ACES2065-1 → looks → display/view`, so the looks are baked into
    ///   the compiled shader and applied to every frame (persisting across a sequence)
    ///   rather than baked into a per-frame source texture.
    @discardableResult
    func setupCombinedTransform(config: OCIOConfig,
                                sourceSpace: String,
                                display: String,
                                view: String,
                                lookSteps: [[String: String]] = []) throws -> Bool {
        return try runSetup("Combined transform") {
            try setupCombinedTransformLocked(config: config, sourceSpace: sourceSpace,
                                             display: display, view: view, lookSteps: lookSteps)
        }
    }

    private func setupCombinedTransformLocked(config: OCIOConfig,
                                              sourceSpace: String,
                                              display: String,
                                              view: String,
                                              lookSteps: [[String: String]]) throws {
        let lookSig = lookSteps.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|") }
            .joined(separator: ";")
        let key = PipelineKey.combined(sourceSpace: sourceSpace, display: display,
                                       view: view, lookSig: lookSig)
        if currentSnapshot?.key == key { return }

        guard let sceneLinearSpace = config.sceneLinearColorSpace() else {
            throw OCIOGPUError.shaderCompilationFailed(
                "No scene_linear role in OCIO config – cannot build combined single-pass transform")
        }

        print("🔧 Setting up combined single-pass GPU transform: \(sourceSpace) → [\(sceneLinearSpace)] → \(display)/\(view)"
              + (lookSteps.isEmpty ? "" : " (+\(lookSteps.count) AMF look step(s))"))
        rawLUTs.removeAll()

        // Linearise pass (always required).
        let (linProc, _) = try OCIOProcessor.makeLinearizeProcessor(
            config: config, sourceSpace: sourceSpace)
        var linShaderNS:  NSString?; var linTexArray:  NSArray?
        try linProc.getGPUShaderAndTextures(&linShaderNS,  texturesData: &linTexArray)
        guard let linCode = linShaderNS as? String else {
            throw OCIOGPUError.shaderCompilationFailed("No linearise Metal shader from OCIO")
        }
        let linInfos = extractTextureInfos(from: linTexArray as? [[String: Any]] ?? [], shaderCode: linCode)
        let reoLin   = reorderTexturesForOCIO(shaderCode: linCode, textureInfos: linInfos)

        // Compile lin → exposure → dispProc, where dispProc is either a plain display
        // processor or a group that also folds in the AMF looks.
        func compile(dispProc: OCIOProcessor) throws -> PipelineSnapshot {
            var dispShaderNS: NSString?; var dispTexArray: NSArray?
            try dispProc.getGPUShaderAndTextures(&dispShaderNS, texturesData: &dispTexArray)
            guard let dispCode = dispShaderNS as? String else {
                throw OCIOGPUError.shaderCompilationFailed("No display Metal shader from OCIO")
            }
            let dispInfos = extractTextureInfos(from: dispTexArray as? [[String: Any]] ?? [], shaderCode: dispCode)
            let reoDisp   = reorderTexturesForOCIO(shaderCode: dispCode, textureInfos: dispInfos)
            return try compileCombinedShader(linCode: linCode, dispCode: dispCode,
                                             linTextures: reoLin, dispTextures: reoDisp)
        }
        func plainDisplay() throws -> OCIOProcessor {
            try OCIOProcessor.makeDisplayProcessor(
                config: config, sourceSpace: sceneLinearSpace, display: display, view: view)
        }

        var snapshot: PipelineSnapshot
        if lookSteps.isEmpty {
            snapshot = try compile(dispProc: try plainDisplay())
        } else {
            // scene_linear → ACES2065-1 → [looks] → display/view, as one group transform.
            // Never leave the pipeline blank because a look-shader failed — fall back.
            do {
                let acesSpace = config.colorSpace(forRole: "aces_interchange") ?? "ACES2065-1"
                var steps: [[String: String]] = [["type": "colorspace", "src": sceneLinearSpace, "dst": acesSpace]]
                steps += lookSteps
                steps += [["type": "display", "src": acesSpace, "display": display, "view": view]]
                snapshot = try compile(dispProc: try OCIOProcessor.makeGroupTransformProcessor(config: config, steps: steps))
            } catch {
                print("⚠️ Display look-shader failed (\(error)); falling back to no-look display pass")
                snapshot = try compile(dispProc: try plainDisplay())
            }
        }

        snapshot.key = key
        publish(snapshot)
        print("✅ Combined single-pass GPU transform ready (\(snapshot.textures.count) LUT textures total)")
    }

    /// Set up a combined GPU transform that uses an inverse display transform for the first step.
    /// Pipeline: inverse(inverseDisplay/inverseView) → scene_linear → ×exposure → display/view
    @discardableResult
    func setupCombinedInverseDisplayTransform(config: OCIOConfig,
                                               inverseDisplay: String,
                                               inverseView: String,
                                               display: String,
                                               view: String) throws -> Bool {
        return try runSetup("Combined inverse display") {
            try setupCombinedInverseDisplayTransformLocked(config: config,
                                                           inverseDisplay: inverseDisplay,
                                                           inverseView: inverseView,
                                                           display: display, view: view)
        }
    }

    private func setupCombinedInverseDisplayTransformLocked(config: OCIOConfig,
                                                            inverseDisplay: String,
                                                            inverseView: String,
                                                            display: String,
                                                            view: String) throws {
        // Use a synthetic source key so the cache can distinguish inverse display from normal
        let syntheticSource = "inv(\(inverseDisplay)/\(inverseView))"
        let key = PipelineKey.combinedInverse(syntheticSource: syntheticSource,
                                              display: display, view: view)
        if currentSnapshot?.key == key { return }

        guard let sceneLinearSpace = config.sceneLinearColorSpace() else {
            throw OCIOGPUError.shaderCompilationFailed(
                "No scene_linear role in OCIO config – cannot build combined inverse display transform")
        }

        print("🔧 Setting up combined inverse display GPU transform: inv(\(inverseDisplay)/\(inverseView)) → [\(sceneLinearSpace)] → \(display)/\(view)")
        rawLUTs.removeAll()

        // Build the two processors
        let invProc = try OCIOProcessor.makeInverseDisplayProcessor(
            config: config, display: inverseDisplay, view: inverseView)
        let dispProc = try OCIOProcessor.makeDisplayProcessor(
            config: config, sourceSpace: sceneLinearSpace, display: display, view: view)

        // Extract shader code + LUT textures from each
        var linShaderNS:  NSString?; var linTexArray:  NSArray?
        try invProc.getGPUShaderAndTextures(&linShaderNS,  texturesData: &linTexArray)
        guard let linCode = linShaderNS as? String else {
            throw OCIOGPUError.shaderCompilationFailed("No inverse display Metal shader from OCIO")
        }

        var dispShaderNS: NSString?; var dispTexArray: NSArray?
        try dispProc.getGPUShaderAndTextures(&dispShaderNS, texturesData: &dispTexArray)
        guard let dispCode = dispShaderNS as? String else {
            throw OCIOGPUError.shaderCompilationFailed("No display Metal shader from OCIO")
        }

        // Build + reorder texture arrays
        let linInfos  = extractTextureInfos(from: linTexArray  as? [[String: Any]] ?? [], shaderCode: linCode)
        let dispInfos = extractTextureInfos(from: dispTexArray as? [[String: Any]] ?? [], shaderCode: dispCode)
        let reoLin    = reorderTexturesForOCIO(shaderCode: linCode,  textureInfos: linInfos)
        let reoDisp   = reorderTexturesForOCIO(shaderCode: dispCode, textureInfos: dispInfos)

        var snapshot = try compileCombinedShader(linCode: linCode, dispCode: dispCode,
                                                 linTextures: reoLin, dispTextures: reoDisp)
        snapshot.key = key
        publish(snapshot)
        print("✅ Combined inverse display GPU transform ready (\(snapshot.textures.count) LUT textures total)")
    }

    /// Inverse-display variant of `setupCombinedACES2Transform`.
    /// Linearises via inverse display/view instead of a simple colorspace transform.
    /// Pipeline: inv(display/view) → scene_linear → ×exposure → ACES2
    @discardableResult
    func setupCombinedInverseDisplayACES2Transform(config: OCIOConfig,
                                                    inverseDisplay: String,
                                                    inverseView: String,
                                                    peakNits: Float,
                                                    gamutTag: String,
                                                    aces2Processor: OCIOProcessor) throws -> Bool {
        return try runSetup("Combined inverse-display ACES2") {
            try setupCombinedInverseDisplayACES2TransformLocked(config: config,
                                                                inverseDisplay: inverseDisplay,
                                                                inverseView: inverseView,
                                                                peakNits: peakNits,
                                                                gamutTag: gamutTag,
                                                                aces2Processor: aces2Processor)
        }
    }

    private func setupCombinedInverseDisplayACES2TransformLocked(config: OCIOConfig,
                                                                 inverseDisplay: String,
                                                                 inverseView: String,
                                                                 peakNits: Float,
                                                                 gamutTag: String,
                                                                 aces2Processor: OCIOProcessor) throws {
        let syntheticSource = "inv(\(inverseDisplay)/\(inverseView))"
        // This pass applies no AMF looks, so its look signature is always empty.
        let key = PipelineKey.aces2(sourceSpace: syntheticSource, peakNits: peakNits,
                                    gamutTag: gamutTag, lookSig: "")
        if currentSnapshot?.key == key { return }

        print("🔧 Setting up combined inverse-display ACES2 GPU transform: \(syntheticSource) → [linear] → ACES2")
        rawLUTs.removeAll()

        let invProc = try OCIOProcessor.makeInverseDisplayProcessor(
            config: config, display: inverseDisplay, view: inverseView)

        var linShaderNS: NSString?; var linTexNS: NSArray?
        try invProc.getGPUShaderAndTextures(&linShaderNS, texturesData: &linTexNS)
        guard let linCode = linShaderNS as? String else {
            throw OCIOGPUError.shaderCompilationFailed("No inverse display Metal shader for ACES2 combined pass")
        }

        var a2ShaderNS: NSString?; var a2TexNS: NSArray?
        try aces2Processor.getGPUShaderAndTextures(&a2ShaderNS, texturesData: &a2TexNS)
        guard let dispCode = a2ShaderNS as? String else {
            throw OCIOGPUError.shaderCompilationFailed("No ACES2 Metal shader for combined pass")
        }

        let linInfos  = extractTextureInfos(from: linTexNS as? [[String: Any]] ?? [], shaderCode: linCode)
        let dispInfos = extractTextureInfos(from: a2TexNS  as? [[String: Any]] ?? [], shaderCode: dispCode)
        let reoLin    = reorderTexturesForOCIO(shaderCode: linCode,  textureInfos: linInfos)
        let reoDisp   = reorderTexturesForOCIO(shaderCode: dispCode, textureInfos: dispInfos)

        var snapshot = try compileCombinedShader(linCode: linCode, dispCode: dispCode,
                                                 linTextures: reoLin, dispTextures: reoDisp)
        snapshot.key = key
        publish(snapshot)
        print("✅ Combined inverse-display ACES2 GPU pass ready: \(syntheticSource) → ACES2 (\(snapshot.textures.count) LUTs)")
    }

    /// Returns true when the combined ACES2 pipeline is already compiled for the given parameters,
    /// meaning `setupCombinedACES2Transform` and the processor creation can be skipped entirely.
    func isACES2PipelineReady(sourceSpace: String, peakNits: Float, gamutTag: String,
                              lookSig: String = "") -> Bool {
        // Fast pre-check only: the authoritative check runs inside `runSetup`, atomically
        // with the compile, so a stale answer here at worst costs one coalesced request.
        return currentSnapshot?.key == PipelineKey.aces2(sourceSpace: sourceSpace, peakNits: peakNits,
                                              gamutTag: gamutTag, lookSig: lookSig)
    }

    /// - Parameters:
    ///   - lookCode/lookTextures: optional middle OCIO pass (AMF look group, scene_linear
    ///     in/out) inserted between exposure and the display/ACES2 pass.
    private func compileCombinedShader(linCode: String, dispCode: String,
                                       linTextures: [TextureInfo],
                                       dispTextures: [TextureInfo],
                                       lookCode: String? = nil,
                                       lookTextures: [TextureInfo] = []) throws -> PipelineSnapshot {
        let source = generateCombinedShaderWrapper(linCode: linCode, dispCode: dispCode,
                                                   linTextures: linTextures, dispTextures: dispTextures,
                                                   lookCode: lookCode, lookTextures: lookTextures)
        let opts = MTLCompileOptions()
        opts.fastMathEnabled = false
        let library = try device.makeLibrary(source: source, options: opts)
        guard let fn = library.makeFunction(name: "ocioColorTransform") else {
            throw OCIOGPUError.shaderCompilationFailed("No kernel function in combined shader")
        }
        let pso = try device.makeComputePipelineState(function: fn)
        // Texture binding order must match the kernel parameter order: lin, look, disp.
        let infos = linTextures + lookTextures + dispTextures
        print("✅ Combined shader compiled – \(linTextures.count) lin + \(lookTextures.count) look + \(dispTextures.count) disp LUTs")
        return PipelineSnapshot(pipelineState: pso, textures: infos.map { $0.texture }, textureInfos: infos)
    }

    private func generateCombinedShaderWrapper(linCode: String, dispCode: String,
                                               linTextures: [TextureInfo],
                                               dispTextures: [TextureInfo],
                                               lookCode: String? = nil,
                                               lookTextures: [TextureInfo] = []) -> String {
        // Rename OCIO identifiers so the shader blobs don't define the same symbol names.
        // "OCIOTransform"  → "OCIOLinearize" / "OCIOLook" / "OCIODisplay"
        // "ocio_"          → "lzr_"          / "lok_"     / "dsp_"
        let lCode = linCode
            .replacingOccurrences(of: "OCIOTransform", with: "OCIOLinearize")
            .replacingOccurrences(of: "ocio_", with: "lzr_")
        let dCode = dispCode
            .replacingOccurrences(of: "OCIOTransform", with: "OCIODisplay")
            .replacingOccurrences(of: "ocio_", with: "dsp_")
        let kCode = lookCode.map {
            $0.replacingOccurrences(of: "OCIOTransform", with: "OCIOLook")
              .replacingOccurrences(of: "ocio_", with: "lok_")
        }

        func prefixed(_ infos: [TextureInfo], _ p: String) -> [TextureInfo] {
            infos.map { TextureInfo(name: $0.name.replacingOccurrences(of: "ocio_", with: p),
                                   type: $0.type, texture: $0.texture) }
        }
        let rLin  = prefixed(linTextures,  "lzr_")
        let rLook = prefixed(lookTextures, "lok_")
        let rDisp = prefixed(dispTextures, "dsp_")

        // Build kernel texture declarations + function call parameter lists.
        // Declaration / binding order: lin, look, disp (matches orderedTextures).
        var decls = ""
        var linParams  = ""
        var lookParams = ""
        var dispParams = ""
        var idx = 2

        func appendTex(_ info: TextureInfo, _ params: inout String) {
            let comma  = ",\n                "
            let sampler = info.type == "1D" ? "nearestSampler" : "linearSampler"
            switch info.type {
            case "3D": decls += "\(comma)texture3d<float, access::sample> \(info.name) [[texture(\(idx))]]"
            case "2D": decls += "\(comma)texture2d<float, access::sample> \(info.name) [[texture(\(idx))]]"
            default:   decls += "\(comma)texture1d<float, access::sample> \(info.name) [[texture(\(idx))]]"
            }
            params += (params.isEmpty ? "" : ",\n                    ")
            params += "\(info.name),\n                    \(sampler)"
            idx += 1
        }
        for info in rLin  { appendTex(info, &linParams)  }
        for info in rLook { appendTex(info, &lookParams) }
        for info in rDisp { appendTex(info, &dispParams) }

        let linCall  = linParams.isEmpty  ? "color" : "\(linParams),\n                    color"
        let lookCall = lookParams.isEmpty ? "color" : "\(lookParams),\n                    color"
        let dispCall = dispParams.isEmpty ? "color" : "\(dispParams),\n                    color"

        let lookFunction = kCode.map { "\n        // ── Look pass: AMF looks (scene_linear in/out) ───────────────────────────\n        \($0)\n" } ?? ""
        // Plain concatenation (not a multi-line literal) so it can be safely interpolated
        // mid-kernel without tripping Swift's multi-line indentation rule.
        let lookInvocation = kCode != nil
            ? "// Look pass – AMF look transforms (LMTs) applied in scene-linear\n            color = OCIOLook(\n                    \(lookCall)\n            );"
            : ""

        return """
        #include <metal_stdlib>
        using namespace metal;

        // ── Pass 1: source → scene_linear ────────────────────────────────────────
        \(lCode)
        \(lookFunction)
        // ── Pass 2: scene_linear → display/view ──────────────────────────────────
        \(dCode)

        kernel void ocioColorTransform(
            texture2d<float, access::read>  inputTexture  [[texture(0)]],
            texture2d<float, access::write> outputTexture [[texture(1)]]\(decls),
            constant float& exposure [[buffer(0)]],
            constant float4& channelMask [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) { return; }
            constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
            constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

            float4 color = inputTexture.read(gid);

            // Pass 1 – decode source encoding (log, gamma, etc.) → scene-linear
            color = OCIOLinearize(
                \(linCall)
            );

            // Exposure applied in scene-linear space – always physically correct
            color.rgb *= exp2(exposure);
            \(lookInvocation)

            // Channel isolation – replicate selected channel to greyscale
            if (channelMask.w > 0.5)
                color.rgb = float3(color.a);
            else if (channelMask.x + channelMask.y + channelMask.z < 3.0)
                color.rgb = float3(dot(color.rgb, channelMask.xyz));

            // Pass 2 – apply display / view transform (ACES ODT, tone mapping, etc.)
            color = OCIODisplay(
                \(dispCall)
            );

            outputTexture.write(color, gid);
        }
        """
    }

    /// True when any pipeline (display transform or ACES2) has been compiled and
    /// is ready to use via `encodeTransform`. Both paths share the same snapshot,
    /// so this is the only check needed.
    var isDisplayPipelineReady: Bool { currentSnapshot != nil }

    /// Clear the compiled pipeline state so the next draw falls back to rendering
    /// `currentImage.metalTexture` directly (no OCIO shader applied).
    /// Used after a CPU-side AMF pipeline apply to show the pre-processed result.
    func invalidate() {
        publish(nil)
    }

    /// Encode the OCIO transform into an **existing** command buffer using a
    /// caller-supplied output texture.  No allocation, no async, no continuation.
    /// Intended for use inside a MTKView draw() loop where the command buffer is
    /// already open and the output texture is a persistent per-view allocation.
    /// Returns `false` (and encodes nothing) if the pipeline is not ready.
    @discardableResult
    func encodeTransform(into commandBuffer: MTLCommandBuffer,
                         input: MTLTexture,
                         output: MTLTexture,
                         exposure: Float,
                         channelMask: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)) -> Bool {
        // One consistent snapshot of pipeline + LUTs for this encode.
        guard let snapshot = currentSnapshot else { return false }
        let pipelineState = snapshot.pipelineState
        let orderedTextures = snapshot.textures
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        retainUntilCompleted(snapshot, by: commandBuffer)

        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(input, index: 0)
        computeEncoder.setTexture(output, index: 1)

        var exposureValue = exposure
        computeEncoder.setBytes(&exposureValue, length: MemoryLayout<Float>.size, index: 0)

        var mask = channelMask
        computeEncoder.setBytes(&mask, length: MemoryLayout<SIMD4<Float>>.size, index: 1)

        for (index, texture) in orderedTextures.enumerated() {
            computeEncoder.setTexture(texture, index: 2 + index)
        }

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width:  (input.width  + 15) / 16,
            height: (input.height + 15) / 16,
            depth:  1
        )
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()
        return true
    }

    /// Apply OCIO transform with exposure on the GPU (Metal compute)
    func processTexture(
        input: MTLTexture,
        exposure: Float,
        channelMask: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
    ) async -> MTLTexture? {
        // Take one consistent snapshot of pipeline + LUTs at the start of this call;
        // a concurrent setup may publish a new one at any time.
        guard let snapshot = currentSnapshot else {
            print("⚠️ Metal compute pipeline not set up")
            return nil
        }
        let pipelineState = snapshot.pipelineState
        let orderedTextures = snapshot.textures
        
        guard let commandQueue = commandQueue else {
            print("❌ No Metal command queue")
            return nil
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("❌ Failed to create command buffer")
            return nil
        }
        
        // Create output texture.
        // Always use rgba16Float so:
        //   (a) the compute shader can write to it regardless of input format
        //       (Metal disallows access::write on bgra8Unorm / rgba16Unorm in compute)
        //   (b) HDR values from the OCIO display transform aren't clamped to [0,1]
        //   (c) the downstream MetalEDRRenderer / CAMetalLayer get float headroom
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: input.width,
            height: input.height,
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderRead, .shaderWrite]
        outputDescriptor.storageMode = .private
        
        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            print("❌ Failed to create output texture")
            return nil
        }
        
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            print("❌ Failed to create compute encoder")
            return nil
        }
        
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(input, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)
        
        // Set exposure value
        var exposureValue = exposure
        computeEncoder.setBytes(&exposureValue, length: MemoryLayout<Float>.size, index: 0)
        
        // Set channel mask
        var mask = channelMask
        computeEncoder.setBytes(&mask, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        
        // Set OCIO LUT textures using the snapshot captured at function entry
        for (index, texture) in orderedTextures.enumerated() {
            computeEncoder.setTexture(texture, index: 2 + index)
        }
        
        // Dispatch compute threads
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (input.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (input.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        retainUntilCompleted(snapshot, by: commandBuffer)
        return await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { buf in
                continuation.resume(returning: buf.status == .completed ? outputTexture : nil)
            }
            commandBuffer.commit()
        }
    }
    
    // MARK: - Metal Helpers
    
    /// Returns true if the OCIO-generated shader treats this texture as multi-channel (RGB / float3).
    /// OCIO always emits a helper function `float3 <name>_sample(...)` for RGB textures and
    /// `float <name>_sample(...)` for red-only textures — match on that, not on nested-paren
    /// accessor scanning which breaks on multi-expression argument lists.
    private func shaderSamplesRGB(textureName: String, shaderCode: String) -> Bool {
        if shaderCode.contains("float3 \(textureName)_sample") { return true  }
        if shaderCode.contains("float \(textureName)_sample")  { return false }
        // Fallback: look for .rgb immediately following any .sample() result
        return shaderCode.contains("\(textureName).sample") &&
               shaderCode.range(of: "\(textureName)\\.sample[^)]+\\)\\.rgb",
                                  options: .regularExpression) != nil
    }

    private struct TextureInfo {
        let name: String
        let type: String
        let texture: MTLTexture
    }
    
    private func compileMetalShader(shaderCode: String, textureInfos: [TextureInfo]) throws -> PipelineSnapshot {
        do {
            let computeKernelWrapper = try generateShaderWrapper(shaderCode: shaderCode, textureInfos: textureInfos)
            let reorderedInfos = reorderTexturesForOCIO(shaderCode: shaderCode, textureInfos: textureInfos)
            let compileOptions = MTLCompileOptions()
            compileOptions.fastMathEnabled = false  // ACES uses pow/log/sqrt that fast-math can miscompile
            let library = try device.makeLibrary(source: computeKernelWrapper, options: compileOptions)
            guard let function = library.makeFunction(name: "ocioColorTransform") else {
                throw OCIOGPUError.shaderCompilationFailed("Failed to find compute kernel function")
            }
            let newPipeline = try device.makeComputePipelineState(function: function)
            print("✅ Metal OCIO shader compiled (\(textureInfos.count) LUT textures)")
            return PipelineSnapshot(pipelineState: newPipeline,
                                    textures: reorderedInfos.map { $0.texture },
                                    textureInfos: reorderedInfos)
        } catch {
            print("❌ Shader compilation failed: \(error.localizedDescription)")
            throw OCIOGPUError.shaderCompilationFailed("Metal shader compilation failed: \(error.localizedDescription)")
        }
    }
    
    private func generateShaderWrapper(shaderCode: String, textureInfos: [TextureInfo]) throws -> String {
        // Parse the OCIO shader to determine the expected parameter order
        let orderedTextureInfos = reorderTexturesForOCIO(shaderCode: shaderCode, textureInfos: textureInfos)
        
        var textureDeclarations = ""
        var functionCallParameters = ""
        
        var textureIndex = 2
        for info in orderedTextureInfos {
            let comma = ",\n                "
            
            if info.type == "3D" {
                textureDeclarations += "\(comma)texture3d<float, access::sample> \(info.name) [[texture(\(textureIndex))]]"
                functionCallParameters += (functionCallParameters.isEmpty ? "" : ",\n                    ")
                functionCallParameters += "\(info.name),\n                    linearSampler"
            } else if info.type == "2D" {
                textureDeclarations += "\(comma)texture2d<float, access::sample> \(info.name) [[texture(\(textureIndex))]]"
                functionCallParameters += (functionCallParameters.isEmpty ? "" : ",\n                    ")
                functionCallParameters += "\(info.name),\n                    linearSampler"
            } else if info.type == "1D" {
                textureDeclarations += "\(comma)texture1d<float, access::sample> \(info.name) [[texture(\(textureIndex))]]"
                functionCallParameters += (functionCallParameters.isEmpty ? "" : ",\n                    ")
                functionCallParameters += "\(info.name),\n                    nearestSampler"
            }
            textureIndex += 1
        }
        
        return """
        #include <metal_stdlib>
        using namespace metal;
        
        // OCIO-generated transformation function
        \(shaderCode)
        
        kernel void ocioColorTransform(
            texture2d<float, access::read> inputTexture [[texture(0)]],
            texture2d<float, access::write> outputTexture [[texture(1)]]\(textureDeclarations),
            constant float& exposure [[buffer(0)]],
            constant float4& channelMask [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
                return;
            }
            
            // Create samplers for the LUT textures
            // Use LINEAR filtering for 3D LUTs (smooth color gradients)
            // Use NEAREST filtering for 1D LUTs (preserve sharp gamut compression curves)
            constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
            constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
            
            // Read input pixel
            float4 color = inputTexture.read(gid);
            
            // Apply exposure in scene-linear space
            color.rgb *= exp2(exposure);
            
            // Channel isolation – replicate selected channel to greyscale
            if (channelMask.w > 0.5)
                color.rgb = float3(color.a);
            else if (channelMask.x + channelMask.y + channelMask.z < 3.0)
                color.rgb = float3(dot(color.rgb, channelMask.xyz));
            
            // Apply OCIO color transformation with all required textures
            color = OCIOTransform(
                \(functionCallParameters),
                color
            );
            
            // Write output
            outputTexture.write(color, gid);
        }
        """
    }
    
    /// Parse OCIO shader to determine the expected texture parameter order
    private func reorderTexturesForOCIO(shaderCode: String, textureInfos: [TextureInfo]) -> [TextureInfo] {
        // Look for the constructor signature in the OCIO shader
        // Example: ocioOCIOTransform(texture3d<float> ocio_lut3d_1, sampler ..., texture2d<float> ocio_lut1d_0, ...)
        
        // Create a lookup dictionary
        var textureDict: [String: TextureInfo] = [:]
        for info in textureInfos {
            textureDict[info.name] = info
        }
        
        // Find the constructor or function signature
        let lines = shaderCode.components(separatedBy: .newlines)
        var orderedNames: [String] = []
        var inConstructor = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Look for constructor start
            if trimmed.contains("ocioOCIOTransform(") {
                inConstructor = true
            }
            
            if inConstructor {
                // Extract texture names - look for patterns like "texture3d<float> ocio_lut3d_1" or "texture2d<float> ocio_lut1d_0" or "texture1d<float> ocio_reach_m_table_0"
                if trimmed.contains("texture1d<float>") || trimmed.contains("texture2d<float>") || trimmed.contains("texture3d<float>") {
                    // Split by whitespace and look for texture names
                    let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    for (index, part) in parts.enumerated() {
                        if (part.contains("texture1d") || part.contains("texture2d") || part.contains("texture3d")) && index + 1 < parts.count {
                            let nextPart = parts[index + 1]
                            // Remove any trailing characters like commas or semicolons
                            let textureName = nextPart.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
                            if textureDict[textureName] != nil && !orderedNames.contains(textureName) {
                                orderedNames.append(textureName)
                            }
                        }
                    }
                }
                
                // Stop at closing parenthesis of constructor
                if trimmed.hasPrefix("}") {
                    break
                }
            }
        }
        
        // If we found an ordering, use it
        if orderedNames.count == textureInfos.count {
            var reordered: [TextureInfo] = []
            for name in orderedNames {
                if let info = textureDict[name] {
                    reordered.append(info)
                }
            }
            return reordered
        }
        
        print("⚠️ Could not parse OCIO texture order (found \(orderedNames.count)/\(textureInfos.count)), using original order")
        return textureInfos
    }
    
    private func createMetal1DLUTTexture(data: Data, width: Int, channels: Int) -> MTLTexture? {
        // Build the upload payload: r32Float for 1-channel, rgba32Float for 3-channel
        // (Metal has no rgb32Float format, so we pad to 4 components).
        let pixelFormat: MTLPixelFormat
        let uploadData: Data
        let bytesPerTexel: Int

        if channels == 1 {
            // Always use rgba32Float even for single-channel LUTs.
            // Storing as r32Float works fine for the shader (which only reads .r),
            // but keeping a uniform pixel format simplifies readback and avoids
            // per-format branching everywhere.  Memory cost: trivial (362 texels).
            pixelFormat = .rgba32Float
            bytesPerTexel = 4 * MemoryLayout<Float>.size
            uploadData = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
                let floats = ptr.bindMemory(to: Float.self)
                var out = [Float]()
                out.reserveCapacity(width * 4)
                for i in 0..<width {
                    out.append(i < floats.count ? floats[i] : 0)
                    out.append(0); out.append(0); out.append(0)
                }
                return Data(bytes: out, count: out.count * MemoryLayout<Float>.size)
            }
        } else if channels == 3 {
            pixelFormat = .rgba32Float
            bytesPerTexel = 4 * MemoryLayout<Float>.size
            let n = width * 3
            uploadData = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
                let floats = ptr.bindMemory(to: Float.self)
                var out = [Float]()
                out.reserveCapacity(width * 4)
                for i in stride(from: 0, to: n, by: 3) {
                    out.append(floats[i])
                    out.append(floats[i + 1])
                    out.append(floats[i + 2])
                    out.append(1.0)
                }
                return Data(bytes: out, count: out.count * MemoryLayout<Float>.size)
            }
        } else {
            print("⚠️ Unexpected channel count for 1D texture: \(channels)")
            return nil
        }

        // Use .private storage + blit upload to guarantee GPU texture cache coherency.
        //
        // CPU writes via texture.replace() on a .shared texture are NOT tracked by
        // Metal's hazard system. When Metal's texture pool recycles a physical address,
        // the GPU's sampler cache may still hold stale data from a prior dispatch that
        // used a texture at that address. Using .private storage forces all data through
        // a command-buffer blit, which Metal tracks — guaranteeing cache invalidation
        // before the next compute pass reads the texture.
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            print("❌ Failed to create 1D LUT texture")
            return nil
        }

        // Staging buffer in shared memory — CPU writes here, blit encoder copies to private texture.
        let stagingByteCount = uploadData.count
        guard let stagingBuffer = device.makeBuffer(bytes: uploadData.withUnsafeBytes({ $0.baseAddress! }),
                                                    length: stagingByteCount,
                                                    options: .storageModeShared) else {
            print("❌ Failed to create 1D LUT staging buffer")
            return nil
        }

        guard let blitQueue = commandQueue,
              let blitCmdBuf = blitQueue.makeCommandBuffer(),
              let blitEncoder = blitCmdBuf.makeBlitCommandEncoder() else {
            print("❌ Failed to create blit command buffer for LUT upload")
            return nil
        }

        blitEncoder.copy(
            from: stagingBuffer,
            sourceOffset: 0,
            sourceBytesPerRow: width * bytesPerTexel,
            sourceBytesPerImage: width * bytesPerTexel,
            sourceSize: MTLSize(width: width, height: 1, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        blitCmdBuf.commit()
        blitCmdBuf.waitUntilCompleted()

        print("✅ Metal 1D LUT texture uploaded (private+blit, \(width) texels, \(pixelFormat == .r32Float ? "R32Float" : "RGBA32Float"))")
        return texture
    }

    private func createMetal3DLUTTexture(data: Data, edgeLength: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float  // OCIO typically uses RGB, but Metal prefers RGBA
        descriptor.width = edgeLength
        descriptor.height = edgeLength
        descriptor.depth = edgeLength
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared  // Use shared so CPU can write to it
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            print("❌ Failed to create 3D LUT texture")
            return nil
        }
        
        // Upload data to texture
        // Note: OCIO provides RGB data, we may need to convert to RGBA
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: edgeLength, height: edgeLength, depth: edgeLength)
        )
        
        // Convert RGB float data to RGBA if needed
        let rgbComponentCount = edgeLength * edgeLength * edgeLength * 3
        let rgbaData = data.withUnsafeBytes { (rgbPtr: UnsafeRawBufferPointer) -> Data in
            let rgbFloats = rgbPtr.bindMemory(to: Float.self)
            var rgbaFloats = [Float]()
            rgbaFloats.reserveCapacity(edgeLength * edgeLength * edgeLength * 4)
            
            for i in stride(from: 0, to: rgbComponentCount, by: 3) {
                rgbaFloats.append(rgbFloats[i])     // R
                rgbaFloats.append(rgbFloats[i + 1]) // G
                rgbaFloats.append(rgbFloats[i + 2]) // B
                rgbaFloats.append(1.0)              // A
            }
            
            return Data(bytes: rgbaFloats, count: rgbaFloats.count * MemoryLayout<Float>.size)
        }
        
        let bytesPerRow = edgeLength * 4 * MemoryLayout<Float>.size
        let bytesPerImage = bytesPerRow * edgeLength
        
        rgbaData.withUnsafeBytes { ptr in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                slice: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }
        
        print("✅ Metal 3D LUT texture created")
        return texture
    }
    
    private func createMetal2DLUTTexture(data: Data, width: Int, height: Int, channels: Int) -> MTLTexture? {
        // Create a 2D texture for 1D LUT data (OCIO encodes 1D LUTs as 2D textures)
        // OCIO might provide RED (1 channel) or RGB (3 channels) data
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            print("❌ Failed to create 2D LUT texture")
            return nil
        }
        
        // Convert to RGBA for Metal
        let componentCount = width * height * channels
        let rgbaData = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            let floats = ptr.bindMemory(to: Float.self)
            var rgbaFloats = [Float]()
            rgbaFloats.reserveCapacity(width * height * 4)
            
            if channels == 1 {
                // Single channel - replicate to RGB
                for i in 0..<(width * height) {
                    let value = floats[i]
                    rgbaFloats.append(value)  // R
                    rgbaFloats.append(value)  // G
                    rgbaFloats.append(value)  // B
                    rgbaFloats.append(1.0)    // A
                }
            } else if channels == 3 {
                // RGB data - add alpha
                for i in stride(from: 0, to: componentCount, by: 3) {
                    rgbaFloats.append(floats[i])     // R
                    rgbaFloats.append(floats[i + 1]) // G
                    rgbaFloats.append(floats[i + 2]) // B
                    rgbaFloats.append(1.0)           // A
                }
            } else {
                print("⚠️ Unexpected channel count: \(channels)")
                return Data()
            }
            
            return Data(bytes: rgbaFloats, count: rgbaFloats.count * MemoryLayout<Float>.size)
        }
        
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        
        rgbaData.withUnsafeBytes { ptr in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: width * 4 * MemoryLayout<Float>.size
            )
        }
        
        print("✅ Metal 2D LUT texture created (\(width)x\(height), \(channels)→4 channels)")
        return texture
    }
}

struct OCIOUniforms {
    var exposure: Float
    var padding: (Float, Float, Float)
}

enum OCIOGPUError: LocalizedError {
    case shaderCompilationFailed(String)
    case processorCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .shaderCompilationFailed(let message):
            return "Shader compilation failed: \(message)"
        case .processorCreationFailed:
            return "Failed to create OCIO GPU processor"
        }
    }
}

