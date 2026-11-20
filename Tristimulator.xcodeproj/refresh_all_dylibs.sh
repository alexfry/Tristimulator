#!/bin/bash
# refresh_all_dylibs.sh
# Nuclear option: Re-scan and re-embed ALL dependencies

set -e

echo "🔄 Refreshing All Dylibs (Complete Re-scan)"
echo "============================================"
echo ""

echo "This will:"
echo "  1. Backup current Dylibs/ folder"
echo "  2. Re-run complete dependency scan"
echo "  3. Copy ALL dependencies (including missed ones)"
echo "  4. Sign everything"
echo ""

read -p "Continue? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""

# Backup current Dylibs
if [ -d "./Dylibs" ]; then
    BACKUP_NAME="Dylibs.backup.$(date +%s)"
    echo "Backing up current Dylibs/ to $BACKUP_NAME..."
    mv "./Dylibs" "./$BACKUP_NAME"
    echo "  ✅ Backed up"
    echo ""
fi

# Re-run the embed script
echo "Running complete dependency embedding..."
echo ""

if [ ! -f "./embed_dylibs_simple.sh" ]; then
    echo "❌ embed_dylibs_simple.sh not found"
    exit 1
fi

chmod +x ./embed_dylibs_simple.sh
./embed_dylibs_simple.sh

echo ""
echo "============================================"
echo "✅ All dylibs refreshed!"
echo "============================================"
echo ""
echo "📋 IMPORTANT: Update Xcode"
echo "============================="
echo ""
echo "The Dylibs/ folder has been completely rebuilt."
echo "You MUST update the Copy Files phase in Xcode:"
echo ""
echo "1. Xcode → Tristimulator target → Build Phases"
echo ""
echo "2. Find 'Copy Dylibs' or 'Copy Files' phase"
echo ""
echo "3. Delete ALL files from the phase:"
echo "   • Click each file and press Delete"
echo "   • Or select all (⌘A) and press Delete"
echo ""
echo "4. Add ALL dylibs back:"
echo "   • Click '+' in the phase"
echo "   • Navigate to: $(pwd)/Dylibs"
echo "   • Select ALL files (⌘A)"
echo "   • Click 'Add'"
echo ""
echo "5. Verify:"
echo "   • Destination: Frameworks"
echo "   • Code Sign On Copy: ✅ CHECKED"
echo "   • Should show ~100+ .dylib files"
echo ""
echo "6. Clean and rebuild:"
echo "   • ⌘⇧K (Clean Build Folder)"
echo "   • ⌘B (Build)"
echo "   • ⌘R (Run)"
echo ""
echo "This should catch ALL missing dependencies!"
echo ""
