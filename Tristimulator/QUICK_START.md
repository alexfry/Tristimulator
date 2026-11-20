# Quick Start Guide - Building Tristimulator

## Current Status

The project is currently using **mock implementations** (`MockBridges.swift`) for OpenImageIO and OpenColorIO. This allows you to build and run the app immediately to test the UI and basic functionality.

The mock bridge supports loading standard image formats (PNG, JPEG, TIFF) using macOS's native image loading.

## Building Now (With Mocks)

1. **Just build and run!** ✅
   - The project should build successfully with the mock bridges
   - You can test the UI, exposure controls, and basic image loading
   - Works with PNG, JPEG, TIFF, and other standard formats

## Transitioning to Real Bridges

When you're ready to add full OpenImageIO and OpenColorIO support:

### Step 1: Install Dependencies

```bash
# Install OpenImageIO
brew install openimageio

# Install OpenColorIO  
brew install opencolorio

# Verify installation
brew list openimageio
brew list opencolorio
```

### Step 2: Configure Xcode Build Settings

1. **Add Header Search Paths**
   - Select your project in Xcode
   - Go to Build Settings
   - Search for "Header Search Paths"
   - Add these paths:
     ```
     /opt/homebrew/include
     /opt/homebrew/include/OpenImageIO
     /opt/homebrew/include/OpenColorIO
     ```
   - Make sure to mark them as **recursive** (double-click and add)

2. **Add Library Search Paths**
   - Search for "Library Search Paths"
   - Add:
     ```
     /opt/homebrew/lib
     ```

3. **Configure Bridging Header**
   - Search for "Objective-C Bridging Header"
   - Set to: `Tristimulator/Tristimulator-Bridging-Header.h`
   - (Adjust path based on your project structure)

4. **Link Binary with Libraries**
   - Go to Build Phases tab
   - Expand "Link Binary With Libraries"
   - Click + and choose "Add Other..." → "Add Files..."
   - Navigate to `/opt/homebrew/lib/`
   - Add:
     - `libOpenImageIO.dylib`
     - `libOpenColorIO.dylib`

5. **Add Other Linker Flags**
   - Back in Build Settings
   - Search for "Other Linker Flags"
   - Add:
     ```
     -lOpenImageIO
     -lOpenColorIO
     -lc++
     ```

6. **Set C++ Language Dialect**
   - Search for "C++ Language Dialect"
   - Set to: **C++17** or **GNU++17**

7. **Enable Modules**
   - Search for "Enable Modules"
   - Set to: **Yes**

### Step 3: Remove Mock Bridges

Once the real bridges are working:

1. **Delete MockBridges.swift** from your project
2. **Clean Build Folder** (Cmd+Shift+K)
3. **Rebuild** (Cmd+B)

### Step 4: Test with Real Images

Try loading:
- **EXR files** (HDR/high bit depth)
- **HDR files** (Radiance HDR)
- **DPX files** (Digital cinema)
- Camera RAW is not supported (LibRaw is not linked)

## Troubleshooting

### "Library not found" errors

If you get library not found errors at runtime:

```bash
# Check where Homebrew installed the libraries
brew --prefix openimageio
brew --prefix opencolorio

# If they're in a different location, update the paths
```

### Architecture mismatch (Intel vs Apple Silicon)

```bash
# Make sure libraries match your Mac architecture
file /opt/homebrew/lib/libOpenImageIO.dylib

# Should show: arm64 for Apple Silicon, x86_64 for Intel
```

If there's a mismatch, you may need to:
- Use `/usr/local` instead of `/opt/homebrew` (Intel Macs)
- Rebuild the libraries from source for your architecture

### Bridging header not found

- Make sure the path is relative to your project
- The file should be in your project directory
- Check the path in File Inspector (right panel in Xcode)

### Header files not found in .mm files

Make sure:
- Header Search Paths include `/opt/homebrew/include`
- The paths are marked as recursive
- You've done a clean build

## Signing Certificate Issue

For the signing error you mentioned:

1. **Select your project** in Xcode
2. **Go to Signing & Capabilities** tab
3. **Uncheck "Automatically manage signing"**
4. **Choose "Sign to Run Locally"**
5. Or: **Change Team** to your personal team or "None"

For development, you can:
- Use a personal development certificate
- Sign to run locally only
- Disable signing for debug builds

## Quick Fixes for Build Errors

### Error: Cannot find type 'OCIOConfig'

✅ **Fixed** - Using mock implementations now

When ready for real implementation:
- Ensure bridging header is configured
- Verify `OpenColorIOBridge.h` is in the bridging header
- Clean and rebuild

### Error: Value of type 'MTKView' has no member 'wantsExtendedDynamicRangeContent'

✅ **Fixed** - Removed this property (it's iOS-only)

EDR is automatically enabled on macOS when you use an extended color space.

## Testing EDR/HDR

To test if EDR is working:

1. **Run on a compatible Mac:**
   - MacBook Pro (2018 or later)
   - iMac Pro
   - Pro Display XDR
   - Any Mac with an XDR display

2. **Check the HDR indicator** in the toolbar

3. **Load an HDR image** (if available) or:
   - Create a test image with values > 1.0 in a graphics app
   - Adjust exposure to +5 stops on a regular image
   - Bright whites should appear brighter than UI elements

## What Works Now (With Mocks)

✅ UI and layout
✅ Image loading (standard formats)
✅ Exposure control
✅ Metal rendering
✅ Basic metadata display
✅ Scopes UI (data generation pending)

## What Requires Real Bridges

⏳ EXR/HDR/DPX format support
⏳ True HDR pixel data
⏳ OCIO color transforms
⏳ Advanced metadata
⏳ Professional color spaces
⏳ LUT support

## Next Steps

1. **Try building and running now** with the mocks
2. **Test the UI** and make any adjustments you want
3. **Install dependencies** when ready for full functionality
4. **Configure Xcode** following the steps above
5. **Remove MockBridges.swift** once real bridges work

## Getting Help

If you run into issues:

1. Check the full error message in Xcode
2. Verify library paths: `ls -l /opt/homebrew/lib/libOpenImageIO*`
3. Check header paths: `ls -l /opt/homebrew/include/OpenImageIO/`
4. Look at the detailed build log in Report Navigator

The mock implementation should get you up and running immediately. You can add the real bridges incrementally as you test!
