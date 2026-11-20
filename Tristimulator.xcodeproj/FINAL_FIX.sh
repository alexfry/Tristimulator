#!/bin/bash
# FINAL_FIX.sh
# The absolute final solution to this mess

set -e

echo "🚀 FINAL FIX - Complete Dylib Solution"
echo "======================================="
echo ""
echo "This will properly handle ALL dylibs with correct versioning."
echo ""

read -p "Ready? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    HOMEBREW_PREFIX="/opt/homebrew"
else
    HOMEBREW_PREFIX="/usr/local"
fi

DYLIBS_DIR="./Dylibs"
SIGNING_IDENTITY="Apple Development: Alex Fry (7CART63SAF)"

echo ""
echo "Step 1: Find ALL OpenImageIO/OpenColorIO related files in Homebrew"
echo "==================================================================="
echo ""

# Get every single OpenImageIO and OpenColorIO file
ALL_OIIO_FILES=$(ls -1 "$HOMEBREW_PREFIX/lib"/libOpenImageIO*.dylib 2>/dev/null || true)
ALL_OCIO_FILES=$(ls -1 "$HOMEBREW_PREFIX/lib"/libOpenColorIO*.dylib 2>/dev/null || true)

echo "Found in Homebrew:"
echo "$ALL_OIIO_FILES" | while read f; do [ -n "$f" ] && echo "  $(basename $f)"; done
echo "$ALL_OCIO_FILES" | while read f; do [ -n "$f" ] && echo "  $(basename $f)"; done
echo ""

echo "Step 2: Copy each file (following symlinks for content, keeping name)"
echo "====================================================================="
echo ""

copy_and_process() {
    local src_path=$1
    local file_name=$(basename "$src_path")
    
    if [ -f "$DYLIBS_DIR/$file_name" ]; then
        echo "  ✓ $file_name (exists)"
        return
    fi
    
    echo "  + $file_name"
    
    # If it's a symlink, copy the REAL file but keep the SYMLINK name
    if [ -L "$src_path" ]; then
        REAL_PATH=$(readlink -f "$src_path" 2>/dev/null || greadlink -f "$src_path" 2>/dev/null || realpath "$src_path" 2>/dev/null || echo "$src_path")
        cp "$REAL_PATH" "$DYLIBS_DIR/$file_name"
    else
        cp "$src_path" "$DYLIBS_DIR/$file_name"
    fi
    
    chmod +w "$DYLIBS_DIR/$file_name"
    
    # Fix install name to match the filename (not the real path)
    install_name_tool -id "@rpath/$file_name" "$DYLIBS_DIR/$file_name" 2>/dev/null || true
    
    # Fix all dependencies
    otool -L "$DYLIBS_DIR/$file_name" | grep -E "($HOMEBREW_PREFIX|/usr/local|@rpath)" | awk '{print $1}' | while read dep; do
        if [ -z "$dep" ] || [ "$dep" = "$DYLIBS_DIR/$file_name:" ]; then
            continue
        fi
        
        dep_base=$(basename "$dep")
        
        # Change Homebrew paths to @rpath
        if echo "$dep" | grep -qE "($HOMEBREW_PREFIX|/usr/local)"; then
            if [ -f "$DYLIBS_DIR/$dep_base" ]; then
                install_name_tool -change "$dep" "@rpath/$dep_base" "$DYLIBS_DIR/$file_name" 2>/dev/null || true
            fi
        fi
    done
    
    # Sign it
    xattr -cr "$DYLIBS_DIR/$file_name" 2>/dev/null || true
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$DYLIBS_DIR/$file_name" 2>/dev/null || true
}

# Process all found files
echo "$ALL_OIIO_FILES" | while read f; do
    [ -n "$f" ] && [ -e "$f" ] && copy_and_process "$f"
done

echo "$ALL_OCIO_FILES" | while read f; do
    [ -n "$f" ] && [ -e "$f" ] && copy_and_process "$f"
done

echo ""
echo "Step 3: Fix cross-references between the files we just added"
echo "============================================================="
echo ""

# Second pass: fix references between OpenImageIO files
for dylib in "$DYLIBS_DIR"/libOpenImageIO*.dylib "$DYLIBS_DIR"/libOpenColorIO*.dylib; do
    if [ ! -f "$dylib" ]; then
        continue
    fi
    
    dylib_name=$(basename "$dylib")
    echo "  Fixing: $dylib_name"
    
    # Get all @rpath dependencies
    otool -L "$dylib" | grep "@rpath" | awk '{print $1}' | while read dep; do
        dep_file=$(basename "$dep")
        
        # If we have this file but the path is wrong, fix it
        if [ -f "$DYLIBS_DIR/$dep_file" ]; then
            # Make sure it points to @rpath/filename
            install_name_tool -change "$dep" "@rpath/$dep_file" "$dylib" 2>/dev/null || true
        fi
    done
done

echo ""
echo "Step 4: Show what we have now"
echo "=============================="
echo ""

echo "OpenImageIO/OpenColorIO files in Dylibs/:"
ls -lh "$DYLIBS_DIR" | grep -E "(OpenImageIO|OpenColorIO)" | awk '{print "  " $9 " (" $5 ")"}'

echo ""
echo "======================================="
echo "✅ DONE!"
echo "======================================="
echo ""
echo "You should now have BOTH:"
echo "  • libOpenImageIO_Util.dylib"
echo "  • libOpenImageIO_Util.3.1.dylib"
echo ""
echo "📋 FINAL STEPS IN XCODE:"
echo "========================"
echo ""
echo "1. Build Phases → Copy Dylibs"
echo ""
echo "2. Make sure ALL these files are included:"
ls -1 "$DYLIBS_DIR" | grep -E "(OpenImageIO|OpenColorIO)" | while read f; do
    echo "   • $f"
done
echo ""
echo "3. If any are missing from the phase:"
echo "   • Click '+'"
echo "   • Add them"
echo ""
echo "4. Clean Build Folder: ⌘⇧K"
echo "5. Build: ⌘B"
echo "6. Run: ⌘R"
echo ""
echo "This SHOULD fix it!"
echo ""
