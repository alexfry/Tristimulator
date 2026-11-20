# Source Node Architecture: Color Space vs Inverse Display Modes

## Visual Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          SOURCE NODE (Dual Mode)                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │  MODE SELECTOR                                                │         │
│  │  ┌──────────────┬────────────────┐                           │         │
│  │  │ Color Space  │ Inverse Display│  ← User toggles           │         │
│  │  └──────────────┴────────────────┘                           │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  ┌────────────────────────────────┬────────────────────────────────────┐   │
│  │ COLOR SPACE MODE               │ INVERSE DISPLAY MODE               │   │
│  ├────────────────────────────────┼────────────────────────────────────┤   │
│  │                                │                                    │   │
│  │ Input:                         │ Input:                             │   │
│  │  • Source colorspace name      │  • Display name                    │   │
│  │    (e.g., "sRGB")              │  • View name                       │   │
│  │                                │                                    │   │
│  │ Transform:                     │ Transform:                         │   │
│  │  ColorSpace → ColorSpace       │  DisplayView (INVERSE) → Linear    │   │
│  │                                │                                    │   │
│  │ Example:                       │ Example:                           │   │
│  │  sRGB → ACES2065-1             │  "ACES"/"SDR Video"⁻¹ → AP0        │   │
│  │                                │                                    │   │
│  └────────────────────────────────┴────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Data Flow Comparison

### Color Space Mode (Traditional)
```
┌──────────────────┐
│  Source Image    │
│  (e.g., sRGB)    │
└────────┬─────────┘
         │
         │ applyColorspaceTransform()
         │ ┌─────────────────────────────────┐
         ├─│ OCIOProcessor                   │
         │ │ config: OCIOConfig              │
         │ │ sourceSpace: "sRGB"             │
         │ │ destinationSpace: "ACES2065-1"  │
         │ └─────────────────────────────────┘
         ▼
┌──────────────────┐
│ Working Space    │
│ (ACES2065-1)     │
└────────┬─────────┘
         │
         ▼
   [Display Node]
```

### Inverse Display Mode (New)
```
┌────────────────────────┐
│  Display-Referred      │
│  Source Image          │
│  (e.g., SDR screenshot)│
└───────────┬────────────┘
            │
            │ applyInverseDisplayTransform()
            │
            │ Step 1: Inverse Display Transform
            │ ┌──────────────────────────────────────┐
            ├─│ makeInverseDisplayProcessor()        │
            │ │ display: "ACES"                      │
            │ │ view: "ACES 1.0 - SDR Video"        │
            │ │ direction: TRANSFORM_DIR_INVERSE     │
            │ └──────────────────────────────────────┘
            ▼
┌────────────────────────┐
│  Scene-Linear          │
│  (from scene_linear    │
│   role)                │
└───────────┬────────────┘
            │
            │ Step 2 (optional): scene-linear → working space
            │ ┌──────────────────────────────────────┐
            ├─│ OCIOProcessor (if needed)            │
            │ │ sourceSpace: "ACES2065-1"            │
            │ │ destinationSpace: "ACEScg"           │
            │ └──────────────────────────────────────┘
            ▼
┌────────────────────────┐
│  Working Space         │
│  (e.g., ACEScg/AP1)    │
└───────────┬────────────┘
            │
            ▼
      [Display Node]
```

## UI Component Breakdown

```
Source Node UI
├── Mode Selector (Pill Toggle)
│   ├── "Color Space" button
│   └── "Inverse Display" button
│
├── Color Space Mode Content
│   ├── Picker: Source Color Space
│   │   └── Options: All available colorspaces from OCIO config
│   └── Image Metadata Disclosure
│
└── Inverse Display Mode Content
    ├── Label: "Display to Invert"
    ├── Picker: Display
    │   └── Options: All displays from OCIO config
    ├── Label: "View to Invert"
    ├── Picker: View
    │   └── Options: Views for selected display
    ├── Info Text: "Inverts display/view transform..."
    └── Image Metadata Disclosure
```

## Code Flow

```swift
// User changes mode or selection
↓
ColorPipelineNodeView.onChange
↓
applyColorTransformAndReapplyDisplay()
↓
ImageManager.applyColorTransform(from:to:)
↓
switch sourceTransformMode {
    case .colorspace:
        → applyColorspaceTransform(...)
          ├── OCIOProcessor(sourceSpace, destinationSpace)
          └── processPixelData()
    
    case .inverseDisplay:
        → applyInverseDisplayTransform(...)
          ├── makeInverseDisplayProcessor(display, view)
          ├── processPixelData() → scene-linear
          └── (optional) OCIOProcessor(scene-linear → working)
}
↓
Update transformedImageData
↓
Apply display transform (display node)
```

## OCIO API Mapping

### Color Space Mode
```cpp
// C++ equivalent
OCIO::ConstProcessorRcPtr processor = 
    config->getProcessor(sourceSpace, destinationSpace);
```

### Inverse Display Mode
```cpp
// C++ equivalent
OCIO::DisplayViewTransformRcPtr transform = 
    OCIO::DisplayViewTransform::Create();

transform->setSrc(scene_linear_role);  // Destination in inverse
transform->setDisplay(display);
transform->setView(view);
transform->setDirection(OCIO::TRANSFORM_DIR_INVERSE);  // KEY!

OCIO::ConstProcessorRcPtr processor = 
    config->getProcessor(transform);
```

## State Management

```swift
@Observable class ImageManager {
    // Mode selection
    var sourceTransformMode: SourceTransformMode = .colorspace
    
    // Color Space mode properties (existing)
    // (selectedSourceSpace is in ColorPipelineNodeView)
    
    // Inverse Display mode properties (new)
    var sourceInverseDisplay: String = ""
    var sourceInverseView: String = ""
    
    // Transform result
    var colorTransform: ColorTransform?
    // Stores: sourceColorSpace, destinationColorSpace, display?, view?
}
```

## Error Handling

```swift
try applyColorTransform(from:to:)
    ↓
    switch mode {
        case .colorspace:
            if sourceSpace == destSpace → no-op
            if invalid spaces → OCIO error
        
        case .inverseDisplay:
            if display.isEmpty || view.isEmpty 
                → throw .invalidInverseDisplayConfig
            if transform cannot be inverted
                → OCIO error (non-invertible transform)
    }
```

## Use Case: Loading SDR Reference for HDR Grading

```
1. User loads SDR screenshot (sRGB, Rec.709, gamma 2.2)
   ┌────────────────────┐
   │ SDR Screenshot     │
   │ Values: 0.0 - 1.0  │
   └────────────────────┘

2. Set Source Node to "Inverse Display" mode
   Display: "sRGB"
   View: "sRGB EOTF"
   
3. Inverse transform applied
   ┌────────────────────┐
   │ Scene-Linear AP0   │
   │ Values: 0.0 - 1.0  │ ← Now in linear light
   └────────────────────┘
   
4. Working Space: ACES2065-1 (identity or minimal transform)
   
5. Display Node: HDR output
   Display: "ACES"
   View: "ACES 1.0 - HDR 1000 nits"
   
6. Result:
   ┌────────────────────┐
   │ HDR Display        │
   │ SDR reference now  │
   │ correctly mapped   │
   │ to HDR space       │
   └────────────────────┘
```

## Benefits Summary

✅ **ACES 2.0 Ready**: Handles configs where display transforms ≠ colorspaces
✅ **Flexible Pipeline**: Convert display-referred → scene-linear → display
✅ **Reference Workflow**: Load SDR/HDR refs for comparison
✅ **Clean UX**: Clear mode toggle, no confusion
✅ **Validation**: Proper error handling for incomplete configs
✅ **Future-Proof**: Works with modern and legacy OCIO configs
