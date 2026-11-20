#!/bin/bash
# build_self_contained.sh
# Build fully self-contained static libraries with headers for Tristimulator
# No Homebrew dependencies at runtime or archive time

set -e

echo "🎯 Self-Contained Tristimulator Build Script"
echo "=========================================="
echo ""
echo "Goal: Create a fully self-contained app with no external dependencies"
echo ""

# Configuration
PROJECT_ROOT="$PWD"
VENDOR_DIR="$PROJECT_ROOT/Vendor"
BUILD_DIR="$HOME/Tristimulator_StaticBuild"
ARCH=$(uname -m)

# Detect Homebrew (needed only for initial build)
if [ -d "/opt/homebrew" ]; then
    BREW_PREFIX="/opt/homebrew"
elif [ -d "/usr/local" ]; then
    BREW_PREFIX="/usr/local"
else
    echo "❌ Homebrew required for building (but won't be needed at runtime)"
    echo "   Install from: https://brew.sh"
    exit 1
fi

echo "📋 Configuration:"
echo "  Project root: $PROJECT_ROOT"
echo "  Vendor directory: $VENDOR_DIR"
echo "  Build directory: $BUILD_DIR"
echo "  Architecture: $ARCH"
echo "  Homebrew: $BREW_PREFIX (build-time only)"
echo ""

# Check prerequisites
echo "📦 Installing build prerequisites..."
echo ""

for pkg in cmake ninja; do
    if ! command -v $pkg &> /dev/null; then
        echo "Installing $pkg..."
        brew install $pkg
    else
        echo "✅ $pkg already installed"
    fi
done

echo ""

# Create directories
mkdir -p "$VENDOR_DIR"
mkdir -p "$BUILD_DIR"

echo "⏱️  This will take 30-60 minutes. Continue? (y/N)"
read -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "================================================"
echo "🔨 Building OpenImageIO (static + headers)"
echo "================================================"
echo ""

cd "$BUILD_DIR"

# Clean previous build
rm -rf oiio
rm -rf "$VENDOR_DIR/OpenImageIO"

echo "📥 Cloning OpenImageIO..."
git clone --depth 1 --branch v3.1.7.0 https://github.com/OpenImageIO/oiio.git
cd oiio

mkdir -p build
cd build

echo "⚙️  Configuring OpenImageIO..."
cmake .. \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DBUILD_SHARED_LIBS=OFF \
  -DLINKSTATIC=ON \
  -DUSE_PYTHON=OFF \
  -DUSE_OPENGL=OFF \
  -DUSE_QT=OFF \
  -DOIIO_BUILD_TOOLS=OFF \
  -DOIIO_BUILD_TESTS=OFF \
  -DBUILD_TESTING=OFF \
  -DSTOP_ON_WARNING=OFF \
  -DCMAKE_INSTALL_PREFIX="$VENDOR_DIR/OpenImageIO" \
  -DCMAKE_PREFIX_PATH="$BREW_PREFIX"

echo "🔨 Building OpenImageIO (this takes ~15-20 minutes)..."
ninja -j$(sysctl -n hw.ncpu)

echo "📦 Installing OpenImageIO to Vendor directory..."
ninja install

echo "✅ OpenImageIO built successfully"
echo ""

# Verify
OIIO_HEADER="$VENDOR_DIR/OpenImageIO/include/OpenImageIO/imageio.h"

if [ ! -f "$OIIO_HEADER" ]; then
    echo "❌ Headers not found: $OIIO_HEADER"
    exit 1
fi

# Check for static library (.a) or dynamic library (.dylib)
OIIO_LIB_STATIC="$VENDOR_DIR/OpenImageIO/lib/libOpenImageIO.a"
OIIO_LIB_DYNAMIC="$VENDOR_DIR/OpenImageIO/lib/libOpenImageIO.dylib"

if [ -f "$OIIO_LIB_STATIC" ]; then
    echo "✅ Found static library: $OIIO_LIB_STATIC"
    OIIO_LIB="$OIIO_LIB_STATIC"
    OIIO_LIB_TYPE="static"
elif [ -f "$OIIO_LIB_DYNAMIC" ]; then
    echo "⚠️  Found dynamic library: $OIIO_LIB_DYNAMIC"
    echo "   (Static build failed, but we can still use this)"
    OIIO_LIB="$OIIO_LIB_DYNAMIC"
    OIIO_LIB_TYPE="dynamic"
else
    echo "❌ No library found in: $VENDOR_DIR/OpenImageIO/lib/"
    ls -la "$VENDOR_DIR/OpenImageIO/lib/" || true
    exit 1
fi

echo "✅ Verified:"
echo "   Library: $OIIO_LIB ($(du -h "$OIIO_LIB" | cut -f1)) [$OIIO_LIB_TYPE]"
echo "   Headers: $VENDOR_DIR/OpenImageIO/include/OpenImageIO/"
ls "$VENDOR_DIR/OpenImageIO/include/OpenImageIO/" | head -5
echo "   ... ($(ls "$VENDOR_DIR/OpenImageIO/include/OpenImageIO/" | wc -l | tr -d ' ') header files)"
echo ""

echo "================================================"
echo "🔨 Building OpenColorIO (static + headers)"
echo "================================================"
echo ""

cd "$BUILD_DIR"

# Clean previous build
rm -rf OpenColorIO
rm -rf "$VENDOR_DIR/OpenColorIO"

echo "📥 Cloning OpenColorIO..."
git clone --depth 1 --branch v2.5.0 https://github.com/AcademySoftwareFoundation/OpenColorIO.git
cd OpenColorIO

mkdir -p build
cd build

echo "⚙️  Configuring OpenColorIO..."
cmake .. \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DBUILD_SHARED_LIBS=OFF \
  -DOCIO_BUILD_APPS=OFF \
  -DOCIO_BUILD_PYTHON=OFF \
  -DOCIO_BUILD_TESTS=OFF \
  -DOCIO_BUILD_GPU_TESTS=OFF \
  -DBUILD_TESTING=OFF \
  -DOCIO_INSTALL_EXT_PACKAGES=NONE \
  -DCMAKE_INSTALL_PREFIX="$VENDOR_DIR/OpenColorIO" \
  -DCMAKE_PREFIX_PATH="$BREW_PREFIX"

echo "🔨 Building OpenColorIO (this takes ~10-15 minutes)..."
ninja -j$(sysctl -n hw.ncpu)

echo "📦 Installing OpenColorIO to Vendor directory..."
ninja install

echo "✅ OpenColorIO built successfully"
echo ""

# Verify
OCIO_HEADER="$VENDOR_DIR/OpenColorIO/include/OpenColorIO/OpenColorIO.h"

if [ ! -f "$OCIO_HEADER" ]; then
    echo "❌ Headers not found: $OCIO_HEADER"
    exit 1
fi

# Check for static library (.a) or dynamic library (.dylib)
OCIO_LIB_STATIC="$VENDOR_DIR/OpenColorIO/lib/libOpenColorIO.a"
OCIO_LIB_DYNAMIC="$VENDOR_DIR/OpenColorIO/lib/libOpenColorIO.dylib"

if [ -f "$OCIO_LIB_STATIC" ]; then
    echo "✅ Found static library: $OCIO_LIB_STATIC"
    OCIO_LIB="$OCIO_LIB_STATIC"
    OCIO_LIB_TYPE="static"
elif [ -f "$OCIO_LIB_DYNAMIC" ]; then
    echo "⚠️  Found dynamic library: $OCIO_LIB_DYNAMIC"
    echo "   (Static build failed, but we can still use this)"
    OCIO_LIB="$OCIO_LIB_DYNAMIC"
    OCIO_LIB_TYPE="dynamic"
else
    echo "❌ No library found in: $VENDOR_DIR/OpenColorIO/lib/"
    ls -la "$VENDOR_DIR/OpenColorIO/lib/" || true
    exit 1
fi

echo "✅ Verified:"
echo "   Library: $OCIO_LIB ($(du -h "$OCIO_LIB" | cut -f1)) [$OCIO_LIB_TYPE]"
echo "   Headers: $VENDOR_DIR/OpenColorIO/include/OpenColorIO/"
ls "$VENDOR_DIR/OpenColorIO/include/OpenColorIO/" | head -5
echo "   ... ($(ls "$VENDOR_DIR/OpenColorIO/include/OpenColorIO/" | wc -l | tr -d ' ') header files)"
echo ""

# Check for utility library
OIIO_UTIL_LIB_STATIC="$VENDOR_DIR/OpenImageIO/lib/libOpenImageIO_Util.a"
OIIO_UTIL_LIB_DYNAMIC="$VENDOR_DIR/OpenImageIO/lib/libOpenImageIO_Util.dylib"

if [ -f "$OIIO_UTIL_LIB_STATIC" ]; then
    echo "✅ Found OpenImageIO_Util (static): $OIIO_UTIL_LIB_STATIC"
elif [ -f "$OIIO_UTIL_LIB_DYNAMIC" ]; then
    echo "✅ Found OpenImageIO_Util (dynamic): $OIIO_UTIL_LIB_DYNAMIC"
else
    echo "⚠️  OpenImageIO_Util library not found (may be combined into main library)"
fi
echo ""

# Create summary
echo "================================================"
echo "✅ BUILD COMPLETE - Now Configure Xcode"
echo "================================================"
echo ""

echo "📊 Summary:"
echo "  • All libraries and headers are in: $VENDOR_DIR"
echo "  • No Homebrew dependencies at runtime"
echo "  • No dynamic libraries to embed"
echo "  • Ready for archive/distribution"
echo ""

TOTAL_SIZE=$(du -sh "$VENDOR_DIR" | cut -f1)
echo "  Total vendor size: $TOTAL_SIZE"
echo ""

# Create Xcode configuration guide
CONFIG_FILE="$PROJECT_ROOT/XCODE_CONFIGURATION.md"
cat > "$CONFIG_FILE" << 'XCODE_CONFIG'
# Xcode Configuration for Self-Contained Build

## Overview
Your project now has all dependencies in the `Vendor/` directory:
- Static libraries (`.a` files)
- Headers (`.h`/`.hpp` files)
- No external dependencies needed

## Required Xcode Build Settings

### 1. Header Search Paths

**Setting:** `HEADER_SEARCH_PATHS`

**Value:**
```
$(PROJECT_DIR)/Vendor/OpenImageIO/include
$(PROJECT_DIR)/Vendor/OpenColorIO/include
$(inherited)
```

**Where to set:**
- Target: Tristimulator (not project level)
- Configuration: All (Debug and Release)
- Platform: Any Architecture | Any SDK

**How to set:**
1. Select Tristimulator target
2. Build Settings tab
3. Search: "Header Search Paths"
4. Double-click to edit
5. Add the two paths above
6. Make sure they appear for ALL configurations

### 2. Library Search Paths

**Setting:** `LIBRARY_SEARCH_PATHS`

**Value:**
```
$(PROJECT_DIR)/Vendor/OpenImageIO/lib
$(PROJECT_DIR)/Vendor/OpenColorIO/lib
$(inherited)
```

**Remove** any references to:
- `/opt/homebrew/lib`
- `/usr/local/lib`
- `$(PROJECT_DIR)/Dylibs`

### 3. Other Linker Flags

**Setting:** `OTHER_LDFLAGS`

**Value:**
```
-lOpenImageIO
-lOpenImageIO_Util
-lOpenColorIO
-lc++
-lz
-framework Foundation
-framework AppKit
-framework Metal
-framework CoreGraphics
```

**Remove** any duplicate `-l` flags that cause warnings.

### 4. Remove Dynamic Library Phases

Since we're using static libraries, you don't need:

1. **Remove "Copy Dylibs" phase** (if it exists)
   - Build Phases → Delete any "Copy Files" phase copying `.dylib` files

2. **Remove dylib embedding scripts** (if they exist)
   - Build Phases → Delete any "Run Script" phases doing dylib work

### 5. Clean Up Project

**Remove these if they exist:**
- `Dylibs/` directory (no longer needed)
- Any embedded `.dylib` files in your project navigator

## Verification Steps

### Step 1: Clean Everything
```bash
# In Xcode
⌘⇧K (Product → Clean Build Folder)

# Then in Terminal
rm -rf ~/Library/Developer/Xcode/DerivedData/Tristimulator-*
```

### Step 2: Build (Debug)
```bash
⌘B (Product → Build)
```

**Expected result:**
- ✅ Build succeeds with no warnings
- ✅ No "library not found" errors
- ✅ No "file not found" errors for headers

### Step 3: Run
```bash
⌘R (Product → Run)
```

**Expected result:**
- ✅ App launches
- ✅ Can load images
- ✅ No crashes on startup

### Step 4: Archive
```bash
Product → Archive
```

**Expected result:**
- ✅ Archive succeeds
- ✅ No linker errors
- ✅ No undefined symbols
- ✅ Ready for distribution

### Step 5: Verify Independence

Check that the built app has no Homebrew dependencies:

```bash
# After building
otool -L ~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug/Tristimulator.app/Contents/MacOS/Tristimulator
```

**Should NOT see:**
- `/opt/homebrew/lib/...`
- `/usr/local/lib/...`

**Should ONLY see:**
- System frameworks (`/System/Library/...`)
- `@rpath/...` (if any)
- Built-in libraries

## Troubleshooting

### "OpenImageIO/imageio.h file not found"

**Cause:** Header search paths not set correctly

**Fix:**
1. Check Header Search Paths includes `$(PROJECT_DIR)/Vendor/OpenImageIO/include`
2. Make sure it's set for the TARGET, not just project
3. Make sure it's set for ALL configurations
4. Clean build folder and try again

### "library not found for -lOpenImageIO"

**Cause:** Library search paths not set correctly

**Fix:**
1. Check Library Search Paths includes `$(PROJECT_DIR)/Vendor/OpenImageIO/lib`
2. Verify the `.a` files actually exist in `Vendor/OpenImageIO/lib/`
3. Clean and rebuild

### "Undefined symbols" errors

**Cause:** Missing dependency libraries

**Fix:**
1. Add `-lz` to Other Linker Flags (for zlib)
2. Add `-lc++` (for C++ standard library)
3. Make sure `-lOpenImageIO_Util` is included
4. Check that static libraries are for the correct architecture

### Archive succeeds but app crashes on launch

**Cause:** Missing runtime resources or entitlements

**Fix:**
1. Check that all frameworks are linked
2. Add com.apple.security.cs.allow-unsigned-executable-memory entitlement if needed
3. Check Console.app for crash logs

## Distribution Checklist

Before distributing your app:

- [ ] Archive builds successfully
- [ ] App runs from Archive build
- [ ] No Homebrew dependencies in binary (`otool -L`)
- [ ] Code signing works
- [ ] Notarization works (if distributing outside App Store)
- [ ] App bundle is self-contained
- [ ] All required resources are included

## File Structure

Your project should now look like:

```
Tristimulator/
├── Tristimulator.xcodeproj
├── Tristimulator/
│   ├── OpenImageIOBridge.h
│   ├── OpenImageIOBridge.mm  ← includes <OpenImageIO/imageio.h>
│   ├── OpenColorIOBridge.h
│   ├── OpenColorIOBridge.mm  ← includes <OpenColorIO/OpenColorIO.h>
│   └── ... other source files
├── Vendor/
│   ├── OpenImageIO/
│   │   ├── include/
│   │   │   └── OpenImageIO/
│   │   │       ├── imageio.h
│   │   │       ├── imagebuf.h
│   │   │       └── ... (all headers)
│   │   └── lib/
│   │       ├── libOpenImageIO.a
│   │       └── libOpenImageIO_Util.a
│   └── OpenColorIO/
│       ├── include/
│       │   └── OpenColorIO/
│       │       ├── OpenColorIO.h
│       │       └── ... (all headers)
│       └── lib/
│           └── libOpenColorIO.a
└── XCODE_CONFIGURATION.md  ← this file
```

## Benefits of This Approach

✅ **Self-contained:** No external dependencies
✅ **Archivable:** Works in Archive configuration
✅ **Distributable:** Can be notarized and distributed
✅ **Simple:** No dylib path manipulation needed
✅ **Portable:** Works on any Mac (same architecture)
✅ **Fast:** Static linking optimizes better

## Caveats

⚠️ **Build time:** Initial build takes 30-60 minutes
⚠️ **Binary size:** App will be larger (~50-100MB added)
⚠️ **Updates:** To update libraries, re-run `build_self_contained.sh`
⚠️ **Architecture:** Built for current architecture only (arm64 or x86_64)

For universal binary (arm64 + x86_64), you need to build twice and use `lipo`.

---

**Questions?** Check the main build script output or search for "static library xcode" documentation.
XCODE_CONFIG

echo "✅ Created configuration guide: $CONFIG_FILE"
echo ""

echo "================================================"
echo "🎯 NEXT STEPS"
echo "================================================"
echo ""
echo "1. Open your Xcode project"
echo ""
echo "2. Follow the instructions in:"
echo "   $CONFIG_FILE"
echo ""
echo "3. Key settings to change:"
echo "   • Header Search Paths: \$(PROJECT_DIR)/Vendor/.../include"
echo "   • Library Search Paths: \$(PROJECT_DIR)/Vendor/.../lib"
echo "   • Remove Homebrew paths (/opt/homebrew, /usr/local)"
echo "   • Remove any dylib copying build phases"
echo ""
echo "4. Clean build folder (⌘⇧K)"
echo ""
echo "5. Build (⌘B)"
echo ""
echo "6. Archive (Product → Archive)"
echo ""
echo "================================================"
echo ""
echo "🎉 Your app will now be fully self-contained!"
echo "   No Homebrew, no dylibs, no dependencies."
echo ""
