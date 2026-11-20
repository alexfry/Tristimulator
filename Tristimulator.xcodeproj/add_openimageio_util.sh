#!/bin/bash
# add_openimageio_util.sh
# Add the missing OpenImageIO_Util library

set -e

echo "🔧 Adding OpenImageIO_Util Library"
echo "==================================="
echo ""

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    HOMEBREW_PREFIX="/opt/homebrew"
elif [ "$ARCH" = "x86_64" ]; then
    HOMEBREW_PREFIX="/usr/local"
else
    HOMEBREW_PREFIX=$(brew --prefix)
fi

DYLIBS_DIR="./Dylibs"
SIGNING_IDENTITY="Apple Development: Alex Fry (7CART63SAF)"

# Check if Dylibs directory exists
if [ ! -d "$DYLIBS_DIR" ]; then
    echo "❌ Dylibs directory not found: $DYLIBS_DIR"
    echo "   Run ./embed_dylibs_simple.sh first"
    exit 1
fi

# Find OpenImageIO_Util library
UTIL_LIB="$HOMEBREW_PREFIX/lib/libOpenImageIO_Util.dylib"

if [ ! -f "$UTIL_LIB" ]; then
    # Try versioned
    UTIL_LIB="$HOMEBREW_PREFIX/lib/libOpenImageIO_Util.3.1.dylib"
    if [ ! -f "$UTIL_LIB" ]; then
        echo "❌ OpenImageIO_Util library not found"
        echo "   Checked:"
        echo "   - $HOMEBREW_PREFIX/lib/libOpenImageIO_Util.dylib"
        echo "   - $HOMEBREW_PREFIX/lib/libOpenImageIO_Util.3.1.dylib"
        exit 1
    fi
fi

echo "Found: $UTIL_LIB"
echo ""

# Get the library name
LIB_NAME=$(basename "$UTIL_LIB")

# Check if already copied
if [ -f "$DYLIBS_DIR/$LIB_NAME" ]; then
    echo "⚠️  $LIB_NAME already exists in Dylibs/"
    read -p "Replace it? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping."
        exit 0
    fi
fi

echo "Step 1: Copying library..."
# Follow symlinks to get actual file
if [ -L "$UTIL_LIB" ]; then
    REAL_LIB=$(readlink -f "$UTIL_LIB" 2>/dev/null || greadlink -f "$UTIL_LIB" 2>/dev/null || echo "$UTIL_LIB")
    cp "$REAL_LIB" "$DYLIBS_DIR/$LIB_NAME"
else
    cp "$UTIL_LIB" "$DYLIBS_DIR/$LIB_NAME"
fi

chmod +w "$DYLIBS_DIR/$LIB_NAME"
echo "  ✅ Copied $LIB_NAME"
echo ""

echo "Step 2: Fixing install name..."
install_name_tool -id "@rpath/$LIB_NAME" "$DYLIBS_DIR/$LIB_NAME" 2>/dev/null || true

# Fix dependencies
DEPS=$(otool -L "$DYLIBS_DIR/$LIB_NAME" | grep -E "($HOMEBREW_PREFIX|/usr/local)" | awk '{print $1}' || true)

for dep in $DEPS; do
    dep_name=$(basename "$dep")
    if [ -f "$DYLIBS_DIR/$dep_name" ]; then
        install_name_tool -change "$dep" "@rpath/$dep_name" "$DYLIBS_DIR/$LIB_NAME" 2>/dev/null || true
    fi
done

echo "  ✅ Install name fixed"
echo ""

echo "Step 3: Signing library..."
xattr -cr "$DYLIBS_DIR/$LIB_NAME" 2>/dev/null || true

if codesign --force --sign "$SIGNING_IDENTITY" \
            --timestamp \
            --options runtime \
            "$DYLIBS_DIR/$LIB_NAME" 2>/dev/null; then
    echo "  ✅ Signed successfully"
else
    echo "  ⚠️  Signing failed, but continuing..."
fi
echo ""

echo "Step 4: Verifying..."
if codesign --verify --deep --strict "$DYLIBS_DIR/$LIB_NAME" 2>/dev/null; then
    echo "  ✅ Verification passed"
else
    echo "  ⚠️  Verification failed"
fi
echo ""

echo "==================================="
echo "✅ OpenImageIO_Util added!"
echo "==================================="
echo ""
echo "📋 Next Steps in Xcode:"
echo ""
echo "1. Add to Copy Files phase:"
echo "   • Build Phases → Copy Dylibs"
echo "   • Click '+' to add files"
echo "   • Select: Dylibs/$LIB_NAME"
echo "   • Make sure 'Code Sign On Copy' is checked"
echo ""
echo "2. Add to linker flags:"
echo "   • Build Settings → Other Linker Flags"
echo "   • Add: -lOpenImageIO_Util"
echo ""
echo "   Should look like:"
echo "   -lOpenImageIO"
echo "   -lOpenImageIO_Util"
echo "   -lOpenColorIO"
echo ""
echo "3. Clean and rebuild:"
echo "   • Clean Build Folder (⌘⇧K)"
echo "   • Build (⌘B)"
echo ""
