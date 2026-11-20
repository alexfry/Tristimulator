#!/bin/bash
# check_what_got_copied.sh
# Compare Dylibs/ folder vs what's actually in the app bundle

echo "🔍 Comparing Source vs Built App"
echo "================================="
echo ""

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug -name "Tristimulator.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ App not found"
    exit 1
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

echo "Checking OpenImageIO_Util files..."
echo ""

echo "In Dylibs/ folder:"
ls -lh ./Dylibs/libOpenImageIO_Util* 2>/dev/null | while read line; do
    FILE=$(echo "$line" | awk '{print $9}')
    echo "  ✅ $(basename $FILE)"
done || echo "  ❌ None found"

echo ""
echo "In app bundle ($FRAMEWORKS_DIR):"
ls -lh "$FRAMEWORKS_DIR"/libOpenImageIO_Util* 2>/dev/null | while read line; do
    FILE=$(echo "$line" | awk '{print $9}')
    echo "  ✅ $(basename $FILE)"
done || echo "  ❌ None found"

echo ""
echo "================================="
echo ""

IN_DYLIBS=$(ls -1 ./Dylibs/libOpenImageIO_Util* 2>/dev/null | wc -l | tr -d ' ')
IN_APP=$(ls -1 "$FRAMEWORKS_DIR"/libOpenImageIO_Util* 2>/dev/null | wc -l | tr -d ' ')

echo "Summary:"
echo "  In Dylibs/: $IN_DYLIBS files"
echo "  In app bundle: $IN_APP files"
echo ""

if [ "$IN_DYLIBS" -gt 0 ] && [ "$IN_APP" -eq 0 ]; then
    echo "❌ PROBLEM: Files exist in Dylibs/ but NOT copied to app!"
    echo ""
    echo "This means the Copy Files build phase is not configured correctly."
    echo ""
    echo "FIX:"
    echo "===="
    echo "1. Open Xcode"
    echo "2. Select Tristimulator target"
    echo "3. Build Phases tab"
    echo "4. Find 'Copy Dylibs' or 'Copy Files' phase"
    echo "5. Check if libOpenImageIO_Util.dylib is listed"
    echo "6. If NOT listed:"
    echo "   • Click '+'"
    echo "   • Add: Dylibs/libOpenImageIO_Util.dylib"
    echo "   • Also add any other libOpenImageIO_Util*.dylib files"
    echo "7. Make sure 'Code Sign On Copy' is checked"
    echo "8. Clean (⌘⇧K) and Build (⌘B)"
    echo ""
elif [ "$IN_DYLIBS" -gt "$IN_APP" ]; then
    echo "⚠️  Some files copied but not all!"
    echo ""
    echo "Missing from app bundle:"
    for f in ./Dylibs/libOpenImageIO_Util*; do
        fname=$(basename "$f")
        if [ ! -f "$FRAMEWORKS_DIR/$fname" ]; then
            echo "  • $fname"
        fi
    done
    echo ""
    echo "Add these to Copy Files phase in Xcode."
elif [ "$IN_APP" -gt 0 ]; then
    echo "✅ Files are being copied!"
    echo ""
    echo "But the app still crashes, which means:"
    echo "  • Maybe you need to clean and rebuild"
    echo "  • Or there's a different file with a similar name"
    echo ""
    echo "Try:"
    echo "  1. Clean Build Folder (⌘⇧K)"
    echo "  2. Delete Derived Data:"
    echo "     rm -rf ~/Library/Developer/Xcode/DerivedData/Tristimulator-*"
    echo "  3. Build (⌘B)"
else
    echo "❌ No OpenImageIO_Util files found anywhere!"
    echo ""
    echo "Run: ./FINAL_FIX.sh first"
fi
echo ""
