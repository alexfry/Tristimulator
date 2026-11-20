#!/bin/bash
# sign_frameworks_dev.sh
# Properly sign all frameworks with Apple Development certificate

set -e

echo "🔐 Signing Frameworks with Development Certificate"
echo "=================================================="
echo ""

# Configuration
FRAMEWORKS_DIR="./Frameworks"
SIGNING_IDENTITY="Apple Development: Alex Fry (7CART63SAF)"
TEAM_ID="G3"

# Verify frameworks directory exists
if [ ! -d "$FRAMEWORKS_DIR" ]; then
    echo "❌ Frameworks directory not found: $FRAMEWORKS_DIR"
    exit 1
fi

# Verify signing identity is available
echo "Step 1: Verifying signing identity..."
if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    echo "❌ Signing identity not found: $SIGNING_IDENTITY"
    echo ""
    echo "Available identities:"
    security find-identity -v -p codesigning
    exit 1
fi
echo "  ✅ Identity found: $SIGNING_IDENTITY"
echo ""

# Remove extended attributes
echo "Step 2: Removing extended attributes..."
xattr -cr "$FRAMEWORKS_DIR"/*.framework 2>/dev/null || true
echo "  ✅ Metadata cleaned"
echo ""

# Sign all frameworks
echo "Step 3: Signing frameworks..."
echo ""

COUNT=0
FAILED=0
FAILED_LIST=()

for fw in "$FRAMEWORKS_DIR"/*.framework; do
    if [ -d "$fw" ]; then
        fw_name=$(basename "$fw" .framework)
        echo "  Signing $fw_name..."
        
        # Remove any existing signature
        codesign --remove-signature "$fw" 2>/dev/null || true
        
        # Sign with development identity
        if codesign --force --sign "$SIGNING_IDENTITY" \
                    --timestamp \
                    --options runtime \
                    "$fw" 2>&1; then
            COUNT=$((COUNT + 1))
            echo "    ✅ Signed successfully"
        else
            echo "    ❌ Failed to sign"
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$fw_name")
        fi
    fi
done

echo ""
echo "=================================================="
echo "📊 Summary:"
echo "  ✅ Successfully signed: $COUNT frameworks"
if [ $FAILED -gt 0 ]; then
    echo "  ❌ Failed to sign: $FAILED frameworks"
    echo ""
    echo "Failed frameworks:"
    for name in "${FAILED_LIST[@]}"; do
        echo "    • $name"
    done
fi
echo "=================================================="
echo ""

# Verify signatures
echo "Step 4: Verifying signatures..."
echo ""

VERIFIED=0
for fw in "$FRAMEWORKS_DIR"/*.framework; do
    if [ -d "$fw" ]; then
        fw_name=$(basename "$fw" .framework)
        if codesign --verify --deep --strict "$fw" 2>/dev/null; then
            VERIFIED=$((VERIFIED + 1))
        else
            echo "  ⚠️  $fw_name: Verification failed"
        fi
    fi
done

echo "  ✅ Verified $VERIFIED/$COUNT signed frameworks"
echo ""

echo "=================================================="
echo "📋 Next Steps in Xcode:"
echo "=================================================="
echo ""
echo "1. Build Settings → Code Signing:"
echo "   • Code Signing Identity: Apple Development"
echo "   • Development Team: G3"
echo "   • Code Signing Style: Automatic"
echo ""
echo "2. Build Settings → Other Code Signing Flags:"
echo "   REMOVE --deep flag (frameworks already signed)"
echo "   Should be empty or just contain app-specific flags"
echo ""
echo "3. Build Phases → Copy Files (Frameworks):"
echo "   • Destination: Frameworks"
echo "   • Code Sign On Copy: YES"
echo "   • All frameworks should be listed"
echo ""
echo "4. Clean Build:"
echo "   • Product → Clean Build Folder (⌘⇧K)"
echo "   • Delete Derived Data:"
echo "     rm -rf ~/Library/Developer/Xcode/DerivedData/Tristimulator-*"
echo ""
echo "5. Build:"
echo "   • Product → Build (⌘B)"
echo ""
echo "=================================================="
echo ""

if [ $FAILED -gt 0 ]; then
    echo "⚠️  WARNING: Some frameworks failed to sign."
    echo "   This may cause build failures."
    echo "   Check the error messages above."
    echo ""
    exit 1
fi

echo "✅ All frameworks signed successfully!"
echo ""
