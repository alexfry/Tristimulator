#!/bin/bash
# fix_headers_symlinks.sh
# Fix broken symlinks - copy actual header files

set -e

echo "🔧 Fixing Header Symlinks"
echo "========================="
echo ""

PROJECT_INCLUDE="./Include"

# Remove the broken symlinks
echo "Removing broken symlinks..."
rm -rf "$PROJECT_INCLUDE/OpenImageIO"
rm -rf "$PROJECT_INCLUDE/OpenColorIO"

# Detect Homebrew
if [ -d "/opt/homebrew" ]; then
    BREW_PREFIX="/opt/homebrew"
elif [ -d "/usr/local" ]; then
    BREW_PREFIX="/usr/local"
else
    echo "❌ Homebrew not found"
    exit 1
fi

echo "Copying real files from: $BREW_PREFIX/include"
echo ""

# Copy following symlinks with -L flag
echo "📦 Copying OpenImageIO headers (following symlinks)..."
cp -RL "$BREW_PREFIX/include/OpenImageIO" "$PROJECT_INCLUDE/"
echo "   ✅ Done"

echo "📦 Copying OpenColorIO headers (following symlinks)..."
cp -RL "$BREW_PREFIX/include/OpenColorIO" "$PROJECT_INCLUDE/"
echo "   ✅ Done"

echo ""
echo "Verifying files are real (not symlinks)..."
echo ""

# Check a few key files
if [ -f "$PROJECT_INCLUDE/OpenImageIO/imageio.h" ] && [ ! -L "$PROJECT_INCLUDE/OpenImageIO/imageio.h" ]; then
    echo "✅ OpenImageIO/imageio.h is a real file"
else
    echo "❌ OpenImageIO/imageio.h is still a symlink or missing"
    exit 1
fi

if [ -f "$PROJECT_INCLUDE/OpenColorIO/OpenColorIO.h" ] && [ ! -L "$PROJECT_INCLUDE/OpenColorIO/OpenColorIO.h" ]; then
    echo "✅ OpenColorIO/OpenColorIO.h is a real file"
else
    echo "❌ OpenColorIO/OpenColorIO.h is still a symlink or missing"
    exit 1
fi

echo ""
echo "📊 Summary:"
OIIO_COUNT=$(find "$PROJECT_INCLUDE/OpenImageIO" -type f \( -name "*.h" -o -name "*.hpp" -o -name "*.cpp" \) | wc -l | tr -d ' ')
OCIO_COUNT=$(find "$PROJECT_INCLUDE/OpenColorIO" -type f \( -name "*.h" -o -name "*.hpp" \) | wc -l | tr -d ' ')

echo "  • OpenImageIO: $OIIO_COUNT files"
echo "  • OpenColorIO: $OCIO_COUNT files"
echo ""

echo "================================================"
echo "✅ Headers fixed!"
echo "================================================"
echo ""
echo "Now in Xcode:"
echo ""
echo "1. Build Settings → Header Search Paths"
echo "   Set to: \$(PROJECT_DIR)/Include"
echo ""
echo "2. Clean (⌘⇧K)"
echo ""
echo "3. Build (⌘B)"
echo ""
echo "Your #include statements will now find real files!"
echo ""
