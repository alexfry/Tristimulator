#!/bin/bash
# fix_missing_versioned_dylibs.sh
# Find and add missing versioned dylibs

set -e

echo "🔧 Finding and Adding Missing Versioned Dylibs"
echo "==============================================="
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

# Check current state
echo "Step 1: Checking for OpenImageIO_Util versioned library..."
echo ""

# Check what we have in Dylibs/
echo "Current OpenImageIO_Util files in Dylibs/:"
ls -la "$DYLIBS_DIR" | grep -i "OpenImageIO_Util" || echo "  (none found)"
echo ""

# Check what's available in Homebrew
echo "Available in Homebrew:"
ls -la "$HOMEBREW_PREFIX/lib" | grep -i "OpenImageIO_Util" || echo "  (none found)"
echo ""

# The specific file we need
NEEDED_FILE="libOpenImageIO_Util.3.1.dylib"

if [ -f "$DYLIBS_DIR/$NEEDED_FILE" ]; then
    echo "✅ $NEEDED_FILE already exists in Dylibs/"
    echo ""
    echo "The file exists but might not be in Copy Files phase."
    echo "Check Xcode Build Phases → Copy Dylibs"
    exit 0
fi

# Try to find it in Homebrew
SOURCE_FILE=""

if [ -f "$HOMEBREW_PREFIX/lib/$NEEDED_FILE" ]; then
    SOURCE_FILE="$HOMEBREW_PREFIX/lib/$NEEDED_FILE"
elif [ -L "$HOMEBREW_PREFIX/lib/$NEEDED_FILE" ]; then
    # It's a symlink, follow it
    SOURCE_FILE=$(readlink -f "$HOMEBREW_PREFIX/lib/$NEEDED_FILE" 2>/dev/null || greadlink -f "$HOMEBREW_PREFIX/lib/$NEEDED_FILE" 2>/dev/null)
fi

if [ -z "$SOURCE_FILE" ] || [ ! -f "$SOURCE_FILE" ]; then
    echo "❌ Could not find $NEEDED_FILE in Homebrew"
    echo ""
    echo "Trying to find any OpenImageIO_Util library..."
    
    # Look for any version
    UTIL_FILES=$(find "$HOMEBREW_PREFIX/lib" -name "libOpenImageIO_Util*.dylib" 2>/dev/null || true)
    
    if [ -n "$UTIL_FILES" ]; then
        echo "Found these:"
        echo "$UTIL_FILES"
        echo ""
        echo "You may need to update OpenImageIO:"
        echo "  brew upgrade openimageio"
    else
        echo "No OpenImageIO_Util libraries found at all!"
        echo "Try:"
        echo "  brew reinstall openimageio"
    fi
    exit 1
fi

echo "Found source: $SOURCE_FILE"
echo ""

echo "Step 2: Copying to Dylibs/..."
cp "$SOURCE_FILE" "$DYLIBS_DIR/$NEEDED_FILE"
chmod +w "$DYLIBS_DIR/$NEEDED_FILE"
echo "  ✅ Copied"
echo ""

echo "Step 3: Fixing install name..."
install_name_tool -id "@rpath/$NEEDED_FILE" "$DYLIBS_DIR/$NEEDED_FILE" 2>/dev/null || true

# Fix dependencies to use @rpath
DEPS=$(otool -L "$DYLIBS_DIR/$NEEDED_FILE" | grep -E "($HOMEBREW_PREFIX|/usr/local)" | awk '{print $1}' || true)

for dep in $DEPS; do
    dep_name=$(basename "$dep")
    if [ -f "$DYLIBS_DIR/$dep_name" ]; then
        install_name_tool -change "$dep" "@rpath/$dep_name" "$DYLIBS_DIR/$NEEDED_FILE" 2>/dev/null || true
    fi
done

echo "  ✅ Install name fixed"
echo ""

echo "Step 4: Signing..."
xattr -cr "$DYLIBS_DIR/$NEEDED_FILE" 2>/dev/null || true

if codesign --force --sign "$SIGNING_IDENTITY" \
            --timestamp \
            --options runtime \
            "$DYLIBS_DIR/$NEEDED_FILE" 2>/dev/null; then
    echo "  ✅ Signed"
else
    echo "  ⚠️  Signing failed (may still work)"
fi
echo ""

echo "Step 5: Checking other versioned libraries..."
echo ""

# Check if we need other versioned files
VERSIONED_LIBS=$(ls "$HOMEBREW_PREFIX/lib"/libOpenImageIO*.3.1.dylib 2>/dev/null || true)

for lib in $VERSIONED_LIBS; do
    lib_name=$(basename "$lib")
    
    if [ ! -f "$DYLIBS_DIR/$lib_name" ]; then
        echo "  Found: $lib_name (not in Dylibs yet)"
        
        # Copy it
        if [ -L "$lib" ]; then
            REAL_LIB=$(readlink -f "$lib" 2>/dev/null || greadlink -f "$lib" 2>/dev/null || echo "$lib")
            cp "$REAL_LIB" "$DYLIBS_DIR/$lib_name"
        else
            cp "$lib" "$DYLIBS_DIR/$lib_name"
        fi
        
        chmod +w "$DYLIBS_DIR/$lib_name"
        
        # Fix install name
        install_name_tool -id "@rpath/$lib_name" "$DYLIBS_DIR/$lib_name" 2>/dev/null || true
        
        # Fix dependencies
        DEPS=$(otool -L "$DYLIBS_DIR/$lib_name" | grep -E "($HOMEBREW_PREFIX|/usr/local)" | awk '{print $1}' || true)
        for dep in $DEPS; do
            dep_name=$(basename "$dep")
            if [ -f "$DYLIBS_DIR/$dep_name" ]; then
                install_name_tool -change "$dep" "@rpath/$dep_name" "$DYLIBS_DIR/$lib_name" 2>/dev/null || true
            fi
        done
        
        # Sign
        xattr -cr "$DYLIBS_DIR/$lib_name" 2>/dev/null || true
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$DYLIBS_DIR/$lib_name" 2>/dev/null || true
        
        echo "    ✅ Added and processed $lib_name"
    fi
done

echo ""
echo "==============================================="
echo "✅ Versioned dylibs added!"
echo "==============================================="
echo ""
echo "📋 NEXT STEPS IN XCODE:"
echo "======================="
echo ""
echo "1. Build Phases → Copy Dylibs"
echo "   • Click '+' to add files"
echo "   • Select:"
for lib in "$DYLIBS_DIR"/libOpenImageIO*.3.1.dylib; do
    if [ -f "$lib" ]; then
        echo "     - $(basename $lib)"
    fi
done
echo ""
echo "2. Make sure 'Code Sign On Copy' is checked"
echo ""
echo "3. Clean and rebuild:"
echo "   ⌘⇧K then ⌘B"
echo ""
echo "4. Run the app (⌘R)"
echo ""
