#!/bin/bash
# fix_frameworks.sh
# Fix frameworks by ensuring they have the actual binary code

set -e

echo "🔧 Fixing Framework Binaries"
echo "============================="
echo ""

# Try to find Frameworks directory
if [ -d "./Frameworks" ]; then
    FRAMEWORKS_DIR="./Frameworks"
elif [ -d "../Frameworks" ]; then
    FRAMEWORKS_DIR="../Frameworks"
elif [ -d "Frameworks" ]; then
    FRAMEWORKS_DIR="Frameworks"
else
    echo "❌ Frameworks directory not found!"
    echo ""
    echo "Please run this script from:"
    echo "  - The same directory as the Frameworks folder"
    echo ""
    echo "Current directory: $(pwd)"
    echo "Contents:"
    ls -la
    exit 1
fi

echo "Using Frameworks directory: $FRAMEWORKS_DIR"
echo ""

HOMEBREW_PREFIX="/opt/homebrew"

echo "Step 1: Fix OpenImageIO.3.1.framework..."

OIIO_FW="$FRAMEWORKS_DIR/OpenImageIO.3.1.framework"
OIIO_BINARY="$OIIO_FW/Versions/A/OpenImageIO.3.1"
OIIO_SOURCE="$HOMEBREW_PREFIX/lib/libOpenImageIO.3.1.dylib"

# Resolve if source is a symlink
if [ -L "$OIIO_SOURCE" ]; then
    OIIO_REAL=$(readlink "$OIIO_SOURCE")
    if [ "${OIIO_REAL:0:1}" != "/" ]; then
        # Relative path, make absolute
        OIIO_SOURCE="$(dirname $OIIO_SOURCE)/$OIIO_REAL"
    else
        OIIO_SOURCE="$OIIO_REAL"
    fi
    echo "  Source is symlink, using real file: $OIIO_SOURCE"
fi

if [ ! -f "$OIIO_SOURCE" ]; then
    echo "  ❌ Source not found: $OIIO_SOURCE"
    exit 1
fi

if [ -f "$OIIO_BINARY" ]; then
    echo "  Replacing binary..."
    rm -f "$OIIO_BINARY"
fi

# Copy the REAL binary
cp "$OIIO_SOURCE" "$OIIO_BINARY"
chmod +x "$OIIO_BINARY"

# Fix install name
install_name_tool -id "@rpath/OpenImageIO.3.1.framework/Versions/A/OpenImageIO.3.1" "$OIIO_BINARY"

# Verify
SIZE=$(du -h "$OIIO_BINARY" | cut -f1)
SYMBOLS=$(nm -gU "$OIIO_BINARY" 2>/dev/null | grep -c "OpenImageIO" || echo "0")
echo "  ✅ Fixed! Size: $SIZE, Symbols: $SYMBOLS"

echo ""
echo "Step 2: Fix OpenColorIO.2.5.framework..."

OCIO_FW="$FRAMEWORKS_DIR/OpenColorIO.2.5.framework"
OCIO_BINARY="$OCIO_FW/Versions/A/OpenColorIO.2.5"
OCIO_SOURCE="$HOMEBREW_PREFIX/lib/libOpenColorIO.2.5.dylib"

# Resolve if source is a symlink
if [ -L "$OCIO_SOURCE" ]; then
    OCIO_REAL=$(readlink "$OCIO_SOURCE")
    if [ "${OCIO_REAL:0:1}" != "/" ]; then
        # Relative path, make absolute
        OCIO_SOURCE="$(dirname $OCIO_SOURCE)/$OCIO_REAL"
    else
        OCIO_SOURCE="$OCIO_REAL"
    fi
    echo "  Source is symlink, using real file: $OCIO_SOURCE"
fi

if [ ! -f "$OCIO_SOURCE" ]; then
    echo "  ❌ Source not found: $OCIO_SOURCE"
    exit 1
fi

if [ -f "$OCIO_BINARY" ]; then
    echo "  Replacing binary..."
    rm -f "$OCIO_BINARY"
fi

# Copy the REAL binary
cp "$OCIO_SOURCE" "$OCIO_BINARY"
chmod +x "$OCIO_BINARY"

# Fix install name
install_name_tool -id "@rpath/OpenColorIO.2.5.framework/Versions/A/OpenColorIO.2.5" "$OCIO_BINARY"

# Verify
SIZE=$(du -h "$OCIO_BINARY" | cut -f1)
SYMBOLS=$(nm -gU "$OCIO_BINARY" 2>/dev/null | grep -c "OpenColorIO" || echo "0")
echo "  ✅ Fixed! Size: $SIZE, Symbols: $SYMBOLS"

echo ""
echo "============================="
echo "✅ Frameworks fixed!"
echo ""
echo "Now in Xcode:"
echo "1. Clean Build Folder (⌘⇧K)"
echo "2. Build (⌘B)"
echo ""
