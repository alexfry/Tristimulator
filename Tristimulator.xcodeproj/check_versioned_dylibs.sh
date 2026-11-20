#!/bin/bash
# check_versioned_dylibs.sh
# Check which versioned dylibs are missing

echo "🔍 Checking Versioned Dylib Dependencies"
echo "========================================="
echo ""

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug -name "Tristimulator.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ App not found"
    exit 1
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

echo "Checking dylib dependencies..."
echo ""

MISSING_DEPS=()

# Check each dylib in the bundle for its dependencies
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    if [ -f "$dylib" ]; then
        dylib_name=$(basename "$dylib")
        
        # Get dependencies that use @rpath
        DEPS=$(otool -L "$dylib" 2>/dev/null | grep "@rpath" | awk '{print $1}' || true)
        
        # Check if each dependency exists
        while IFS= read -r dep; do
            if [ -n "$dep" ]; then
                # Extract filename from @rpath/filename
                dep_file=$(basename "$dep")
                
                # Check if it exists in Frameworks
                if [ ! -f "$FRAMEWORKS_DIR/$dep_file" ]; then
                    echo "❌ $dylib_name needs: $dep_file (MISSING!)"
                    
                    # Add to missing list if not already there
                    if ! echo "${MISSING_DEPS[@]}" | grep -q "$dep_file"; then
                        MISSING_DEPS+=("$dep_file")
                    fi
                fi
            fi
        done <<< "$DEPS"
    fi
done

echo ""
echo "========================================="
echo "Summary"
echo "========================================="
echo ""

if [ ${#MISSING_DEPS[@]} -eq 0 ]; then
    echo "✅ All dependencies satisfied!"
else
    echo "❌ Missing ${#MISSING_DEPS[@]} dependencies:"
    echo ""
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  • $dep"
    done
    echo ""
    echo "These need to be added to your Dylibs/ folder"
    echo "and included in the Copy Files phase."
    echo ""
    echo "Run: ./fix_missing_versioned_dylibs.sh"
fi
echo ""
