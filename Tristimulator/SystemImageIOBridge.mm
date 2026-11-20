//
//  SystemImageIOBridge.mm
//  Tristimulator
//
//  Backs SystemImageIOBridge with macOS ImageIO (CGImageSource /
//  CGImageDestination). Produces OIIOImage / OIIOImageSpec instances by
//  constructing an OIIO::ImageBuf around a CG-decoded float RGBA buffer so
//  downstream code sees the same types regardless of source library.
//

#import "SystemImageIOBridge.h"
#import "OpenImageIOBridge.h"

#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <OpenImageIO/imageio.h>
#include <OpenImageIO/imagebuf.h>
#include <vector>
#include <string>

using namespace OIIO;

// Forward declarations of OIIOImage / OIIOImageSpec private inits. Defined in
// OpenImageIOBridge.mm — exposed here via category-style declarations.
@interface OIIOImage (Internal)
- (instancetype)initWithImageBuf:(const ImageBuf &)buf
                      layerNames:(NSArray<NSString *> * _Nullable)layerNames;
- (const ImageBuf &)imageBuf;
@end

@interface OIIOImageSpec (Internal)
- (instancetype)initWithImageSpec:(const ImageSpec &)spec
                       layerNames:(NSArray<NSString *> * _Nullable)overrideLayers;
@end

#pragma mark - Helpers

static NSError *makeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SystemImageIOBridge"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"unknown error"}];
}

static NSString *colorSpaceTagForCGColorSpace(CGColorSpaceRef cs) {
    if (!cs) return @"sRGB";
    CFStringRef name = CGColorSpaceGetName(cs);
    if (!name) return @"sRGB";

    if (CFEqual(name, kCGColorSpaceSRGB))                       return @"sRGB";
    if (CFEqual(name, kCGColorSpaceLinearSRGB))                 return @"Linear";
    if (CFEqual(name, kCGColorSpaceExtendedSRGB))               return @"sRGB";
    if (CFEqual(name, kCGColorSpaceExtendedLinearSRGB))         return @"Linear";
    if (CFEqual(name, kCGColorSpaceDisplayP3))                  return @"Display P3";
    if (CFEqual(name, kCGColorSpaceLinearDisplayP3))            return @"Linear Display P3";
    if (CFEqual(name, kCGColorSpaceExtendedDisplayP3))          return @"Display P3";
    if (CFEqual(name, kCGColorSpaceExtendedLinearDisplayP3))    return @"Linear Display P3";
    if (CFEqual(name, kCGColorSpaceITUR_709))                   return @"Rec.709";
    if (CFEqual(name, kCGColorSpaceITUR_2020))                  return @"Rec.2020";
    if (CFEqual(name, kCGColorSpaceITUR_2100_PQ))               return @"Rec.2100-PQ";
    if (CFEqual(name, kCGColorSpaceITUR_2100_HLG))              return @"Rec.2100-HLG";
    if (CFEqual(name, kCGColorSpaceGenericRGBLinear))           return @"Linear";

    return [(__bridge NSString *)name copy] ?: @"sRGB";
}

static BOOL isHDRColorSpaceName(CFStringRef name) {
    if (!name) return NO;
    return (CFEqual(name, kCGColorSpaceITUR_2100_PQ)
         || CFEqual(name, kCGColorSpaceITUR_2100_HLG)
         || CFEqual(name, kCGColorSpaceExtendedLinearSRGB)
         || CFEqual(name, kCGColorSpaceExtendedLinearDisplayP3)
         || CFEqual(name, kCGColorSpaceExtendedSRGB)
         || CFEqual(name, kCGColorSpaceExtendedDisplayP3));
}

/// Open the first image in `path` and read its dimensions + color metadata
/// without decoding pixels. Returns the CGImageSource + CGImage (caller must
/// release both) so we can render straight into a caller-supplied buffer.
static BOOL openCGImage(NSString *path,
                        CGImageSourceRef *outSrc,
                        CGImageRef *outImage,
                        size_t *outWidth,
                        size_t *outHeight,
                        NSString **outColorSpaceTag,
                        BOOL *outIsHDR,
                        NSError **error) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) {
        if (error) *error = makeError(-1, [NSString stringWithFormat:@"CGImageSourceCreateWithURL failed for %@", path]);
        return NO;
    }

    NSDictionary *options = @{
        (id)kCGImageSourceShouldCache: @NO,
        (id)kCGImageSourceShouldAllowFloat: @YES,
    };
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, (__bridge CFDictionaryRef)options);
    if (!img) {
        CFRelease(src);
        if (error) *error = makeError(-2, [NSString stringWithFormat:@"CGImageSourceCreateImageAtIndex failed for %@", path]);
        return NO;
    }

    CGColorSpaceRef srcColorSpace = CGImageGetColorSpace(img);
    CFStringRef srcName = srcColorSpace ? CGColorSpaceGetName(srcColorSpace) : NULL;

    *outSrc    = src;
    *outImage  = img;
    *outWidth  = CGImageGetWidth(img);
    *outHeight = CGImageGetHeight(img);
    if (outColorSpaceTag) *outColorSpaceTag = colorSpaceTagForCGColorSpace(srcColorSpace);
    if (outIsHDR)         *outIsHDR         = isHDRColorSpaceName(srcName);
    return YES;
}

/// Render `img` (sized `width`x`height`) into a caller-supplied 32-bit float
/// RGBA buffer with `width*4*sizeof(float)` row stride. The destination color
/// space *matches the source* — so pixel values preserve the source encoding
/// (gamma-encoded for sRGB, PQ-encoded for HDR, etc.), exactly matching what
/// OIIO's own JPEG/PNG/TIFF readers produce. Downstream OCIO can then decode
/// using the source's color-space tag without a double conversion.
static BOOL renderImageIntoFloatRGBA(CGImageRef img,
                                     float *dstBuffer,
                                     size_t width,
                                     size_t height,
                                     NSError **error) {
    CGColorSpaceRef srcSpace = CGImageGetColorSpace(img);
    CGColorSpaceRef workingSpace = srcSpace ? CGColorSpaceRetain(srcSpace)
                                            : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!workingSpace) {
        if (error) *error = makeError(-3, @"Failed to create working color space");
        return NO;
    }

    CGBitmapInfo bitmapInfo = kCGImageAlphaPremultipliedLast
                            | kCGBitmapFloatComponents
                            | kCGBitmapByteOrder32Little;
    CGContextRef ctx = CGBitmapContextCreate(dstBuffer, width, height,
                                             /*bitsPerComponent=*/32,
                                             /*bytesPerRow=*/width * 4 * sizeof(float),
                                             workingSpace, bitmapInfo);
    if (!ctx) {
        CGColorSpaceRelease(workingSpace);
        if (error) *error = makeError(-5, @"CGBitmapContextCreate failed");
        return NO;
    }

    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(workingSpace);
    return YES;
}

#pragma mark - SystemImageIOBridge

@implementation SystemImageIOBridge

+ (BOOL)handlesExtension:(NSString *)extension {
    if (!extension) return NO;
    NSString *ext = [extension.lowercaseString stringByReplacingOccurrencesOfString:@"." withString:@""];
    static NSSet *kRouted;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kRouted = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"tif", @"tiff", @"heic", @"heif"]];
    });
    return [kRouted containsObject:ext];
}

+ (BOOL)handlesPath:(NSString *)path {
    return [self handlesExtension:path.pathExtension];
}

+ (nullable OIIOImage *)readImageAtPath:(NSString *)path error:(NSError **)error {
    CGImageSourceRef src = NULL;
    CGImageRef img = NULL;
    size_t width = 0, height = 0;
    NSString *csTag = nil;
    BOOL isHDR = NO;
    if (!openCGImage(path, &src, &img, &width, &height, &csTag, &isHDR, error)) {
        return nil;
    }

    ImageSpec spec((int)width, (int)height, 4, TypeDesc::FLOAT);
    spec.channelnames = { "R", "G", "B", "A" };
    spec.alpha_channel = 3;
    spec.attribute("oiio:ColorSpace", std::string([csTag UTF8String]));
    if (isHDR) spec.attribute("oiio:HDR", 1);

    // Allocate the ImageBuf with its own local storage, then render the CG
    // image straight into that storage — no extra malloc/memcpy, no lifetime
    // mismatch when OIIOImage later copies the buf.
    ImageBuf buf(spec);
    float *dst = (float *)buf.localpixels();
    if (!dst) {
        CGImageRelease(img);
        CFRelease(src);
        if (error) *error = makeError(-11, @"ImageBuf has no local storage");
        return nil;
    }

    NSError *renderErr = nil;
    BOOL ok = renderImageIntoFloatRGBA(img, dst, width, height, &renderErr);
    CGImageRelease(img);
    CFRelease(src);
    if (!ok) {
        if (error) *error = renderErr ?: makeError(-12, @"renderImageIntoFloatRGBA failed");
        return nil;
    }

    return [[OIIOImage alloc] initWithImageBuf:buf layerNames:nil];
}

+ (nullable OIIOImageSpec *)readMetadataAtPath:(NSString *)path error:(NSError **)error {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) {
        if (error) *error = makeError(-20, [NSString stringWithFormat:@"CGImageSourceCreateWithURL failed for %@", path]);
        return nil;
    }

    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
    if (!props) {
        CFRelease(src);
        if (error) *error = makeError(-21, @"CGImageSourceCopyPropertiesAtIndex returned NULL");
        return nil;
    }

    NSDictionary *p = (__bridge NSDictionary *)props;
    NSNumber *w = p[(id)kCGImagePropertyPixelWidth];
    NSNumber *h = p[(id)kCGImagePropertyPixelHeight];
    NSNumber *bitDepth = p[(id)kCGImagePropertyDepth];
    NSString *profile  = p[(id)kCGImagePropertyProfileName];

    ImageSpec spec(w.intValue, h.intValue, 4, TypeDesc::FLOAT);
    spec.channelnames = { "R", "G", "B", "A" };
    spec.alpha_channel = 3;

    if (profile)
        spec.attribute("oiio:ColorSpace", std::string([profile UTF8String]));

    if (bitDepth) {
        if (bitDepth.intValue == 8)       spec.format = TypeDesc::UINT8;
        else if (bitDepth.intValue == 16) spec.format = TypeDesc::UINT16;
        else                              spec.format = TypeDesc::FLOAT;
    }

    // Copy through any string/number metadata into OIIO's extra_attribs so
    // OIIOImageSpec.attributes carries it. Plain for-in (not a block) so the
    // captured `spec` doesn't become const inside an Obj-C++ block.
    for (id key in p) {
        NSString *k = [NSString stringWithFormat:@"ImageIO.%@", key];
        NSString *v = [p[key] description];
        spec.attribute([k UTF8String], std::string([v UTF8String]));
    }

    CFRelease(props);
    CFRelease(src);

    return [[OIIOImageSpec alloc] initWithImageSpec:spec layerNames:nil];
}

+ (nullable id<MTLTexture>)readTextureAtPath:(NSString *)path
                                      device:(id<MTLDevice>)device
                                       error:(NSError **)error {
    CGImageSourceRef src = NULL;
    CGImageRef img = NULL;
    size_t width = 0, height = 0;
    if (!openCGImage(path, &src, &img, &width, &height, NULL, NULL, error)) {
        return nil;
    }

    // Decode straight into a float RGBA buffer; convert to half for Metal.
    size_t pixelCount = width * height * 4;
    std::vector<float> pixels(pixelCount);
    NSError *renderErr = nil;
    BOOL ok = renderImageIntoFloatRGBA(img, pixels.data(), width, height, &renderErr);
    CGImageRelease(img);
    CFRelease(src);
    if (!ok) {
        if (error) *error = renderErr ?: makeError(-32, @"renderImageIntoFloatRGBA failed");
        return nil;
    }

    std::vector<uint16_t> half(pixelCount);
    OIIO::convert_pixel_values(TypeDesc::FLOAT, pixels.data(),
                                TypeDesc::HALF,  half.data(),
                                (int)pixelCount);

    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = [device hasUnifiedMemory] ? MTLStorageModeShared
                                                 : MTLStorageModeManaged;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    if (!texture) {
        if (error) *error = makeError(-31, @"newTextureWithDescriptor failed");
        return nil;
    }

    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:half.data()
               bytesPerRow:width * 4 * sizeof(uint16_t)];
    return texture;
}

#pragma mark - Writes

static CFStringRef utiForExtension(NSString *ext) {
    NSString *e = ext.lowercaseString;
    if ([e isEqualToString:@"jpg"]  || [e isEqualToString:@"jpeg"]) return (__bridge CFStringRef)UTTypeJPEG.identifier;
    if ([e isEqualToString:@"png"])                                  return (__bridge CFStringRef)UTTypePNG.identifier;
    if ([e isEqualToString:@"tif"]  || [e isEqualToString:@"tiff"]) return (__bridge CFStringRef)UTTypeTIFF.identifier;
    if ([e isEqualToString:@"heic"] || [e isEqualToString:@"heif"]) return (__bridge CFStringRef)UTTypeHEIC.identifier;
    return NULL;
}

+ (BOOL)writeImage:(OIIOImage *)image toPath:(NSString *)path error:(NSError **)error {
    const ImageBuf &buf = [image imageBuf];
    const ImageSpec &spec = buf.spec();
    NSData *floatData = image.pixelData;
    return [self writeFloatPixelData:floatData
                               width:spec.width
                              height:spec.height
                            channels:spec.nchannels
                              toPath:path
                               error:error];
}

+ (BOOL)writeFloatPixelData:(NSData *)data
                      width:(NSInteger)width
                     height:(NSInteger)height
                   channels:(NSInteger)channels
                     toPath:(NSString *)path
                      error:(NSError **)error {
    if (channels != 4 && channels != 3) {
        if (error) *error = makeError(-40,
            [NSString stringWithFormat:@"SystemImageIOBridge requires 3 or 4 channels, got %ld", (long)channels]);
        return NO;
    }

    CFStringRef uti = utiForExtension(path.pathExtension);
    if (!uti) {
        if (error) *error = makeError(-41,
            [NSString stringWithFormat:@"No UTI mapping for extension '%@'", path.pathExtension]);
        return NO;
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];

    // If channels==3 we pad to RGBA in a temp buffer; CG works in RGBA.
    const float *srcPixels = (const float *)data.bytes;
    std::vector<float> padded;
    const float *finalPixels = srcPixels;
    if (channels == 3) {
        padded.resize((size_t)width * height * 4);
        for (size_t i = 0, n = (size_t)width * height; i < n; ++i) {
            padded[i * 4 + 0] = srcPixels[i * 3 + 0];
            padded[i * 4 + 1] = srcPixels[i * 3 + 1];
            padded[i * 4 + 2] = srcPixels[i * 3 + 2];
            padded[i * 4 + 3] = 1.0f;
        }
        finalPixels = padded.data();
    }

    // Wrap pixels in a CGImage backed by a CFData copy (CGImage takes ownership
    // of the data provider; CGContext would be more memory-efficient but harder
    // to surface as a CGImage for CGImageDestinationAddImage).
    size_t rowBytes = (size_t)width * 4 * sizeof(float);
    size_t totalBytes = rowBytes * (size_t)height;
    CFDataRef pixelData = CFDataCreate(NULL, (const UInt8 *)finalPixels, totalBytes);
    if (!pixelData) {
        if (error) *error = makeError(-42, @"CFDataCreate failed");
        return NO;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixelData);
    CFRelease(pixelData);
    if (!provider) {
        if (error) *error = makeError(-43, @"CGDataProviderCreateWithCFData failed");
        return NO;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    CGBitmapInfo bitmapInfo = kCGImageAlphaPremultipliedLast
                            | kCGBitmapFloatComponents
                            | kCGBitmapByteOrder32Little;
    CGImageRef img = CGImageCreate((size_t)width, (size_t)height,
                                   /*bitsPerComponent=*/32,
                                   /*bitsPerPixel=*/128,
                                   rowBytes, cs, bitmapInfo, provider,
                                   /*decode=*/NULL,
                                   /*shouldInterpolate=*/false,
                                   kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    if (!img) {
        if (error) *error = makeError(-44, @"CGImageCreate failed");
        return NO;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, uti, 1, NULL);
    if (!dest) {
        CGImageRelease(img);
        if (error) *error = makeError(-45,
            [NSString stringWithFormat:@"CGImageDestinationCreateWithURL failed for %@", path]);
        return NO;
    }
    CGImageDestinationAddImage(dest, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(img);

    if (!ok) {
        if (error) *error = makeError(-46, @"CGImageDestinationFinalize failed");
        return NO;
    }
    return YES;
}

@end
