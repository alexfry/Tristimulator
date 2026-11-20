#!/bin/bash
# switch_to_dylibs.sh
# Switch from broken frameworks approach to working dylibs approach

set -e

echo "🔄 Switching to Dylibs Approach"
echo "==============================="
echo ""

echo "This will:"
echo "  1. Remove the broken Frameworks directory"
echo "  2. Create properly signed .dylib files"
echo "  3. Give you instructions for updating Xcode"
echo ""

read -p "Continue? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Step 1: Removing old Frameworks directory..."
if [ -d "./Frameworks" ]; then
    echo "  Backing up to Frameworks.old.$(date +%s)..."
    mv "./Frameworks" "./Frameworks.old.$(date +%s)"
    echo "  ✅ Old frameworks removed"
else
    echo "  (No Frameworks directory found)"
fi
echo ""

echo "Step 2: Running dylib embedding script..."
echo ""
chmod +x embed_dylibs_simple.sh
./embed_dylibs_simple.sh

echo ""
echo "==============================="
echo "✅ Switch complete!"
echo "==============================="
echo ""
echo "Now follow the Xcode configuration steps shown above."
echo ""
