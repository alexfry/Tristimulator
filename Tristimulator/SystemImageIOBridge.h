//
//  SystemImageIOBridge.h
//  Tristimulator
//
//  Obj-C++ bridge over macOS ImageIO (CGImageSource/CGImageDestination) for the
//  JPEG / PNG / TIFF / HEIF formats. OpenImageIOBridge delegates to this bridge
//  for routed extensions so OIIO doesn't need to link libheif, libpng,
//  libjpeg-turbo, libtiff, libfreetype, etc.
//
//  Returns and accepts the same OIIOImage / OIIOImageSpec types as
//  OpenImageIOBridge so call sites don't need to branch.
//

#import <Foundation/Foundation.h>
#import "OpenImageIOBridge.h"

@protocol MTLDevice;
@protocol MTLTexture;

NS_ASSUME_NONNULL_BEGIN

@interface SystemImageIOBridge : NSObject

/// Returns YES if `extension` (case-insensitive, no leading dot) is one of the
/// formats this bridge handles: jpg, jpeg, png, tif, tiff, heic, heif.
+ (BOOL)handlesExtension:(NSString *)extension;

/// Convenience: extracts the extension from `path` and calls handlesExtension:.
+ (BOOL)handlesPath:(NSString *)path;

+ (nullable OIIOImage *)readImageAtPath:(NSString *)path
                                  error:(NSError **)error;

+ (nullable OIIOImageSpec *)readMetadataAtPath:(NSString *)path
                                         error:(NSError **)error;

+ (nullable id<MTLTexture>)readTextureAtPath:(NSString *)path
                                      device:(id<MTLDevice>)device
                                       error:(NSError **)error;

+ (BOOL)writeImage:(OIIOImage *)image
            toPath:(NSString *)path
             error:(NSError **)error;

+ (BOOL)writeFloatPixelData:(NSData *)data
                      width:(NSInteger)width
                     height:(NSInteger)height
                   channels:(NSInteger)channels
                     toPath:(NSString *)path
                      error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
