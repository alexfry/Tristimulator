#!/bin/bash
# fix_dylib_copying.sh
# Diagnose and help fix dylib copying issues

echo "🔧 Diagnosing Dylib Copy Issue"
echo "==============================="
echo ""

# First, check what we have in Dylibs/
echo "Step 1: Checking source Dylibs folder..."
echo "----------------------------------------"

if [ ! -d "./Dylibs" ]; then
    echo "❌ Dylibs folder not found!"
    echo "   Run: ./embed_dylibs_simple.sh first"
    exit 1
fi

DYLIB_COUNT=$(ls -1 ./Dylibs/*.dylib 2>/dev/null | wc -l | tr -d ' ')
echo "Source dylibs available: $DYLIB_COUNT"

if [ "$DYLIB_COUNT" -eq 0 ]; then
    echo "❌ No dylibs in Dylibs folder!"
    exit 1
fi

echo "  ✅ Source dylibs ready"
echo ""

# Check the built app
echo "Step 2: Checking built app..."
echo "------------------------------"

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug -name "Tristimulator.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "⚠️  App not built yet"
    echo "   Build in Xcode first (⌘B)"
    exit 1
fi

echo "App location: $APP_PATH"
echo ""

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
COPIED_COUNT=0

if [ -d "$FRAMEWORKS_DIR" ]; then
    COPIED_COUNT=$(ls -1 "$FRAMEWORKS_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ')
fi

echo "Dylibs in app bundle: $COPIED_COUNT"
echo ""

if [ "$COPIED_COUNT" -eq 0 ]; then
    echo "❌ PROBLEM FOUND: No dylibs copied to app bundle!"
    echo ""
    echo "============================================"
    echo "📋 HOW TO FIX IN XCODE"
    echo "============================================"
    echo ""
    echo "The Copy Files build phase isn't copying dylibs."
    echo "Here's how to fix it:"
    echo ""
    echo "OPTION A - Check Existing Copy Phase"
    echo "-------------------------------------"
    echo "1. Open Tristimulator.xcodeproj in Xcode"
    echo ""
    echo "2. Select Tristimulator target (top left)"
    echo ""
    echo "3. Go to 'Build Phases' tab"
    echo ""
    echo "4. Look for 'Copy Dylibs' or 'Copy Files' phase"
    echo ""
    echo "5. If it exists but is empty:"
    echo "   • Click the '+' button in that phase"
    echo "   • Navigate to: $(pwd)/Dylibs"
    echo "   • Select ALL .dylib files"
    echo "   • Click 'Add'"
    echo "   • Make sure 'Code Sign On Copy' is CHECKED"
    echo ""
    echo "6. Verify settings:"
    echo "   • Destination: Frameworks"
    echo "   • Subpath: (empty)"
    echo "   • Copy only when installing: UNCHECKED"
    echo ""
    echo "OPTION B - Create New Copy Phase"
    echo "--------------------------------"
    echo "If no Copy Files phase exists:"
    echo ""
    echo "1. Build Phases → Click '+' → 'New Copy Files Phase'"
    echo ""
    echo "2. Configure it:"
    echo "   • Rename to: Copy Dylibs"
    echo "   • Destination: Frameworks"
    echo "   • Subpath: (empty)"
    echo "   • Code Sign On Copy: YES"
    echo ""
    echo "3. Click '+' to add files"
    echo "   • Navigate to: $(pwd)/Dylibs"
    echo "   • Select ALL .dylib files (⌘A)"
    echo "   • Click 'Add'"
    echo ""
    echo "AFTER FIXING"
    echo "------------"
    echo "1. Clean Build Folder: ⌘⇧K"
    echo "2. Build: ⌘B"
    echo "3. Run this script again to verify"
    echo ""
    exit 1
fi

if [ "$COPIED_COUNT" -lt "$DYLIB_COUNT" ]; then
    echo "⚠️  WARNING: Only $COPIED_COUNT/$DYLIB_COUNT dylibs copied!"
    echo ""
    echo "Missing dylibs:"
    
    for src_dylib in ./Dylibs/*.dylib; do
        dylib_name=$(basename "$src_dylib")
        if [ ! -f "$FRAMEWORKS_DIR/$dylib_name" ]; then
            echo "  ❌ $dylib_name"
        fi
    done
    echo ""
    echo "Make sure ALL dylibs are added to Copy Files phase."
    echo ""
fi

# Check specific required libs
echo "Step 3: Checking key libraries..."
echo "----------------------------------"

ALL_PRESENT=true

for lib in libOpenImageIO.dylib libOpenImageIO_Util.dylib libOpenColorIO.dylib; do
    if [ -f "$FRAMEWORKS_DIR/$lib" ]; then
        echo "  ✅ $lib"
    else
        echo "  ❌ $lib - MISSING!"
        ALL_PRESENT=false
    fi
done

echo ""

if [ "$ALL_PRESENT" = true ] && [ "$COPIED_COUNT" -eq "$DYLIB_COUNT" ]; then
    echo "============================================"
    echo "✅ All dylibs copied successfully!"
    echo "============================================"
    echo ""
    echo "If app still crashes, check:"
    echo "1. Runpath Search Paths in Build Settings"
    echo "2. Run: ./verify_embedded_dylibs.sh"
    echo ""
else
    echo "============================================"
    echo "⚠️  Issues found - follow fix steps above"
    echo "============================================"
    echo ""
fi
