# Tristimulator — Codebase Quality & Performance Assessment

**Date:** 2026-07-07 · **Scope:** first-party sources (~25k LOC Swift/ObjC++/Metal), excluding vendored headers and OCIO configs.
**Audience:** future Claude/Opus agents implementing fixes. Each finding has an ID, priority, effort estimate, and an implementation plan. Work top-down within a priority band; items are independent unless a dependency is noted.

---

## How to build & verify

- Xcode project: `Tristimulator.xcodeproj`, scheme `Tristimulator`, macOS 15+, Apple Silicon. Third-party libs come from vcpkg via `Scripts/build_thirdparty.sh` (see `README.md`); header/lib search paths are wired in `ThirdParty.xcconfig`.
- Tests: `xcodebuild test -project Tristimulator.xcodeproj -scheme Tristimulator -destination 'platform=macOS'`. The CLF/AMF test suites in `TristimulatorTests/` are the regression gate for anything touching the OCIO pipeline — run them after every pipeline change.
- Manual smoke test for render-path changes: open `Tristimulator/SampleImages/` EXR, toggle Dynamic ACES2 on/off, drag exposure, switch EXR layer, scrub an image sequence, toggle an AMF look. Compare GPU vs CPU path with the "CPU render path" toggle (they must match visually).

## What is deliberately the way it is (do NOT "fix")

- `fastMathEnabled = false` on all OCIO shader compiles (`OCIOGPUProcessor.swift`) — ACES math miscompiles under fast-math.
- 1D LUT textures uploaded via **private storage + blit** with `waitUntilCompleted` (`OCIOGPUProcessor.swift:1091`) — works around a real GPU sampler-cache staleness bug documented in `OCIO_MSL_LUT_BUG.md`.
- `nearestSampler` for 1D LUTs, `linearSampler` for 2D/3D — preserves sharp gamut-compression curves.
- Sequence decode on `DispatchQueue.global`, not the Swift cooperative pool (`ImageSequenceSource.swift:48`) — blocking C++ I/O must stay off the cooperative pool.
- On-demand MTKView rendering (`enableSetNeedsDisplay = true`, `isPaused = true`) and the inline compute-then-render single command buffer in `MetalEDRImageView.Coordinator.draw`.
- The EXR texture pool and "latest wins" scrub coalescing in `ImageSequenceSource`.
- OIIO ImageCache configured `shared=false` (`OpenImageIOBridge.mm:901`) — shared memory corrupts parallel test workers.

---

# P0 — Correctness bugs

## P0-1: `chdir()` process-wide side effect when loading an OCIO config

**Where:** `Tristimulator/OpenColorIOBridge.mm:102` (`+[OCIOConfig configWithPath:error:]`).

```objc
chdir([configDir UTF8String]);   // "permanently", per the comment
```

**Problem:** Loading any custom OCIO config permanently changes the process CWD. Every subsequent relative-path operation in the app (OIIO reads, Python daemon spawn, NSSavePanel defaults, AMF sidecar resolution if ever relative) silently resolves against the config's directory. It is also not thread-safe — a config load racing a decode can flip CWD mid-read.

**Fix plan (S, ~1h):**
1. Delete the `chdir` call. OCIO resolves relative LUT paths itself: `Config::CreateFromFile` records the config's working directory, and `search_path` entries are resolved relative to it. Confirm with a config that references LUTs via relative `search_path`.
2. If some config in the wild still fails, the correct mechanism is `config->setWorkingDir(configDir)` on a mutable copy (`config->createEditableCopy()`), never `chdir`.
3. Regression: load `OCIO/studio-config-*.ocio` (bundled), then a custom config with relative LUT paths, verify both render; verify `FileManager.default.currentDirectoryPath` is unchanged after load.

## P0-2: Full-screen notifications are not filtered per-window, and observers leak

**Where:** `Tristimulator/DocumentContentView.swift:493–544` (`handleOnAppear`).

**Problem (two bugs):**
1. `NSWindow.didEnterFullScreenNotification` / `didExitFullScreenNotification` observers are registered with `object: nil` and the handler never checks `notification.object === hostWindow`. With two document windows open, *any* window entering full screen sets `document.isFullScreen = true` on *every* document — the windowed documents hide their toolbars/sidebar and get black backgrounds. Every other notification handler in this file correctly guards with `notification.object as? NSWindow === hostWindow`; these two are the exception.
2. Block-based observers from `addObserver(forName:object:queue:using:)` are never removed and `handleOnAppear` can run more than once per view lifetime (SwiftUI re-attach), stacking duplicate observers.

**Fix plan (S, ~1–2h):**
1. Add `guard (notification.object as? NSWindow) === hostWindow else { return }` at the top of both handlers. Note `hostWindow` is set asynchronously by `WindowConfigurator`; capture it via the `@State` binding the way the `.onReceive` handlers do — the cleanest option is converting both to `.onReceive(NotificationCenter.default.publisher(for:))` modifiers in the existing `notificationConfiguredView` layer, which gets both filtering and automatic teardown for free.
2. Delete the manual `addObserver` calls entirely once converted.
3. Test: open two windows for two different images, full-screen one, verify the other keeps its toolbar and window background.

## P0-3: Data races on `OCIOGPUProcessor` mutable state between compile threads and the render thread

**Where:** `Tristimulator/OCIOGPUProcessor.swift` — `pipelineState`, `orderedTextures`, `orderedTextureInfos`, `cached*` are plain `var`s on a non-isolated class. They are written from `DispatchQueue.global` workers (`ImageManager.applyDisplayTransform` ~line 773, `applyDynamicACES2Transform` ~line 956) while `MetalEDRImageView.Coordinator.draw` (MTKView delegate thread) reads them via `isDisplayPipelineReady` / `encodeTransform`.

**Problem:** Comments assert "a benign nil read... skips inline OCIO for one frame", but concurrent non-atomic reads/writes of Swift class properties are undefined behaviour, not benign — and worse than a nil read is a *torn pair*: a new `pipelineState` observed with the old `orderedTextures` (compile sequence sets `pipelineState = nil`, mutates textures, then installs the new PSO — the reverse interleaving is visible to the reader). Mismatched LUT bindings produce the kind of intermittent blank-grey/garbage render already noted as an open issue in project memory.

**Fix plan (M, ~half day):**
1. Make the compiled state a single immutable value swapped atomically:
   ```swift
   private struct CompiledPipeline {
       let pso: MTLComputePipelineState
       let textures: [MTLTexture]
       let infos: [TextureInfo]
   }
   private let stateLock = OSAllocatedUnfairLock<CompiledPipeline?>(initialState: nil)
   ```
2. Compile paths build a complete `CompiledPipeline` locally, then `stateLock.withLock { $0 = newValue }`. Invalidation writes `nil`. Cache-key fields (`cachedSourceSpace` etc.) are only touched from the setup paths; fold them into the locked state or confine setup to a serial queue.
3. `encodeTransform`/`processTexture`/`isDisplayPipelineReady` take one locked snapshot at entry and use only the snapshot (the existing "snapshot" comments show the intent; the lock makes it real).
4. Because a PSO and its texture array now travel together, the existing per-frame fallback behaviour is preserved: reader sees either the complete old pipeline, the complete new one, or nil.
5. Regression: rapid exposure drags while switching display/view and toggling ACES2 mode on a 4K EXR; watch for blank-grey frames.

## P0-4: Crash-on-launch risk from force-unwrapped `UTType` identifiers

**Where:** `Tristimulator/ImageDocument.swift:47–58` (`UTType("com.adobe.photoshop-image")!`, `UTType("com.truevision.tga-image")!`, `UTType("public.jpeg-2000")!`, etc.) and `Tristimulator/DocumentContentView.swift:877–879` (`UTType(filenameExtension: "exr")!` …).

**Problem:** `UTType(_:)` returns nil when the identifier isn't registered on the host system. These are evaluated in `readableContentTypes` (static, at app launch). System identifiers are usually present, but this is a launch-time crash dependent on OS state — the exact class of failure force-unwraps exist to avoid.

**Fix plan (S, ~30min):** Build the list with `compactMap`/optional appends; log any identifier that fails to resolve. Same for the open-panel list.

## P0-5: File ▸ Open panel accepts a fraction of the formats the app supports

**Where:** `Tristimulator/DocumentContentView.swift:871–884` — `openImage()` allows only png/jpeg/tiff/bmp/gif/exr/hdr + movies. The document system (`ImageDocument.readableContentTypes`) supports DPX, Cineon, PSD, TGA, DDS, PFM, JXL, HEIC, WebP, and the other types registered in `Info.plist`. Camera RAW is not registered.

**Fix plan (S, ~15min):** `panel.allowedContentTypes = ImageDocument.readableContentTypes` (after P0-4 makes that list safe). One source of truth; delete the local list.

---

# P1 — Performance

## P1-1: `applyAMFPipeline` does full-image debug scans and a whole-texture GPU readback purely for logging

**Where:** `Tristimulator/ImageManager.swift:1136–1157` (input min/max scan), `1180–1201` (output scan), `1237–1266` (full texture readback + third scan, labelled "Read back the new texture and compare").

**Problem:** Every AMF apply on, say, a 4K frame runs three full-image CPU scans plus a complete GPU→CPU texture readback (~66 MB) whose only consumer is `print`. This runs unconditionally in release builds and roughly doubles the cost of the AMF path.

**Fix plan (S, ~1h):** Wrap all three blocks in a single `#if DEBUG`-gated helper (or delete the readback-verification block outright — it was shipped as instrumentation for the now-resolved solarisation bug). Keep one cheap summary log (dimensions, step count). Verify AMF look toggles still render correctly.

## P1-2: Stills retain a full Float32 CPU pixel buffer that the GPU path never uses

**Where:** `ImageManager.loadImage` non-EXR branch (`ImageManager.swift:357–391`) keeps `oiioImage.pixelData` (w×h×4×4 bytes — 265 MB for a 100 MP photo) inside `ImageData`, and `OIIOImage.initWithImageBuf` (`OpenImageIOBridge.mm:769–793`) additionally holds the `ImageBuf` itself, roughly doubling that. The only consumers of `pixelData` are the CPU reference path (`useCPURenderPath`, a debug toggle) and the legacy `applyColorTransform` CPU functions.

**Problem:** Peak and steady-state memory for large stills is several× what the render path needs (the EXR path is already GPU-only and proves the model works: `pixelData: Data()`).

**Fix plan (M, ~1 day):**
1. Make the OIIO still path GPU-only by default: load via `OpenImageIOBridge.readTexture(atPath:layer:device:)` (already exists and handles display-window compositing), set `pixelData: Data()`.
2. When `useCPURenderPath` is enabled (or a CPU-only feature genuinely needs pixels), lazily re-read the file: add `ImageManager.ensureCPUPixelData() async` that re-runs `readImage` and swaps in an `ImageData` with pixels. Call it at the top of the CPU branches of `applyDisplayTransform` / `applyDynamicACES2Transform`.
3. `isVideoFrame` currently means "pixelData is empty" (`ImageManager.swift:187`) and several branches key off it. Introduce an explicit `enum SourceKind { still, videoFrame, sequenceFrame }` on `ImageData` (or ImageManager) rather than inferring from empty pixel data — this finding is blocked on that distinction, and P1-3 wants it too.
4. Regression: stills load + render, CPU-path toggle still works, clipboard copy works, scopes work (they read `originalSourceTexture`, unaffected).

## P1-3: `ImageData: Equatable` compares pixel bytes; SwiftUI diffs can memcmp hundreds of MB

**Where:** `Tristimulator/MetalEDRImageView.swift:335–343`.

**Problem:** `lhs.pixelData == rhs.pixelData` is in the equality chain used by SwiftUI diffing (`updateNSView` change detection, `.onChange(of: document.imageManager.currentImage)` in `DocumentContentView.swift:146`). `Data` equality short-circuits only when the backing storage is identical; after any transform produces a fresh buffer, unequal-but-same-size comparisons scan until the first differing byte, and *equal* buffers (worst case) scan everything. This sits on the UI diff path.

**Fix plan (S, ~1h):** The struct already carries `contentTag` for exactly this purpose on the sequence path. Make equality cheap and identity-based everywhere:
```swift
static func == (lhs: ImageData, rhs: ImageData) -> Bool {
    lhs.width == rhs.width && lhs.height == rhs.height &&
    lhs.channels == rhs.channels && lhs.contentTag == rhs.contentTag &&
    lhs.metadata == rhs.metadata && lhs.metalTexture === rhs.metalTexture
}
```
Then audit the places that construct new `ImageData` with the *same* texture but new pixel content (currently only the sequence pool path, which already bumps `contentTag`) and make `ImageManager`'s transform paths bump a tag too when they swap textures — texture identity already covers them, but the tag makes it explicit. Drop `pixelData` from the comparison entirely.

## P1-4: Every document window re-parses the OCIO config from scratch on the main thread

**Where:** `ImageManager.init` (`ImageManager.swift:200–301`) runs `OCIOConfig(path:)` synchronously; `ImageDocument` creates a fresh `ImageManager` per window (`ImageDocument.swift:97`).

**Problem:** Parsing the bundled ACES studio config is expensive (hundreds of ms). It blocks the main thread during window open, and N windows pay it N times. `OCIO::ConstConfigRcPtr` is immutable and thread-safe — it is designed to be shared.

**Fix plan (M, ~half day):**
1. Add a process-wide cache: `final class OCIOConfigCache { static let shared; func config(forPath: String) throws -> OCIOConfig }` keyed by canonical path, storing the `OCIOConfig` wrapper (which just holds the RcPtr). Guard with a lock.
2. `ImageManager.init` and `loadOCIOConfig(from:)` fetch through the cache.
3. Optionally move the initial load off the main thread: init with `ocioConfig = nil`, kick an async task, and have `initializePipeline` await config readiness. The cache alone fixes the N-windows case; async-ifying fixes first-launch too — do the cache first, measure, then decide.
4. Note: after P0-1 removes `chdir`, sharing configs across documents is safe (today the CWD side effect is per-process anyway).

## P1-5: GPU processor recreated on every image load ("texture reuse bug" workaround)

**Where:** `ImageManager.swift:407–408`:
```swift
// WORKAROUND: Recreate GPU processor to avoid texture reuse bug
self.gpuProcessor = OCIOGPUProcessor(device: device)
```

**Problem:** Discarding the processor throws away the compiled pipeline, forcing a full OCIO shader extraction + MSL compile (100–500 ms per the code's own comments) on every file open, even when the transform chain is unchanged. The underlying bug this dodged (stale sampler cache on pool-recycled `.shared` LUT textures) was subsequently fixed properly by the private+blit LUT upload (`OCIOGPUProcessor.swift:1091–1141`, and `OCIO_MSL_LUT_BUG.md`).

**Fix plan (S–M, ~2h incl. testing):** Remove the recreation, keep the processor across loads, and rely on its internal cache keys. Test the original repro: open image A, open image B with a different transform, switch back; scrub a sequence after opening a still. If any artefact reappears, keep the recreation but *only* when the config changed, not per-image.

## P1-6: Scalar per-pixel Float16↔Float32 and RGB→RGBA conversions

**Where:**
- `ImageManager.applyAMFPipeline` — Float16→Float32 loop (`ImageManager.swift:1080–1088`) and Float32→Float16 loop (`1216–1226`).
- `ImageManager.createMetalTexture` RGB→RGBA loop (`1601–1626`).
- `OCIOGPUProcessor.createMetal3DLUTTexture` / `createMetal2DLUTTexture` / `createMetal1DLUTTexture` RGB→RGBA element-append loops (`1046–1268`) — these run at pipeline-compile time on up to edge³ texels.

**Fix plan (S, ~2–3h):** Use Accelerate:
- `vImageConvert_Planar16FtoPlanarF` / `PlanarFtoPlanar16F` on the interleaved buffer (treat as one planar array of w*h*4 elements).
- RGB→RGBA: `vImageConvert_RGBFFFtoRGBAFFFF` (fill alpha 1.0).
Preallocate output with `Data(count:)` + `withUnsafeMutableBytes` instead of `[Float]` append (the LUT loops currently grow arrays element-by-element). This is a drop-in change per site; verify with the CLF transform tests.

## P1-7: Two independent 2-second polling timers per document for EDR state

**Where:** `ImageManager.init` (`ImageManager.swift:210–228`, Combine timer for auto-nits rebuild) and `ImageDocument.startEDRMonitoring` (`ImageDocument.swift:287–293`, `Timer` for the HDR/SDR badge).

**Problem:** Redundant per-document wakeups; the ImageDocument timer also polls `NSScreen.main` rather than the window's screen (wrong badge on multi-display setups). `maximumExtendedDynamicRangeColorComponentValue` has no direct KVO, so *some* polling is justified — but once, in one place.

**Fix plan (M, ~2–3h):** Consolidate into one observer object (e.g. `EDRMonitor` on ImageManager, which already tracks `currentScreen`): a single 2 s timer that publishes `(isHDRAvailable, currentHeadroom)`, plus `NSApplication.didChangeScreenParametersNotification` for immediate reaction. ImageDocument's badge subscribes; delete its timer. Use `imageManager.currentScreen ?? NSScreen.main` for both consumers.

---

# P2 — Architecture & maintainability

## P2-1: Split the `ImageManager` god object (1,689 lines)

**Where:** `Tristimulator/ImageManager.swift`.

**Problem:** One class owns: OCIO config lifecycle, image loading (3 paths), CPU reference transforms, GPU pipeline orchestration, Dynamic ACES2 + EDR polling, AMF look state + application, exposure, and misc queries. Nearly every feature change touches this file; the AMF state interplay (`originalImageData` vs `amfSourceSnapshot` vs `transformedImageData` vs `currentImage`) is the hardest-to-reason-about state machine in the app.

**Refactor plan (L, ~2–3 days, do incrementally — each step compiles and ships):**
1. **`OCIOConfigStore`** (pairs with P1-4): config loading, path tracking, role/colorspace/display queries (`availableColorSpaces`, `colorSpaceFamilyTree`, `views(for:)`, `sceneLinearColorSpace`…). Pure, easily testable.
2. **`ImageLoader`**: `loadImage(from:layer:)`, `loadFrame(_:)` overloads, `createMetalTexture(from:...)`. Emits `LoadedImage { source: ImageData, kind: SourceKind }`. No OCIO knowledge.
3. **`RenderPipelineController`**: owns `OCIOGPUProcessor`, `applyDisplayTransform`, `applyDynamicACES2Transform`, exposure, the CPU reference path, and `colorTransform`. Input: source `ImageData` + pipeline settings; output: compiled pipeline + (for CPU path) a rendered `ImageData`.
4. **`AMFController`**: sidecar/manual-override state, look toggles, `amfGPULookSteps()`, `effectiveAMFStatus`, pristine-snapshot handling. Exposes look steps to `RenderPipelineController` as data.
5. `ImageManager` remains as a thin @Observable façade composing the four (so views don't all change at once), then views migrate to the specific objects over time.
6. Sequencing note: do P0-3 (pipeline state lock) *before* this, so the extraction moves already-safe code.

## P2-2: Decompose `DocumentContentView` (2,067 lines) and replace NotificationCenter command routing

**Where:** `Tristimulator/DocumentContentView.swift`, `TristimulatorApp.swift` (25+ `Notification.Name`s).

**Problem:** The view needs a 5-layer computed-property chain just to keep the type-checker alive; menu commands are broadcast via NotificationCenter with per-handler `object === hostWindow` filtering (and P0-2 shows how easy it is to miss the filter). This is the idiomatic-SwiftUI replacement point.

**Refactor plan (L, ~2 days):**
1. Introduce a `DocumentCommands` struct (play/pause, step, channel select, exposure ±, copy, export…) published by each document view via `.focusedSceneValue(\.documentCommands, …)`.
2. Menu items in `TristimulatorApp` read `@FocusedValue(\.documentCommands)` and call closures directly — key-window filtering becomes automatic, all `Notification.Name`s and their `.onReceive` plumbing get deleted.
3. Extract subviews into files: `FullScreenChromeOverlay` (toolbar + auto-hide task logic — currently duplicated 3× inline at lines 586–605, 638–665, and the movie/sequence variants), `TransportPillContainer` (movie + sequence pills share their hide-watcher pattern), `ScopeOverlaysLayer`, and move `initializePipeline`/settings restore into an `ImageDocument` extension or a `PipelineBootstrapper` helper — it is model logic, not view code.
4. Collapse the three copy-pasted auto-hide watchers (`startMovieControlsWatcher`, `startSequenceControlsWatcher`, `startStillInfoBarWatcher` — later in the file) into one `AutoHideController` observable with `(isHovering, lastActivity) → visible`.

## P2-3: Stop parsing OCIO-generated MSL with string heuristics for texture binding

**Where:** `OCIOGPUProcessor.reorderTexturesForOCIO` (`OCIOGPUProcessor.swift:984–1044`) — line-scans the shader for `texture3d<float>` tokens to recover parameter order; `shaderSamplesRGB` (`871–878`) — infers channel count from generated helper-function names; the `channels == 3 but shader uses .r` override (`345`).

**Problem:** Rendering correctness depends on the *textual shape* of OCIO's generated MSL. An OCIO upgrade that renames helpers, reflows the signature, or changes whitespace silently breaks LUT binding order (the failure mode is wrong colors, not a crash). The `orderedNames.count == textureInfos.count` fallback to "original order" makes failures silent.

**Fix plan (M, ~1 day):**
1. The order OCIO emits parameters is the enumeration order of `getNumTextures()` then `getNum3DTextures()` on the same `GpuShaderDesc` — the bridge already walks them in that order in `getGPUShaderAndTextures` (`OpenColorIOBridge.mm:905–969`). Reproduce the current parse result against that order for the bundled config's transforms; if they match (expected: 2D/1D first, 3D last, each in index order), delete the parser and trust the array order from the bridge. Add an assert comparing count against the parsed signature *in DEBUG only* as a tripwire.
2. For channel count, use the sampler/texture metadata OCIO provides (`TextureDimensions` is already surfaced as `channelType`) rather than shader-text sniffing; the `.r`-only case is an OCIO reporting quirk — pin it with a unit test that builds the known-affected transform and checks the generated helper signature, so an OCIO upgrade flags the change loudly.
3. Keep `generateCombinedShaderWrapper`'s prefix renaming (`ocio_` → `lzr_`/`lok_`/`dsp_`) but move it and the wrapper templates into their own file (`OCIOShaderAssembly.swift`) with unit tests that compile the assembled source against a `MTLDevice` for a couple of canned OCIO outputs.

## P2-4: Duplicated renderer between app and QuickLook extension (already diverged)

**Where:** `Tristimulator/MetalEDRRenderer.swift` vs `TristimulatorQuickLook/MetalEDRRenderer.swift` (confirmed non-identical), plus duplicated `Shaders.metal`.

**Fix plan (M, ~half day):** Create a local Swift package or framework target (`TristimulatorRenderCore`) containing `MetalEDRRenderer`, the shared shader source, and `colorSpaceForIdentifier` + the BT.1886/P3 colorspace builders (currently in `MetalEDRImageView.swift:376–459`, also useful to the extension). Link from both targets. Diff the two renderer copies first and reconcile intentional differences (the QL one may be trimmed deliberately) via init options rather than forked files.

## P2-5: Concurrency model is implicit; annotate and then adopt Swift 6 checking

**Where:** project-wide. `SWIFT_VERSION = 5.0` with `SWIFT_APPROACHABLE_CONCURRENCY = YES`; `ImageManager` is `@Observable` and mutated from main-actor SwiftUI paths, `Task {}` bodies, and completion contexts; `ScriptingEngine` mixes an `NSLock` + serial queue; `ImageSequenceSource` relies on "`@MainActor` methods + `@ObservationIgnored` dictionaries" discipline.

**Fix plan (M–L, incremental):**
1. Annotate `ImageManager`, `ImageDocument`, `ImageSequenceSource` as `@MainActor` types (most call sites already are), with `nonisolated` for the pure helpers. The `DispatchQueue.global` compile hops in `ImageManager` stay as-is — they only touch captured locals + `OCIOGPUProcessor` (safe after P0-3).
2. Turn on `SWIFT_STRICT_CONCURRENCY = targeted`, fix fallout, then `complete`, then consider `SWIFT_VERSION = 6`.
3. Do after P0-3 and ideally alongside P2-1 (smaller types are easier to annotate honestly).

## P2-6: Replace 346 `print` + 24 emoji `NSLog` calls with `os.Logger`

**Where:** everywhere; worst offenders `DocumentContentView.swift` (70), `ImageManager.swift` (50), `OCIOGPUProcessor.swift` (36).

**Fix plan (M, ~half day, mechanical):**
1. Define categories in one file: `enum Log { static let pipeline = Logger(subsystem: "com.tristimulator", category: "pipeline"); static let io…; static let amf…; static let ui… }`.
2. Convert: lifecycle/diagnostic prints → `.debug` (compiled out of release hot paths' string interpolation cost), user-relevant events → `.info`, failures → `.error`. Keep messages; drop emoji or keep — logger doesn't care.
3. Delete the pure-noise ones on hot paths (`draw`, `updateNSView`, per-frame delivery) outright.
4. Pairs with P1-1 (the AMF debug scans) — do P1-1 first.

## P2-7: Errors are printed, not surfaced

**Where:** e.g. failed EXR layer reload (`DocumentContentView.swift:285`), scripting config-load failure (`1410`), `reapplyAMFLooks` swallows with `try?` (`ImageManager.swift:1396–1398`), `ImageDocument.applyCurrentOCIOTransform` catch-and-print.

**Problem:** When a user action fails (picked a layer, loaded an AMF, chose a config), the app frequently does nothing visible. `showError` (NSAlert) exists but is used inconsistently — and is modal (`runModal`) even for minor issues.

**Fix plan (M, ~1 day):** Add a lightweight, non-modal error/status surface: `@Published var lastPipelineError: String?` on `ImageDocument`, rendered as a dismissible banner over the image area. Route the swallowed catches there. Keep NSAlert only for open-file failures. (Convert `showError`'s `runModal` to `beginSheetModal(for: hostWindow)` while there.)

---

# P3 — Hygiene, dead code, tests

## P3-1: Delete dead code (compiled into the shipping app via filesystem-synced groups)

The project uses `PBXFileSystemSynchronizedRootGroup` — **everything in `Tristimulator/` compiles into the app target** unless excluded. Confirmed unreferenced:

| Item | Evidence | Action |
|---|---|---|
| `Tristimulator/ContentView.swift` (890 lines) | No constructor call anywhere; app uses `DocumentContentView` (`TristimulatorApp.swift:19`) | Delete (it's a stale pre-document-architecture copy of the UI; check for any logic that never got ported before deleting) |
| `Tristimulator/InverseDisplayTest.swift` | Only self-references; it's ad-hoc test code in the app target | Move the useful assertions into `TristimulatorTests`, delete the file |
| `OpenColorIOBridge.mm:987–1182` — `getGPUShaderDescription`, `getGPU3DLUTData`, `getGPUTextureData` | No Swift callers (superseded by `getGPUShaderAndTextures`) | Delete methods + header decls |
| `Tristimulator/Tristimulator/Include/` — 316 vendored headers, 4.8 MB | `ThirdParty.xcconfig` points `HEADER_SEARCH_PATHS` at the vcpkg prefix, not here | Verify a clean build without it, then delete the directory (watch out: it currently sits inside the synced group) |
| `ShaderBaker` Debug menu | `TristimulatorApp.swift:131` — "TEMPORARY — remove after baking" | Either wrap the `CommandMenu("Debug")` in `#if DEBUG`, or move baking to a script/unit-test target and delete the menu |
| Stale root/app-dir docs: `CLF_DEBUG_STATE.md` (bug resolved per memory), `Tristimulator/ARCHITECTURE_DIAGRAM.md`, `GETTING_STARTED.md`, `QUICK_START.md`, `INVERSE_DISPLAY_IMPLEMENTATION.md`, `PYTHON_BRIDGE_IMPLEMENTATION.md`, `SOURCE_NODE_DUAL_MODE_SUMMARY.md`, `OCIO_SETUP.md` | Root `README.md` was recently rewritten as canonical | Review each: fold still-true content into `README.md` or a `docs/` folder, delete the rest (they describe past implementation states and will mislead future agents) |

## P3-2: Git hygiene — user state is tracked

**Where:** `.gitignore` has only 3 entries; `Tristimulator.xcodeproj/project.xcworkspace/xcuserdata/alex.xcuserdatad/UserInterfaceState.xcuserstate` is tracked and perpetually dirty; `TristimulatorQuickLook/BakedShaderInverse/` sits untracked.

**Fix plan (S, ~15min):**
```gitignore
xcuserdata/
*.xcuserstate
.DS_Store
```
plus `git rm --cached` the xcuserstate. Decide whether `BakedShaderInverse/` is a build input (commit it) or output (ignore it) — `BakedShader/` is committed, so probably commit for consistency.

## P3-3: `saveImage` is a stub behind a live Save UI

**Where:** `ImageManager.saveImage` throws `.notImplemented` (`ImageManager.swift:473–481`); the full-screen toolbar exposes `onSaveImage` → `NSSavePanel` (`DocumentContentView.swift:934–952`).

**Fix plan:** Short-term (S): remove/disable the Save button — the user gets a panel then an error today. Proper (M): implement via the existing pieces — run `gpuProcessor.processTexture` on the source, read back, write with `OpenImageIOBridge.writeFloatPixelData` (already implemented and routed through SystemImageIO for JPEG/PNG/TIFF). The "Export Gain Map Image" path (`ImageClipboardHelper`) already does 80% of this; factor its readback into a shared helper.

## P3-4: Test coverage is narrow — add tests for the pure logic that keeps breaking silently

Current: ~1,000 lines covering AMF/CLF parsing + OCIO transform correctness (good, keep as the pipeline gate). Missing, all cheaply testable without UI:

1. **`ImageSequenceSource.discoverSequence` / `alphaPrefix` / `frameNumber`** — naming-convention parsing (`shot_0042`, `beauty.0001`, `render1080`, mixed padding, non-contiguous ranges). Pure static functions; test with temp dirs.
2. **`ColorSpaceAliases.findMatch`** — the image-metadata→OCIO-space matcher that decides the default pipeline per image.
3. **`OCIOSettingsStore`** — save/restore round-trip, stale-config validation fallback, extra-window buckets. (This restore logic in `initializePipeline` has visibly accumulated guard-rails; tests would let it be simplified.)
4. **Shader wrapper assembly** (after P2-3): given canned OCIO shader text + texture lists, assert the assembled kernel compiles on `MTLCreateSystemDefaultDevice()`.
5. **`ScriptingEngine` protocol framing** — newline-JSON round trip against a stub daemon script.

## P3-5: Misc small items

- `ImageSequenceSource.scrubStride` (`ImageSequenceSource.swift:213`) hardcodes the transport-pill slider width (308 px) computed from UI layout constants. Pass the actual slider width in from `SequenceControlsView` (one extra parameter on `seek`) or accept the approximation with a comment linking the two files.
- `ImageDocument.init(configuration:)` prints and ignores the FileWrapper; the real loading happens in the view. Fine, but the dead comments should say so in one line, not fifteen.
- `MTLCompileOptions.fastMathEnabled` is deprecated on newer SDKs — switch to `mathMode = .safe` when bumping the deployment target (behaviour-preserving).
- `DocumentContentView.showError` uses `NSAlert.runModal()` from async contexts — convert to `beginSheetModal` attached to `hostWindow` (covered by P2-7).
- Two near-identical `ResolveAndReadEXRLayer` implementations exist in `OpenImageIOBridge.mm` (the shared static at :129 and an inlined copy inside `ReadEXRIntoTexture` at :410–493). Deduplicate — the inline copy already drifted (it also fills unresolved RGB slots).

---

# Suggested execution order

1. **Quick wins (one session):** P0-1, P0-2, P0-4, P0-5, P1-1, P1-3, P3-2, P3-3(short), P3-5 dedupe.
2. **Render-path safety:** P0-3, then P1-5.
3. **Perf:** P1-4, P1-2 (needs the `SourceKind` enum), P1-6, P1-7.
4. **Structure (bigger, sequential):** P2-3 → P2-1 → P2-5, and independently P2-2, P2-4, P2-6, P2-7.
5. **Ongoing:** P3-1, P3-4 alongside whatever area is being touched.

After any change in bands 2–4: run the CLF/AMF test suite and the manual smoke test at the top of this document. Visual parity between GPU and CPU render paths is the strongest end-to-end check this codebase has — use it.
