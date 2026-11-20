# Third-party notices

Tristimulator’s own application code is under the MIT licence in the repository root `LICENSE` (Copyright (c) 2026 Alex Fry). That licence does not apply to the material in this directory. Each file here is an upstream licence or notice, copied verbatim. Nothing in this directory has been relicensed as MIT.

These files are part of the Xcode app target resources, so a built `Tristimulator.app` carries them at `Contents/Resources/ThirdPartyNotices/` next to `Contents/Resources/LICENSE`.

This is an engineering record of what was fetched and how the dependency set was resolved. It is not a legal opinion and it is not a claim that every asset in the repository is cleared for redistribution. Unresolved items are listed at the end.

## How the set was resolved

vcpkg baseline `32305df7d0b9a308e6ac454dd98ebfe550342c09` (`vcpkg.json` `builtin-baseline`). Direct dependencies after this change:

- `opencolorio` (default features)
- `openimageio` with `default-features` false and features `webp`, `jpegxl`, `openjpeg`, `gif`
- `openexr` (default features)
- `imath` (default features)

The graph below was produced by walking each port’s `vcpkg.json` at that baseline, for an arm64 macOS static link: platform expressions were evaluated for `osx` / `arm64` / `static`; host tools (`vcpkg-cmake`, `vcpkg-cmake-config`, `vcpkg-tool-meson`) were excluded; a dependency requested default features unless the edge set `default-features` to false; feature dependencies were included only for features that edge turned on. `openimageio` depends on `tiff` with `default-features` false, and `opencolorio` depends on `minizip-ng` with `default-features` false and feature `zlib` only.

No macOS `vcpkg install` was run in this change, so the list is the manifest graph, not a directory listing of a built `installed/*/lib`.

## Libraries the manifest installs

Versions are the `version` field of the port at the baseline above. “vcpkg field” is that port’s `license` string, which is not always the same as the upstream file (see OpenImageIO and Highway).

| Port | Version | vcpkg field | Files in this directory | Upstream location |
| --- | --- | --- | --- | --- |
| brotli | 1.2.0 | MIT | `brotli/LICENSE` | `google/brotli` tag `v1.2.0` |
| expat | 2.8.1 | MIT | `expat/COPYING` | `libexpat/libexpat` tag `R_2_8_1`, path `expat/COPYING` (the portfile rewrites `2.8.1` to that ref) |
| fmt | 12.1.0 | MIT | `fmt/LICENSE` | `fmtlib/fmt` tag `12.1.0` |
| giflib | 6.1.3 | MIT | `giflib/COPYING` | `giflib-6.1.3.tar.gz` from the giflib SourceForge project. SHA-512 matches the portfile (`fb1d6319694745e8…`). The file is the MIT terms and does not itself name a copyright holder. The upstream README names Gershon Elber, Toshio Kuratomi, and Eric Raymond as authors. |
| highway | 1.4.0 | Apache-2.0 | `highway/LICENSE` | `google/highway` tag `1.4.0`. The file says the project is Apache-2.0 or BSD-3-Clause, at the user’s choice, and includes those texts. It also mentions CC0 for `hwy/contrib/random/random-inl.h`. The port’s `contrib` feature is not enabled. |
| imath | 3.2.2 | BSD-3-Clause | `imath/LICENSE.md` | `AcademySoftwareFoundation/Imath` tag `v3.2.2` |
| lcms | 2.19.1 | MIT | `lcms/LICENSE` | `mm2/Little-CMS` tag `lcms2.19.1` |
| libdeflate | 1.25 | MIT | `libdeflate/COPYING` | `ebiggers/libdeflate` tag `v1.25` |
| libjpeg-turbo | 3.1.4.1 | BSD-3-Clause | `libjpeg-turbo/LICENSE.md`, `libjpeg-turbo/README.ijg` | `libjpeg-turbo/libjpeg-turbo` tag `3.1.4.1`. `LICENSE.md` points at `README.ijg` for the Independent JPEG Group terms. |
| libjxl | 0.11.2 | BSD-3-Clause | `libjxl/LICENSE`, `libjxl/PATENTS` | `libjxl/libjxl` tag `v0.11.2`. The port forces the system Highway, Brotli, and lcms2 ports and turns off skcms, sjpeg, and tcmalloc. |
| libpng | 1.6.58 | libpng-2.0 | `libpng/LICENSE` | `pnggroup/libpng` tag `v1.6.58` (libpng licence version 2) |
| libwebp | 1.6.0 | BSD-3-Clause | `libwebp/COPYING`, `libwebp/PATENTS` | `webmproject/libwebp` tag `v1.6.0` |
| minizip-ng | 4.1.0 | Zlib | `minizip-ng/LICENSE` | `zlib-ng/minizip-ng` tag `4.1.0`. Only the `zlib` feature is requested. |
| opencolorio | 2.5.2 | BSD-3-Clause | `opencolorio/LICENSE` | `AcademySoftwareFoundation/OpenColorIO` tag `v2.5.2`. That tag has no `NOTICE` file. |
| openexr | 3.4.12 | BSD-3-Clause | `openexr/LICENSE.md` | `AcademySoftwareFoundation/openexr` tag `v3.4.12`. That tag has no `NOTICE` file. |
| openimageio | 3.1.14.0 | BSD-3-Clause | `openimageio/LICENSE.md`, `openimageio/THIRD-PARTY.md`, `openimageio/RELICENSING.md` | `AcademySoftwareFoundation/OpenImageIO` tag `v3.1.14.0`. `LICENSE.md` is the Apache-2.0 text. Upstream headers at that tag say `Copyright Contributors to the OpenImageIO project` and `SPDX-License-Identifier: Apache-2.0`. `THIRD-PARTY.md` is the upstream notice for code incorporated into OpenImageIO. `RELICENSING.md` is the upstream relicensing record and is marked `SPDX-License-Identifier: CC-BY-4.0`. The vcpkg `license` field does not match `LICENSE.md`. |
| openjpeg | 2.5.4 | BSD-2-Clause | `openjpeg/LICENSE` | `uclouvain/openjpeg` tag `v2.5.4` |
| openjph | 0.27.2 | BSD-2-Clause | `openjph/LICENSE` | `aous72/OpenJPH` tag `0.27.2` |
| pystring | 1.1.5 | BSD-3-Clause | `pystring/LICENSE` | `imageworks/pystring` tag `v1.1.5` |
| robin-map | 1.4.1 | MIT | `robin-map/LICENSE` | `Tessil/robin-map` tag `v1.4.1` (header-only, compiled into OpenImageIO) |
| sse2neon | 1.9.1 | MIT | `sse2neon/LICENSE` | `DLTcollab/sse2neon` tag `v1.9.1` (header-only; OpenColorIO depends on it on arm) |
| tiff | 4.7.1 | libtiff | `tiff/LICENSE.md` | `gitlab.com/libtiff/libtiff` tag `v4.7.1`, file `LICENSE.md`. OpenImageIO turns default features off, so the jpeg, lzma, zip, zstd, webp, lerc, and tools features are not requested. The portfile passes `-Djbig=OFF` and comments that JBIG stays off because of GPL and proprietary licensing. |
| yaml-cpp | 0.9.0 | MIT | `yaml-cpp/LICENSE` | `jbeder/yaml-cpp` tag `yaml-cpp-0.9.0` |
| zlib | 1.3.2 | Zlib | `zlib/LICENSE` | `madler/zlib` tag `v1.3.2` |

Apple SDK libraries on the link line (`libc++`, `libcompression`, `libiconv`, and the system frameworks) are not in this directory.

## Copyleft check for this manifest

Removed in this change, and not in the resolved graph:

- `libraw` 0.22.1. The port’s `license` field at this baseline is `LGPL-2.1-only OR CDDL-1.0`. It was an OpenImageIO feature (`libraw`). The app no longer registers camera RAW or DNG.
- `jasper` 4.2.9. It appeared only as a LibRaw dependency. The port’s `license` field is null, so its terms were not established from vcpkg metadata. It is not installed by the manifest after LibRaw is removed.

Still listed on the checked-in link line before this change, but not dependencies of this manifest either before or after the LibRaw removal (`tiff` default features are off, and `minizip-ng` is requested with only `zlib`):

- `bzip2`
- `liblzma` (port `license` field null at this baseline)
- `zstd` 1.5.7 (port `license` field `BSD-3-Clause OR GPL-2.0-only`)

Those three `-l` flags were removed so a link against the vcpkg prefix does not pick them up from a stale install. They are not part of the resolved graph.

No remaining port in the table has a vcpkg `license` field of GPL, LGPL, AGPL, or CDDL. A search of the copied texts found no GNU GPL, LGPL, or AGPL grant. That does not replace inspecting a built binary.

`ffmpeg`, `x264`, and `x265` are not dependencies. OpenImageIO’s `ffmpeg`, `libheif`, `freetype`, and `opencv` features are off. Historical Homebrew dylibs of those codecs remain in git history and are not part of this change.

## Colour config that was matched

`OCIO/studio-config-v4.0.0_aces-v2.0_ocio-v2.5.ocio` is byte-identical to the `studio-config-v4.0.0_aces-v2.0_ocio-v2.5.ocio` asset on the OpenColorIO-Config-ACES `v4.0.0` release (71,755 bytes, SHA-256 `eda5b0008a43b72b98ad540e32eb0eb83b340dde54e35bddba64ccbafac1029a`). `opencolorio-config-aces/LICENSE` is the `LICENSE` file of that repository at tag `v4.0.0` (BSD-3-Clause, “Copyright Contributors to the OpenColorIO Project.”). The same terms are what the app’s Quick Look baked shader was generated from; the Metal wrapper around that generated code is Tristimulator code.

## Not established

These are still in the tree. This change does not delete them and does not supply a licence for them.

- `OCIO/ACES_v2.0.0_All.ocio`, `OCIO/ACES_v2.0.0_Limited.ocio`, `OCIO/ACES_v2.0.0_DisplayP3.ocio`, and `OCIO/luts/` (the `.spi1d`, `.spi3d`, and `.cube` files). The `.cube` files start with `TITLE "Generated by Foundry::LUT"`. No copyright or licence text is in those files, and they were not matched to an upstream release. The Xcode project copies the whole `OCIO` folder into the app, so they are in the built bundle even though the app loads the studio config named above (`search_path` is empty and that config has no `FileTransform`).
- `Tristimulator/SampleImages/OCIO_logo_frame_flared.exr`, the same image under `Icons/`, and the OpenColorIO logo artwork in the app icon. No licence or trademark grant is in the tree.
- `CLF_ApplyTestImages_v01/` and `TristimulatorTests/Fixtures/` have no licence file. They are not app resources. They are in a source checkout.
- `Tristimulator/Tristimulator/Include/` is an older header snapshot still committed after the vcpkg switch (OpenImageIO 3.1.7 SPDX Apache-2.0, OpenColorIO 2.5.0 SPDX BSD-3-Clause, OpenEXR 3.4.2 SPDX BSD-3-Clause, plus fmt, libpng 1.6.50, and libwebp headers). It is not the version the manifest builds, and the app target’s header search path points at the vcpkg prefix rather than this directory. The headers keep their own SPDX lines. They were not deleted here.
- Git history still contains the old `Tristimulator/Dylibs` blobs, including FFmpeg, x264, and x265. History was not rewritten.
