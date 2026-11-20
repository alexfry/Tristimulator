# Tristimulator - Professional HDR Image Viewer

A professional-grade image viewer for macOS with HDR/EDR support, advanced color management, and real-time image analysis scopes.

## 🚀 Quick Start

```bash
git clone <repo>
open Tristimulator.xcodeproj
```

Press `⌘B` and wait. The first build runs `Scripts/build_thirdparty.sh` to compile OpenColorIO, OpenImageIO, OpenEXR/Imath, and ~40 image-format deps from source via vcpkg into `~/Library/Caches/Tristimulator/ThirdParty/installed/arm64-osx-tristimulator/`. That takes ~3 minutes on first run; subsequent builds hit the cache and are instant.

The script needs `pkg-config` for vcpkg's `.pc`-file fixup step — if Homebrew already provides one, it uses that; otherwise it builds vcpkg's own `pkgconf` port (adds ~10s on cold install) and symlinks `pkg-config → pkgconf`. No Homebrew install required.

If you ever want to force a clean rebuild of the third-party stack:

```bash
rm -rf ~/Library/Caches/Tristimulator/ThirdParty
```

## Requirements

- macOS 15+ (Apple Silicon — arm64 only)
- Xcode 16+ (the build uses Xcode's clang toolchain, not Command Line Tools, because CLT's libc++ headers are incomplete on recent installs)

No Homebrew, no system-wide OpenImageIO/OpenColorIO install needed — the build pulls all third-party libraries from source via vcpkg, including its own `pkgconf` if no system `pkg-config` is present.

## ✨ Features

- **HDR/EDR Display Support**: Native macOS Extended Dynamic Range rendering via Metal
- **OpenImageIO Integration**: Read and write image formats including EXR, HDR, DPX, JPEG XL, JPEG 2000, and WebP. Camera RAW is not supported.
- **OpenColorIO Integration**: Industry-standard color management and transforms
- **Python colour-science** (optional): Advanced color analysis and scope generation
- **Real-time Scopes**: Histogram, Waveform, Vectorscope, RGB Parade
- **Professional Workflow**: Exposure control, color space transforms, metadata viewing

## How third-party libraries are built

Everything is statically linked into `Tristimulator.app/Contents/MacOS/Tristimulator` — no `@rpath` plumbing, no `Frameworks/` directory of bundled dylibs, no codesigning of dependencies. The pipeline:

| File | Role |
| --- | --- |
| `vcpkg.json` / `vcpkg-configuration.json` | Manifest with pinned baseline. Lists top-level deps (`opencolorio`, `openimageio`, `openexr`, `imath`) with explicit feature flags. |
| `Triplets/arm64-osx-tristimulator.cmake` | Custom triplet: static linkage, arm64, macOS 15 deployment target, release-only. |
| `Scripts/build_thirdparty.sh` | Hash-cached orchestrator. Clones vcpkg under `~/Library/Caches/Tristimulator/ThirdParty/vcpkg`, runs `vcpkg install`, then emits `Generated/ThirdParty.generated.xcconfig`. |
| `ThirdParty.xcconfig` | Wires the Tristimulator target to the install prefix. |

GPL-licensed codecs (`x264`, `x265`) and `ffmpeg` are excluded — movies use AVFoundation. HEIF/JPEG/PNG/TIFF reads route through macOS ImageIO via `SystemImageIOBridge.{h,mm}`; OIIO retains EXR, JPEG XL, JPEG 2000, and WebP. LibRaw is not a dependency, and the app does not register camera RAW or DNG.

## Architecture

### Layer 1: Native Display (Metal/EDR)
- `MetalEDRImageView.swift` - SwiftUI view wrapper
- `MetalEDRRenderer.swift` - Metal rendering engine
- `Shaders.metal` - GPU shaders with HDR tone mapping

### Layer 2: Image I/O
- `OpenImageIOBridge.{h,mm}` - OIIO wrapper, fast path uses OpenEXR `Imf::MultiPartInputFile` directly for EXR sequences
- `SystemImageIOBridge.{h,mm}` - CGImageSource/CGImageDestination wrapper for JPEG/PNG/TIFF/HEIF, returns the same `OIIOImage`/`OIIOImageSpec` types so callers don't branch

### Layer 3: Color Management
- `OpenColorIOBridge.{h,mm}` - OCIO wrapper for color-space and display-view transforms
- Bundled OCIO configs under `OCIO/` (ACES 2.0 + studio config)

### Layer 4: Analysis (Python colour-science, optional)
- `PythonColourBridge.swift` - PythonKit-based integration
- Histogram / Waveform / Vectorscope / Gamut analysis

### Layer 5: UI (SwiftUI)
- `ContentView.swift` - Main application layout
- `ScopesView.swift` - Real-time scopes
- `ColorControlsView.swift` - Color management UI

## Usage

### Opening Images

1. `⌘O` and pick an image (EXR, JPEG, PNG, HEIF, and the other formats registered in `Tristimulator/Info.plist`)
2. Image loads with automatic color management based on its tagged color space.

### Exposure Control

- Slider in the toolbar, or `⌘+` / `⌘-` / `⌘0` (reset). Stops range -10 to +10.

### Color Management

1. Open Color Controls (`⌘2`)
2. Pick source and destination color spaces, or apply a display/view transform from a loaded OCIO config.

### Scopes

- Toggle with `⌘1`
- Switch between Histogram, Waveform, Vectorscope, RGB Parade
- Update in real time as you adjust exposure

### EDR/HDR Display

- Automatically enabled on compatible Macs/displays. Values above 1.0 are preserved and routed through Metal's EDR pipeline.

## Updating third-party dependencies

To bump a dep version:

1. Edit `vcpkg.json` — change feature flags or pin a newer baseline SHA from `microsoft/vcpkg`.
2. Build in Xcode. The `Scripts/build_thirdparty.sh` Run Script phase detects the manifest hash change and rebuilds only what's needed.
3. If the static-lib list changes (new lib added or removed), update `OTHER_LDFLAGS` in the target's Build Settings — the generated `Generated/ThirdParty.generated.xcconfig` lists the current set.

## Troubleshooting

### First build hangs at "Configuring openimageio"

That's normal on a cold build — OIIO takes the longest to compile (~2 min on M-series). Check progress with `tail -f ~/Library/Caches/Tristimulator/ThirdParty/vcpkg/buildtrees/openimageio/install-arm64-osx-tristimulator-rel-out.log`.

### `'cstdint' file not found` during vcpkg build

The script is using Command Line Tools instead of Xcode's toolchain. Ensure `xcode-select -p` returns a path inside `/Applications/Xcode.app`, or set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` before re-running.

### `Library 'OpenColorIO' not found` at link time

`Library Search Paths` in the Tristimulator target must point at the install prefix:
`/Users/<you>/Library/Caches/Tristimulator/ThirdParty/installed/arm64-osx-tristimulator/lib`. Watch out for empty "Any Architecture | Any SDK" sub-overrides — they silence the parent value.

### App opens but JPEG/PNG/TIFF/HEIF look wrong

That's the `SystemImageIOBridge` path. Open `Console.app` and filter for `SystemImageIOBridge` while loading the file to see the source's CG color space — mismatches usually surface as crushed midtones or over-saturation.

## Licence

Tristimulator’s own code is MIT. See `LICENSE`. Copyright (c) 2026 Alex Fry.

Libraries built by vcpkg, and the matched ACES studio config, keep their own licences. Verbatim texts and the version each text was taken from are in `ThirdPartyNotices/`. Those terms are not MIT. A built app copies `LICENSE` and `ThirdPartyNotices/` into `Contents/Resources/`.

## Credits

Built using:
- [OpenImageIO](https://github.com/OpenImageIO/oiio)
- [OpenColorIO](https://opencolorio.org/)
- [OpenEXR / Imath](https://www.openexr.com/)
- [vcpkg](https://github.com/microsoft/vcpkg) — third-party build orchestrator
- [colour-science](https://www.colour-science.org/) — optional Python analysis
- Apple's Metal, EDR, and ImageIO APIs
