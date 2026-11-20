#!/bin/bash
# inspect_framework_structure.sh
# Inspect the actual structure of the frameworks

echo "🔍 Framework Structure Inspection"
echo "================================="
echo ""

FRAMEWORKS_DIR="./Frameworks"

# Pick a framework to inspect in detail
FW="$FRAMEWORKS_DIR/OpenImageIO.framework"

if [ ! -e "$FW" ]; then
    echo "❌ Framework not found: $FW"
    exit 1
fi

echo "Inspecting: $FW"
echo ""

echo "Top-level structure:"
ls -la "$FW" | head -20
echo ""

echo "Checking what type of file the main executable is:"
file "$FW/OpenImageIO" 2>&1 || echo "  (symlink or file not found)"
echo ""

if [ -L "$FW/OpenImageIO" ]; then
    echo "Main executable is a symlink to:"
    ls -l "$FW/OpenImageIO"
    echo ""
    
    echo "Following the symlink:"
    REAL_PATH=$(readlink "$FW/OpenImageIO")
    echo "  Points to: $REAL_PATH"
    
    FULL_PATH="$FW/$REAL_PATH"
    if [ -f "$FULL_PATH" ]; then
        echo "  ✅ Target exists"
        file "$FULL_PATH"
    else
        echo "  ❌ Target not found at: $FULL_PATH"
    fi
fi
echo ""

echo "Versions directory:"
if [ -d "$FW/Versions" ]; then
    ls -la "$FW/Versions"
    echo ""
    
    if [ -d "$FW/Versions/A" ]; then
        echo "Version A contents:"
        ls -la "$FW/Versions/A"
    fi
else
    echo "  ❌ Versions directory not found"
fi
echo ""

echo "Resources directory:"
if [ -d "$FW/Resources" ]; then
    ls -la "$FW/Resources"
    
    if [ -f "$FW/Resources/Info.plist" ]; then
        echo ""
        echo "Info.plist contents:"
        cat "$FW/Resources/Info.plist"
    fi
else
    echo "  ⚠️  Resources directory not found"
fi
echo ""

echo "================================="
echo "Testing codesign on this framework:"
echo ""
codesign -dvvv "$FW" 2>&1 || true
echo ""

echo "================================="
echo "Quick check of all frameworks:"
echo ""

VALID=0
INVALID=0

for fw in "$FRAMEWORKS_DIR"/*.framework; do
    fw_name=$(basename "$fw" .framework)
    
    # Check if it has proper structure
    if [ -f "$fw/Versions/A/$fw_name" ] && [ -f "$fw/Resources/Info.plist" ]; then
        VALID=$((VALID + 1))
    else
        INVALID=$((INVALID + 1))
        echo "  ❌ $fw_name: Missing required files"
        
        if [ ! -f "$fw/Versions/A/$fw_name" ]; then
            echo "      Missing: Versions/A/$fw_name"
        fi
        if [ ! -f "$fw/Resources/Info.plist" ]; then
            echo "      Missing: Resources/Info.plist"
        fi
    fi
done

echo ""
echo "Summary:"
echo "  ✅ Valid structure: $VALID frameworks"
echo "  ❌ Invalid structure: $INVALID frameworks"
echo ""
