//
//  OpenColorIOBridge.mm
//  Tristimulator
//
//  Objective-C++ bridge to OpenColorIO
//

#import "OpenColorIOBridge.h"
#include <OpenColorIO/OpenColorIO.h>
#include <vector>
#include <string>
#include <unistd.h>

namespace OCIO = OCIO_NAMESPACE;

// Error domain for OCIO errors
static NSErrorDomain const OCIOErrorDomain = @"com.tristimulator.ocio";

@implementation OCIOColorSpace {
    OCIO::ConstColorSpaceRcPtr _colorSpace;
}

- (instancetype)initWithColorSpace:(OCIO::ConstColorSpaceRcPtr)colorSpace {
    if (self = [super init]) {
        _colorSpace = colorSpace;
    }
    return self;
}

- (NSString *)name {
    if (_colorSpace) {
        const char* name = _colorSpace->getName();
        return name ? @(name) : @"";
    }
    return @"";
}

- (NSString *)family {
    if (_colorSpace) {
        const char* family = _colorSpace->getFamily();
        return family ? @(family) : @"";
    }
    return @"";
}

- (NSString *)description {
    if (_colorSpace) {
        const char* desc = _colorSpace->getDescription();
        return desc ? @(desc) : @"";
    }
    return @"";
}

@end

@implementation OCIOConfig {
    OCIO::ConstConfigRcPtr _config;
}

- (instancetype)initWithInternalConfig:(OCIO::ConstConfigRcPtr)config {
    if (self = [super init]) {
        _config = config;
    }
    return self;
}

- (OCIO::ConstConfigRcPtr)internalConfig {
    return _config;
}

+ (instancetype)defaultConfig {
    try {
        OCIO::ConstConfigRcPtr config = OCIO::GetCurrentConfig();
        if (config) {
            return [[OCIOConfig alloc] initWithInternalConfig:config];
        }
    } catch (const std::exception& e) {
        NSLog(@"Error loading default OCIO config: %s", e.what());
    }
    return nil;
}

+ (instancetype)rawConfig {
    try {
        OCIO::ConstConfigRcPtr config = OCIO::Config::CreateRaw();
        if (config) {
            return [[OCIOConfig alloc] initWithInternalConfig:config];
        }
    } catch (const std::exception& e) {
        NSLog(@"Error creating raw OCIO config: %s", e.what());
    }
    return nil;
}

+ (instancetype)configWithPath:(NSString *)path error:(NSError **)error {
    try {
        // Get the directory of the config file for resolving relative paths
        NSString *configDir = [path stringByDeletingLastPathComponent];
        
        // Change to the config directory permanently to help OCIO resolve relative paths
        // Note: This is necessary because OCIO configs often reference LUTs with relative paths
        chdir([configDir UTF8String]);
        
        OCIO::ConstConfigRcPtr config = OCIO::Config::CreateFromFile([path UTF8String]);
        
        if (config) {
            NSLog(@"OCIO config loaded successfully from directory: %@", configDir);
            return [[OCIOConfig alloc] initWithInternalConfig:config];
        }
    } catch (const std::exception& e) {
        if (error) {
            NSString *errorMessage = [NSString stringWithFormat:@"Error could not read '%@' OCIO profile.\nDetails: %s", 
                                      path, e.what()];
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: errorMessage}];
        }
    }
    return nil;
}

- (NSArray<NSString *> *)colorSpaceNames {
    if (!_config) return @[];
    
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    int numColorSpaces = _config->getNumColorSpaces();
    
    for (int i = 0; i < numColorSpaces; i++) {
        const char* name = _config->getColorSpaceNameByIndex(i);
        if (name) {
            [names addObject:@(name)];
        }
    }
    
    return [names copy];
}

- (NSString *)familyForColorSpace:(NSString *)colorSpaceName {
    if (!_config) return @"";
    
    try {
        auto cs = _config->getColorSpace([colorSpaceName UTF8String]);
        if (cs) {
            const char* family = cs->getFamily();
            if (family) {
                return @(family);
            }
        }
    } catch (...) {
        // Fall through to return empty string
    }
    return @"";
}

- (NSArray<NSString *> *)displayNames {
    if (!_config) return @[];
    
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    int numDisplays = _config->getNumDisplays();
    
    for (int i = 0; i < numDisplays; i++) {
        const char* name = _config->getDisplay(i);
        if (name) {
            [names addObject:@(name)];
        }
    }
    
    return [names copy];
}

- (NSArray<NSString *> *)viewNamesForDisplay:(NSString *)display {
    if (!_config) return @[];
    
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    const char* displayCStr = [display UTF8String];
    int numViews = _config->getNumViews(displayCStr);
    
    for (int i = 0; i < numViews; i++) {
        const char* name = _config->getView(displayCStr, i);
        if (name) {
            [names addObject:@(name)];
        }
    }
    
    return [names copy];
}

- (NSString *)defaultDisplay {
    if (!_config) return @"";
    
    const char* display = _config->getDefaultDisplay();
    return display ? @(display) : @"";
}

- (nullable NSString *)configDescription {
    if (!_config) return nil;
    
    const char* desc = _config->getDescription();
    return desc ? @(desc) : nil;
}

- (NSString *)defaultViewForDisplay:(NSString *)display {
    if (!_config) return @"";
    
    const char* view = _config->getDefaultView([display UTF8String]);
    return view ? @(view) : @"";
}

- (NSString *)colorSpaceForRole:(NSString *)role {
    if (!_config) return nil;
    
    try {
        OCIO::ConstColorSpaceRcPtr cs = _config->getColorSpace([role UTF8String]);
        if (cs) {
            const char* name = cs->getName();
            return name ? @(name) : nil;
        }
    } catch (const std::exception& e) {
        NSLog(@"Error getting color space for role '%@': %s", role, e.what());
    }
    return nil;
}

- (NSString *)sceneLinearColorSpace {
    // Try common role names in order of preference
    NSArray *roleNames = @[@"scene_linear", @"aces_interchange", @"linear", @"compositing_linear"];
    
    for (NSString *role in roleNames) {
        NSString *colorSpace = [self colorSpaceForRole:role];
        if (colorSpace) {
            return colorSpace;
        }
    }
    
    // Fallback: if no role found, return nil
    return nil;
}

- (NSString *)defaultColorSpace {
    return [self colorSpaceForRole:@"default"];
}

- (NSArray<NSString *> *)lookNames {
    NSMutableArray *result = [NSMutableArray array];
    try {
        int numLooks = _config->getNumLooks();
        for (int i = 0; i < numLooks; i++) {
            const char *name = _config->getLookNameByIndex(i);
            if (name) [result addObject:@(name)];
        }
    } catch (const std::exception& e) {
        NSLog(@"Error getting look names: %s", e.what());
    }
    return result;
}

@end

@implementation OCIOProcessor {
    OCIO::ConstProcessorRcPtr _processor;
    OCIO::ConstCPUProcessorRcPtr _cpuProcessor;
}

+ (instancetype)processorWithConfig:(OCIOConfig *)config
                         sourceSpace:(NSString *)sourceSpace
                    destinationSpace:(NSString *)destSpace
                               error:(NSError **)error {
    OCIO::ConstConfigRcPtr cfg = [config internalConfig];
    if (!cfg) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid OCIO config"}];
        }
        return nil;
    }
    
    try {
        OCIO::ColorSpaceTransformRcPtr transform = OCIO::ColorSpaceTransform::Create();
        transform->setSrc([sourceSpace UTF8String]);
        transform->setDst([destSpace UTF8String]);
        
        OCIO::ConstProcessorRcPtr processor = cfg->getProcessor(transform);
        OCIO::ConstCPUProcessorRcPtr cpuProcessor = processor->getDefaultCPUProcessor();
        
        OCIOProcessor *ocioProcessor = [[OCIOProcessor alloc] init];
        ocioProcessor->_processor = processor;
        ocioProcessor->_cpuProcessor = cpuProcessor;
        return ocioProcessor;
        
    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
    }
    
    return nil;
}

+ (instancetype)displayProcessorWithConfig:(OCIOConfig *)config
                               sourceSpace:(NSString *)sourceSpace
                                   display:(NSString *)display
                                      view:(NSString *)view
                                     error:(NSError **)error {
    OCIO::ConstConfigRcPtr cfg = [config internalConfig];
    if (!cfg) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid OCIO config"}];
        }
        return nil;
    }
    
    try {
        OCIO::DisplayViewTransformRcPtr transform = OCIO::DisplayViewTransform::Create();
        transform->setSrc([sourceSpace UTF8String]);
        transform->setDisplay([display UTF8String]);
        transform->setView([view UTF8String]);
        
        OCIO::ConstProcessorRcPtr processor = cfg->getProcessor(transform);
        OCIO::ConstCPUProcessorRcPtr cpuProcessor = processor->getDefaultCPUProcessor();
        
        OCIOProcessor *ocioProcessor = [[OCIOProcessor alloc] init];
        ocioProcessor->_processor = processor;
        ocioProcessor->_cpuProcessor = cpuProcessor;
        return ocioProcessor;
        
    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
    }
    
    return nil;
}

+ (instancetype)groupTransformProcessorWithConfig:(OCIOConfig *)config
                                            steps:(NSArray<NSDictionary *> *)steps
                                            error:(NSError **)error {
    OCIO::ConstConfigRcPtr cfg = [config internalConfig];
    if (!cfg) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid OCIO config"}];
        }
        return nil;
    }

    try {
        OCIO::GroupTransformRcPtr group = OCIO::GroupTransform::Create();

        for (NSDictionary *step in steps) {
            NSString *type = step[@"type"];

            if ([type isEqualToString:@"colorspace"]) {
                NSString *src = step[@"src"];
                NSString *dst = step[@"dst"];
                if (!src || !dst) continue;
                OCIO::ColorSpaceTransformRcPtr cs = OCIO::ColorSpaceTransform::Create();
                cs->setSrc([src UTF8String]);
                cs->setDst([dst UTF8String]);
                group->appendTransform(cs);
                NSLog(@"🎨 [AMF Group] colorspace: %@ → %@", src, dst);

            } else if ([type isEqualToString:@"file"]) {
                NSString *path = step[@"path"];
                if (!path) continue;
                OCIO::FileTransformRcPtr ft = OCIO::FileTransform::Create();
                ft->setSrc([path UTF8String]);
                group->appendTransform(ft);
                NSLog(@"🎨 [AMF Group] file: %@", [path lastPathComponent]);

            } else if ([type isEqualToString:@"look"]) {
                NSString *src  = step[@"src"];
                NSString *name = step[@"name"];
                if (!src || !name) continue;
                OCIO::LookTransformRcPtr lt = OCIO::LookTransform::Create();
                lt->setSrc([src UTF8String]);
                lt->setDst([src UTF8String]);  // look operates in same space
                lt->setLooks([name UTF8String]);
                group->appendTransform(lt);
                NSLog(@"🎨 [AMF Group] look: %@ (in %@)", name, src);

            } else if ([type isEqualToString:@"display"]) {
                NSString *src     = step[@"src"];
                NSString *display = step[@"display"];
                NSString *view    = step[@"view"];
                if (!src || !display || !view) continue;
                OCIO::DisplayViewTransformRcPtr dv = OCIO::DisplayViewTransform::Create();
                dv->setSrc([src UTF8String]);
                dv->setDisplay([display UTF8String]);
                dv->setView([view UTF8String]);
                group->appendTransform(dv);
                NSLog(@"🎨 [AMF Group] display: %@ → %@/%@", src, display, view);

            } else {
                NSLog(@"⚠️ [AMF Group] Unknown step type: %@", type);
            }
        }

        OCIO::ConstProcessorRcPtr processor = cfg->getProcessor(group);
        // Use LOSSLESS optimization: avoids FAST_LOG_EXP_POW (approximate math for log/exp/pow)
        // and COMP_SEPARABLE_PREFIX (bakes ops into finite-resolution LUTs that clip extreme
        // values). Both flags are in OPTIMIZATION_DEFAULT and cause incorrect results when the
        // source image contains extreme out-of-range values (as the ACES CLF test image does).
        OCIO::ConstCPUProcessorRcPtr cpuProcessor = processor->getOptimizedCPUProcessor(OCIO::OPTIMIZATION_LOSSLESS);

        OCIOProcessor *ocioProcessor = [[OCIOProcessor alloc] init];
        ocioProcessor->_processor = processor;
        ocioProcessor->_cpuProcessor = cpuProcessor;
        NSLog(@"✅ [AMF Group] Processor built with %lu steps", (unsigned long)[steps count]);
        return ocioProcessor;

    } catch (const std::exception& e) {
        NSLog(@"❌ [AMF Group] Failed to build group transform: %s", e.what());
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
    }
    return nil;
}

+ (instancetype)inverseDisplayProcessorWithConfig:(OCIOConfig *)config
                                          display:(NSString *)display
                                             view:(NSString *)view
                                            error:(NSError **)error {
    OCIO::ConstConfigRcPtr cfg = [config internalConfig];
    if (!cfg) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid OCIO config"}];
        }
        return nil;
    }
    
    // Get scene-linear color space
    NSString *sceneLinear = [config sceneLinearColorSpace];
    if (!sceneLinear) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:9
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not determine scene-linear color space for inverse display transform"}];
        }
        return nil;
    }
    
    NSLog(@"🔄 Creating inverse display transform: %@ / %@ → %@", display, view, sceneLinear);
    
    try {
        // Create DisplayViewTransform
        OCIO::DisplayViewTransformRcPtr transform = OCIO::DisplayViewTransform::Create();
        transform->setSrc([sceneLinear UTF8String]);
        transform->setDisplay([display UTF8String]);
        transform->setView([view UTF8String]);
        
        // KEY: Set direction to INVERSE
        transform->setDirection(OCIO::TRANSFORM_DIR_INVERSE);
        
        OCIO::ConstProcessorRcPtr processor = cfg->getProcessor(transform);
        OCIO::ConstCPUProcessorRcPtr cpuProcessor = processor->getDefaultCPUProcessor();
        
        NSLog(@"✅ Inverse display processor created successfully");
        NSLog(@"   Processor has channel crosstalk: %d", processor->hasChannelCrosstalk());
        NSLog(@"   Processor is no-op: %d", processor->isNoOp());
        
        OCIOProcessor *ocioProcessor = [[OCIOProcessor alloc] init];
        ocioProcessor->_processor = processor;
        ocioProcessor->_cpuProcessor = cpuProcessor;
        return ocioProcessor;
        
    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:10
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        NSLog(@"❌ Failed to create inverse display processor: %s", e.what());
    }
    
    return nil;
}

+ (instancetype)inverseDisplayProcessorWithConfig:(OCIOConfig *)config
                                      sourceSpace:(NSString *)sourceSpace
                                          display:(NSString *)display
                                             view:(NSString *)view
                                            error:(NSError **)error {
    OCIO::ConstConfigRcPtr cfg = [config internalConfig];
    if (!cfg) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid OCIO config"}];
        }
        return nil;
    }

    NSLog(@"🔄 Creating inverse display transform: %@ / %@ → %@", display, view, sourceSpace);

    try {
        // Display/view transform, inverted: display-referred → the given scene-referred space.
        OCIO::DisplayViewTransformRcPtr transform = OCIO::DisplayViewTransform::Create();
        transform->setSrc([sourceSpace UTF8String]);
        transform->setDisplay([display UTF8String]);
        transform->setView([view UTF8String]);
        transform->setDirection(OCIO::TRANSFORM_DIR_INVERSE);

        OCIO::ConstProcessorRcPtr processor = cfg->getProcessor(transform);
        OCIO::ConstCPUProcessorRcPtr cpuProcessor = processor->getDefaultCPUProcessor();

        NSLog(@"✅ Inverse display processor created (src=%@): crosstalk=%d noop=%d",
              sourceSpace, processor->hasChannelCrosstalk(), processor->isNoOp());

        OCIOProcessor *ocioProcessor = [[OCIOProcessor alloc] init];
        ocioProcessor->_processor = processor;
        ocioProcessor->_cpuProcessor = cpuProcessor;
        return ocioProcessor;

    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:10
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        NSLog(@"❌ Failed to create inverse display processor (src=%@): %s", sourceSpace, e.what());
    }

    return nil;
}

/// Build a row-major 4x4 RGB → CIE XYZ-D65 matrix from xy chromaticities.
/// Matches OCIO's ADAPTATION_NONE (no chromatic adaptation).
/// This is the same calculation OCIO's build_conversion_matrix_to_XYZ_D65 performs
/// internally in Generate_output_transform() in ACES.cpp.
static void buildRGBtoXYZ_D65(double Rx, double Ry,
                               double Gx, double Gy,
                               double Bx, double By,
                               double Wx, double Wy,
                               double out[16])
{
    // Convert xy chromaticities to XYZ (normalise to Y=1)
    double Xr = Rx/Ry,        Yr = 1.0, Zr = (1.0-Rx-Ry)/Ry;
    double Xg = Gx/Gy,        Yg = 1.0, Zg = (1.0-Gx-Gy)/Gy;
    double Xb = Bx/By,        Yb = 1.0, Zb = (1.0-Bx-By)/By;
    double Xw = Wx/Wy,        Yw = 1.0, Zw = (1.0-Wx-Wy)/Wy;

    // Solve [[Xr Xg Xb],[Yr Yg Yb],[Zr Zg Zb]] * [Sr,Sg,Sb]' = [Xw,Yw,Zw]
    // using Cramer's rule
    double det = Xr*(Yg*Zb - Zg*Yb) - Xg*(Yr*Zb - Zr*Yb) + Xb*(Yr*Zg - Zr*Yg);
    double Sr  = (Xw*(Yg*Zb - Zg*Yb) - Xg*(Yw*Zb - Zw*Yb) + Xb*(Yw*Zg - Zw*Yg)) / det;
    double Sg  = (Xr*(Yw*Zb - Zw*Yb) - Xw*(Yr*Zb - Zr*Yb) + Xb*(Yr*Zw - Zr*Yw)) / det;
    double Sb  = (Xr*(Yg*Zw - Zg*Yw) - Xg*(Yr*Zw - Zr*Yw) + Xw*(Yr*Zg - Zr*Yg)) / det;

    // Row-major 4x4 for OCIO's setMatrix (column-vector convention: out = M * in)
    out[ 0]=Sr*Xr; out[ 1]=Sg*Xg; out[ 2]=Sb*Xb; out[ 3]=0.0;
    out[ 4]=Sr*Yr; out[ 5]=Sg*Yg; out[ 6]=Sb*Yb; out[ 7]=0.0;
    out[ 8]=Sr*Zr; out[ 9]=Sg*Zg; out[10]=Sb*Zb; out[11]=0.0;
    out[12]=0.0;   out[13]=0.0;   out[14]=0.0;   out[15]=1.0;
}

+ (instancetype)aces2DynamicProcessorWithConfig:(OCIOConfig *)config
                                     sourceSpace:(NSString *)sourceSpace
                                       peakNits:(double)peakNits
                                  outputGamutXY:(nullable NSArray<NSNumber *> *)outputGamutXY
                                          error:(NSError **)error {
    OCIO::ConstConfigRcPtr cfg = [config internalConfig];
    if (!cfg) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid OCIO config"}];
        }
        return nil;
    }

    try {
        // ── Resolve the ACES2065-1 interchange space ─────────────────────────────
        // Try in priority order: the aces_interchange role, then a list of common
        // literal names used across ACES Studio / OCIO builtin / third-party configs.
        std::string acesInterchange;
        {
            // 1. Standard OCIO role
            static const char* kRoles[] = { "aces_interchange" };
            for (const char* role : kRoles) {
                OCIO::ConstColorSpaceRcPtr cs = cfg->getColorSpace(role);
                if (cs) { acesInterchange = cs->getName(); break; }
            }
            // 2. Common literal names (OCIO 2.x builtin, ACES Studio v1/v2, CGI configs)
            static const char* kAliases[] = {
                "ACES2065-1",
                "ACES - ACES2065-1",
                "lin_ap0",
                "Linear - ACES2065-1",
                "ACESlinear",
                "aces_ap0_linear",
            };
            if (acesInterchange.empty()) {
                for (const char* alias : kAliases) {
                    OCIO::ConstColorSpaceRcPtr cs = cfg->getColorSpace(alias);
                    if (cs) { acesInterchange = cs->getName(); break; }
                }
            }
        }
        if (acesInterchange.empty()) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.tristimulator.ocio"
                                            code:3
                                        userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"Dynamic ACES2 requires an ACES2065-1 color space or 'aces_interchange' "
                        @"role in the active OCIO config. The current config does not define one. "
                        @"Switch to Config mode to use the display/view pairs defined in this config."
                }];
            }
            return nil;
        }
        NSLog(@"🎬 ACES2 interchange resolved to: '%s'", acesInterchange.c_str());

        // ── Build parameter vector: [peakNits, Rx,Ry, Gx,Gy, Bx,By, Wx,Wy] ──
        // Default: P3-D65 output gamut
        static const double kP3D65[8] = {
            0.680, 0.320,  // R
            0.265, 0.690,  // G
            0.150, 0.060,  // B
            0.3127, 0.3290 // D65 white
        };
        std::vector<double> params;
        params.push_back(peakNits);
        if (outputGamutXY && outputGamutXY.count == 8) {
            for (NSNumber *v in outputGamutXY) params.push_back(v.doubleValue);
        } else {
            params.insert(params.end(), kP3D65, kP3D65 + 8);
        }

        // ── Step 1: convert from working space to ACES2065-1 ──
        OCIO::ColorSpaceTransformRcPtr cst = OCIO::ColorSpaceTransform::Create();
        cst->setSrc([sourceSpace UTF8String]);
        cst->setDst(acesInterchange.c_str());

        double zeroOffset[4] = {0.0, 0.0, 0.0, 0.0};

        // ── Step 2: Pre-clamp in AP1 ─────────────────────────────────────────────
        // Matches Generate_output_transform() in OCIO's ACES.cpp:
        //   AP0 → AP1  ➜  RangeOp [0, upperBound]  ➜  AP1 → AP0
        // This bounds the scene-referred input before the display rendering.
        //
        // AP0 (ACES2065-1) primaries  xy:
        //   R(0.7347, 0.2653)  G(0.0000, 1.0000)  B(0.0001, -0.0770)  W(0.32168, 0.33767)
        // AP1 (ACEScg) primaries  xy:
        //   R(0.713, 0.293)  G(0.165, 0.830)  B(0.128, 0.044)  W(0.32168, 0.33767)
        double ap0toXYZ[16], ap1toXYZ[16];
        buildRGBtoXYZ_D65(0.7347, 0.2653, 0.0000, 1.0000, 0.0001, -0.0770, 0.32168, 0.33767, ap0toXYZ);
        buildRGBtoXYZ_D65(0.713,  0.293,  0.165,  0.830,  0.128,  0.044,   0.32168, 0.33767, ap1toXYZ);

        // Invert ap1toXYZ to get XYZ → AP1, then AP0→AP1 = (XYZ→AP1) * (AP0→XYZ)
        // We use OCIO MatrixTransforms and let the group handle composition.
        OCIO::MatrixTransformRcPtr ap0ToXYZMtx = OCIO::MatrixTransform::Create();
        ap0ToXYZMtx->setMatrix(ap0toXYZ);
        ap0ToXYZMtx->setOffset(zeroOffset);

        OCIO::MatrixTransformRcPtr ap1ToXYZMtx = OCIO::MatrixTransform::Create();
        ap1ToXYZMtx->setMatrix(ap1toXYZ);
        ap1ToXYZMtx->setOffset(zeroOffset);
        ap1ToXYZMtx->setDirection(OCIO::TRANSFORM_DIR_INVERSE); // XYZ → AP1

        // Upper bound: 8 * (128 + 768 * ln(peakNits/100) / ln(10000/100))
        const double upperBound = 8.0 * (128.0 + 768.0 * (std::log(peakNits / 100.0) / std::log(10000.0 / 100.0)));
        OCIO::RangeTransformRcPtr preClamp = OCIO::RangeTransform::Create();
        preClamp->setMinInValue(0.0);
        preClamp->setMaxInValue(upperBound);
        preClamp->setMinOutValue(0.0);
        preClamp->setMaxOutValue(upperBound);

        // Reverse: AP1 → XYZ → AP0
        OCIO::MatrixTransformRcPtr ap1ToXYZMtxFwd = OCIO::MatrixTransform::Create();
        ap1ToXYZMtxFwd->setMatrix(ap1toXYZ);
        ap1ToXYZMtxFwd->setOffset(zeroOffset);

        OCIO::MatrixTransformRcPtr ap0ToXYZMtxInv = OCIO::MatrixTransform::Create();
        ap0ToXYZMtxInv->setMatrix(ap0toXYZ);
        ap0ToXYZMtxInv->setOffset(zeroOffset);
        ap0ToXYZMtxInv->setDirection(OCIO::TRANSFORM_DIR_INVERSE); // XYZ → AP0

        // ── Step 3: ACES 2 Output Transform (core tone-map + gamut map) ──
        // Style: FIXED_FUNCTION_ACES_OUTPUT_TRANSFORM_20  (OCIO 2.5 name)
        // Params: [peakNits, Rx, Ry, Gx, Gy, Bx, By, Wx, Wy]
        OCIO::FixedFunctionTransformRcPtr ff = OCIO::FixedFunctionTransform::Create(
            OCIO::FIXED_FUNCTION_ACES_OUTPUT_TRANSFORM_20,
            params.data(),
            params.size()
        );

        // ── Step 4: Post-transform clamp [0, peakNits/100] ──────────────────────
        // Matches the post-clamp in Generate_output_transform().
        const double normPeak = peakNits / 100.0;
        OCIO::RangeTransformRcPtr postClamp = OCIO::RangeTransform::Create();
        postClamp->setMinInValue(0.0);
        postClamp->setMaxInValue(normPeak);
        postClamp->setMinOutValue(0.0);
        postClamp->setMaxOutValue(normPeak);

        // ── Step 5: linear limitingGamut → CIE XYZ-D65 ───────────────────────────
        // The FixedFunction outputs linear light in the *limiting* primaries gamut.
        // OCIO's display builtin starts from CIE XYZ-D65, so we bridge the gap with
        // the correct limiting-primaries → XYZ-D65 matrix (ADAPTATION_NONE), matching
        // what Generate_output_transform appends in ACES.cpp.
        // Compute from params[1..8] so any gamut (P3, Rec709, Rec2020, ...) is handled.
        double limitingToXYZ[16];
        buildRGBtoXYZ_D65(
            params[1], params[2],   // Rx, Ry
            params[3], params[4],   // Gx, Gy
            params[5], params[6],   // Bx, By
            params[7], params[8],   // Wx, Wy
            limitingToXYZ
        );
        OCIO::MatrixTransformRcPtr toXYZ = OCIO::MatrixTransform::Create();
        toXYZ->setMatrix(limitingToXYZ);
        toXYZ->setOffset(zeroOffset);

        // ── Step 6: CIE XYZ-D65 → Extended Display P3 (OCIO builtin) ─────────────
        // "DISPLAY - CIE-XYZ-D65_to_DisplayP3-HDR" is OCIO's official encoding
        // for macOS kCGColorSpaceDisplayP3 / kCGColorSpaceExtendedDisplayP3.
        // Internally it applies:
        //   - XYZ-D65 → linear P3-D65 matrix  (cancels step 3 above, leaving identity)
        //   - MONCURVE_MIRROR_REV (gamma=2.4, offset=0.055)   ← the actual OETF
        // MONCURVE_MIRROR_REV reflects the sRGB curve around 0 for negative values,
        // exactly matching Extended Display P3 behaviour per Apple's documentation.
        OCIO::BuiltinTransformRcPtr displayBT = OCIO::BuiltinTransform::Create();
        displayBT->setStyle("DISPLAY - CIE-XYZ-D65_to_DisplayP3-HDR");

        // ── Bundle into a GroupTransform ──
        OCIO::GroupTransformRcPtr group = OCIO::GroupTransform::Create();
        group->appendTransform(cst);            // 1. source → ACES2065-1 (AP0)
        group->appendTransform(ap0ToXYZMtx);    // 2a. AP0 → XYZ
        group->appendTransform(ap1ToXYZMtx);    // 2b. XYZ → AP1  (inverse)
        group->appendTransform(preClamp);        // 2c. clamp [0, upperBound] in AP1
        group->appendTransform(ap1ToXYZMtxFwd); // 2d. AP1 → XYZ
        group->appendTransform(ap0ToXYZMtxInv); // 2e. XYZ → AP0
        group->appendTransform(ff);              // 3.  ACES 2.0 Output Transform
        group->appendTransform(postClamp);       // 4.  clamp [0, peakNits/100]
        group->appendTransform(toXYZ);           // 5.  limiting gamut → XYZ-D65
        group->appendTransform(displayBT);       // 6.  XYZ-D65 → Display P3 HDR

        OCIO::ConstProcessorRcPtr processor = cfg->getProcessor(group);
        OCIO::ConstCPUProcessorRcPtr cpuProcessor = processor->getDefaultCPUProcessor();

        OCIOProcessor *result = [[OCIOProcessor alloc] init];
        result->_processor   = processor;
        result->_cpuProcessor = cpuProcessor;
        NSLog(@"✅ ACES2 dynamic processor: peakNits=%.0f sourceSpace=%@",
              peakNits, sourceSpace);
        return result;

    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        return nil;
    }
}

+ (instancetype)aces2FixedFunctionProcessorWithConfig:(OCIOConfig *)config
                                             peakNits:(double)peakNits
                                        outputGamutXY:(nullable NSArray<NSNumber *> *)outputGamutXY
                                                error:(NSError **)error {
    OCIO::ConstConfigRcPtr cfg = [config internalConfig];
    if (!cfg) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid OCIO config"}];
        }
        return nil;
    }

    try {
        // P3-D65 default output gamut
        static const double kP3D65[8] = {
            0.680, 0.320,
            0.265, 0.690,
            0.150, 0.060,
            0.3127, 0.3290
        };
        std::vector<double> params;
        params.push_back(peakNits);
        if (outputGamutXY && outputGamutXY.count == 8) {
            for (NSNumber *v in outputGamutXY) params.push_back(v.doubleValue);
        } else {
            params.insert(params.end(), kP3D65, kP3D65 + 8);
        }

        OCIO::FixedFunctionTransformRcPtr ff = OCIO::FixedFunctionTransform::Create(
            OCIO::FIXED_FUNCTION_ACES_OUTPUT_TRANSFORM_20,
            params.data(),
            params.size()
        );

        OCIO::ConstProcessorRcPtr processor = cfg->getProcessor(ff);
        OCIO::ConstCPUProcessorRcPtr cpuProcessor = processor->getDefaultCPUProcessor();

        OCIOProcessor *result = [[OCIOProcessor alloc] init];
        result->_processor   = processor;
        result->_cpuProcessor = cpuProcessor;
        NSLog(@"✅ ACES2 FixedFunction-only processor: peakNits=%.0f", peakNits);
        return result;

    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        return nil;
    }
}

- (NSData *)processPixelData:(NSData *)pixelData
                       width:(NSInteger)width
                      height:(NSInteger)height
                    channels:(NSInteger)channels
                       error:(NSError **)error {
    if (!_cpuProcessor) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid processor"}];
        }
        return nil;
    }
    
    try {
        // Create output buffer
        NSMutableData *outputData = [pixelData mutableCopy];
        float *pixels = (float *)[outputData mutableBytes];
        
        // Create image description
        OCIO::PackedImageDesc imgDesc(
            pixels,
            width,
            height,
            channels,
            OCIO::BIT_DEPTH_F32,
            sizeof(float),                    // channel stride
            sizeof(float) * channels,         // x stride
            sizeof(float) * channels * width  // y stride
        );
        
        // Apply the color transformation
        _cpuProcessor->apply(imgDesc);
        
        return outputData;
        
    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
    }
    
    return nil;
}

- (BOOL)getGPUShaderAndTextures:(NSString **)shaderDesc
                   texturesData:(NSArray<NSDictionary *> **)texturesData
                          error:(NSError **)error {
    if (!_processor) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid processor"}];
        }
        return NO;
    }

    try {
        // Build ONE shader descriptor — shader text and texture data are extracted from the
        // same object so they are guaranteed to be consistent with each other.
        OCIO::GpuShaderDescRcPtr desc = OCIO::GpuShaderDesc::CreateShaderDesc();
        desc->setLanguage(OCIO::GPU_LANGUAGE_MSL_2_0);
        desc->setFunctionName("OCIOTransform");
        desc->setResourcePrefix("ocio");

        OCIO::ConstGPUProcessorRcPtr gpuProc = _processor->getDefaultGPUProcessor();
        gpuProc->extractGpuShaderInfo(desc);

        // — Shader text —
        const char* shaderText = desc->getShaderText();
        if (shaderText && shaderDesc) {
            *shaderDesc = [NSString stringWithUTF8String:shaderText];
        }

        // — Texture data —
        NSMutableArray<NSDictionary *> *textures = [NSMutableArray array];

        unsigned numTextures = desc->getNumTextures();
        for (unsigned i = 0; i < numTextures; i++) {
            const char* textureName = nullptr;
            const char* samplerName = nullptr;
            unsigned width = 0, height = 0;
            OCIO::GpuShaderDesc::TextureType channelKind;        // RED or RGB
            OCIO::GpuShaderDesc::TextureDimensions dimensions;   // 1D or 2D
            OCIO::Interpolation interpolation;

            desc->getTexture(i, textureName, samplerName, width, height, channelKind, dimensions, interpolation);

            const float* values = nullptr;
            desc->getTextureValues(i, values);

            if (values) {
                unsigned channelCount = (channelKind == OCIO::GpuShaderDesc::TEXTURE_RGB_CHANNEL) ? 3 : 1;
                size_t dataSize = width * height * channelCount * sizeof(float);
                NSLog(@"🔎 OCIO texture[%u] '%s': dims=%d (%@) width=%u height=%u dataSize=%zu",
                      i, textureName,
                      (int)dimensions,
                      (channelKind == OCIO::GpuShaderDesc::TEXTURE_RGB_CHANNEL) ? @"RGB" : @"RED",
                      width, height, dataSize);
                NSData *data = [NSData dataWithBytes:values length:dataSize];
                NSString *typeStr = (height == 1) ? @"1D" : @"2D";

                [textures addObject:@{
                    @"name":        textureName ? [NSString stringWithUTF8String:textureName] : @"",
                    @"samplerName": samplerName ? [NSString stringWithUTF8String:samplerName] : @"",
                    @"width":       @(width),
                    @"height":      @(height),
                    @"channels":    @(channelCount),
                    @"channelType": (channelKind == OCIO::GpuShaderDesc::TEXTURE_RGB_CHANNEL) ? @"RGB" : @"RED",
                    @"type":        typeStr,
                    @"data":        data
                }];
            }
        }

        unsigned num3DTextures = desc->getNum3DTextures();
        for (unsigned i = 0; i < num3DTextures; i++) {
            const char* textureName = nullptr;
            const char* samplerName = nullptr;
            unsigned edge = 0;
            OCIO::Interpolation interpolation;

            desc->get3DTexture(i, textureName, samplerName, edge, interpolation);

            const float* values = nullptr;
            desc->get3DTextureValues(i, values);

            if (values) {
                size_t dataSize = edge * edge * edge * 3 * sizeof(float);
                NSData *data = [NSData dataWithBytes:values length:dataSize];

                [textures addObject:@{
                    @"name":        textureName ? [NSString stringWithUTF8String:textureName] : @"",
                    @"samplerName": samplerName ? [NSString stringWithUTF8String:samplerName] : @"",
                    @"edgeLength":  @(edge),
                    @"type":        @"3D",
                    @"data":        data
                }];
            }
        }

        if (texturesData) {
            *texturesData = textures;
        }

        return YES;

    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:6
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        return NO;
    }
}

- (BOOL)getGPUShaderDescription:(NSString **)shaderDesc error:(NSError **)error {
    if (!_processor) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid processor"}];
        }
        return NO;
    }
    
    try {
        // Get GPU processor
        OCIO::GpuShaderDescRcPtr shaderDescriptor = OCIO::GpuShaderDesc::CreateShaderDesc();
        shaderDescriptor->setLanguage(OCIO::GPU_LANGUAGE_MSL_2_0); // Metal Shading Language
        shaderDescriptor->setFunctionName("OCIOTransform");
        shaderDescriptor->setResourcePrefix("ocio");
        
        OCIO::ConstGPUProcessorRcPtr gpuProcessor = _processor->getDefaultGPUProcessor();
        gpuProcessor->extractGpuShaderInfo(shaderDescriptor);
        
        // Get the shader text
        const char* shaderText = shaderDescriptor->getShaderText();
        if (shaderText && shaderDesc) {
            *shaderDesc = [NSString stringWithUTF8String:shaderText];
        }
        
        return YES;
        
    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:6
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        return NO;
    }
}

- (BOOL)getGPU3DLUTData:(NSData **)lutData edgeLength:(NSInteger *)edgeLen error:(NSError **)error {
    if (!_processor) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid processor"}];
        }
        return NO;
    }
    
    try {
        // Get GPU processor
        OCIO::GpuShaderDescRcPtr shaderDescriptor = OCIO::GpuShaderDesc::CreateShaderDesc();
        shaderDescriptor->setLanguage(OCIO::GPU_LANGUAGE_MSL_2_0);
        
        OCIO::ConstGPUProcessorRcPtr gpuProcessor = _processor->getDefaultGPUProcessor();
        gpuProcessor->extractGpuShaderInfo(shaderDescriptor);
        
        // Get 3D LUT information
        unsigned numTextures = shaderDescriptor->getNum3DTextures();
        
        if (numTextures > 0) {
            // Get the first 3D texture (typically there's only one)
            const char* textureName = nullptr;
            const char* samplerName = nullptr;
            unsigned edge = 0;
            OCIO::Interpolation interpolation;
            
            shaderDescriptor->get3DTexture(0, textureName, samplerName, edge, interpolation);
            
            if (edgeLen) {
                *edgeLen = edge;
            }
            
            // Get the texture values
            const float* values = nullptr;
            shaderDescriptor->get3DTextureValues(0, values);
            
            if (values && lutData) {
                size_t dataSize = edge * edge * edge * 3 * sizeof(float); // RGB
                *lutData = [NSData dataWithBytes:values length:dataSize];
            }
            
            return YES;
        }
        
        return YES; // No 3D LUT needed, which is fine
        
    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:7
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        return NO;
    }
}

- (BOOL)getGPUTextureData:(NSArray<NSDictionary *> **)texturesData error:(NSError **)error {
    if (!_processor) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid processor"}];
        }
        return NO;
    }
    
    try {
        // Get GPU processor and shader descriptor
        OCIO::GpuShaderDescRcPtr shaderDescriptor = OCIO::GpuShaderDesc::CreateShaderDesc();
        shaderDescriptor->setLanguage(OCIO::GPU_LANGUAGE_MSL_2_0);
        
        OCIO::ConstGPUProcessorRcPtr gpuProcessor = _processor->getDefaultGPUProcessor();
        gpuProcessor->extractGpuShaderInfo(shaderDescriptor);
        
        NSMutableArray<NSDictionary *> *textures = [NSMutableArray array];
        
        // Get 2D/1D LUT textures
        unsigned numTextures = shaderDescriptor->getNumTextures();
        for (unsigned i = 0; i < numTextures; i++) {
            const char* textureName = nullptr;
            const char* samplerName = nullptr;
            unsigned width = 0;
            unsigned height = 0;
            OCIO::GpuShaderDesc::TextureType channelKind;        // RED or RGB
            OCIO::GpuShaderDesc::TextureDimensions dimensions;   // 1D or 2D
            OCIO::Interpolation interpolation;
            
            shaderDescriptor->getTexture(i, textureName, samplerName, width, height, channelKind, dimensions, interpolation);
            
            // Get the texture values
            const float* values = nullptr;
            shaderDescriptor->getTextureValues(i, values);
            
            if (values) {
                // Convert TextureDimensions to actual channel count
                unsigned channelCount = (channelKind == OCIO::GpuShaderDesc::TEXTURE_RGB_CHANNEL) ? 3 : 1;
                size_t dataSize = width * height * channelCount * sizeof(float);
                NSData *data = [NSData dataWithBytes:values length:dataSize];
                
                // Determine if this is a 1D or 2D texture based on height
                NSString *textureType = (height == 1) ? @"1D" : @"2D";
                
                [textures addObject:@{
                    @"name": textureName ? [NSString stringWithUTF8String:textureName] : @"",
                    @"samplerName": samplerName ? [NSString stringWithUTF8String:samplerName] : @"",
                    @"width": @(width),
                    @"height": @(height),
                    @"channels": @(channelCount),
                    @"type": textureType,
                    @"data": data
                }];
            }
        }
        
        // Get 3D LUT textures
        unsigned num3DTextures = shaderDescriptor->getNum3DTextures();
        for (unsigned i = 0; i < num3DTextures; i++) {
            const char* textureName = nullptr;
            const char* samplerName = nullptr;
            unsigned edge = 0;
            OCIO::Interpolation interpolation;
            
            shaderDescriptor->get3DTexture(i, textureName, samplerName, edge, interpolation);
            
            const float* values = nullptr;
            shaderDescriptor->get3DTextureValues(i, values);
            
            if (values) {
                size_t dataSize = edge * edge * edge * 3 * sizeof(float); // RGB
                NSData *data = [NSData dataWithBytes:values length:dataSize];
                
                [textures addObject:@{
                    @"name": textureName ? [NSString stringWithUTF8String:textureName] : @"",
                    @"samplerName": samplerName ? [NSString stringWithUTF8String:samplerName] : @"",
                    @"edgeLength": @(edge),
                    @"type": @"3D",
                    @"data": data
                }];
            }
        }
        
        if (texturesData) {
            *texturesData = textures;
        }
        
        return YES;
        
    } catch (const std::exception& e) {
        if (error) {
            *error = [NSError errorWithDomain:OCIOErrorDomain
                                         code:8
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        return NO;
    }
}

@end

@implementation OpenColorIOBridge

+ (NSString *)version {
    return @(OCIO::GetVersion());
}

+ (BOOL)isAvailable {
    @try {
        OCIO::ConstConfigRcPtr config = OCIO::GetCurrentConfig();
        return config != nullptr;
    } @catch (...) {
        return NO;
    }
}

@end
