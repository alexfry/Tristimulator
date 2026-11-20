# Inverse Display Transform Implementation Guide

## Overview

Modern OCIO ACES 2.0 configs do not expose display transforms as bidirectional colorspaces. To perform an inverse display transform (display-referred → scene-referred), we need to use OCIO's `DisplayViewTransform` with `TRANSFORM_DIR_INVERSE`.

## Implementation Required

### 1. Add to OCIOConfig Bridge (Objective-C++/C++)

You need to add a method to create an inverse display transform processor. This should be added to your OCIO bridge implementation (likely in a file like `OCIOBridge.mm` or similar).

```objc
// In your OCIOConfig wrapper class
- (OCIOProcessor *)createInverseDisplayProcessor:(NSString *)display
                                            view:(NSString *)view
                                           error:(NSError **)error {
    try {
        // Get scene-linear role name (or use canonical name)
        std::string sceneLinear = m_config->getCanonicalName(OCIO::ROLE_SCENE_LINEAR);
        
        // Create DisplayViewTransform
        OCIO::DisplayViewTransformRcPtr transform = OCIO::DisplayViewTransform::Create();
        transform->setSrc(sceneLinear.c_str());
        transform->setDisplay([display UTF8String]);
        transform->setView([view UTF8String]);
        
        // KEY: Set direction to INVERSE to go from display → scene-linear
        transform->setDirection(OCIO::TRANSFORM_DIR_INVERSE);
        
        // Get processor from config
        OCIO::ConstProcessorRcPtr processor = m_config->getProcessor(transform);
        
        // Create CPU processor for pixel data processing
        OCIO::ConstCPUProcessorRcPtr cpuProcessor = processor->getDefaultCPUProcessor();
        
        // Wrap in your OCIOProcessor wrapper
        return [[OCIOProcessor alloc] initWithCPUProcessor:cpuProcessor];
        
    } catch (const OCIO::Exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"OCIOErrorDomain"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        return nil;
    }
}
```

### 2. Swift Bridge Method

Add this to your `OCIOConfig` Swift wrapper:

```swift
extension OCIOConfig {
    /// Create a processor that inverts a display/view transform
    ///
    /// - Parameters:
    ///   - display: Display name (e.g., "ACES", "sRGB")
    ///   - view: View name (e.g., "ACES 1.0 - SDR Video")
    /// - Returns: Processor that converts display-referred → scene-linear
    func createInverseDisplayProcessor(display: String, view: String) throws -> OCIOProcessor {
        // Call the Objective-C++ bridge method
        var error: NSError?
        guard let processor = self.createInverseDisplayProcessor(display, view: view, error: &error) else {
            throw error ?? ImageError.ocioNotAvailable
        }
        return processor
    }
}
```

### 3. Update OCIOProcessor+InverseDisplay.swift

Once the bridge is implemented, update the stub in `OCIOProcessor+InverseDisplay.swift`:

```swift
static func makeInverseDisplayProcessor(
    config: OCIOConfig,
    display: String,
    view: String
) throws -> OCIOProcessor {
    return try config.createInverseDisplayProcessor(display: display, view: view)
}
```

## GPU Path Implementation

For GPU-accelerated inverse display transforms, you'll need to:

1. Add GPU shader compilation support for inverse display transforms in `OCIOGPUProcessor`
2. Use OCIO's GPU processor API with the inverse transform:

```cpp
OCIO::ConstGPUProcessorRcPtr gpuProc = processor->getDefaultGPUProcessor();
```

3. Generate and compile the Metal shader code from OCIO's shader text:

```cpp
OCIO::GpuShaderDescRcPtr shaderDesc = OCIO::GpuShaderDesc::CreateShaderDesc();
shaderDesc->setLanguage(OCIO::GPU_LANGUAGE_MSL_2_0);  // Metal Shading Language
gpuProc->extractGpuShaderInfo(shaderDesc);

const char* shaderText = shaderDesc->getShaderText();
const char* functionName = shaderDesc->getFunctionName();
```

4. Update `setupCombinedTransform` and `setupCombinedACES2Transform` to support inverse display as the source transform

## Testing

1. **Load an ACES 2.0 config** (like the bundled studio-config-v4.0.0_aces-v2.0_ocio-v2.5)

2. **Set Source Node to "Inverse Display" mode**

3. **Select a display and view** (e.g., "ACES" / "ACES 1.0 - SDR Video")

4. **Load a display-referred image** (e.g., a screenshot or SDR reference image)

5. **Verify the output**:
   - The image should be converted from display-referred to scene-linear
   - You should see values > 1.0 for bright areas (since they're now in linear)
   - The Working Space transform should then work correctly on this scene-linear data

## Use Cases

### Use Case 1: Loading SDR References
```
SDR Screenshot (sRGB, gamma 2.2)
  ↓ [Inverse Display: sRGB / sRGB EOTF]
Scene-Linear (AP1 or AP0)
  ↓ [Working Space: identity or AP1 → AP0]
Scene-Linear Working Space
  ↓ [Display: ACES / HDR 1000 nits]
HDR Display Output
```

### Use Case 2: Converting Display-Referred LUTs
```
Display-Referred LUT Output
  ↓ [Inverse Display: ACES / SDR Video]
Scene-Linear ACES2065-1
  ↓ [Working Space: transform as needed]
Scene-Linear AP1
  ↓ [Display: new display/view]
New Display Output
```

## OCIO References

- [OCIO DisplayViewTransform Docs](https://opencolorio.readthedocs.io/en/latest/api/c_displayviewtransform.html)
- [OCIO Transform Direction](https://opencolorio.readthedocs.io/en/latest/api/c_processor.html#_CPPv4N13OpenColorIO18TransformDirectionE)
- [OCIO v2 Migration Guide](https://opencolorio.readthedocs.io/en/latest/guides/authoring/authoring.html)

## Notes

- **Direction**: `TRANSFORM_DIR_INVERSE` reverses the transform direction
- **Scene-Linear Role**: Most configs define a `scene_linear` role; use this as the "destination" of the inverse transform
- **GPU Performance**: Inverse transforms compile to the same GPU shader code as forward transforms (just with inverted matrices/LUTs)
- **Validation**: OCIO will throw an exception if the transform cannot be inverted (e.g., if it contains non-invertible 3D LUTs)
