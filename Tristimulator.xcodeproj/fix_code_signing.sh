#!/bin/bash
# fix_code_signing.sh
# Fix code signing issues for embedded frameworks

set -e

echo "🔐 Fixing Framework Code Signing"
echo "================================="
echo ""

FRAMEWORKS_DIR="./Frameworks"

if [ ! -d "$FRAMEWORKS_DIR" ]; then
    echo "❌ Frameworks directory not found"
    exit 1
fi

echo "Step 1: Removing any extended attributes (macOS metadata)..."
xattr -cr "$FRAMEWORKS_DIR"/*.framework 2>/dev/null || true
echo "  ✅ Metadata removed"

echo ""
echo "Step 2: Ad-hoc signing all frameworks..."

COUNT=0
FAILED=0

for fw in "$FRAMEWORKS_DIR"/*.framework; do
    if [ -d "$fw" ]; then
        fw_name=$(basename "$fw")
        echo "  Signing $fw_name..."
        
        if codesign --force --deep --sign "-" "$fw" 2>/dev/null; then
            COUNT=$((COUNT + 1))
        else
            echo "    ⚠️  Failed to sign $fw_name"
            FAILED=$((FAILED + 1))
        fi
    fi
done

echo ""
echo "================================="
echo "✅ Signed $COUNT frameworks"
if [ $FAILED -gt 0 ]; then
    echo "⚠️  Failed to sign $FAILED frameworks"
fi
echo "================================="
echo ""

echo "📋 Next steps in Xcode:"
echo ""
echo "1. Go to Build Phases → Copy Frameworks"
echo "2. UNCHECK 'Code Sign On Copy' for all frameworks"
echo "   (They're already signed by this script)"
echo ""
echo "3. Go to Build Settings → Search 'Code Signing Identity'"
echo "4. Set to 'Sign to Run Locally'"
echo ""
echo "5. Clean Build Folder (⌘⇧K)"
echo "6. Build (⌘B)"
echo ""
echo "This will work for development. For distribution,"
echo "see CODE_SIGNING_FIX.md for proper signing."
echo ""
