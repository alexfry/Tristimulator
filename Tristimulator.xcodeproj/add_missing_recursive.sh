#!/bin/bash
# add_missing_recursive.sh
# Recursively find and add ALL missing dependencies

set -e

echo "🔍 Recursive Dependency Scanner and Fixer"
echo "=========================================="
echo ""

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    HOMEBREW_PREFIX="/opt/homebrew"
else
    HOMEBREW_PREFIX="/usr/local"
fi

DYLIBS_DIR="./Dylibs"
SIGNING_IDENTITY="Apple Development: Alex Fry (7CART63SAF)"

echo "This will scan ALL dylibs recursively and add any missing ones."
echo ""

ADDED_COUNT=0
MAX_ITERATIONS=10
ITERATION=0

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))
    echo "Scan iteration $ITERATION..."
    
    FOUND_NEW=false
    
    # Check every dylib we have for missing dependencies
    for dylib in "$DYLIBS_DIR"/*.dylib; do
        if [ ! -f "$dylib" ]; then
            continue
        fi
        
        # Get dependencies
        DEPS=$(otool -L "$dylib" 2>/dev/null | grep -E "(@rpath|$HOMEBREW_PREFIX|/usr/local)" | awk '{print $1}' || true)
        
        while IFS= read -r dep; do
            if [ -z "$dep" ]; then
                continue
            fi
            
            # Extract filename
            if echo "$dep" | grep -q "@rpath"; then
                dep_file=$(basename "$dep")
            else
                dep_file=$(basename "$dep")
            fi
            
            # Skip if we already have it
            if [ -f "$DYLIBS_DIR/$dep_file" ]; then
                continue
            fi
            
            # Try to find it in Homebrew
            SOURCE=""
            if [ -f "$HOMEBREW_PREFIX/lib/$dep_file" ]; then
                SOURCE="$HOMEBREW_PREFIX/lib/$dep_file"
            elif [ -L "$HOMEBREW_PREFIX/lib/$dep_file" ]; then
                # Follow symlink
                SOURCE=$(readlink -f "$HOMEBREW_PREFIX/lib/$dep_file" 2>/dev/null || \
                         greadlink -f "$HOMEBREW_PREFIX/lib/$dep_file" 2>/dev/null || \
                         realpath "$HOMEBREW_PREFIX/lib/$dep_file" 2>/dev/null || \
                         echo "")
            fi
            
            if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
                continue
            fi
            
            # Found a new dependency!
            echo "  📦 Found missing: $dep_file"
            FOUND_NEW=true
            
            # Copy it
            cp "$SOURCE" "$DYLIBS_DIR/$dep_file"
            chmod +w "$DYLIBS_DIR/$dep_file"
            
            # Fix install name
            install_name_tool -id "@rpath/$dep_file" "$DYLIBS_DIR/$dep_file" 2>/dev/null || true
            
            # Fix its dependencies
            DEP_DEPS=$(otool -L "$DYLIBS_DIR/$dep_file" | grep -E "($HOMEBREW_PREFIX|/usr/local)" | awk '{print $1}' || true)
            for d in $DEP_DEPS; do
                d_name=$(basename "$d")
                if [ -f "$DYLIBS_DIR/$d_name" ]; then
                    install_name_tool -change "$d" "@rpath/$d_name" "$DYLIBS_DIR/$dep_file" 2>/dev/null || true
                fi
            done
            
            # Sign it
            xattr -cr "$DYLIBS_DIR/$dep_file" 2>/dev/null || true
            codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$DYLIBS_DIR/$dep_file" 2>/dev/null || true
            
            ADDED_COUNT=$((ADDED_COUNT + 1))
            
        done <<< "$DEPS"
    done
    
    if [ "$FOUND_NEW" = false ]; then
        echo "  ✅ No new dependencies found"
        break
    fi
done

echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo ""

if [ $ADDED_COUNT -eq 0 ]; then
    echo "✅ No missing dependencies - all good!"
else
    echo "✅ Added $ADDED_COUNT missing dylibs"
    echo ""
    echo "Newly added files:"
    echo ""
    
    # Show what was added (rough estimate - files modified in last minute)
    find "$DYLIBS_DIR" -name "*.dylib" -mmin -1 -exec basename {} \; | while read f; do
        echo "  • $f"
    done
    
    echo ""
    echo "📋 NEXT STEPS IN XCODE:"
    echo "======================="
    echo ""
    echo "Since you said you're adding ALL dylibs, just do:"
    echo ""
    echo "1. Build Phases → Copy Dylibs"
    echo "2. Remove ALL files (⌘A, then Delete)"
    echo "3. Click '+'"
    echo "4. Navigate to: $(pwd)/Dylibs"
    echo "5. Select ALL (⌘A)"
    echo "6. Add"
    echo "7. Check 'Code Sign On Copy'"
    echo "8. Clean (⌘⇧K) and Build (⌘B)"
fi

echo ""
echo "Total dylibs in Dylibs/: $(ls -1 "$DYLIBS_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ')"
echo ""
