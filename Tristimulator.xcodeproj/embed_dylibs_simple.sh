#!/bin/bash
# embed_dylibs_simple.sh
# Simple approach: Embed .dylib files directly (no framework conversion)
# This is what works reliably for Homebrew libraries

set -e

echo "🚀 Tristimulator Dylib Embedding (Simple Approach)"
echo "================================================"
echo ""

# Configuration
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

echo "📋 Configuration:"
echo "  Architecture: $ARCH"
echo "  Homebrew prefix: $HOMEBREW_PREFIX"
echo "  Dylibs directory: $DYLIBS_DIR"
echo "  Signing identity: $SIGNING_IDENTITY"
echo ""

# Step 1: Check prerequisites
echo "📋 Step 1: Checking prerequisites..."
if [ ! -f "$HOMEBREW_PREFIX/lib/libOpenImageIO.dylib" ]; then
    echo "❌ OpenImageIO not found. Run: brew install openimageio"
    exit 1
fi
if [ ! -f "$HOMEBREW_PREFIX/lib/libOpenColorIO.dylib" ]; then
    echo "❌ OpenColorIO not found. Run: brew install opencolorio"
    exit 1
fi

# Check signing identity
if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    echo "❌ Signing identity not found: $SIGNING_IDENTITY"
    exit 1
fi

echo "✅ Prerequisites met"
echo ""

# Step 2: Analyze dependencies
echo "📊 Step 2: Analyzing dependencies..."

DEPS_TEMP_FILE=$(mktemp /tmp/tristimulator_deps.XXXXXX)

find_all_deps() {
    local lib=$1
    
    # Check if already processed
    if grep -qF "$lib" "$DEPS_TEMP_FILE" 2>/dev/null; then
        return
    fi
    
    # Add to processed list
    echo "$lib" >> "$DEPS_TEMP_FILE"
    
    # Find dependencies
    local deps=$(otool -L "$lib" 2>/dev/null | grep -E "($HOMEBREW_PREFIX|/usr/local)" | awk '{print $1}' || true)
    
    for dep in $deps; do
        if [ -f "$dep" ]; then
            find_all_deps "$dep"
        fi
    done
}

# Start with main libraries (including _Util which might not be auto-detected)
find_all_deps "$HOMEBREW_PREFIX/lib/libOpenImageIO.dylib"
find_all_deps "$HOMEBREW_PREFIX/lib/libOpenColorIO.dylib"

# Explicitly add OpenImageIO_Util (needed for ParamValue and other utilities)
if [ -f "$HOMEBREW_PREFIX/lib/libOpenImageIO_Util.dylib" ]; then
    find_all_deps "$HOMEBREW_PREFIX/lib/libOpenImageIO_Util.dylib"
fi
if [ -f "$HOMEBREW_PREFIX/lib/libOpenImageIO_Util.3.1.dylib" ]; then
    find_all_deps "$HOMEBREW_PREFIX/lib/libOpenImageIO_Util.3.1.dylib"
fi

# Convert to array
ALL_DEPS=()
while IFS= read -r lib; do
    ALL_DEPS+=("$lib")
done < "$DEPS_TEMP_FILE"

rm -f "$DEPS_TEMP_FILE"

echo "Found ${#ALL_DEPS[@]} dependencies to embed:"
for lib in "${ALL_DEPS[@]}"; do
    echo "  • $(basename $lib)"
done
echo ""

# Step 3: Create dylibs directory
echo "📁 Step 3: Creating dylibs directory..."
if [ -d "$DYLIBS_DIR" ]; then
    echo "⚠️  Dylibs directory exists. Backing up..."
    mv "$DYLIBS_DIR" "${DYLIBS_DIR}.backup.$(date +%s)"
fi
mkdir -p "$DYLIBS_DIR"
echo "✅ Directory created: $DYLIBS_DIR"
echo ""

# Step 4: Copy dylibs
echo "📦 Step 4: Copying dylibs..."

COPIED_COUNT=0
for lib in "${ALL_DEPS[@]}"; do
    if [ -f "$lib" ]; then
        lib_name=$(basename "$lib")
        echo "  Copying $lib_name..."
        
        # Follow symlinks to get actual file
        if [ -L "$lib" ]; then
            REAL_LIB=$(readlink -f "$lib" 2>/dev/null || greadlink -f "$lib" 2>/dev/null || echo "$lib")
            cp "$REAL_LIB" "$DYLIBS_DIR/$lib_name"
        else
            cp "$lib" "$DYLIBS_DIR/$lib_name"
        fi
        
        chmod +w "$DYLIBS_DIR/$lib_name"
        COPIED_COUNT=$((COPIED_COUNT + 1))
    fi
done

echo "✅ Copied $COPIED_COUNT dylibs"
echo ""

# Step 5: Fix install names
echo "🔧 Step 5: Fixing install names..."

for dylib in "$DYLIBS_DIR"/*.dylib; do
    dylib_name=$(basename "$dylib")
    echo "  Processing $dylib_name..."
    
    # Change the dylib's own install name to use @rpath
    install_name_tool -id "@rpath/$dylib_name" "$dylib" 2>/dev/null || true
    
    # Fix all dependencies to use @rpath
    DEPS=$(otool -L "$dylib" | grep -E "($HOMEBREW_PREFIX|/usr/local)" | awk '{print $1}' || true)
    
    for dep in $DEPS; do
        dep_name=$(basename "$dep")
        if [ -f "$DYLIBS_DIR/$dep_name" ]; then
            install_name_tool -change "$dep" "@rpath/$dep_name" "$dylib" 2>/dev/null || true
        fi
    done
done

echo "✅ Install names fixed"
echo ""

# Step 6: Sign all dylibs
echo "✍️  Step 6: Signing dylibs..."

SIGNED_COUNT=0
FAILED_COUNT=0

for dylib in "$DYLIBS_DIR"/*.dylib; do
    dylib_name=$(basename "$dylib")
    echo "  Signing $dylib_name..."
    
    # Remove any extended attributes
    xattr -cr "$dylib" 2>/dev/null || true
    
    # Sign the dylib
    if codesign --force --sign "$SIGNING_IDENTITY" \
                --timestamp \
                --options runtime \
                "$dylib" 2>/dev/null; then
        SIGNED_COUNT=$((SIGNED_COUNT + 1))
    else
        echo "    ⚠️  Failed to sign $dylib_name"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done

echo "✅ Signed $SIGNED_COUNT/$COPIED_COUNT dylibs"
if [ $FAILED_COUNT -gt 0 ]; then
    echo "⚠️  Failed to sign $FAILED_COUNT dylibs"
fi
echo ""

# Step 7: Verify
echo "🔍 Step 7: Verifying dylibs..."

VERIFIED_COUNT=0
for dylib in "$DYLIBS_DIR"/*.dylib; do
    if codesign --verify --deep --strict "$dylib" 2>/dev/null; then
        VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
    else
        echo "  ⚠️  $(basename $dylib): Verification failed"
    fi
done

echo "✅ Verified $VERIFIED_COUNT/$SIGNED_COUNT signed dylibs"
echo ""

# Calculate size
TOTAL_SIZE=$(du -sh "$DYLIBS_DIR" | awk '{print $1}')

echo "================================================"
echo "✅ DYLIB EMBEDDING COMPLETE!"
echo "================================================"
echo ""
echo "📊 Summary:"
echo "  • Copied: $COPIED_COUNT dylibs"
echo "  • Signed: $SIGNED_COUNT dylibs"
echo "  • Verified: $VERIFIED_COUNT dylibs"
echo "  • Total size: $TOTAL_SIZE"
echo "  • Location: $DYLIBS_DIR"
echo ""

echo "================================================"
echo "📋 Next Steps for Xcode Configuration:"
echo "================================================"
echo ""
echo "1. Remove Old Frameworks:"
echo "   • In Xcode project navigator, find and DELETE the 'Frameworks' folder"
echo "   • Select 'Move to Trash' (not just remove reference)"
echo ""
echo "2. Add Dylibs Folder:"
echo "   • Drag '$DYLIBS_DIR' folder into Xcode project"
echo "   • Check 'Create folder references'"
echo "   • Add to Tristimulator target"
echo ""
echo "3. Configure 'Copy Files' Build Phase:"
echo "   • Select Tristimulator target → Build Phases"
echo "   • Delete the old 'Copy Files (Frameworks)' phase if it exists"
echo "   • Click '+' → 'New Copy Files Phase'"
echo "   • Name it 'Copy Dylibs'"
echo "   • Set Destination: 'Frameworks' (yes, dylibs go in Frameworks folder)"
echo "   • Drag all .dylib files from '$DYLIBS_DIR' into this phase"
echo "   • Check 'Code Sign On Copy'"
echo ""
echo "4. Update Build Settings:"
echo ""
echo "   Framework Search Paths:"
echo "     DELETE or clear this setting"
echo ""
echo "   Header Search Paths:"
echo "     $HOMEBREW_PREFIX/include"
echo "     $HOMEBREW_PREFIX/include/OpenImageIO"
echo "     $HOMEBREW_PREFIX/include/OpenColorIO"
echo ""
echo "   Library Search Paths:"
echo "     DELETE: $HOMEBREW_PREFIX/lib"
echo "     (We're embedding everything)"
echo ""
echo "   Runpath Search Paths:"
echo "     @executable_path/../Frameworks"
echo "     @loader_path/../Frameworks"
echo ""
echo "   Other Linker Flags:"
echo "     -lOpenImageIO"
echo "     -lOpenImageIO_Util"
echo "     -lOpenColorIO"
echo "     (Keep these - they'll find your embedded dylibs)"
echo ""
echo "   Code Signing Identity:"
echo "     Debug: Apple Development"
echo "     Release: Apple Development"
echo ""
echo "   Development Team:"
echo "     G3"
echo ""
echo "   Other Code Signing Flags:"
echo "     (Leave EMPTY - remove any --deep flags)"
echo ""
echo "5. Clean and Build:"
echo "   • Product → Clean Build Folder (⌘⇧K)"
echo "   • Delete Derived Data:"
echo "     rm -rf ~/Library/Developer/Xcode/DerivedData/Tristimulator-*"
echo "   • Product → Build (⌘B)"
echo ""
echo "6. Verify the Built App:"
echo "   ./verify_embedded_dylibs.sh"
echo ""
echo "================================================"
echo ""

# Create verification script
cat > verify_embedded_dylibs.sh << 'VERIFY_EOF'
#!/bin/bash
# Verify the built app has properly embedded dylibs

echo "🔍 Verifying Embedded Dylibs"
echo "============================"
echo ""

# Find the built app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug -name "Tristimulator.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ Could not find built app"
    echo "   Build the app first, then run this script"
    exit 1
fi

echo "Found app: $APP_PATH"
echo ""

# Check embedded dylibs
EMBEDDED_DIR="$APP_PATH/Contents/Frameworks"

if [ ! -d "$EMBEDDED_DIR" ]; then
    echo "❌ No Frameworks directory in app bundle"
    exit 1
fi

DYLIB_COUNT=$(ls -1 "$EMBEDDED_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ')
echo "Embedded dylibs: $DYLIB_COUNT"
echo ""

# Check a few key dylibs
echo "Checking key dylibs:"
for lib in libOpenImageIO.dylib libOpenColorIO.dylib; do
    if [ -f "$EMBEDDED_DIR/$lib" ]; then
        echo "  ✅ $lib"
        
        # Check signature
        if codesign --verify "$EMBEDDED_DIR/$lib" 2>/dev/null; then
            echo "     Signature: Valid"
        else
            echo "     Signature: ⚠️  Invalid or missing"
        fi
        
        # Check install name
        INSTALL_NAME=$(otool -D "$EMBEDDED_DIR/$lib" | tail -1)
        echo "     Install name: $INSTALL_NAME"
    else
        echo "  ❌ $lib - NOT FOUND"
    fi
done
echo ""

# Check main executable dependencies
echo "Main executable dependencies:"
MAIN_EXEC="$APP_PATH/Contents/MacOS/Tristimulator"

if [ -f "$MAIN_EXEC" ]; then
    HOMEBREW_DEPS=$(otool -L "$MAIN_EXEC" | grep -E "(homebrew|/usr/local)" | wc -l | tr -d ' ')
    
    if [ "$HOMEBREW_DEPS" -eq 0 ]; then
        echo "  ✅ No Homebrew dependencies (good!)"
        echo "     All dependencies use @rpath"
    else
        echo "  ⚠️  Still has $HOMEBREW_DEPS Homebrew dependencies:"
        otool -L "$MAIN_EXEC" | grep -E "(homebrew|/usr/local)"
        echo ""
        echo "     This might cause issues on machines without Homebrew"
    fi
else
    echo "  ❌ Main executable not found"
fi
echo ""

echo "============================"
echo "Verification complete!"
echo ""
VERIFY_EOF

chmod +x verify_embedded_dylibs.sh

echo "✅ Verification script created: verify_embedded_dylibs.sh"
echo ""
