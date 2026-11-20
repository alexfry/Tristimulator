#!/bin/bash
# diagnose_dylib_chain.sh
# Show the complete dependency chain to understand what's missing

echo "🔍 Complete Dylib Dependency Analysis"
echo "======================================"
echo ""

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug -name "Tristimulator.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ App not found"
    exit 1
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

echo "App location: $APP_PATH"
echo ""

# Check what OpenImageIO files we have
echo "OpenImageIO-related files in app bundle:"
echo "========================================="
ls -lh "$FRAMEWORKS_DIR" | grep -i openimageio | while read line; do
    FILE=$(echo "$line" | awk '{print $9}')
    SIZE=$(echo "$line" | awk '{print $5}')
    
    if [ -L "$FRAMEWORKS_DIR/$FILE" ]; then
        TARGET=$(readlink "$FRAMEWORKS_DIR/$FILE")
        echo "  $FILE -> $TARGET (symlink, $SIZE)"
    else
        echo "  $FILE ($SIZE)"
    fi
done
echo ""

# Check dependencies of each OpenImageIO file
echo "Dependencies of OpenImageIO files:"
echo "==================================="
echo ""

for oiio_file in "$FRAMEWORKS_DIR"/libOpenImageIO*.dylib; do
    if [ -f "$oiio_file" ]; then
        FILE_NAME=$(basename "$oiio_file")
        echo "📦 $FILE_NAME"
        echo "   Dependencies:"
        
        otool -L "$oiio_file" | grep "@rpath" | while read line; do
            DEP=$(echo "$line" | awk '{print $1}')
            DEP_FILE=$(basename "$DEP")
            
            if [ -f "$FRAMEWORKS_DIR/$DEP_FILE" ]; then
                echo "     ✅ $DEP_FILE (present)"
            else
                echo "     ❌ $DEP_FILE (MISSING!)"
            fi
        done
        echo ""
    fi
done

# Check what we have in source Dylibs/
echo "Source Dylibs/ folder:"
echo "======================"
if [ -d "./Dylibs" ]; then
    echo ""
    ls -lh ./Dylibs | grep -i openimageio | while read line; do
        FILE=$(echo "$line" | awk '{print $9}')
        SIZE=$(echo "$line" | awk '{print $5}')
        
        if [ -L "./Dylibs/$FILE" ]; then
            TARGET=$(readlink "./Dylibs/$FILE")
            echo "  $FILE -> $TARGET (symlink, $SIZE)"
        else
            echo "  $FILE ($SIZE)"
        fi
    done
else
    echo "  ❌ Dylibs/ folder not found"
fi
echo ""

# Specific check for the problematic file
echo "Specific Check: libOpenImageIO_Util.3.1.dylib"
echo "=============================================="
echo ""

if [ -f "$FRAMEWORKS_DIR/libOpenImageIO_Util.3.1.dylib" ]; then
    echo "✅ Present in app bundle"
elif [ -f "$FRAMEWORKS_DIR/libOpenImageIO_Util.dylib" ]; then
    echo "⚠️  libOpenImageIO_Util.dylib exists, but .3.1 version missing"
    echo ""
    echo "Checking if it's a symlink..."
    if [ -L "$FRAMEWORKS_DIR/libOpenImageIO_Util.dylib" ]; then
        TARGET=$(readlink "$FRAMEWORKS_DIR/libOpenImageIO_Util.dylib")
        echo "  Yes, points to: $TARGET"
        
        if [ -f "$FRAMEWORKS_DIR/$TARGET" ]; then
            echo "  Target exists: ✅"
        else
            echo "  Target missing: ❌"
        fi
    else
        echo "  Not a symlink, it's a real file"
    fi
else
    echo "❌ Not in app bundle at all!"
fi
echo ""

if [ -f "./Dylibs/libOpenImageIO_Util.3.1.dylib" ]; then
    echo "✅ Present in source Dylibs/"
    echo "   → Needs to be added to Copy Files phase in Xcode"
elif [ -f "./Dylibs/libOpenImageIO_Util.dylib" ]; then
    echo "⚠️  libOpenImageIO_Util.dylib exists in Dylibs/, but .3.1 version missing"
    echo "   → Run: ./fix_missing_versioned_dylibs.sh"
else
    echo "❌ Not in source Dylibs/ either!"
    echo "   → Run: ./fix_missing_versioned_dylibs.sh"
fi
echo ""

echo "======================================"
echo "Recommendation"
echo "======================================"
echo ""

if [ ! -f "./Dylibs/libOpenImageIO_Util.3.1.dylib" ]; then
    echo "1. Run: ./fix_missing_versioned_dylibs.sh"
    echo "   This will copy the versioned library to Dylibs/"
    echo ""
    echo "2. In Xcode, add the versioned file to Copy Files phase"
    echo ""
    echo "3. Clean and rebuild"
else
    echo "The file exists in Dylibs/ but wasn't copied to app."
    echo ""
    echo "In Xcode:"
    echo "1. Build Phases → Copy Dylibs"
    echo "2. Click '+' to add files"
    echo "3. Add: libOpenImageIO_Util.3.1.dylib"
    echo "4. Clean (⌘⇧K) and Build (⌘B)"
fi
echo ""
