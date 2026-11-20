#!/bin/bash
# diagnose_archive_issue.sh
# Diagnose why archiving fails when regular builds work

echo "🔍 Archive Build Issue Diagnosis"
echo "================================="
echo ""

# Check Homebrew installation
echo "1️⃣ Checking Homebrew installation..."
if [ -d "/opt/homebrew" ]; then
    BREW_PREFIX="/opt/homebrew"
    echo "✅ Apple Silicon detected: $BREW_PREFIX"
elif [ -d "/usr/local" ]; then
    BREW_PREFIX="/usr/local"
    echo "✅ Intel Mac detected: $BREW_PREFIX"
else
    echo "❌ Homebrew not found!"
    exit 1
fi
echo ""

# Check for libraries
echo "2️⃣ Checking for required libraries..."
OIIO_LIB="$BREW_PREFIX/lib/libOpenImageIO.dylib"
OCIO_LIB="$BREW_PREFIX/lib/libOpenColorIO.dylib"

if [ -f "$OIIO_LIB" ]; then
    echo "✅ OpenImageIO found: $OIIO_LIB"
    ls -lh "$OIIO_LIB"
else
    echo "❌ OpenImageIO not found at: $OIIO_LIB"
fi

if [ -f "$OCIO_LIB" ]; then
    echo "✅ OpenColorIO found: $OCIO_LIB"
    ls -lh "$OCIO_LIB"
else
    echo "❌ OpenColorIO not found at: $OCIO_LIB"
fi
echo ""

# Check for versioned libraries
echo "3️⃣ Checking for versioned library files..."
echo "OpenImageIO variants:"
ls -lh "$BREW_PREFIX/lib/libOpenImageIO"* 2>/dev/null || echo "  None found"
echo ""
echo "OpenColorIO variants:"
ls -lh "$BREW_PREFIX/lib/libOpenColorIO"* 2>/dev/null || echo "  None found"
echo ""

# Check project structure
echo "4️⃣ Checking project structure..."
if [ -d "Tristimulator.xcodeproj" ]; then
    echo "✅ Found Tristimulator.xcodeproj"
elif [ -d "Tristimulator.xcworkspace" ]; then
    echo "✅ Found Tristimulator.xcworkspace"
else
    echo "⚠️  Project file not found in current directory"
    echo "   Current directory: $PWD"
fi
echo ""

# Check for embedded dylibs
echo "5️⃣ Checking for embedded dylibs..."
if [ -d "Dylibs" ]; then
    echo "✅ Found Dylibs directory:"
    ls -lh Dylibs/
else
    echo "❌ No Dylibs directory found"
    echo "   This might be why Archive fails!"
fi
echo ""

# Check DerivedData
echo "6️⃣ Checking recent builds..."
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$DERIVED_DATA" ]; then
    echo "Most recent Tristimulator builds:"
    find "$DERIVED_DATA" -name "Tristimulator-*" -type d -maxdepth 1 | head -3
else
    echo "⚠️  DerivedData not found"
fi
echo ""

# Recommendations
echo "================================================"
echo "📋 RECOMMENDATIONS"
echo "================================================"
echo ""

HAS_DYLIBS=false
if [ -d "Dylibs" ] && [ "$(ls -A Dylibs 2>/dev/null)" ]; then
    HAS_DYLIBS=true
fi

if [ "$HAS_DYLIBS" = true ]; then
    echo "✅ You have a Dylibs directory with embedded libraries."
    echo ""
    echo "For Archive builds to work, you need to:"
    echo ""
    echo "Option A: Use embedded dylibs (recommended)"
    echo "----------------------------------------"
    echo "1. In Xcode Build Settings, set:"
    echo "   • LIBRARY_SEARCH_PATHS = \$(PROJECT_DIR)/Dylibs"
    echo "   • Remove /opt/homebrew/lib from search paths"
    echo ""
    echo "2. Make sure Build Phases includes:"
    echo "   • 'Copy Files' phase with Destination: Frameworks"
    echo "   • All .dylib files from Dylibs/ directory"
    echo "   • 'Code Sign On Copy' checked"
    echo ""
    echo "3. Other Linker Flags should have:"
    echo "   -lOpenImageIO"
    echo "   -lOpenImageIO_Util"
    echo "   -lOpenColorIO"
    echo "   -lc++"
    echo ""
else
    echo "❌ No embedded dylibs found."
    echo ""
    echo "You have TWO options:"
    echo ""
    echo "Option A: Embed the dylibs (faster)"
    echo "-----------------------------------"
    echo "Run this script to copy and prepare libraries:"
    echo "  ./fix_dylib_copying.sh"
    echo ""
    echo "Then in Xcode:"
    echo "  1. Add Dylibs/*.dylib to your project"
    echo "  2. Add them to a 'Copy Files' build phase"
    echo "  3. Set destination to 'Frameworks'"
    echo "  4. Check 'Code Sign On Copy'"
    echo ""
    echo "Option B: Build static libraries (best long-term)"
    echo "-------------------------------------------------"
    echo "Run this script (takes 30-60 minutes):"
    echo "  ./build_static_libs.sh"
    echo ""
    echo "Then follow the instructions it provides."
    echo ""
fi

echo ""
echo "================================================"
echo "🔍 COMMON ISSUES & SOLUTIONS"
echo "================================================"
echo ""
echo "Issue: 'library OpenImageIO not found'"
echo "---------------------------------------"
echo "Cause: Archive builds don't search /opt/homebrew/lib by default"
echo "Fix: Either embed dylibs OR add to LIBRARY_SEARCH_PATHS"
echo ""
echo "Issue: Duplicate library warnings"
echo "---------------------------------"
echo "Cause: Library specified multiple times in linker flags"
echo "Fix: Check 'Other Linker Flags' - remove duplicates"
echo ""
echo "Issue: Works in Debug, fails in Archive"
echo "----------------------------------------"
echo "Cause: Different library search paths for different configs"
echo "Fix: Set search paths for 'Any Architecture | Any SDK'"
echo ""

# Check for common Xcode issues
echo ""
echo "7️⃣ Quick Xcode checklist..."
echo ""
echo "In Xcode Build Settings, verify:"
echo "  [ ] LIBRARY_SEARCH_PATHS includes library location"
echo "  [ ] HEADER_SEARCH_PATHS includes /opt/homebrew/include"
echo "  [ ] LD_RUNPATH_SEARCH_PATHS includes @executable_path/../Frameworks"
echo "  [ ] OTHER_LDFLAGS doesn't have duplicate -l entries"
echo "  [ ] ENABLE_HARDENED_RUNTIME = YES"
echo "  [ ] CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES"
echo ""
echo "In Build Phases:"
echo "  [ ] 'Copy Files' phase exists with destination 'Frameworks'"
echo "  [ ] All dylibs are in the Copy Files phase"
echo "  [ ] 'Code Sign On Copy' is checked"
echo ""

echo "================================================"
echo "Run this diagnostic again after making changes"
echo "================================================"
