#!/bin/bash
# copy_all_headers.sh
# Copy OpenImageIO, OpenColorIO, AND all their header dependencies

set -e

echo "📦 Copying All Required Headers"
echo "================================"
echo ""

# Detect Homebrew
if [ -d "/opt/homebrew" ]; then
    BREW_PREFIX="/opt/homebrew"
elif [ -d "/usr/local" ]; then
    BREW_PREFIX="/usr/local"
else
    echo "❌ Homebrew not found"
    exit 1
fi

PROJECT_INCLUDE="./Tristimulator/Include"
mkdir -p "$PROJECT_INCLUDE"

echo "Source: $BREW_PREFIX/include"
echo "Destination: $PROJECT_INCLUDE"
echo ""

# Function to copy headers following symlinks
copy_headers() {
    local name=$1
    echo "📋 Copying $name..."
    
    if [ -d "$BREW_PREFIX/include/$name" ]; then
        rm -rf "$PROJECT_INCLUDE/$name"
        cp -RL "$BREW_PREFIX/include/$name" "$PROJECT_INCLUDE/"
        echo "   ✅ Copied $name"
    else
        echo "   ⚠️  $name not found (may not be needed)"
    fi
}

# Copy main libraries
copy_headers "OpenImageIO"
copy_headers "OpenColorIO"

# Copy OpenImageIO dependencies
echo ""
echo "📋 Copying OpenImageIO dependencies..."
copy_headers "Imath"
copy_headers "OpenEXR"
copy_headers "Iex"
copy_headers "IlmThread"
copy_headers "half"
copy_headers "fmt"

# Copy OpenColorIO dependencies
echo ""
echo "📋 Copying OpenColorIO dependencies..."
copy_headers "yaml-cpp"
copy_headers "pystring"

# Copy common image format libraries
echo ""
echo "📋 Copying image format libraries..."
copy_headers "png.h"
copy_headers "jpeglib.h"
copy_headers "tiff.h"
copy_headers "tiffio.h"
copy_headers "webp"

# Some headers are single files, not directories
echo ""
echo "📋 Copying single-file headers..."

for header in libpng16/png.h libpng16/pngconf.h zlib.h zconf.h; do
    if [ -f "$BREW_PREFIX/include/$header" ]; then
        mkdir -p "$PROJECT_INCLUDE/$(dirname "$header")"
        cp -L "$BREW_PREFIX/include/$header" "$PROJECT_INCLUDE/$header"
        echo "   ✅ Copied $header"
    fi
done

echo ""
echo "🧪 Testing compilation..."
echo ""

# Create a test file
TEST_FILE="/tmp/test_oiio.mm"
cat > "$TEST_FILE" << 'EOF'
#include <OpenImageIO/imageio.h>
#include <OpenImageIO/imagebuf.h>
#include <OpenImageIO/imagebufalgo.h>

int main() {
    return 0;
}
EOF

# Try to compile with only our Include directory
INCLUDE_PATH="$(pwd)/$PROJECT_INCLUDE"

if clang++ -c -I"$INCLUDE_PATH" -std=c++17 "$TEST_FILE" -o /tmp/test_oiio.o 2>&1 | tee /tmp/compile_output.txt; then
    echo ""
    echo "✅ SUCCESS! Compilation works with only local headers!"
    rm -f /tmp/test_oiio.o
else
    echo ""
    echo "⚠️  Compilation failed. Checking what's missing..."
    echo ""
    
    # Parse error output to find missing headers
    MISSING=$(grep "fatal error:" /tmp/compile_output.txt | grep "file not found" | sed "s/.*'\(.*\)'.*/\1/" | sort -u)
    
    if [ -n "$MISSING" ]; then
        echo "Missing headers:"
        echo "$MISSING"
        echo ""
        echo "Let me try to find and copy them..."
        echo ""
        
        for missing_header in $MISSING; do
            # Extract just the directory name
            missing_dir=$(echo "$missing_header" | cut -d'/' -f1)
            
            if [ -d "$BREW_PREFIX/include/$missing_dir" ]; then
                echo "📦 Found $missing_dir, copying..."
                copy_headers "$missing_dir"
            else
                # Try to find the file directly
                found=$(find "$BREW_PREFIX/include" -name "$(basename $missing_header)" 2>/dev/null | head -1)
                if [ -n "$found" ]; then
                    rel_path="${found#$BREW_PREFIX/include/}"
                    mkdir -p "$PROJECT_INCLUDE/$(dirname "$rel_path")"
                    cp -L "$found" "$PROJECT_INCLUDE/$rel_path"
                    echo "   ✅ Copied $(dirname "$rel_path")"
                fi
            fi
        done
        
        echo ""
        echo "Retrying compilation..."
        if clang++ -c -I"$INCLUDE_PATH" -std=c++17 "$TEST_FILE" -o /tmp/test_oiio.o 2>/dev/null; then
            echo "✅ SUCCESS after copying missing headers!"
            rm -f /tmp/test_oiio.o
        else
            echo "❌ Still failing. Manual intervention needed."
            echo "Run the compilation and check errors:"
            echo "clang++ -c -I$INCLUDE_PATH -std=c++17 $TEST_FILE 2>&1 | grep 'file not found'"
        fi
    fi
fi

rm -f "$TEST_FILE" /tmp/compile_output.txt

echo ""
echo "================================================"
echo "📊 SUMMARY"
echo "================================================"
echo ""

# Count what we have
TOTAL_HEADERS=$(find "$PROJECT_INCLUDE" -type f \( -name "*.h" -o -name "*.hpp" \) 2>/dev/null | wc -l | tr -d ' ')
echo "Total headers copied: $TOTAL_HEADERS"
echo ""

echo "Directories in Include/:"
ls -1 "$PROJECT_INCLUDE" | grep -v "^\." | while read dir; do
    if [ -d "$PROJECT_INCLUDE/$dir" ]; then
        count=$(find "$PROJECT_INCLUDE/$dir" -type f \( -name "*.h" -o -name "*.hpp" \) 2>/dev/null | wc -l | tr -d ' ')
        echo "  • $dir: $count files"
    fi
done

echo ""
echo "================================================"
echo "✅ XCODE CONFIGURATION"
echo "================================================"
echo ""
echo "Header Search Paths (ONLY this, nothing else):"
echo ""
echo "  \$(SRCROOT)/Tristimulator/Include"
echo ""
echo "NO Homebrew paths needed!"
echo ""
echo "Library Search Paths:"
echo "  /opt/homebrew/lib"
echo ""
echo "(Libraries still from Homebrew, but headers are self-contained)"
echo ""
echo "Now:"
echo "  1. Set Header Search Paths to: \$(SRCROOT)/Tristimulator/Include"
echo "  2. Remove /opt/homebrew/include from Header Search Paths"
echo "  3. Clean (⌘⇧K)"
echo "  4. Build (⌘B)"
echo ""
