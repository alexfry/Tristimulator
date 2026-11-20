#!/bin/bash
# find_all_missing_deps.sh
# Scan the app bundle and find ALL missing dependencies recursively

echo "🔍 Finding All Missing Dependencies"
echo "===================================="
echo ""

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    HOMEBREW_PREFIX="/opt/homebrew"
elif [ "$ARCH" = "x86_64" ]; then
    HOMEBREW_PREFIX="/usr/local"
else
    HOMEBREW_PREFIX=$(brew --prefix)
fi

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug -name "Tristimulator.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ App not found - build it first"
    exit 1
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

echo "Scanning app bundle: $APP_PATH"
echo ""

# Track what we've checked and what's missing
CHECKED_FILE=$(mktemp /tmp/checked_deps.XXXXXX)
MISSING_FILE=$(mktemp /tmp/missing_deps.XXXXXX)

check_dependencies() {
    local file=$1
    local file_name=$(basename "$file")
    
    # Skip if already checked
    if grep -qF "$file_name" "$CHECKED_FILE" 2>/dev/null; then
        return
    fi
    
    # Mark as checked
    echo "$file_name" >> "$CHECKED_FILE"
    
    # Get dependencies
    local deps=$(otool -L "$file" 2>/dev/null | grep "@rpath" | awk '{print $1}' || true)
    
    # Check each dependency
    while IFS= read -r dep; do
        if [ -n "$dep" ]; then
            local dep_file=$(basename "$dep")
            
            if [ ! -f "$FRAMEWORKS_DIR/$dep_file" ]; then
                # Missing dependency!
                if ! grep -qF "$dep_file" "$MISSING_FILE" 2>/dev/null; then
                    echo "$dep_file" >> "$MISSING_FILE"
                    echo "  ❌ Missing: $dep_file (needed by $file_name)"
                fi
            else
                # Recursively check this dependency
                check_dependencies "$FRAMEWORKS_DIR/$dep_file"
            fi
        fi
    done <<< "$deps"
}

echo "Checking all dylibs in app bundle..."
echo ""

# Start with all dylibs in Frameworks
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    if [ -f "$dylib" ]; then
        check_dependencies "$dylib"
    fi
done

# Also check the main executable
MAIN_EXEC="$APP_PATH/Contents/MacOS/Tristimulator"
if [ -f "$MAIN_EXEC" ]; then
    check_dependencies "$MAIN_EXEC"
fi

echo ""
echo "===================================="
echo "Summary"
echo "===================================="
echo ""

if [ ! -s "$MISSING_FILE" ]; then
    echo "✅ No missing dependencies found!"
    echo "   All dylibs are present."
else
    MISSING_COUNT=$(wc -l < "$MISSING_FILE" | tr -d ' ')
    echo "❌ Found $MISSING_COUNT missing dependencies:"
    echo ""
    
    cat "$MISSING_FILE" | sort -u | while read dep; do
        echo "  • $dep"
        
        # Try to find it in Homebrew
        if [ -f "$HOMEBREW_PREFIX/lib/$dep" ]; then
            echo "    Found in: $HOMEBREW_PREFIX/lib/$dep"
        else
            echo "    ⚠️  Not found in Homebrew - might need to install package"
        fi
    done
    echo ""
    echo "Run: ./add_all_missing_deps.sh to add them"
fi

# Cleanup
rm -f "$CHECKED_FILE" "$MISSING_FILE"

echo ""
