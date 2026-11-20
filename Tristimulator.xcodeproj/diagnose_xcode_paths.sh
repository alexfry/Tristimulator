#!/bin/bash
# diagnose_xcode_paths.sh
# Check if everything is in place for Xcode to find headers

echo "🔍 Xcode Header Path Diagnostics"
echo "================================="
echo ""

# Current directory
echo "Current directory:"
pwd
echo ""

# Check if we're in the right place
if [ ! -d "Tristimulator" ]; then
    echo "❌ Not in project root! Run this from /Users/afry/GitHub/Tristimulator"
    exit 1
fi

# Check headers exist
echo "Checking headers..."
echo ""

if [ -f "Tristimulator/Include/OpenImageIO/imageio.h" ]; then
    echo "✅ Headers found at: Tristimulator/Include/OpenImageIO/imageio.h"
else
    echo "❌ Headers NOT found at: Tristimulator/Include/OpenImageIO/imageio.h"
    echo ""
    echo "Looking for headers:"
    find . -name "imageio.h" -type f 2>/dev/null
    exit 1
fi

# Check source file
if [ -f "Tristimulator/OpenImageIOBridge.mm" ]; then
    echo "✅ Source found at: Tristimulator/OpenImageIOBridge.mm"
else
    echo "❌ Source NOT found"
    exit 1
fi

echo ""
echo "File structure looks correct!"
echo ""

# Show the exact path
FULL_PATH="$(pwd)/Tristimulator/Include"
echo "Full include path: $FULL_PATH"
echo ""

# Test compilation
echo "Testing compilation with different path formats..."
echo ""

TEST_FILE="Tristimulator/OpenImageIOBridge.mm"

# Test 1: Absolute path
echo "Test 1: Using absolute path..."
if clang++ -c -I"$FULL_PATH" -std=c++17 "$TEST_FILE" -o /tmp/test1.o 2>&1 | grep -q "error:"; then
    echo "  ❌ Failed with absolute path"
else
    echo "  ✅ Success with absolute path: -I$FULL_PATH"
    rm -f /tmp/test1.o
fi

# Test 2: Relative path from project root
echo "Test 2: Using relative path..."
if clang++ -c -I"./Tristimulator/Include" -std=c++17 "$TEST_FILE" -o /tmp/test2.o 2>&1 | grep -q "error:"; then
    echo "  ❌ Failed with relative path"
else
    echo "  ✅ Success with relative path: -I./Tristimulator/Include"
    rm -f /tmp/test2.o
fi

echo ""
echo "================================================"
echo "🎯 XCODE SETTINGS"
echo "================================================"
echo ""

echo "In Xcode Build Settings, set EXACTLY this:"
echo ""
echo "Header Search Paths:"
echo "  \$(SRCROOT)/Tristimulator/Include"
echo ""
echo "Where \$(SRCROOT) will be:"
echo "  $(pwd)"
echo ""
echo "So Xcode will look in:"
echo "  $(pwd)/Tristimulator/Include/"
echo ""

echo "IMPORTANT CHECKS:"
echo "================="
echo ""
echo "1. Make sure you're editing the TARGET settings, not PROJECT"
echo "   (The target name 'Tristimulator' should be bold/selected)"
echo ""
echo "2. Make sure it's set for ALL configurations"
echo "   (Click on the setting and check it appears for Debug and Release)"
echo ""
echo "3. Make sure 'All' is selected (not 'Basic') in Build Settings"
echo ""
echo "4. REMOVE any of these from Header Search Paths:"
echo "   ❌ /opt/homebrew/include"
echo "   ❌ /usr/local/include"
echo ""
echo "5. After setting, do:"
echo "   • Clean Build Folder (⌘⇧K)"
echo "   • Quit and restart Xcode"
echo "   • Build (⌘B)"
echo ""

# Try to read from pbxproj if available
if [ -f "Tristimulator.xcodeproj/project.pbxproj" ]; then
    echo "================================================"
    echo "Current project.pbxproj settings:"
    echo "================================================"
    echo ""
    grep -A 2 "HEADER_SEARCH_PATHS" Tristimulator.xcodeproj/project.pbxproj | head -20
    echo ""
fi

echo "If the build still fails, run this debug command:"
echo ""
echo "xcodebuild -project Tristimulator.xcodeproj -target Tristimulator -showBuildSettings | grep HEADER_SEARCH_PATHS"
echo ""
