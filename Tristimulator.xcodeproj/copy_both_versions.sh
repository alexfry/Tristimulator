#!/bin/bash
# copy_both_versions.sh
# Copy BOTH versioned and unversioned dylibs

set -e

echo "🔧 Copying Both Versioned and Unversioned Dylibs"
echo "================================================="
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

echo "For OpenImageIO libraries, we need BOTH:"
echo "  • Versioned: libOpenImageIO_Util.3.1.dylib"
echo "  • Unversioned: libOpenImageIO_Util.dylib"
echo ""

# List of libraries that need both versions
LIBS_NEEDING_BOTH=(
    "OpenImageIO"
    "OpenImageIO_Util"
    "OpenColorIO"
)

ADDED=0
SKIPPED=0

for lib_base in "${LIBS_NEEDING_BOTH[@]}"; do
    echo "Processing: $lib_base"
    echo ""
    
    # Find all versions in Homebrew
    FOUND_FILES=$(find "$HOMEBREW_PREFIX/lib" -name "lib${lib_base}*.dylib" 2>/dev/null || true)
    
    if [ -z "$FOUND_FILES" ]; then
        echo "  ⚠️  No files found for $lib_base"
        echo ""
        continue
    fi
    
    # Copy each version
    while IFS= read -r src_file; do
        if [ -z "$src_file" ]; then
            continue
        fi
        
        file_name=$(basename "$src_file")
        
        # Check if already in Dylibs/
        if [ -f "$DYLIBS_DIR/$file_name" ]; then
            echo "  ✅ $file_name (already present)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        
        echo "  Adding: $file_name"
        
        # Follow symlinks
        if [ -L "$src_file" ]; then
            REAL_FILE=$(readlink -f "$src_file" 2>/dev/null || greadlink -f "$src_file" 2>/dev/null || echo "$src_file")
            cp "$REAL_FILE" "$DYLIBS_DIR/$file_name"
        else
            cp "$src_file" "$DYLIBS_DIR/$file_name"
        fi
        
        chmod +w "$DYLIBS_DIR/$file_name"
        
        # Fix install name
        install_name_tool -id "@rpath/$file_name" "$DYLIBS_DIR/$file_name" 2>/dev/null || true
        
        # Fix dependencies
        DEPS=$(otool -L "$DYLIBS_DIR/$file_name" | grep -E "($HOMEBREW_PREFIX|/usr/local)" | awk '{print $1}' || true)
        for dep in $DEPS; do
            dep_name=$(basename "$dep")
            if [ -f "$DYLIBS_DIR/$dep_name" ]; then
                install_name_tool -change "$dep" "@rpath/$dep_name" "$DYLIBS_DIR/$file_name" 2>/dev/null || true
            fi
        done
        
        # Sign
        xattr -cr "$DYLIBS_DIR/$file_name" 2>/dev/null || true
        if codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$DYLIBS_DIR/$file_name" 2>/dev/null; then
            echo "    ✅ Signed"
        else
            echo "    ⚠️  Signing failed"
        fi
        
        ADDED=$((ADDED + 1))
        
    done <<< "$FOUND_FILES"
    
    echo ""
done

echo "================================================="
echo "Summary"
echo "================================================="
echo ""
echo "Added: $ADDED files"
echo "Already present: $SKIPPED files"
echo ""

if [ $ADDED -gt 0 ]; then
    echo "New files added to Dylibs/:"
    ls -1 "$DYLIBS_DIR" | grep -E "(OpenImageIO|OpenColorIO)" || true
    echo ""
    echo "📋 NEXT: Add these to Xcode Copy Files phase"
    echo "================================================="
    echo ""
    echo "1. Xcode → Build Phases → Copy Dylibs"
    echo "2. Click '+'"
    echo "3. Add the new files listed above"
    echo "4. Clean (⌘⇧K) and Build (⌘B)"
else
    echo "All files already present."
    echo "If app still crashes, the issue is in Copy Files phase."
fi
echo ""
