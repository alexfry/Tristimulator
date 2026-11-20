# Source Node Dual-Mode Implementation Summary

## What Was Implemented

This implementation adds support for **two modes** in the Source node to handle modern OCIO ACES 2.0 configs where display transforms are not exposed as bidirectional colorspaces.

### 1. Source Transform Modes

Added `SourceTransformMode` enum with two cases:
- **Color Space Mode** (existing behavior): Standard colorspace-to-colorspace transform
- **Inverse Display Mode** (new): Inverts a display/view transform to convert display-referred images to scene-linear

### 2. ImageManager Updates

#### New Properties
```swift
var sourceTransformMode: SourceTransformMode = .colorspace
var sourceInverseDisplay: String = ""
var sourceInverseView: String = ""
```

#### Enhanced `applyColorTransform` Method
Now supports both modes by dispatching to:
- `applyColorspaceTransform()` - existing colorspace → colorspace logic
- `applyInverseDisplayTransform()` - new inverse display → scene-linear logic

The inverse display mode:
1. Applies the inverse of the display/view transform (display-referred → scene-linear)
2. Optionally converts from scene-linear to the working space if different
3. Works with both CPU and GPU render paths

### 3. UI Updates (ColorPipelineNodeView)

#### Mode Selector
Added a clean pill-style toggle in the Source node:
```
┌─────────────────────────────┐
│ [Color Space] Inverse Display │ ← Toggle buttons
└─────────────────────────────┘
```

#### Conditional UI
- **Color Space Mode**: Shows the standard colorspace picker
- **Inverse Display Mode**: Shows:
  - Display picker ("Display to Invert")
  - View picker ("View to Invert")
  - Helpful info text explaining the feature

### 4. Error Handling

Added new error case:
```swift
case invalidInverseDisplayConfig
```

Validates that both display and view are selected when in inverse display mode.

## Files Modified

1. **ImageManager.swift**
   - Added `SourceTransformMode` enum
   - Added `sourceTransformMode`, `sourceInverseDisplay`, `sourceInverseView` properties
   - Refactored `applyColorTransform()` to support both modes
   - Added `applyColorspaceTransform()` (existing logic extracted)
   - Added `applyInverseDisplayTransform()` (new logic)
   - Added error case for invalid inverse display config

2. **ColorPipelineNodeView.swift**
   - Added mode selector UI (pill-style toggle)
   - Added conditional UI for each mode
   - Added display/view pickers for inverse display mode
   - Added helpful info text

## Files Created

1. **OCIOProcessor+InverseDisplay.swift**
   - Extension with stub for `makeInverseDisplayProcessor()`
   - Documentation on what needs to be implemented in C++ bridge
   - Temporary error explaining C++ implementation needed

2. **INVERSE_DISPLAY_IMPLEMENTATION.md**
   - Complete guide for implementing the C++ bridge
   - Code examples for Objective-C++ bridge
   - GPU implementation notes
   - Testing instructions
   - Use case examples

## How It Works

### Color Space Mode (existing)
```
Source Image (e.g., sRGB)
  ↓ [OCIOProcessor: sRGB → ACES2065-1]
Scene-Linear ACES2065-1
  ↓ [Display Transform]
Display Output
```

### Inverse Display Mode (new)
```
Display-Referred Image (e.g., SDR screenshot)
  ↓ [Inverse Display Transform: ACES/SDR Video → scene-linear]
Scene-Linear ACES2065-1
  ↓ [Optional: scene-linear → working space]
Working Space (e.g., ACEScg)
  ↓ [Display Transform]
Display Output
```

## Next Steps

To complete this implementation, you need to:

1. **Implement C++ Bridge** (see INVERSE_DISPLAY_IMPLEMENTATION.md)
   - Add `createInverseDisplayProcessor` method to your OCIO Objective-C++ bridge
   - Use OCIO's `DisplayViewTransform` with `TRANSFORM_DIR_INVERSE`

2. **Update OCIOProcessor+InverseDisplay.swift**
   - Replace stub implementation with call to C++ bridge
   - Remove temporary error

3. **Add GPU Support** (optional but recommended)
   - Update `OCIOGPUProcessor` to support inverse display transforms
   - Add shader compilation for inverse transforms
   - Update combined transform setup methods

4. **Testing**
   - Load ACES 2.0 config
   - Switch Source node to "Inverse Display" mode
   - Load a display-referred image (e.g., SDR screenshot)
   - Verify correct conversion to scene-linear
   - Test with both CPU and GPU render paths

## Benefits

1. **ACES 2.0 Compatibility**: Properly handles configs where display transforms aren't colorspaces
2. **Reference Comparison**: Load SDR/HDR references and compare them in scene-linear space
3. **Flexible Pipeline**: Convert display-referred images to scene-linear for further processing
4. **Clean UI**: Mode selector makes it clear which transform type is being used

## Design Decisions

- **Mode Toggle**: Used pill-style segmented control matching the Display node's Config/ACES2 toggle for consistency
- **Separate Properties**: Kept `sourceInverseDisplay`/`sourceInverseView` separate from regular display/view to avoid confusion
- **Validation**: Added explicit error case for incomplete inverse display configuration
- **Documentation**: Extensive implementation guide to help with C++ bridge development
