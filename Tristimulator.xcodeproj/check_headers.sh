#!/bin/bash
# check_headers.sh
# Verify OpenImageIO and OpenColorIO headers are accessible

echo "🔍 Checking OpenImageIO/OpenColorIO Headers"
echo "==========================================="
echo ""

# Check Homebrew prefix
if [ -d "/opt/homebrew" ]; then
    BREW_PREFIX="/opt/homebrew"
elif [ -d "/usr/local" ]; then
    BREW_PREFIX="/usr/local"
else
    echo "❌ Homebrew not found"
    exit 1
fi

echo "Homebrew prefix: $BREW_PREFIX"
echo ""

# Check for headers in standard location
echo "1️⃣ Checking standard include path..."
echo ""

if [ -f "$BREW_PREFIX/include/OpenImageIO/imageio.h" ]; then
    echo "✅ OpenImageIO headers found:"
    echo "   $BREW_PREFIX/include/OpenImageIO/imageio.h"
else
    echo "❌ OpenImageIO headers NOT found at standard location"
    echo "   Expected: $BREW_PREFIX/include/OpenImageIO/imageio.h"
fi

if [ -f "$BREW_PREFIX/include/OpenColorIO/OpenColorIO.h" ]; then
    echo "✅ OpenColorIO headers found:"
    echo "   $BREW_PREFIX/include/OpenColorIO/OpenColorIO.h"
else
    echo "❌ OpenColorIO headers NOT found at standard location"
    echo "   Expected: $BREW_PREFIX/include/OpenColorIO/OpenColorIO.h"
fi

echo ""
echo "2️⃣ Searching all Homebrew locations..."
echo ""

OIIO_HEADER=$(find "$BREW_PREFIX" -name "imageio.h" 2>/dev/null | head -1)
OCIO_HEADER=$(find "$BREW_PREFIX" -name "OpenColorIO.h" 2>/dev/null | head -1)

if [ -n "$OIIO_HEADER" ]; then
    echo "📁 OpenImageIO header found at:"
    echo "   $OIIO_HEADER"
    OIIO_INCLUDE_DIR=$(dirname $(dirname "$OIIO_HEADER"))
    echo "   → Include directory: $OIIO_INCLUDE_DIR"
else
    echo "❌ OpenImageIO header not found anywhere in Homebrew"
fi

echo ""

if [ -n "$OCIO_HEADER" ]; then
    echo "📁 OpenColorIO header found at:"
    echo "   $OCIO_HEADER"
    OCIO_INCLUDE_DIR=$(dirname $(dirname "$OCIO_HEADER"))
    echo "   → Include directory: $OCIO_INCLUDE_DIR"
else
    echo "❌ OpenColorIO header not found anywhere in Homebrew"
fi

echo ""
echo "3️⃣ Checking installed packages..."
echo ""

if brew list openimageio &>/dev/null; then
    echo "✅ openimageio is installed"
    brew list openimageio | grep -E "\.(h|hpp)$" | head -5
    echo "   ... (showing first 5 headers)"
else
    echo "❌ openimageio is NOT installed"
    echo "   Install with: brew install openimageio"
fi

echo ""

if brew list opencolorio &>/dev/null; then
    echo "✅ opencolorio is installed"
    brew list opencolorio | grep -E "\.(h|hpp)$" | head -5
    echo "   ... (showing first 5 headers)"
else
    echo "❌ opencolorio is NOT installed"
    echo "   Install with: brew install opencolorio"
fi

echo ""
echo "================================================"
echo "📋 XCODE CONFIGURATION RECOMMENDATION"
echo "================================================"
echo ""

if [ -f "$BREW_PREFIX/include/OpenImageIO/imageio.h" ] && [ -f "$BREW_PREFIX/include/OpenColorIO/OpenColorIO.h" ]; then
    echo "✅ Headers are in standard location!"
    echo ""
    echo "Set in Xcode Build Settings:"
    echo ""
    echo "Header Search Paths:"
    echo "  $BREW_PREFIX/include"
    echo "  \$(inherited)"
    echo ""
    echo "Make sure this is set for:"
    echo "  • ALL configurations (Debug and Release)"
    echo "  • At the TARGET level (not project level)"
    echo "  • For 'Any Architecture | Any SDK'"
else
    echo "⚠️  Headers are NOT in standard location!"
    echo ""
    if [ -n "$OIIO_HEADER" ] && [ -n "$OCIO_HEADER" ]; then
        echo "Set in Xcode Build Settings:"
        echo ""
        echo "Header Search Paths:"
        if [ "$OIIO_INCLUDE_DIR" = "$OCIO_INCLUDE_DIR" ]; then
            echo "  $OIIO_INCLUDE_DIR"
        else
            echo "  $OIIO_INCLUDE_DIR"
            echo "  $OCIO_INCLUDE_DIR"
        fi
        echo "  \$(inherited)"
    else
        echo "You may need to reinstall the packages:"
        echo "  brew reinstall openimageio opencolorio"
    fi
fi

echo ""
echo "================================================"
echo "🔧 QUICK TESTS"
echo "================================================"
echo ""

# Test if compiler can find headers
echo "Testing if clang can find headers..."
echo ""

cat > /tmp/test_oiio.mm << 'EOF'
#include <OpenImageIO/imageio.h>
int main() { return 0; }
EOF

if clang++ -I"$BREW_PREFIX/include" /tmp/test_oiio.mm -o /tmp/test_oiio &>/dev/null; then
    echo "✅ Compiler CAN find OpenImageIO headers with -I$BREW_PREFIX/include"
else
    echo "❌ Compiler CANNOT find OpenImageIO headers even with -I$BREW_PREFIX/include"
    echo "   This indicates a deeper problem with the installation"
fi

rm -f /tmp/test_oiio.mm /tmp/test_oiio

echo ""
echo "================================================"
echo ""
echo "If headers are found but Xcode Archive still fails:"
echo ""
echo "1. Clean Build Folder (⌘⇧K)"
echo "2. Delete DerivedData:"
echo "   rm -rf ~/Library/Developer/Xcode/DerivedData/Tristimulator-*"
echo "3. Restart Xcode"
echo "4. Try Archive again"
echo ""
