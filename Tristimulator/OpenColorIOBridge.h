//
//  OpenColorIOBridge.h
//  Tristimulator
//
//  Objective-C++ bridge to OpenColorIO
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Represents an OCIO color space
@interface OCIOColorSpace : NSObject

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *family;
@property (nonatomic, readonly, copy) NSString *description;

@end

/// Represents an OCIO configuration
@interface OCIOConfig : NSObject

/// Load the default OCIO configuration from environment variable
+ (nullable instancetype)defaultConfig;

/// Load an OCIO configuration from a file path
+ (nullable instancetype)configWithPath:(NSString *)path error:(NSError **)error;

/// Create a minimal raw OCIO configuration (no color spaces, no roles).
/// Sufficient for FileTransform / CLF operations that are self-contained.
/// Use this in unit tests to avoid depending on a bundled config file.
+ (nullable instancetype)rawConfig NS_SWIFT_NAME(rawConfig());

/// Get the description of this config
- (nullable NSString *)configDescription;

/// Get all available color space names
- (NSArray<NSString *> *)colorSpaceNames;

/// Get the family string for a given color space name (returns empty string if not found)
- (NSString *)familyForColorSpace:(NSString *)colorSpaceName;

/// Get all available display names
- (NSArray<NSString *> *)displayNames;

/// Get view names for a specific display
- (NSArray<NSString *> *)viewNamesForDisplay:(NSString *)display;

/// Get the default display
- (NSString *)defaultDisplay;

/// Get the default view for a display
- (NSString *)defaultViewForDisplay:(NSString *)display;

/// Get color space name for a role
- (nullable NSString *)colorSpaceForRole:(NSString *)role;

/// Get the scene-linear role color space (typically "scene_linear" or "aces_interchange")
- (nullable NSString *)sceneLinearColorSpace;

/// Get the default color space (typically for data that doesn't have color space info)
- (nullable NSString *)defaultColorSpace;

/// Get all look names defined in the config
- (NSArray<NSString *> *)lookNames;

@end

/// Represents an OCIO processor for transforming image data
@interface OCIOProcessor : NSObject

/// Create a processor for color space to color space transformation
/// @param config The OCIO configuration to use
/// @param sourceSpace Source color space name
/// @param destSpace Destination color space name
/// @param error Error information if creation fails
+ (nullable instancetype)processorWithConfig:(OCIOConfig *)config
                                  sourceSpace:(NSString *)sourceSpace
                             destinationSpace:(NSString *)destSpace
                                        error:(NSError **)error;

/// Create a processor for display transformation
/// @param config The OCIO configuration to use
/// @param sourceSpace Source color space name
/// @param display Display name
/// @param view View name
/// @param error Error information if creation fails
+ (nullable instancetype)displayProcessorWithConfig:(OCIOConfig *)config
                                        sourceSpace:(NSString *)sourceSpace
                                            display:(NSString *)display
                                               view:(NSString *)view
                                              error:(NSError **)error;

/// Create a processor for inverse display transformation (display-referred → scene-linear)
/// This is essential for ACES 2.0 configs where display transforms aren't exposed as bidirectional colorspaces.
/// @param config The OCIO configuration to use
/// @param display Display name to invert
/// @param view View name to invert
/// @param error Error information if creation fails
+ (nullable instancetype)inverseDisplayProcessorWithConfig:(OCIOConfig *)config
                                                   display:(NSString *)display
                                                      view:(NSString *)view
                                                     error:(NSError **)error;

/// Variant of inverseDisplayProcessorWithConfig that pins the destination scene-referred
/// space explicitly instead of using the config's scene_linear role. Used by ShaderBaker to
/// bake an inverse display shader whose output lands in a known space (e.g. ACES2065-1 / AP0),
/// making it the exact inverse of the forward ACES 2 display shader.
/// @param config      The OCIO configuration to use
/// @param sourceSpace Destination scene-referred space of the inverse (e.g. "ACES2065-1")
/// @param display     Display name to invert (e.g. "sRGB - Display")
/// @param view        View name to invert (e.g. "ACES 2.0 - SDR 100 nits (Rec.709)")
/// @param error       Error information if creation fails
+ (nullable instancetype)inverseDisplayProcessorWithConfig:(OCIOConfig *)config
                                               sourceSpace:(NSString *)sourceSpace
                                                   display:(NSString *)display
                                                      view:(NSString *)view
                                                     error:(NSError **)error;

/// Create a processor for the ACES 2 output transform with dynamic peak luminance.
/// Builds a programmatic GroupTransform: sourceSpace → ACES2065-1 → ACES2_OutputTransform → EDR scale.
/// @param config       The OCIO configuration (used to resolve the ACES interchange color space).
/// @param sourceSpace  Input working color space (e.g. "ACEScg" or "ACES2065-1").
/// @param peakNits     Peak display luminance in nits (e.g. 100 = SDR, 1000 = HDR).
/// @param edrScale     Multiply ACES2 output (0–1) by this value to get EDR linear units.
///                     Pass the display's `maximumPotentialExtendedDynamicRangeColorComponentValue`.
/// @param outputGamutXY  8 xy chromaticity values: [Rx,Ry, Gx,Gy, Bx,By, Wx,Wy].
///                       Pass nil to use the P3-D65 primaries.
/// @param error        Error information if creation fails.
+ (nullable instancetype)aces2DynamicProcessorWithConfig:(OCIOConfig *)config
                                             sourceSpace:(NSString *)sourceSpace
                                               peakNits:(double)peakNits
                                          outputGamutXY:(nullable NSArray<NSNumber *> *)outputGamutXY
                                                  error:(NSError **)error;

/// Build a processor from an ordered array of transform-step dictionaries.
/// Each step is an NSDictionary with a "type" key plus type-specific fields:
///   "colorspace": @{@"type":@"colorspace", @"src":@"...", @"dst":@"..."}
///   "file":       @{@"type":@"file",       @"path":@"..."}
///   "look":       @{@"type":@"look",       @"src":@"...", @"name":@"..."}
///   "display":    @{@"type":@"display",    @"src":@"...", @"display":@"...", @"view":@"..."}
/// Steps are applied in order, chained via a OCIO GroupTransform.
+ (nullable instancetype)groupTransformProcessorWithConfig:(OCIOConfig *)config
                                                     steps:(NSArray<NSDictionary *> *)steps
                                                     error:(NSError **)error
    NS_SWIFT_NAME(groupTransformProcessor(with:steps:));

/// Create a processor for JUST the ACES 2 FixedFunction transform (no pre/post clamps,
/// no display encoding). Input: AP0 scene-linear. Output: linear in the limiting gamut.
/// Used by ShaderBaker to bake a shader where peakNits can be patched to a runtime uniform.
/// @param config       The OCIO configuration (used only to create the processor context).
/// @param peakNits     Seed peak luminance — will be patched to a uniform in the baked shader.
/// @param outputGamutXY  8 xy chromaticity values [Rx,Ry,Gx,Gy,Bx,By,Wx,Wy]. Nil → P3-D65.
/// @param error        Error information if creation fails.
+ (nullable instancetype)aces2FixedFunctionProcessorWithConfig:(OCIOConfig *)config
                                                      peakNits:(double)peakNits
                                                 outputGamutXY:(nullable NSArray<NSNumber *> *)outputGamutXY
                                                         error:(NSError **)error;

/// Apply the color transformation to RGB pixel data
/// @param pixelData Raw pixel data (float RGB or RGBA)
/// @param width Image width
/// @param height Image height
/// @param channels Number of channels (3 for RGB, 4 for RGBA)
/// @param error Error information if creation fails
/// @return Transformed pixel data, or nil if processing fails
- (nullable NSData *)processPixelData:(NSData *)pixelData
                                width:(NSInteger)width
                               height:(NSInteger)height
                             channels:(NSInteger)channels
                                error:(NSError **)error;

/// Generate Metal shader code AND extract all texture data in a single OCIO pass.
/// Both outputs come from the same GpuShaderDesc so they are guaranteed to be in sync.
/// @param shaderDesc  Receives the complete Metal shader text
/// @param texturesData  Receives an array of texture-data dictionaries (same format as getGPUTextureData)
/// @param error  Error information if generation fails
/// @return YES if successful, NO otherwise
- (BOOL)getGPUShaderAndTextures:(NSString **)shaderDesc
                   texturesData:(NSArray<NSDictionary *> **)texturesData
                          error:(NSError **)error;

/// Generate Metal shader code for GPU processing (legacy — prefer getGPUShaderAndTextures:)
- (BOOL)getGPUShaderDescription:(NSString **)shaderDesc error:(NSError **)error;

/// Get ALL GPU texture data (1D, 2D, and 3D LUTs) (legacy — prefer getGPUShaderAndTextures:)
- (BOOL)getGPUTextureData:(NSArray<NSDictionary *> **)texturesData error:(NSError **)error;

@end

/// Main bridge interface to OpenColorIO
@interface OpenColorIOBridge : NSObject

/// Get the version of OpenColorIO
+ (NSString *)version;

/// Test if OCIO is available and properly configured
+ (BOOL)isAvailable;

@end

NS_ASSUME_NONNULL_END
