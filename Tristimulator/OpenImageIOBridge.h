//
//  OpenImageIOBridge.h
//  Tristimulator
//
//  Objective-C++ bridge to OpenImageIO
//

#import <Foundation/Foundation.h>

@protocol MTLDevice;
@protocol MTLTexture;

NS_ASSUME_NONNULL_BEGIN

/// Represents image specifications from OpenImageIO
@interface OIIOImageSpec : NSObject

@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) NSInteger channels;
@property (nonatomic, readonly) NSInteger bitDepth;
@property (nonatomic, readonly, copy) NSString *colorSpace;
@property (nonatomic, readonly) BOOL isHDR;
@property (nonatomic, readonly) float maxLuminance;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *attributes;

/// Ordered list of layer (group) names found in this image, derived from the
/// dot-separated channel name convention used by EXR (and some TIFF) files.
/// Empty string ("") = the default / unnamed layer (typically R, G, B, A).
/// Single-layer images always return an empty array.
@property (nonatomic, readonly, copy) NSArray<NSString *> *layerNames;

@end

/// Represents an image loaded via OpenImageIO
@interface OIIOImage : NSObject

@property (nonatomic, readonly) OIIOImageSpec *spec;
@property (nonatomic, readonly) NSData *pixelData;

/// Create a Metal texture from this image
/// @param device The Metal device to use for texture creation
/// @return A Metal texture, or nil if creation fails
- (nullable id<MTLTexture>)createMetalTexture:(id<MTLDevice>)device;

@end

/// Main bridge interface to OpenImageIO
@interface OpenImageIOBridge : NSObject

/// Read an image from the specified path, always returning a 4-channel RGBA
/// result.  For multi-layer files the default / unnamed layer (R, G, B, A
/// channels without a dot prefix) is selected automatically.
/// @param path  The file path to read from
/// @param error Error information if the operation fails
/// @return An OIIOImage object, or nil if reading fails
+ (nullable OIIOImage *)readImageAtPath:(NSString *)path error:(NSError **)error;

/// Read a specific named layer from a multi-layer file (EXR, TIFF, etc.),
/// returning a 4-channel RGBA result.
/// @param path  The file path to read from
/// @param layer The layer prefix to extract, e.g. \"diffuse\", \"specular\".
///              Pass an empty string to read the default unnamed layer.
/// @param error Error information if the operation fails
/// @return An OIIOImage object, or nil if reading fails
+ (nullable OIIOImage *)readImageAtPath:(NSString *)path
                                  layer:(NSString *)layer
                                  error:(NSError **)error;

/// Return the ordered list of layer names present in `path` without fully
/// decoding the pixel data.  Empty string = default unnamed layer.
/// Returns nil on read error.
+ (nullable NSArray<NSString *> *)layerNamesAtPath:(NSString *)path
                                             error:(NSError **)error;

/// Read an image from disk, bypassing OIIO's shared image cache.
/// Use this in unit tests where multiple test runner processes share the same
/// OIIO image cache via OS shared memory — concurrent reads can corrupt the
/// cache's type-conversion state.  This reads directly from disk every time.
+ (nullable OIIOImage *)readImageUncached:(NSString *)path error:(NSError **)error
    NS_SWIFT_NAME(readImageUncached(_:));

/// Decode a single layer directly to a Metal texture, bypassing the CPU pixel
/// buffer entirely.  Use this for image-sequence playback where `pixelData` is
/// never needed — it saves one large malloc + memcpy per frame.
/// @param path   File path to read.
/// @param layer  Layer name (empty string = default RGBA layer).
/// @param device Metal device to allocate the texture on.
/// @param error  Error information if the operation fails.
/// @return A ready-to-use Metal texture (RGBA16Float), or nil on failure.
+ (nullable id<MTLTexture>)readTextureAtPath:(NSString *)path
                                       layer:(NSString *)layer
                                      device:(id<MTLDevice>)device
                                       error:(NSError **)error;

/// Read just the image header (no pixel decode) and return an OIIOImageSpec.
/// Use this when you need metadata (dimensions, color space, bit depth, etc.)
/// without paying for a full pixel decode — e.g. when the texture will be
/// loaded separately via the direct OpenEXR path.
+ (nullable OIIOImageSpec *)readMetadataAtPath:(NSString *)path
                                         error:(NSError **)error;

/// Decode an EXR file directly into a pre-allocated MTLTexture (pool fast path).
/// The texture must be RGBA16Float and exactly match the EXR's display-window size.
/// Avoids both the IOKit round-trip of newTextureWithDescriptor: and the
/// zero-initialisation overhead of std::vector — just malloc + decompress + upload.
/// @param path    EXR file path.
/// @param layer   Layer name (empty string = default RGBA layer).
/// @param texture An existing RGBA16Float MTLTexture to fill.
/// @return YES on success, NO on failure.
+ (BOOL)readEXRAtPath:(NSString *)path
                layer:(NSString *)layer
          intoTexture:(id<MTLTexture>)texture;

/// Write an image to the specified path
/// @param image The image to write
/// @param path The file path to write to
/// @param format The output format (e.g., "png", "exr", "tiff")
/// @param error Error information if the operation fails
/// @return YES if successful, NO otherwise
+ (BOOL)writeImage:(OIIOImage *)image toPath:(NSString *)path format:(NSString *)format error:(NSError **)error;

/// Write raw 32-bit float pixel data to an EXR file.
/// Writes all `channels` channels; use 4 for RGBA (R, G, B, A naming).
/// Creates intermediate directories automatically.
+ (BOOL)writeFloatPixelData:(NSData *)data
                      width:(NSInteger)width
                     height:(NSInteger)height
                   channels:(NSInteger)channels
                     toPath:(NSString *)path
                      error:(NSError **)error;

/// Get list of supported read formats
/// @return Array of file extension strings
+ (NSArray<NSString *> *)supportedReadFormats;

/// Get list of supported write formats
/// @return Array of file extension strings
+ (NSArray<NSString *> *)supportedWriteFormats;

/// Convert an image to different channels and bit depth
/// @param image The source image
/// @param channels Number of channels (1, 3, or 4)
/// @param bitDepth Bit depth (8, 16, or 32)
/// @param error Error information if the operation fails
/// @return A new converted image, or nil if conversion fails
+ (nullable OIIOImage *)convertImage:(OIIOImage *)image 
                            channels:(NSInteger)channels 
                            bitDepth:(NSInteger)bitDepth 
                               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
