#!/bin/bash
# add_all_missing_deps.sh
# Add all missing dependencies to Dylibs folder

set -e

echo "🔧 Adding All Missing Dependencies"
echo "==================================="
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

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug -name "Tristimulator.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ App not found - build it first"
    exit 1
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

# Track missing deps
CHECKED_FILE=$(mktemp /tmp/checked_deps.XXXXXX)
MISSING_FILE=$(mktemp /tmp/missing_deps.XXXXXX)

check_dependencies() {
    local file=$1
    local file_name=$(basename "$file")
    
    # Skip if already checked
    if grep -qF "$file_name" "$CHECKED_FILE" 2>/dev/null; then
        return
    fi
    
    echo "$file_name" >> "$CHECKED_FILE"
    
    # Get dependencies
    local deps=$(otool -L "$file" 2>/dev/null | grep "@rpath" | awk '{print $1}' || true)
    
    while IFS= read -r dep; do
        if [ -n "$dep" ]; then
            local dep_file=$(basename "$dep")
            
            if [ ! -f "$FRAMEWORKS_DIR/$dep_file" ]; then
                if ! grep -qF "$dep_file" "$MISSING_FILE" 2>/dev/null; then
                    echo "$dep_file" >> "$MISSING_FILE"
                fi
            else
                check_dependencies "$FRAMEWORKS_DIR/$dep_file"
            fi
        fi
    done <<< "$deps"
}

echo "Step 1: Scanning for missing dependencies..."
echo ""

for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    if [ -f "$dylib" ]; then
        check_dependencies "$dylib"
    fi
done

MAIN_EXEC="$APP_PATH/Contents/MacOS/Tristimulator"
if [ -f "$MAIN_EXEC" ]; then
    check_dependencies "$MAIN_EXEC"
fi

if [ ! -s "$MISSING_FILE" ]; then
    echo "✅ No missing dependencies!"
    rm -f "$CHECKED_FILE" "$MISSING_FILE"
    exit 0
fi

MISSING_COUNT=$(wc -l < "$MISSING_FILE" | tr -d ' ')
echo "Found $MISSING_COUNT missing dependencies"
echo ""

echo "Step 2: Adding missing dylibs..."
echo ""

ADDED_COUNT=0
NOT_FOUND_COUNT=0
ALREADY_IN_DYLIBS=0

cat "$MISSING_FILE" | sort -u | while read dep_file; do
    echo "Processing: $dep_file"
    
    # Check if already in Dylibs/
    if [ -f "$DYLIBS_DIR/$dep_file" ]; then
        echo "  ⚠️  Already in Dylibs/ - just needs to be added to Copy Files phase"
        ALREADY_IN_DYLIBS=$((ALREADY_IN_DYLIBS + 1))
        continue
    fi
    
    # Try to find in Homebrew
    SOURCE=""
    if [ -f "$HOMEBREW_PREFIX/lib/$dep_file" ]; then
        SOURCE="$HOMEBREW_PREFIX/lib/$dep_file"
    elif [ -L "$HOMEBREW_PREFIX/lib/$dep_file" ]; then
        # Follow symlink
        SOURCE=$(readlink -f "$HOMEBREW_PREFIX/lib/$dep_file" 2>/dev/null || greadlink -f "$HOMEBREW_PREFIX/lib/$dep_file" 2>/dev/null || echo "")
    fi
    
    if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
        echo "  ❌ Not found in Homebrew"
        NOT_FOUND_COUNT=$((NOT_FOUND_COUNT + 1))
        continue
    fi
    
    # Copy it
    cp "$SOURCE" "$DYLIBS_DIR/$dep_file"
    chmod +w "$DYLIBS_DIR/$dep_file"
    
    # Fix install name
    install_name_tool -id "@rpath/$dep_file" "$DYLIBS_DIR/$dep_file" 2>/dev/null || true
    
    # Fix its dependencies
    DEPS=$(otool -L "$DYLIBS_DIR/$dep_file" | grep -E "($HOMEBREW_PREFIX|/usr/local)" | awk '{print $1}' || true)
    for dep in $DEPS; do
        dep_name=$(basename "$dep")
        if [ -f "$DYLIBS_DIR/$dep_name" ]; then
            install_name_tool -change "$dep" "@rpath/$dep_name" "$DYLIBS_DIR/$dep_file" 2>/dev/null || true
        fi
    done
    
    # Sign it
    xattr -cr "$DYLIBS_DIR/$dep_file" 2>/dev/null || true
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$DYLIBS_DIR/$dep_file" 2>/dev/null || true
    
    echo "  ✅ Added, fixed, and signed"
    ADDED_COUNT=$((ADDED_COUNT + 1))
done

rm -f "$CHECKED_FILE" "$MISSING_FILE"

echo ""
echo "==================================="
echo "Summary"
echo "==================================="
echo ""

if [ $ADDED_COUNT -gt 0 ]; then
    echo "✅ Added $ADDED_COUNT new dylibs to Dylibs/"
fi

if [ $ALREADY_IN_DYLIBS -gt 0 ]; then
    echo "⚠️  $ALREADY_IN_DYLIBS dylibs already in Dylibs/ - need to be added to Copy Files"
fi

if [ $NOT_FOUND_COUNT -gt 0 ]; then
    echo "❌ $NOT_FOUND_COUNT dylibs not found in Homebrew"
    echo "   You may need to install additional packages"
fi

echo ""
echo "==================================="
echo "📋 NEXT STEPS IN XCODE"
echo "==================================="
echo ""
echo "The new dylibs have been added to Dylibs/ folder."
echo ""
echo "You need to add them to the Copy Files phase:"
echo ""
echo "1. Xcode → Tristimulator target → Build Phases"
echo ""
echo "2. Find 'Copy Dylibs' phase"
echo ""
echo "3. Click '+' to add files"
echo ""
echo "4. Navigate to Dylibs/ folder"
echo ""
echo "5. Select ONLY the NEW files just added:"
cat "$MISSING_FILE" 2>/dev/null | sort -u | while read dep; do
    if [ -f "$DYLIBS_DIR/$dep" ]; then
        echo "   • $dep"
    fi
done
echo ""
echo "6. Or easier: Remove all files and re-add ALL dylibs"
echo "   • Select all files in the phase"
echo "   • Press Delete"
echo "   • Click '+'"
echo "   • Navigate to Dylibs/"
echo "   • Select ALL (⌘A)"
echo "   • Add them"
echo ""
echo "7. Make sure 'Code Sign On Copy' is checked"
echo ""
echo "8. Clean and rebuild:"
echo "   ⌘⇧K then ⌘B"
echo ""
echo "9. Run app (⌘R)"
echo ""
