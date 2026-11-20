#!/bin/bash
# verify_header_paths.sh
# Check exactly where everything is

echo "🔍 Header Path Verification"
echo "==========================="
echo ""

echo "Current directory:"
pwd
echo ""

echo "Checking for headers..."
echo ""

if [ -f "Tristimulator/Include/OpenImageIO/imageio.h" ]; then
    echo "✅ Headers are at: Tristimulator/Include/"
    HEADER_LOCATION="Tristimulator/Include"
elif [ -f "Include/OpenImageIO/imageio.h" ]; then
    echo "✅ Headers are at: Include/"
    HEADER_LOCATION="Include"
else
    echo "❌ Can't find headers!"
    echo ""
    echo "Looking for headers everywhere:"
    find . -name "imageio.h" -type f 2>/dev/null | head -5
    exit 1
fi

echo ""
echo "Checking for source file..."
echo ""

if [ -f "Tristimulator/OpenImageIOBridge.mm" ]; then
    echo "✅ Source is at: Tristimulator/OpenImageIOBridge.mm"
else
    echo "❌ Can't find OpenImageIOBridge.mm"
    exit 1
fi

echo ""
echo "================================================"
echo "📋 XCODE CONFIGURATION"
echo "================================================"
echo ""

if [ "$HEADER_LOCATION" = "Tristimulator/Include" ]; then
    echo "Your headers are in: Tristimulator/Include/"
    echo ""
    echo "Set in Xcode Build Settings:"
    echo ""
    echo "Header Search Paths:"
    echo "  \$(SRCROOT)/Tristimulator/Include"
    echo ""
    echo "Where \$(SRCROOT) = $(pwd)"
    echo "So it will look in: $(pwd)/Tristimulator/Include/"
    echo ""
elif [ "$HEADER_LOCATION" = "Include" ]; then
    echo "Your headers are in: Include/"
    echo ""
    echo "Set in Xcode Build Settings:"
    echo ""
    echo "Header Search Paths:"
    echo "  \$(SRCROOT)/Include"
    echo ""
    echo "Where \$(SRCROOT) = $(pwd)"
    echo "So it will look in: $(pwd)/Include/"
    echo ""
fi

echo "Test compilation:"
echo "-----------------"
echo ""

TEST_FILE="/tmp/test_include.mm"
cat > "$TEST_FILE" << 'EOF'
#include <OpenImageIO/imageio.h>
int main() { return 0; }
EOF

INCLUDE_PATH="$(pwd)/$HEADER_LOCATION"

if clang++ -c -I"$INCLUDE_PATH" "$TEST_FILE" -o /tmp/test_include.o 2>/dev/null; then
    echo "✅ Compiler CAN find headers with -I$INCLUDE_PATH"
    rm -f /tmp/test_include.o
else
    echo "❌ Compiler CANNOT find headers even with -I$INCLUDE_PATH"
    echo ""
    echo "Testing what's actually in the directory:"
    ls -la "$INCLUDE_PATH/OpenImageIO/" | head -10
fi

rm -f "$TEST_FILE"

echo ""
echo "================================================"
echo ""
echo "Copy this EXACT setting into Xcode:"
echo ""
if [ "$HEADER_LOCATION" = "Tristimulator/Include" ]; then
    echo "   \$(SRCROOT)/Tristimulator/Include"
elif [ "$HEADER_LOCATION" = "Include" ]; then
    echo "   \$(SRCROOT)/Include"
fi
echo ""
