//
//  OpenImageIOBridge.mm
//  Tristimulator
//
//  Real OpenImageIO Implementation
//

#import "OpenImageIOBridge.h"
#import "SystemImageIOBridge.h"
#import <Metal/Metal.h>

#include <OpenImageIO/imageio.h>
#include <OpenImageIO/imagebuf.h>
#include <OpenImageIO/imagebufalgo.h>
#include <OpenImageIO/imagecache.h>

// Direct OpenEXR API — used for the fast sequence-playback path.
// Bypasses OIIO's ImageCache and double-buffer overhead when reading EXRs.
#include <OpenEXR/ImfInputFile.h>
#include <OpenEXR/ImfMultiPartInputFile.h>
#include <OpenEXR/ImfFrameBuffer.h>
#include <OpenEXR/ImfChannelList.h>
#include <OpenEXR/ImfHeader.h>
#include <OpenEXR/ImfInputPart.h>
#include <OpenEXR/ImfThreading.h>

#include <set>
#include <vector>
#include <string>
#include <algorithm>
#include <thread>

using namespace OIIO;

/// File metadata, layer names and library error text are not guaranteed to be
/// valid UTF-8. +stringWithUTF8String: returns nil for invalid input, and nil
/// in a collection literal or -addObject: throws. Never returns nil.
static NSString *SafeNSString(const char *cstr) {
    if (!cstr) return @"";
    NSString *s = [NSString stringWithUTF8String:cstr];
    if (s) return s;
    s = [[NSString alloc] initWithCString:cstr encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}
// OpenEXR v3 headers already define: namespace Imf = OPENEXR_IMF_NAMESPACE
// and half lives in Imath, not Imf.

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Direct OpenEXR helpers (fast path for EXR sequence playback)
// ─────────────────────────────────────────────────────────────────────────────

/// Strip the view suffix from an EXR part name.
/// Multi-view Nuke EXRs use part names like "ID_castle.main" where "main" is
/// the view name (stored in a per-part "view" attribute).  This helper strips
/// the ".viewname" suffix so the layer name becomes just "ID_castle".
/// Also handles the default RGBA part whose name is typically "rgba.viewname".
static std::string
StripViewFromPartName(const std::string &partName, const Imf::Header &header) {
    if (!header.hasView()) return partName;
    std::string view = header.view();
    if (view.empty()) return partName;
    std::string suffix = "." + view;
    if (partName.size() > suffix.size() &&
        partName.compare(partName.size() - suffix.size(), suffix.size(), suffix) == 0) {
        std::string stripped = partName.substr(0, partName.size() - suffix.size());
        // "rgba" after stripping is the default layer → return "".
        if (stripped == "rgba") return "";
        return stripped;
    }
    return partName;
}

/// Extract ordered unique layer prefixes from an EXR ChannelList.
/// Mirrors ExtractLayerNames() but works directly on the native EXR header,
/// preserving the EXR-defined channel ordering (alphabetical by channel name).
static std::vector<std::string>
ExrLayerNamesFromChannelList(const Imf::ChannelList &channels) {
    std::set<std::string>    seen;
    std::vector<std::string> result;
    for (auto it = channels.begin(); it != channels.end(); ++it) {
        std::string name(it.name());
        auto dot = name.rfind('.');
        std::string prefix = (dot == std::string::npos) ? "" : name.substr(0, dot);
        if (seen.insert(prefix).second) result.push_back(prefix);
    }
    return result;
}

/// Given a pool of channel names belonging to a layer, find the best match for
/// an RGBA slot.  Tries exact short names first (".R"), then common long-form
/// suffixes (".red", ".r"), case-insensitively.  Returns the matching name from
/// the pool, or "" if no match is found.
static std::string
FindChannelInPool(const std::vector<std::string> &pool,
                  const std::string &layer,
                  int slot)  // 0=R, 1=G, 2=B, 3=A
{
    // Suffix variants to try for each RGBA slot (case-insensitive).
    static const char *suffixes[4][4] = {
        { ".R", ".red",   ".r",   nullptr },
        { ".G", ".green", ".g",   nullptr },
        { ".B", ".blue",  ".b",   nullptr },
        { ".A", ".alpha", ".a",   nullptr },
    };
    // Also try bare names (no layer prefix) for the default layer.
    static const char *bareSuffixes[4][4] = {
        { "R", "red",   "r",   nullptr },
        { "G", "green", "g",   nullptr },
        { "B", "blue",  "b",   nullptr },
        { "A", "alpha", "a",   nullptr },
    };

    for (int si = 0; suffixes[slot][si]; ++si) {
        std::string candidate = layer.empty()
            ? std::string(bareSuffixes[slot][si])
            : layer + suffixes[slot][si];
        for (const auto &ch : pool) {
            // Case-insensitive comparison
            if (ch.size() == candidate.size() &&
                std::equal(ch.begin(), ch.end(), candidate.begin(),
                           [](char a, char b) {
                               return std::tolower((unsigned char)a) ==
                                      std::tolower((unsigned char)b);
                           })) {
                return ch;
            }
        }
    }
    return "";
}

/// Given a ChannelList, an (effective) layer name, and the data window, resolve
/// RGBA channels, build a FrameBuffer, and read pixels into the output buffer.
/// Shared logic used by both ReadEXRTextureDirectly and ReadEXRIntoTexture.
///
/// `effectiveLayer` is the layer prefix used for channel-name matching.
/// For multi-part EXRs where each part has bare R,G,B,A channels and the
/// part name serves as the layer, pass the part name here.  For single-part
/// EXRs with dot-prefixed channels, pass the raw layer name (may be "").
static void
ResolveAndReadEXRLayer(Imf::InputPart &part,
                       const Imf::ChannelList &channels,
                       const std::string &effectiveLayer,
                       const Imath::Box2i &dw,
                       Imath::half *pixels,
                       int width, int height)
{
    // Build a pool of all channels that belong to this layer.
    std::vector<std::string> pool;
    for (auto it = channels.begin(); it != channels.end(); ++it) {
        std::string name(it.name());
        if (effectiveLayer.empty()) {
            if (name.rfind('.') == std::string::npos) pool.push_back(name);
        } else {
            // Match "layer.R" style channels.
            if (name.size() > effectiveLayer.size() + 1 &&
                name.compare(0, effectiveLayer.size() + 1, effectiveLayer + ".") == 0)
                pool.push_back(name);
        }
    }
    const double fillValues[4] = { 0.0, 0.0, 0.0, 1.0 };
    std::string  resolved[4];

    for (int slot = 0; slot < 4; ++slot) {
        std::string match = FindChannelInPool(pool, effectiveLayer, slot);
        if (!match.empty())
            resolved[slot] = match;
        else if (slot < (int)pool.size())
            resolved[slot] = pool[slot];
    }

    // 1-channel layer → greyscale replication.
    if (pool.size() == 1 && !resolved[0].empty()) {
        if (resolved[1].empty()) resolved[1] = resolved[0];
        if (resolved[2].empty()) resolved[2] = resolved[0];
    }
    const size_t nPixels = (size_t)width * height;
    const size_t xStride = 4 * sizeof(Imath::half);
    const size_t yStride = (size_t)width * xStride;

    Imf::FrameBuffer fb;
    std::set<std::string> insertedNames;
    int primarySlotForName[4] = { -1, -1, -1, -1 };

    for (int slot = 0; slot < 4; ++slot) {
        Imath::half *slotBase = pixels + slot;
        if (!resolved[slot].empty()) {
            if (insertedNames.count(resolved[slot]) == 0) {
                fb.insert(resolved[slot],
                          Imf::Slice::Make(Imf::HALF, slotBase, dw,
                                           xStride, yStride,
                                           1, 1, fillValues[slot]));
                insertedNames.insert(resolved[slot]);
                primarySlotForName[slot] = slot;
            } else {
                for (int p = 0; p < slot; ++p) {
                    if (resolved[p] == resolved[slot]) {
                        primarySlotForName[slot] = p;
                        break;
                    }
                }
            }
        }
    }

    // Fill alpha with 1.0 when no alpha channel is present.
    if (resolved[3].empty()) {
        Imath::half one(1.0f);
        for (size_t i = 3; i < nPixels * 4; i += 4)
            pixels[i] = one;
    }

    part.setFrameBuffer(fb);
    part.readPixels(dw.min.y, dw.max.y);

    // Copy replicated channels.
    for (int slot = 0; slot < 4; ++slot) {
        int primary = primarySlotForName[slot];
        if (primary >= 0 && primary != slot) {
            for (size_t i = 0; i < nPixels; ++i)
                pixels[i * 4 + slot] = pixels[i * 4 + primary];
        }
    }
}

/// Find the part index and effective layer name for a given user-facing layer.
/// Multi-part EXRs may use either:
///   a) dot-prefixed channels in a single part (layer.R, layer.G, ...)
///   b) bare channels in a named part (part "diffuse" with R,G,B,A)
/// Returns {partIndex, effectiveLayerForChannelMatching}.
static std::pair<int, std::string>
FindPartForLayer(Imf::MultiPartInputFile &file, const std::string &layer) {
    // First pass: look for dot-prefixed channels matching the layer.
    for (int p = 0; p < file.parts(); ++p) {
        const Imf::ChannelList &ch = file.header(p).channels();
        if (layer.empty()) {
            // Default layer — look for bare channels (no dot prefix).
            for (auto it = ch.begin(); it != ch.end(); ++it) {
                std::string name(it.name());
                if (name.rfind('.') == std::string::npos)
                    return {p, ""};
            }
        } else {
            std::string prefix = layer + ".";
            for (auto it = ch.begin(); it != ch.end(); ++it) {
                std::string name(it.name());
                if (name.size() > prefix.size() &&
                    name.compare(0, prefix.size(), prefix) == 0)
                    return {p, layer};
            }
        }
    }
    // Second pass: match by part name (for multi-part with bare channels).
    // Try both the raw part name and the view-stripped name so that layer
    // "ID_castle" matches part "ID_castle.main".
    if (!layer.empty()) {
        for (int p = 0; p < file.parts(); ++p) {
            if (file.header(p).hasName()) {
                std::string pn = file.header(p).name();
                if (pn == layer)
                    return {p, ""};
                if (StripViewFromPartName(pn, file.header(p)) == layer)
                    return {p, ""};
            }
        }
    }
    // Fallback: part 0 with the raw layer name.
    return {0, layer};
}

/// Read a single EXR file directly into an MTLTexture (RGBA16Float), bypassing
/// OIIO's ImageCache and double-buffer overhead.  Supports multi-part EXRs.
static id<MTLTexture>
ReadEXRTextureDirectly(const char *filename,
                       const std::string &layer,
                       id<MTLDevice> device,
                       NSError **outError)
{
    try {
        Imf::MultiPartInputFile file(filename, Imf::globalThreadCount());

        auto [partIdx, effectiveLayer] = FindPartForLayer(file, layer);

        const Imf::Header     &header   = file.header(partIdx);
        const Imf::ChannelList &channels = header.channels();
        const Imath::Box2i    &dw       = header.dataWindow();
        const Imath::Box2i    &dispW    = header.displayWindow();

        // Use the display window for the output image size.
        const int outWidth  = dispW.max.x - dispW.min.x + 1;
        const int outHeight = dispW.max.y - dispW.min.y + 1;
        const int dwWidth   = dw.max.x - dw.min.x + 1;
        const int dwHeight  = dw.max.y - dw.min.y + 1;

        const size_t outPixels  = (size_t)outWidth * outHeight;
        const size_t outRowBytes = (size_t)outWidth * 4 * sizeof(Imath::half);

        // Read into a data-window-sized buffer first.
        const size_t dwPixels  = (size_t)dwWidth * dwHeight;
        std::vector<Imath::half> dwBuf(dwPixels * 4);

        Imf::InputPart part(file, partIdx);
        ResolveAndReadEXRLayer(part, channels, effectiveLayer, dw,
                               dwBuf.data(), dwWidth, dwHeight);

        // If data window == display window, upload directly.
        // Otherwise, composite data window into a display-window-sized buffer.
        const Imath::half *uploadPtr;
        std::vector<Imath::half> dispBuf;

        if (dw.min.x == dispW.min.x && dw.min.y == dispW.min.y &&
            dwWidth == outWidth && dwHeight == outHeight) {
            uploadPtr = dwBuf.data();
        } else {
            dispBuf.resize(outPixels * 4);
            // Fill with black, alpha=0 (transparent outside data window).
            Imath::half zero(0.0f);
            for (size_t i = 0; i < outPixels; ++i) {
                dispBuf[i * 4 + 0] = zero;
                dispBuf[i * 4 + 1] = zero;
                dispBuf[i * 4 + 2] = zero;
                dispBuf[i * 4 + 3] = zero;
            }
            // Copy data window pixels into the correct position.
            const int offX = dw.min.x - dispW.min.x;
            const int offY = dw.min.y - dispW.min.y;
            for (int y = 0; y < dwHeight; ++y) {
                const int destY = y + offY;
                if (destY < 0 || destY >= outHeight) continue;
                for (int x = 0; x < dwWidth; ++x) {
                    const int destX = x + offX;
                    if (destX < 0 || destX >= outWidth) continue;
                    const size_t srcIdx  = ((size_t)y * dwWidth + x) * 4;
                    const size_t destIdx = ((size_t)destY * outWidth + destX) * 4;
                    dispBuf[destIdx + 0] = dwBuf[srcIdx + 0];
                    dispBuf[destIdx + 1] = dwBuf[srcIdx + 1];
                    dispBuf[destIdx + 2] = dwBuf[srcIdx + 2];
                    dispBuf[destIdx + 3] = dwBuf[srcIdx + 3];
                }
            }
            uploadPtr = dispBuf.data();
        }

        // ── Create MTLTexture and upload ──────────────────────────────────────
        MTLTextureDescriptor *desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                               width:(NSUInteger)outWidth
                                                              height:(NSUInteger)outHeight
                                                           mipmapped:NO];
        desc.usage       = MTLTextureUsageShaderRead;
        desc.storageMode = [device hasUnifiedMemory] ? MTLStorageModeShared
                                                     : MTLStorageModeManaged;
        id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
        if (!texture) return nil;

        [texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)outWidth, (NSUInteger)outHeight)
                   mipmapLevel:0
                     withBytes:uploadPtr
                   bytesPerRow:outRowBytes];
        return texture;

    } catch (const std::exception &e) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"OpenEXRDirect" code:-1
                              userInfo:@{NSLocalizedDescriptionKey:
                                  SafeNSString(e.what())}];
        }
        return nil;
    }
}

/// Variant of ReadEXRTextureDirectly that writes into a caller-supplied texture
/// instead of allocating a new one.  The texture must be RGBA16Float and match
/// the EXR's display-window dimensions.
static BOOL
ReadEXRIntoTexture(const char *filename,
                   const std::string &layer,
                   id<MTLTexture> texture,
                   NSError **outError)
{
    Imath::half *dwPixels = nullptr;
    try {
        Imf::MultiPartInputFile file(filename, Imf::globalThreadCount());

        auto [partIdx, effectiveLayer] = FindPartForLayer(file, layer);

        const Imf::Header     &header   = file.header(partIdx);
        const Imf::ChannelList &channels = header.channels();
        const Imath::Box2i    &dw       = header.dataWindow();
        const Imath::Box2i    &dispW    = header.displayWindow();

        const int outWidth  = dispW.max.x - dispW.min.x + 1;
        const int outHeight = dispW.max.y - dispW.min.y + 1;
        const int dwWidth   = dw.max.x - dw.min.x + 1;
        const int dwHeight  = dw.max.y - dw.min.y + 1;

        // Bail out if the display-window dimensions don't match the texture.
        if ((NSUInteger)outWidth  != texture.width ||
            (NSUInteger)outHeight != texture.height) {
            if (outError) {
                *outError = [NSError errorWithDomain:@"OpenEXRDirect" code:-3
                                  userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"EXR display %dx%d doesn't match texture %lux%lu",
                     outWidth, outHeight, (unsigned long)texture.width, (unsigned long)texture.height]}];
            }
            return NO;
        }

        // ── Read into data-window-sized buffer ────────────────────────────────
        const size_t dwNPixels  = (size_t)dwWidth * dwHeight;
        const size_t dwRowBytes = (size_t)dwWidth * 4 * sizeof(Imath::half);
        dwPixels = static_cast<Imath::half *>(malloc(dwNPixels * 4 * sizeof(Imath::half)));
        if (!dwPixels) {
            if (outError) {
                *outError = [NSError errorWithDomain:@"OpenEXRDirect" code:-2
                                  userInfo:@{NSLocalizedDescriptionKey: @"Out of memory"}];
            }
            return NO;
        }

        // ── Resolve RGBA channel names ────────────────────────────────────────
        std::vector<std::string> pool;
        for (auto it = channels.begin(); it != channels.end(); ++it) {
            std::string name(it.name());
            if (effectiveLayer.empty()) {
                if (name.rfind('.') == std::string::npos) pool.push_back(name);
            } else {
                if (name.size() > effectiveLayer.size() + 1 &&
                    name.compare(0, effectiveLayer.size() + 1, effectiveLayer + ".") == 0)
                    pool.push_back(name);
            }
        }

        const double      fillValues[4]  = { 0.0, 0.0, 0.0, 1.0 };
        std::string       resolved[4];

        for (int slot = 0; slot < 4; ++slot) {
            std::string match = FindChannelInPool(pool, effectiveLayer, slot);
            if (!match.empty())
                resolved[slot] = match;
            else if (slot < (int)pool.size())
                resolved[slot] = pool[slot];
        }

        if (pool.size() == 1 && !resolved[0].empty()) {
            if (resolved[1].empty()) resolved[1] = resolved[0];
            if (resolved[2].empty()) resolved[2] = resolved[0];
        }

        const size_t xStride = 4 * sizeof(Imath::half);
        const size_t yStride = (size_t)dwWidth * 4 * sizeof(Imath::half);

        Imf::FrameBuffer fb;
        std::set<std::string> insertedNames;
        int primarySlotForName[4] = { -1, -1, -1, -1 };

        for (int slot = 0; slot < 4; ++slot) {
            Imath::half *slotBase = dwPixels + slot;
            if (!resolved[slot].empty()) {
                if (insertedNames.count(resolved[slot]) == 0) {
                    fb.insert(resolved[slot],
                              Imf::Slice::Make(Imf::HALF, slotBase, dw,
                                               xStride, yStride,
                                               /*xSampling=*/1, /*ySampling=*/1,
                                               fillValues[slot]));
                    insertedNames.insert(resolved[slot]);
                    primarySlotForName[slot] = slot;
                } else {
                    for (int p = 0; p < slot; ++p) {
                        if (resolved[p] == resolved[slot]) {
                            primarySlotForName[slot] = p;
                            break;
                        }
                    }
                }
            }
        }

        // Fill unresolved slots in the data-window buffer.
        for (int slot = 0; slot < 3; ++slot) {
            if (resolved[slot].empty()) {
                Imath::half zero(0.0f);
                for (size_t i = (size_t)slot; i < dwNPixels * 4; i += 4)
                    dwPixels[i] = zero;
            }
        }
        if (resolved[3].empty()) {
            Imath::half one(1.0f);
            for (size_t i = 3; i < dwNPixels * 4; i += 4)
                dwPixels[i] = one;
        }

        Imf::InputPart part(file, partIdx);
        part.setFrameBuffer(fb);
        part.readPixels(dw.min.y, dw.max.y);

        // Copy replicated channels.
        for (int slot = 0; slot < 4; ++slot) {
            int primary = primarySlotForName[slot];
            if (primary >= 0 && primary != slot) {
                for (size_t i = 0; i < dwNPixels; ++i)
                    dwPixels[i * 4 + slot] = dwPixels[i * 4 + primary];
            }
        }

        // ── Upload to texture ─────────────────────────────────────────────────
        const size_t outRowBytes = (size_t)outWidth * 4 * sizeof(Imath::half);

        if (dw.min.x == dispW.min.x && dw.min.y == dispW.min.y &&
            dwWidth == outWidth && dwHeight == outHeight) {
            // Fast path: data window == display window.
            [texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)outWidth, (NSUInteger)outHeight)
                       mipmapLevel:0
                         withBytes:dwPixels
                       bytesPerRow:dwRowBytes];
        } else {
            // Composite data window into display-window-sized buffer.
            const size_t outNPixels = (size_t)outWidth * outHeight;
            Imath::half *outBuf = static_cast<Imath::half *>(
                malloc(outNPixels * 4 * sizeof(Imath::half)));
            if (!outBuf) { free(dwPixels); return NO; }

            // Fill with black, alpha=0 (transparent outside data window).
            Imath::half zero(0.0f);
            for (size_t i = 0; i < outNPixels; ++i) {
                outBuf[i * 4 + 0] = zero;
                outBuf[i * 4 + 1] = zero;
                outBuf[i * 4 + 2] = zero;
                outBuf[i * 4 + 3] = zero;
            }
            // Copy data-window pixels at the correct offset.
            const int offX = dw.min.x - dispW.min.x;
            const int offY = dw.min.y - dispW.min.y;
            for (int y = 0; y < dwHeight; ++y) {
                const int destY = y + offY;
                if (destY < 0 || destY >= outHeight) continue;
                const size_t srcRow  = (size_t)y * dwWidth * 4;
                const size_t destRow = (size_t)destY * outWidth * 4;
                const int x0 = std::max(0, -offX);
                const int x1 = std::min(dwWidth, outWidth - offX);
                if (x0 < x1) {
                    memcpy(&outBuf[destRow + (x0 + offX) * 4],
                           &dwPixels[srcRow + x0 * 4],
                           (size_t)(x1 - x0) * 4 * sizeof(Imath::half));
                }
            }
            [texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)outWidth, (NSUInteger)outHeight)
                       mipmapLevel:0
                         withBytes:outBuf
                       bytesPerRow:outRowBytes];
            free(outBuf);
        }
        free(dwPixels);
        return YES;

    } catch (const std::exception &e) {
        free(dwPixels);
        if (outError) {
            *outError = [NSError errorWithDomain:@"OpenEXRDirect" code:-1
                              userInfo:@{NSLocalizedDescriptionKey:
                                  SafeNSString(e.what())}];
        }
        return NO;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - C++ layer helpers (OIIO path)
// ─────────────────────────────────────────────────────────────────────────────

/// Return ordered unique layer prefixes from spec.channelnames.
/// Channel "R","G","B","A" (no dot) → prefix "".
/// Channel "diffuse.R" → prefix "diffuse".
static std::vector<std::string> ExtractLayerNames(const ImageSpec &spec) {
    std::set<std::string> seen;
    std::vector<std::string> result;
    for (const auto &ch : spec.channelnames) {
        auto dot = ch.rfind('.');
        std::string prefix = (dot == std::string::npos) ? "" : ch.substr(0, dot);
        if (seen.insert(prefix).second) result.push_back(prefix);
    }
    return result;
}

/// Iterate all subimages of an already-opened ImageInput and collect layer
/// prefixes.  Handles both single-part EXRs (all channels in subimage 0) and
/// multi-part EXRs (each part = one subimage with bare R,G,B,A channels and
/// a part name stored as "oiio:subimagename").
static std::vector<std::string>
ExtractLayerNamesAllSubimages(ImageInput *inp) {
    std::set<std::string>    seen;
    std::vector<std::string> result;
    int subimage = 0;
    bool isMultiSubimage = false;
    do {
        const ImageSpec &si = inp->spec();
        std::string partName = si.get_string_attribute("oiio:subimagename", "");
        // Strip the view suffix from the part name (e.g. "ID_castle.main" → "ID_castle").
        // OIIO exposes the EXR per-part "view" attribute as a string.
        std::string viewName = si.get_string_attribute("view", "");
        if (!viewName.empty() && !partName.empty()) {
            std::string suffix = "." + viewName;
            if (partName.size() > suffix.size() &&
                partName.compare(partName.size() - suffix.size(), suffix.size(), suffix) == 0) {
                partName = partName.substr(0, partName.size() - suffix.size());
                if (partName == "rgba") partName = "";
            }
        }
        for (const auto &ch : si.channelnames) {
            auto dot = ch.rfind('.');
            std::string prefix;
            if (dot != std::string::npos) {
                // Channel already has a dot-separated layer prefix.
                prefix = ch.substr(0, dot);
            } else if (!partName.empty() && isMultiSubimage) {
                // Bare channel name (R,G,B,A) inside a named part —
                // use the view-stripped part name as the layer prefix.
                prefix = partName;
            }
            // else: bare channel, unnamed part → default layer ("")
            if (seen.insert(prefix).second) result.push_back(prefix);
        }
        ++subimage;
        if (inp->seek_subimage(subimage, 0)) {
            isMultiSubimage = true;
        } else {
            break;
        }
    } while (true);
    return result;
}

/// Build a 4-channel RGBA ImageBuf from `src` for the named `layer`.
/// Empty string = default unnamed layer (R/G/B/A channels or first 4).
///
/// Priority:
///   1. Exact name match:  "R"/"G"/"B"/"A"  or  "<layer>.R" etc.
///   2. ith channel in the layer prefix pool
///   3. Constant: 0.0 for colour slots, 1.0 for alpha
static ImageBuf ExtractLayerRGBA(const ImageBuf &src, const std::string &layer) {
    const ImageSpec &spec = src.spec();
    const auto &names = spec.channelnames;

    // Collect channel names and indices that belong to this layer
    std::vector<std::string> pool;
    std::vector<int> layerPool;
    for (int i = 0; i < (int)names.size(); ++i) {
        const auto &n = names[i];
        if (layer.empty()) {
            if (n.rfind('.') == std::string::npos) { pool.push_back(n); layerPool.push_back(i); }
        } else {
            if (n.size() > layer.size() + 1 &&
                n.compare(0, layer.size() + 1, layer + ".") == 0)
                { pool.push_back(n); layerPool.push_back(i); }
        }
    }

    int   channelorder[4]  = { -1, -1, -1, -1 };
    float channelvalues[4] = { 0.0f, 0.0f, 0.0f, 1.0f };

    for (int slot = 0; slot < 4; ++slot) {
        // Pass 1: name matching via FindChannelInPool (handles .R, .red, etc.)
        std::string match = FindChannelInPool(pool, layer, slot);
        if (!match.empty()) {
            auto it = std::find(names.begin(), names.end(), match);
            if (it != names.end()) { channelorder[slot] = (int)(it - names.begin()); continue; }
        }
        // Pass 2: pool fallback
        if (slot < (int)layerPool.size()) { channelorder[slot] = layerPool[slot]; continue; }
        // Pass 3: constant (already set in channelvalues)
    }

    // Replicate single-channel layers to greyscale (R→G, R→B)
    if (layerPool.size() == 1 && channelorder[0] >= 0) {
        if (channelorder[1] < 0) channelorder[1] = channelorder[0];
        if (channelorder[2] < 0) channelorder[2] = channelorder[0];
    }

    ImageBuf rgba;
    ImageBufAlgo::channels(rgba, src, 4, channelorder, channelvalues);
    return rgba;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - OIIOImageSpec
// ─────────────────────────────────────────────────────────────────────────────

@implementation OIIOImageSpec {
    ImageSpec _spec;
}

- (instancetype)initWithImageSpec:(const ImageSpec &)spec {
    return [self initWithImageSpec:spec
                       layerNames:nil];
}

/// Designated initialiser.  `overrideLayers` lets callers inject the full
/// channel-name list from the original (pre-normalisation) ImageSpec when
/// the `spec` arg is a normalised 4-channel RGBA buf whose own channel
/// names would only produce a single unnamed layer.
- (instancetype)initWithImageSpec:(const ImageSpec &)spec
                       layerNames:(NSArray<NSString *> * _Nullable)overrideLayers {
    self = [super init];
    if (self) {
        _spec  = spec;
        // Use display-window dimensions (full_width/full_height) so that
        // EXR files whose data window is smaller than the display window
        // report the correct full-frame size.  For non-EXR formats these
        // equal spec.width / spec.height by default.
        _width    = spec.full_width  > 0 ? spec.full_width  : spec.width;
        _height   = spec.full_height > 0 ? spec.full_height : spec.height;
        _channels = spec.nchannels;

        // Bit depth
        if (spec.format == TypeDesc::UINT8)                          _bitDepth = 8;
        else if (spec.format == TypeDesc::UINT16 ||
                 spec.format == TypeDesc::HALF)                      _bitDepth = 16;
        else                                                         _bitDepth = 32;

        // Color space
        auto cs = spec.get_string_attribute("oiio:ColorSpace", "Linear");
        _colorSpace = SafeNSString(cs.c_str());

        // HDR flag
        _isHDR = (spec.format == TypeDesc::HALF  ||
                  spec.format == TypeDesc::FLOAT  ||
                  spec.format == TypeDesc::DOUBLE);

        // Peak luminance
        _maxLuminance = spec.get_float_attribute("maxLuminance", 0.0f);

        // Extra attributes
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        for (const auto &param : spec.extra_attribs) {
            NSString *key   = SafeNSString(param.name().c_str());
            NSString *value = SafeNSString(param.get_string().c_str());
            attrs[key] = value;
        }
        _attributes = [attrs copy];

        // Layer names — use override if provided, otherwise extract from spec
        if (overrideLayers) {
            _layerNames = [overrideLayers copy];
        } else {
            auto layers = ExtractLayerNames(spec);
            if (layers.size() > 1) {
                NSMutableArray *arr = [NSMutableArray arrayWithCapacity:layers.size()];
                for (const auto &l : layers)
                    [arr addObject:SafeNSString(l.c_str())];
                _layerNames = [arr copy];
            } else {
                _layerNames = @[];
            }
        }
    }
    return self;
}

- (const ImageSpec &)imageSpec { return _spec; }

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - OIIOImage
// ─────────────────────────────────────────────────────────────────────────────

@implementation OIIOImage {
    ImageBuf _imageBuf;
}

/// Accepts a pre-normalised 4-channel RGBA ImageBuf.  Pass the result of
/// ExtractLayerRGBA — never an original many-channel buf — to avoid OOM.
- (instancetype)initWithImageBuf:(const ImageBuf &)buf {
    return [self initWithImageBuf:buf layerNames:nil];
}

/// Designated form — `layerNames` overrides the layer list derived from buf's
/// own channel names.  Use when buf is a normalised 4-channel RGBA extract
/// whose channel names would not reveal the original multi-layer structure.
- (instancetype)initWithImageBuf:(const ImageBuf &)buf
                      layerNames:(NSArray<NSString *> * _Nullable)layerNames {
    self = [super init];
    if (self) {
        _imageBuf = buf;
        const ImageSpec &spec = buf.spec();

        // Build spec; pass layerNames override so multi-layer info is preserved
        // even after the buf has been normalised to 4 RGBA channels.
        _spec = [[OIIOImageSpec alloc] initWithImageSpec:spec layerNames:layerNames];

        // Safe allocation: at most 4K RGBA-float = ~128 MB
        size_t dataSize = (size_t)spec.width * spec.height * spec.nchannels * sizeof(float);
        float *pixels = (float *)malloc(dataSize);
        if (!pixels) { return nil; }

        if (buf.get_pixels(ROI::All(), TypeDesc::FLOAT, pixels)) {
            _pixelData = [NSData dataWithBytesNoCopy:pixels length:dataSize freeWhenDone:YES];
        } else {
            free(pixels);
            return nil;
        }
    }
    return self;
}

- (const ImageBuf &)imageBuf { return _imageBuf; }

- (nullable id<MTLTexture>)createMetalTexture:(id<MTLDevice>)device {
    const ImageSpec &spec = _imageBuf.spec();
    // Data window dimensions (the actual pixel region).
    const int dwWidth  = spec.width;
    const int dwHeight = spec.height;
    // Display window dimensions (the full frame).
    const int outWidth  = (spec.full_width  > 0) ? spec.full_width  : dwWidth;
    const int outHeight = (spec.full_height > 0) ? spec.full_height : dwHeight;

    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:(NSUInteger)outWidth
                                                          height:(NSUInteger)outHeight
                                                       mipmapped:NO];
    desc.usage       = MTLTextureUsageShaderRead;
    desc.storageMode = [device hasUnifiedMemory] ? MTLStorageModeShared
                                                 : MTLStorageModeManaged;

    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    if (!texture) { return nil; }

    // Pad to RGBA if somehow < 4 channels (defensive; shouldn't occur after normalisation)
    ImageBuf rgbaBuf;
    if (spec.nchannels < 4) {
        int   channelorder[]  = { 0, spec.nchannels > 1 ? 1 : 0,
                                  spec.nchannels > 2 ? 2 : 0, -1 };
        float channelvalues[] = { 0, 0, 0, 1 };
        ImageBufAlgo::channels(rgbaBuf, _imageBuf, 4, channelorder, channelvalues);
    } else {
        rgbaBuf = _imageBuf;
    }

    // Read data-window pixels as HALF.
    size_t dwPixelCount = (size_t)dwWidth * dwHeight * 4;
    std::vector<uint16_t> dwPixels(dwPixelCount);
    rgbaBuf.get_pixels(ROI::All(), TypeDesc::HALF, dwPixels.data());

    if (dwWidth == outWidth && dwHeight == outHeight &&
        spec.x == spec.full_x && spec.y == spec.full_y) {
        // Fast path: data window == display window.
        [texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)outWidth, (NSUInteger)outHeight)
                   mipmapLevel:0
                     withBytes:dwPixels.data()
                   bytesPerRow:(size_t)outWidth * 4 * sizeof(uint16_t)];
    } else {
        // Composite data window into display-window-sized buffer.
        size_t outPixelCount = (size_t)outWidth * outHeight * 4;
        std::vector<uint16_t> outBuf(outPixelCount);
        // Fill with black, alpha=0 (transparent outside data window).
        for (size_t i = 0; i < (size_t)outWidth * outHeight; ++i) {
            outBuf[i * 4 + 0] = 0;
            outBuf[i * 4 + 1] = 0;
            outBuf[i * 4 + 2] = 0;
            outBuf[i * 4 + 3] = 0;
        }
        const int offX = spec.x - spec.full_x;
        const int offY = spec.y - spec.full_y;
        for (int y = 0; y < dwHeight; ++y) {
            const int destY = y + offY;
            if (destY < 0 || destY >= outHeight) continue;
            const int x0 = std::max(0, -offX);
            const int x1 = std::min(dwWidth, outWidth - offX);
            if (x0 < x1) {
                memcpy(&outBuf[((size_t)destY * outWidth + x0 + offX) * 4],
                       &dwPixels[((size_t)y * dwWidth + x0) * 4],
                       (size_t)(x1 - x0) * 4 * sizeof(uint16_t));
            }
        }
        [texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)outWidth, (NSUInteger)outHeight)
                   mipmapLevel:0
                     withBytes:outBuf.data()
                   bytesPerRow:(size_t)outWidth * 4 * sizeof(uint16_t)];
    }
    return texture;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - OpenImageIOBridge
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - OpenImageIOBridge
// ─────────────────────────────────────────────────────────────────────────────

@implementation OpenImageIOBridge

// Called once by the ObjC runtime before any class method is invoked.
+ (void)initialize {
    if (self != [OpenImageIOBridge class]) return;

    // Use all CPU cores for every OIIO decode.
    // Default is 1 — on a 10-core M-series this is a 10× throughput improvement.
    OIIO::attribute("threads", 0);   // 0 = hardware_concurrency()

    // Give the global ImageCache enough RAM to hold a full 1080p sequence loop
    // in memory (~2 GB ≈ 125 frames of half-float RGBA).  This means second-pass
    // playback of any sequence that fits is purely from RAM, matching Resolve.
    // shared=false: each process gets its own private cache.
    // shared=true would use OS shared memory across all processes on the machine;
    // when multiple xcodebuild test workers start simultaneously they corrupt each
    // other's cached ImageSpec (channel names), breaking RGBA channel mapping.
    // The app is single-process so private-per-process caching is identical in practice.
    auto ic = OIIO::ImageCache::create(/*shared=*/false);
    ic->attribute("max_memory_MB",   2048.0f);
    // Allow many files open simultaneously for a sequence — the default (100) is
    // too low when 16 prefetch tasks each have a file partially read.
    ic->attribute("max_open_files",  256);

    // Configure OpenEXR's IlmThread pool for the direct EXR path.
    // OpenEXR defaults to 0 (single-threaded).  Setting to hardware_concurrency()
    // lets it decompress scanlines in parallel.  The pool is global and shared
    // across all concurrently open InputFiles, so this won't oversubscribe when
    // many prefetch tasks run at once — OpenEXR manages the pool internally.
    Imf::setGlobalThreadCount((int)std::thread::hardware_concurrency());
}
/// Shared implementation: full decode + RGBA normalisation + layer-name injection.
+ (nullable OIIOImage *)_readPath:(const char *)filename
                            layer:(const std::string &)layer
                            error:(NSError **)error {
    // Quick open to validate the file (also primes OIIO's error state)
    {
        auto inp = ImageInput::open(filename);
        if (!inp) {
            if (error) {
                *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-1
                              userInfo:@{NSLocalizedDescriptionKey:
                                  SafeNSString(OIIO::geterror().c_str())}];
            }
            return nil;
        }
        inp->close();
    }

    // Full decode — subimage 0.  force=false lets OIIO's ImageCache serve any
    // repeat reads from RAM (useful when the same file is re-opened after a
    // layer switch).  FLOAT gives full precision for the still/CPU path.
    ImageBuf buf(filename);
    if (!buf.read(0, 0, /*force=*/false, TypeDesc::FLOAT)) {
        if (error) {
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-2
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(buf.geterror().c_str())}];
        }
        return nil;
    }

    // ── Crash prevention ─────────────────────────────────────────────────────
    // Always normalise to 4-channel RGBA before constructing OIIOImage.
    // Prevents runaway malloc for EXRs with 50+ channel layers.
    ImageBuf rgba = ExtractLayerRGBA(buf, layer);
    if (rgba.has_error()) {
        if (error) {
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-3
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(rgba.geterror().c_str())}];
        }
        return nil;
    }

    // ── Layer-name injection ──────────────────────────────────────────────────
    // Scan ALL subimages (multi-part EXRs store each layer in a separate part).
    // A quick header-only re-open is cheap compared to the full pixel decode.
    NSMutableArray *layerNamesArr = nil;
    {
        auto inp = ImageInput::open(filename);
        if (inp) {
            auto allLayers = ExtractLayerNamesAllSubimages(inp.get());
            inp->close();
            if (allLayers.size() > 1) {
                layerNamesArr = [NSMutableArray arrayWithCapacity:allLayers.size()];
                for (const auto &l : allLayers)
                    [layerNamesArr addObject:SafeNSString(l.c_str())];
            }
        }
    }

    return [[OIIOImage alloc] initWithImageBuf:rgba layerNames:layerNamesArr];
}

+ (nullable OIIOImage *)readImageAtPath:(NSString *)path error:(NSError **)error {
    if ([SystemImageIOBridge handlesPath:path])
        return [SystemImageIOBridge readImageAtPath:path error:error];
    return [self _readPath:[path UTF8String] layer:"" error:error];
}

+ (nullable OIIOImage *)readImageAtPath:(NSString *)path
                                  layer:(NSString *)layer
                                  error:(NSError **)error {
    if ([SystemImageIOBridge handlesPath:path])
        return [SystemImageIOBridge readImageAtPath:path error:error];   // single-layer
    std::string layerStr = layer ? std::string([layer UTF8String]) : "";
    return [self _readPath:[path UTF8String] layer:layerStr error:error];
}

+ (nullable OIIOImage *)readImageUncached:(NSString *)path error:(NSError **)error {
    if ([SystemImageIOBridge handlesPath:path])
        return [SystemImageIOBridge readImageAtPath:path error:error];
    const char *filename = [path UTF8String];

    // Use ImageInput directly — this completely bypasses the OIIO ImageCache.
    // ImageBuf(filename)+force=true copies from the cache into local storage
    // rather than re-reading from disk, so it propagates any stale cache data.
    // ImageInput has no cache involvement at all.
    auto inp = ImageInput::open(filename);
    if (!inp) {
        if (error) {
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-1
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(OIIO::geterror().c_str())}];
        }
        return nil;
    }

    // Snapshot spec (channel names, dimensions) before reading pixels.
    ImageSpec fileSpec = inp->spec();
    int w = fileSpec.width, h = fileSpec.height, nc = fileSpec.nchannels;

    std::vector<float> rawPixels((size_t)w * h * nc);
    bool ok = inp->read_image(0, 0, 0, nc, TypeDesc::FLOAT, rawPixels.data());
    std::string errMsg = ok ? "" : inp->geterror();
    inp->close();
    inp.reset();

    if (!ok) {
        if (error) {
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-2
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(errMsg.c_str())}];
        }
        return nil;
    }

    // Wrap rawPixels in an ImageBuf (no copy — rawPixels outlives this scope).
    // set_pixels is intentionally avoided: it has surprising behavior with ROI::All()
    // on a freshly-constructed ImageBuf in some OIIO versions.
    ImageSpec localSpec(w, h, nc, TypeDesc::FLOAT);
    localSpec.channelnames = fileSpec.channelnames;
    ImageBuf localBuf(localSpec, rawPixels.data());

    ImageBuf rgba = ExtractLayerRGBA(localBuf, "");
    if (rgba.has_error()) {
        if (error) {
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-3
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(rgba.geterror().c_str())}];
        }
        return nil;
    }

    return [[OIIOImage alloc] initWithImageBuf:rgba layerNames:nil];
}

+ (nullable NSArray<NSString *> *)layerNamesAtPath:(NSString *)path
                                             error:(NSError **)error {
    if ([SystemImageIOBridge handlesPath:path]) return @[];  // single-layer formats
    const char *filename = [path UTF8String];

    // ── Fast path for EXR: read header directly via OpenEXR ──────────────────
    // Uses MultiPartInputFile so that multi-part EXRs (where each layer lives
    // in a separate part) are handled correctly — InputFile only sees part 0.
    if ([path.lowercaseString hasSuffix:@".exr"]) {
        try {
            Imf::MultiPartInputFile file(filename, /*numThreads=*/1);
            std::set<std::string>    seen;
            std::vector<std::string> result;
            for (int p = 0; p < file.parts(); ++p) {
                const Imf::ChannelList &channels = file.header(p).channels();
                // Also check for a "name" attribute which some multi-part EXRs
                // use as the layer/part name (channels may be bare R,G,B,A in
                // each part, with the part name providing the layer prefix).
                std::string partName;
                if (file.header(p).hasName())
                    partName = StripViewFromPartName(
                        file.header(p).name(), file.header(p));
                for (auto it = channels.begin(); it != channels.end(); ++it) {
                    std::string chName(it.name());
                    auto dot = chName.rfind('.');
                    std::string prefix;
                    if (dot != std::string::npos) {
                        // Channel already has a dot-separated layer prefix.
                        prefix = chName.substr(0, dot);
                    } else if (!partName.empty() && file.parts() > 1) {
                        // Bare channel name (R,G,B,A) inside a named part —
                        // use the view-stripped part name as the layer prefix.
                        prefix = partName;
                    }
                    // else: bare channel, unnamed part → default layer ("")
                    if (seen.insert(prefix).second) result.push_back(prefix);
                }
            }
            if (result.size() <= 1) return @[];
            NSMutableArray *arr = [NSMutableArray arrayWithCapacity:result.size()];
            for (const auto &l : result)
                [arr addObject:SafeNSString(l.c_str())];
            return [arr copy];
        } catch (const std::exception &e) {
            if (error)
                *error = [NSError errorWithDomain:@"OpenEXRDirect" code:-1
                              userInfo:@{NSLocalizedDescriptionKey:
                                  SafeNSString(e.what())}];
            return nil;
        }
    }

    // ── OIIO path for all other formats ──────────────────────────────────────
    auto inp = ImageInput::open(filename);
    if (!inp) {
        if (error) {
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-1
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(OIIO::geterror().c_str())}];
        }
        return nil;
    }
    auto allLayers = ExtractLayerNamesAllSubimages(inp.get());
    inp->close();
    if (allLayers.size() <= 1) return @[];
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:allLayers.size()];
    for (const auto &l : allLayers)
        [arr addObject:SafeNSString(l.c_str())];
    return [arr copy];
}

+ (nullable OIIOImageSpec *)readMetadataAtPath:(NSString *)path
                                         error:(NSError **)error {
    if ([SystemImageIOBridge handlesPath:path])
        return [SystemImageIOBridge readMetadataAtPath:path error:error];
    const char *filename = [path UTF8String];
    auto inp = ImageInput::open(filename);
    if (!inp) {
        if (error) {
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-1
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(OIIO::geterror().c_str())}];
        }
        return nil;
    }
    // Use subimage 0's spec for dimensions, color space, bit depth, etc.
    const ImageSpec spec = inp->spec();   // copy — seek_subimage may invalidate ref

    // Extract layer names across ALL subimages (handles multi-part EXRs).
    // Must re-seek to subimage 0 first since we already read it above.
    inp->seek_subimage(0, 0);
    auto allLayers = ExtractLayerNamesAllSubimages(inp.get());

    NSMutableArray *layerArr = nil;
    if (allLayers.size() > 1) {
        layerArr = [NSMutableArray arrayWithCapacity:allLayers.size()];
        for (const auto &l : allLayers)
            [layerArr addObject:SafeNSString(l.c_str())];
    }
    OIIOImageSpec *result = [[OIIOImageSpec alloc] initWithImageSpec:spec
                                                          layerNames:layerArr];
    inp->close();
    return result;
}

+ (nullable id<MTLTexture>)readTextureAtPath:(NSString *)path
                                       layer:(NSString *)layer
                                      device:(id<MTLDevice>)device
                                       error:(NSError **)error {
    if ([SystemImageIOBridge handlesPath:path])
        return [SystemImageIOBridge readTextureAtPath:path device:device error:error];
    std::string layerStr = layer ? std::string([layer UTF8String]) : "";
    const char *filename = [path UTF8String];

    // ── Fast path: use OpenEXR directly for .exr files ───────────────────────
    // Avoids OIIO's ImageCache overhead and the double-allocation caused by
    // reading all N channels and then extracting 4.  Falls back to the OIIO
    // path on any exception (e.g. unusual tile layouts, deep EXR, etc.).
    if ([path.lowercaseString hasSuffix:@".exr"]) {
        NSError *exrError = nil;
        id<MTLTexture> tex = ReadEXRTextureDirectly(filename, layerStr, device, &exrError);
        if (tex) return tex;
        // On failure fall through to the OIIO path below so callers always
        // get a result if the file is valid but just unusual in some way.
        // (If OIIO also fails it will surface its own error via outError.)
    }

    // ── Read as HALF (not FLOAT) ─────────────────────────────────────────────
    // • Halves the amount of data decompressed into RAM vs TypeDesc::FLOAT.
    // • For native-HALF EXRs (the most common HDR format) this is a zero-cost
    //   identity; OIIO passes the scanline data through without conversion.
    // • force=false: let OIIO's ImageCache hold decoded tiles.  Second-pass
    //   reads of the same file region are served from RAM without disk I/O.
    ImageBuf src(filename);
    if (!src.read(0, 0, /*force=*/false, TypeDesc::HALF)) {
        if (error)
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-1
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(src.geterror().c_str())}];
        return nil;
    }

    ImageBuf rgba = ExtractLayerRGBA(src, layerStr);

    // Free the full-channel source buf before the texture allocation so peak
    // RSS stays lower (relevant for large multi-channel EXRs).
    src.clear();

    const ImageSpec &spec = rgba.spec();
    // Data window: the region with actual pixel data.
    const size_t dwWidth  = (size_t)spec.width;
    const size_t dwHeight = (size_t)spec.height;
    // Display window: the full-frame size (may be larger than data window for EXR).
    const size_t outWidth  = (spec.full_width  > 0) ? (size_t)spec.full_width  : dwWidth;
    const size_t outHeight = (spec.full_height > 0) ? (size_t)spec.full_height : dwHeight;
    const size_t outRowBytes = outWidth * 4 * sizeof(uint16_t);   // RGBA16Float

    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:outWidth
                                                          height:outHeight
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    // Apple Silicon has unified CPU/GPU memory.  Shared storage lets
    // replaceRegion: write directly to that memory without a managed sync copy.
    // Fall back to Managed on discrete-GPU Macs where the two heaps are separate.
    desc.storageMode = [device hasUnifiedMemory] ? MTLStorageModeShared
                                                 : MTLStorageModeManaged;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    if (!texture) return nil;

    // Get the data-window pixels as HALF.
    const void *localPixels = rgba.localpixels();
    std::vector<uint16_t> convertedBuf;
    const void *dwPixelPtr = nullptr;
    const size_t dwRowBytes = dwWidth * 4 * sizeof(uint16_t);

    if (localPixels && rgba.spec().format == TypeDesc::HALF) {
        dwPixelPtr = localPixels;
    } else {
        convertedBuf.resize(dwWidth * dwHeight * 4);
        rgba.get_pixels(ROI::All(), TypeDesc::HALF, convertedBuf.data());
        dwPixelPtr = convertedBuf.data();
    }

    if (dwWidth == outWidth && dwHeight == outHeight &&
        spec.x == spec.full_x && spec.y == spec.full_y) {
        // Fast path: data window == display window.
        [texture replaceRegion:MTLRegionMake2D(0, 0, outWidth, outHeight)
                   mipmapLevel:0
                     withBytes:dwPixelPtr
                   bytesPerRow:dwRowBytes];
    } else {
        // Composite data window into a display-window-sized buffer.
        std::vector<uint16_t> outBuf(outWidth * outHeight * 4);
        // Fill with black, alpha=0 (transparent outside data window).
        for (size_t i = 0; i < outWidth * outHeight; ++i) {
            outBuf[i * 4 + 0] = 0;       // R = 0
            outBuf[i * 4 + 1] = 0;       // G = 0
            outBuf[i * 4 + 2] = 0;       // B = 0
            outBuf[i * 4 + 3] = 0;       // A = 0 (transparent)
        }
        const int offX = spec.x - spec.full_x;
        const int offY = spec.y - spec.full_y;
        for (size_t y = 0; y < dwHeight; ++y) {
            const int destY = (int)y + offY;
            if (destY < 0 || destY >= (int)outHeight) continue;
            const int x0 = std::max(0, -offX);
            const int x1 = std::min((int)dwWidth, (int)outWidth - offX);
            if (x0 < x1) {
                memcpy(&outBuf[((size_t)destY * outWidth + x0 + offX) * 4],
                       &((const uint16_t *)dwPixelPtr)[(y * dwWidth + x0) * 4],
                       (size_t)(x1 - x0) * 4 * sizeof(uint16_t));
            }
        }
        [texture replaceRegion:MTLRegionMake2D(0, 0, outWidth, outHeight)
                   mipmapLevel:0
                     withBytes:outBuf.data()
                   bytesPerRow:outRowBytes];
    }
    return texture;
}

+ (BOOL)readEXRAtPath:(NSString *)path
                layer:(NSString *)layer
          intoTexture:(id<MTLTexture>)texture {
    std::string layerStr = layer ? std::string([layer UTF8String]) : "";
    return ReadEXRIntoTexture([path UTF8String], layerStr, texture, nil);
}

+ (BOOL)writeImage:(OIIOImage *)image toPath:(NSString *)path format:(NSString *)format error:(NSError **)error {
    if ([SystemImageIOBridge handlesPath:path])
        return [SystemImageIOBridge writeImage:image toPath:path error:error];
    const ImageBuf &buf = [image imageBuf];
    if (!buf.write([path UTF8String])) {
        if (error) {
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-3
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(buf.geterror().c_str())}];
        }
        return NO;
    }
    return YES;
}

+ (BOOL)writeFloatPixelData:(NSData *)data
                      width:(NSInteger)width
                     height:(NSInteger)height
                   channels:(NSInteger)channels
                     toPath:(NSString *)path
                      error:(NSError **)error {
    if ([SystemImageIOBridge handlesPath:path])
        return [SystemImageIOBridge writeFloatPixelData:data width:width height:height
                                              channels:channels toPath:path error:error];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    static const char *kChNames[4] = { "R", "G", "B", "A" };
    int nc = (int)channels;
    ImageSpec spec((int)width, (int)height, nc, TypeDesc::FLOAT);
    for (int i = 0; i < nc && i < 4; ++i)
        spec.channelnames[i] = kChNames[i];

    auto out = ImageOutput::create([path UTF8String]);
    if (!out) {
        if (error)
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-5
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(OIIO::geterror().c_str())}];
        return NO;
    }
    if (!out->open([path UTF8String], spec)) {
        if (error)
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-6
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(out->geterror().c_str())}];
        return NO;
    }
    bool ok = out->write_image(TypeDesc::FLOAT, data.bytes);
    std::string writeErr = ok ? "" : out->geterror();
    out->close();
    if (!ok) {
        if (error)
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-7
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(writeErr.c_str())}];
        return NO;
    }
    return YES;
}

+ (NSArray<NSString *> *)supportedReadFormats {
    std::string formats;
    getattribute("extension_list", formats);
    NSMutableArray *result = [NSMutableArray array];
    NSString *str = SafeNSString(formats.c_str());
    for (NSString *component in [str componentsSeparatedByString:@";"]) {
        NSArray *parts = [component componentsSeparatedByString:@":"];
        if (parts.count > 1)
            [result addObjectsFromArray:[parts[1] componentsSeparatedByString:@","]];
    }
    // ImageIO-routed formats are not always present in OIIO's extension_list
    // (HEIF in particular). Make sure they're advertised so format-picker UIs
    // include them.
    NSArray *routed = @[@"jpg", @"jpeg", @"png", @"tif", @"tiff", @"heic", @"heif"];
    for (NSString *ext in routed) {
        if (![result containsObject:ext]) [result addObject:ext];
    }
    return [result copy];
}

+ (NSArray<NSString *> *)supportedWriteFormats {
    return [self supportedReadFormats];
}

+ (nullable OIIOImage *)convertImage:(OIIOImage *)image
                            channels:(NSInteger)channels
                            bitDepth:(NSInteger)bitDepth
                               error:(NSError **)error {
    const ImageBuf  &srcBuf  = [image imageBuf];
    const ImageSpec &srcSpec = srcBuf.spec();

    TypeDesc format;
    if (bitDepth == 8)       format = TypeDesc::UINT8;
    else if (bitDepth == 16) format = TypeDesc::HALF;
    else                     format = TypeDesc::FLOAT;

    int   channelorder[4]  = { -1, -1, -1, -1 };
    float channelvalues[4] = { 0, 0, 0, 1 };
    for (int i = 0; i < (int)channels && i < 4; ++i)
        channelorder[i] = (i < srcSpec.nchannels) ? i : -1;

    ImageSpec dstSpec(srcSpec.width, srcSpec.height, (int)channels, format);
    ImageBuf  dstBuf(dstSpec);
    ImageBufAlgo::channels(dstBuf, srcBuf, (int)channels, channelorder, channelvalues);

    if (dstBuf.has_error()) {
        if (error) {
            *error = [NSError errorWithDomain:@"OpenImageIOBridge" code:-4
                          userInfo:@{NSLocalizedDescriptionKey:
                              SafeNSString(dstBuf.geterror().c_str())}];
        }
        return nil;
    }
    return [[OIIOImage alloc] initWithImageBuf:dstBuf];
}

@end

