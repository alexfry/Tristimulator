#!/bin/bash
# check_built_app.sh
# Check if dylibs were actually copied into the built app

echo "🔍 Checking Built App Bundle"
echo "============================"
echo ""

# Find the built app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug -name "Tristimulator.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ Could not find built app"
    exit 1
fi

echo "Found app: $APP_PATH"
echo ""

# Check Frameworks directory
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

echo "Checking Frameworks directory:"
echo "------------------------------"

if [ ! -d "$FRAMEWORKS_DIR" ]; then
    echo "❌ Contents/Frameworks directory does NOT exist!"
    echo ""
    echo "This is the problem - no dylibs were copied."
    echo ""
    echo "📋 TO FIX:"
    echo "=========="
    echo "In Xcode Build Phases → Copy Dylibs:"
    echo "  • Make sure Destination is set to: Frameworks"
    echo "  • Make sure all .dylib files are listed"
    echo "  • Clean and rebuild"
    echo ""
    exit 1
fi

echo "✅ Frameworks directory exists"
echo ""

# Count dylibs
DYLIB_COUNT=$(ls -1 "$FRAMEWORKS_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ')

echo "Dylibs in app bundle: $DYLIB_COUNT"
echo ""

if [ "$DYLIB_COUNT" -eq 0 ]; then
    echo "❌ NO DYLIBS COPIED!"
    echo ""
    echo "The Copy Files phase didn't copy anything."
    echo ""
    echo "📋 TO FIX:"
    echo "=========="
    echo "1. Xcode → Select Tristimulator target"
    echo "2. Build Phases → Find 'Copy Dylibs' or 'Copy Files'"
    echo "3. Check:"
    echo "   • Destination: Frameworks"
    echo "   • Subpath: (empty)"
    echo "   • All .dylib files should be listed"
    echo "4. If no files are listed:"
    echo "   • Click '+' to add files"
    echo "   • Navigate to Dylibs/ folder"
    echo "   • Select ALL .dylib files"
    echo "   • Add them"
    echo "5. Clean Build Folder (⌘⇧K)"
    echo "6. Build (⌘B)"
    echo ""
    exit 1
fi

# Check for key dylibs
echo "Key dylibs status:"
echo "------------------"

for lib in libOpenImageIO.dylib libOpenImageIO_Util.dylib libOpenColorIO.dylib; do
    if [ -f "$FRAMEWORKS_DIR/$lib" ]; then
        echo "  ✅ $lib"
    else
        echo "  ❌ $lib - MISSING!"
    fi
done
echo ""

# Check all dylibs
echo "All dylibs in bundle:"
echo "--------------------"
ls -lh "$FRAMEWORKS_DIR"/*.dylib 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
echo ""

# Check main executable dependencies
echo "Main executable status:"
echo "-----------------------"
MAIN_EXEC="$APP_PATH/Contents/MacOS/Tristimulator"

if [ -f "$MAIN_EXEC" ]; then
    echo "Checking what the main executable is looking for..."
    echo ""
    
    # Check for @rpath references
    RPATH_DEPS=$(otool -L "$MAIN_EXEC" | grep "@rpath" || true)
    
    if [ -n "$RPATH_DEPS" ]; then
        echo "Libraries it expects to find:"
        echo "$RPATH_DEPS"
        echo ""
        
        # Check if they exist
        echo "Verifying each library exists:"
        echo "$RPATH_DEPS" | while read -r line; do
            LIB_PATH=$(echo "$line" | awk '{print $1}')
            LIB_NAME=$(basename "$LIB_PATH")
            
            if [ -f "$FRAMEWORKS_DIR/$LIB_NAME" ]; then
                echo "  ✅ $LIB_NAME"
            else
                echo "  ❌ $LIB_NAME - NOT IN BUNDLE!"
            fi
        done
    else
        echo "⚠️  No @rpath dependencies found."
        echo "    This might mean dylibs weren't linked properly."
    fi
else
    echo "❌ Main executable not found"
fi

echo ""
echo "============================"
echo "Summary"
echo "============================"
echo ""

if [ "$DYLIB_COUNT" -gt 0 ]; then
    echo "✅ Dylibs were copied: $DYLIB_COUNT files"
    echo ""
    echo "If app still crashes:"
    echo "  • Check that ALL required dylibs are present"
    echo "  • Check Runpath Search Paths in Build Settings"
    echo "  • Try: ./verify_embedded_dylibs.sh for more details"
else
    echo "❌ NO dylibs were copied!"
    echo ""
    echo "Fix the Copy Files build phase and rebuild."
fi
echo ""
