#!/bin/bash
# setup_xcode_for_vendor.sh
# Configure Xcode to use the Vendor directory that already exists

set -e

echo "🎯 Xcode Configuration for Vendor Libraries"
echo "============================================"
echo ""

PROJECT_ROOT="$PWD"
VENDOR_DIR="$PROJECT_ROOT/Vendor"

# Check if Vendor directory exists
if [ ! -d "$VENDOR_DIR" ]; then
    echo "❌ Vendor directory not found: $VENDOR_DIR"
    echo "   Run ./build_self_contained.sh first"
    exit 1
fi

# Check for OpenImageIO
if [ ! -d "$VENDOR_DIR/OpenImageIO" ]; then
    echo "❌ OpenImageIO not found in Vendor directory"
    exit 1
fi

# Check for OpenColorIO
if [ ! -d "$VENDOR_DIR/OpenColorIO" ]; then
    echo "❌ OpenColorIO not found in Vendor directory"
    exit 1
fi

echo "✅ Found Vendor directory with dependencies"
echo ""

# Detect what we have
echo "📦 Detected libraries:"
echo ""

# OpenImageIO
if [ -f "$VENDOR_DIR/OpenImageIO/lib/libOpenImageIO.dylib" ]; then
    OIIO_LIB_TYPE="dynamic (.dylib)"
    OIIO_NEEDS_COPY=true
elif [ -f "$VENDOR_DIR/OpenImageIO/lib/libOpenImageIO.a" ]; then
    OIIO_LIB_TYPE="static (.a)"
    OIIO_NEEDS_COPY=false
else
    echo "❌ No OpenImageIO library found"
    exit 1
fi

if [ -f "$VENDOR_DIR/OpenImageIO/lib/libOpenImageIO_Util.dylib" ]; then
    OIIO_UTIL_TYPE="dynamic (.dylib)"
elif [ -f "$VENDOR_DIR/OpenImageIO/lib/libOpenImageIO_Util.a" ]; then
    OIIO_UTIL_TYPE="static (.a)"
else
    OIIO_UTIL_TYPE="not found (may be merged)"
fi

# OpenColorIO
if [ -f "$VENDOR_DIR/OpenColorIO/lib/libOpenColorIO.dylib" ]; then
    OCIO_LIB_TYPE="dynamic (.dylib)"
    OCIO_NEEDS_COPY=true
elif [ -f "$VENDOR_DIR/OpenColorIO/lib/libOpenColorIO.a" ]; then
    OCIO_LIB_TYPE="static (.a)"
    OCIO_NEEDS_COPY=false
else
    echo "❌ No OpenColorIO library found"
    exit 1
fi

echo "  • OpenImageIO: $OIIO_LIB_TYPE"
echo "  • OpenImageIO_Util: $OIIO_UTIL_TYPE"
echo "  • OpenColorIO: $OCIO_LIB_TYPE"
echo ""

# Check headers
if [ -f "$VENDOR_DIR/OpenImageIO/include/OpenImageIO/imageio.h" ]; then
    echo "✅ OpenImageIO headers found"
else
    echo "❌ OpenImageIO headers missing"
    exit 1
fi

if [ -f "$VENDOR_DIR/OpenColorIO/include/OpenColorIO/OpenColorIO.h" ]; then
    echo "✅ OpenColorIO headers found"
else
    echo "❌ OpenColorIO headers missing"
    exit 1
fi

echo ""
echo "================================================"
echo "📋 XCODE BUILD SETTINGS"
echo "================================================"
echo ""

echo "Copy these settings into Xcode:"
echo ""

echo "1️⃣  Header Search Paths (HEADER_SEARCH_PATHS):"
echo "   ---------------------------------------------"
echo "   \$(PROJECT_DIR)/Vendor/OpenImageIO/include"
echo "   \$(PROJECT_DIR)/Vendor/OpenColorIO/include"
echo "   \$(inherited)"
echo ""

echo "2️⃣  Library Search Paths (LIBRARY_SEARCH_PATHS):"
echo "   ----------------------------------------------"
echo "   \$(PROJECT_DIR)/Vendor/OpenImageIO/lib"
echo "   \$(PROJECT_DIR)/Vendor/OpenColorIO/lib"
echo "   \$(inherited)"
echo ""
echo "   Remove these if present:"
echo "   ❌ /opt/homebrew/lib"
echo "   ❌ /usr/local/lib"
echo ""

echo "3️⃣  Other Linker Flags (OTHER_LDFLAGS):"
echo "   -------------------------------------"
echo "   -lOpenImageIO"
echo "   -lOpenImageIO_Util"
echo "   -lOpenColorIO"
echo "   -lc++"
echo "   -lz"
echo "   -framework Foundation"
echo "   -framework AppKit"
echo "   -framework Metal"
echo "   -framework CoreGraphics"
echo ""

if [ "$OIIO_NEEDS_COPY" = true ] || [ "$OCIO_NEEDS_COPY" = true ]; then
    echo "⚠️  IMPORTANT: You have DYNAMIC libraries (.dylib)"
    echo ""
    echo "4️⃣  Runpath Search Paths (LD_RUNPATH_SEARCH_PATHS):"
    echo "   -------------------------------------------------"
    echo "   @executable_path/../Frameworks"
    echo "   @loader_path/../Frameworks"
    echo "   \$(inherited)"
    echo ""
    echo "5️⃣  Build Phases - Add 'Copy Files' Phase:"
    echo "   ----------------------------------------"
    echo "   Destination: Frameworks"
    echo "   Copy these files:"
    
    if [ "$OIIO_NEEDS_COPY" = true ]; then
        echo "   • Vendor/OpenImageIO/lib/libOpenImageIO.dylib"
        echo "   • Vendor/OpenImageIO/lib/libOpenImageIO_Util.dylib"
    fi
    
    if [ "$OCIO_NEEDS_COPY" = true ]; then
        echo "   • Vendor/OpenColorIO/lib/libOpenColorIO.dylib"
    fi
    
    echo ""
    echo "   ✅ Check 'Code Sign On Copy'"
    echo ""
    
    # Fix install names for the dylibs
    echo "6️⃣  Fixing install names for dylibs..."
    echo ""
    
    cd "$VENDOR_DIR/OpenImageIO/lib"
    for lib in *.dylib; do
        if [ -f "$lib" ]; then
            echo "   Fixing: $lib"
            install_name_tool -id "@rpath/$lib" "$lib" 2>/dev/null || true
            
            # Fix references to other OpenImageIO libs
            for dep in *.dylib; do
                if [ -f "$dep" ] && [ "$lib" != "$dep" ]; then
                    install_name_tool -change \
                        "$VENDOR_DIR/OpenImageIO/lib/$dep" \
                        "@rpath/$dep" \
                        "$lib" 2>/dev/null || true
                fi
            done
        fi
    done
    
    cd "$VENDOR_DIR/OpenColorIO/lib"
    for lib in *.dylib; do
        if [ -f "$lib" ]; then
            echo "   Fixing: $lib"
            install_name_tool -id "@rpath/$lib" "$lib" 2>/dev/null || true
        fi
    done
    
    cd "$PROJECT_ROOT"
    
    echo ""
    echo "✅ Install names fixed"
    echo ""
else
    echo "✅ You have static libraries - no copy phase needed!"
    echo ""
fi

echo "================================================"
echo "🚀 NEXT STEPS IN XCODE"
echo "================================================"
echo ""
echo "1. Open Tristimulator.xcodeproj in Xcode"
echo ""
echo "2. Select the Tristimulator target"
echo ""
echo "3. Go to Build Settings tab"
echo "   • Make sure 'All' and 'Combined' are selected"
echo "   • Search for 'Header Search Paths'"
echo "   • Double-click and add the paths shown above"
echo "   • Search for 'Library Search Paths'"
echo "   • Double-click and add the paths shown above"
echo "   • Remove any /opt/homebrew or /usr/local paths"
echo "   • Search for 'Other Linker Flags'"
echo "   • Make sure it has the flags shown above"
echo ""

if [ "$OIIO_NEEDS_COPY" = true ] || [ "$OCIO_NEEDS_COPY" = true ]; then
    echo "4. Go to Build Phases tab"
    echo "   • Click '+' at top left"
    echo "   • Select 'New Copy Files Phase'"
    echo "   • Set Destination to: Frameworks"
    echo "   • Click '+' in the copy phase"
    echo "   • Add the .dylib files listed above"
    echo "   • Check 'Code Sign On Copy'"
    echo ""
fi

echo "5. Clean Build Folder (⌘⇧K)"
echo ""
echo "6. Build (⌘B)"
echo ""
echo "7. If successful, try Archive (Product → Archive)"
echo ""

echo "================================================"
echo ""

# Create a quick reference file
cat > QUICK_XCODE_SETUP.txt << EOF
XCODE BUILD SETTINGS QUICK REFERENCE
Generated: $(date)

Header Search Paths:
  \$(PROJECT_DIR)/Vendor/OpenImageIO/include
  \$(PROJECT_DIR)/Vendor/OpenColorIO/include

Library Search Paths:
  \$(PROJECT_DIR)/Vendor/OpenImageIO/lib
  \$(PROJECT_DIR)/Vendor/OpenColorIO/lib

Other Linker Flags:
  -lOpenImageIO
  -lOpenImageIO_Util
  -lOpenColorIO
  -lc++
  -lz
  -framework Foundation
  -framework AppKit
  -framework Metal
  -framework CoreGraphics

EOF

if [ "$OIIO_NEEDS_COPY" = true ] || [ "$OCIO_NEEDS_COPY" = true ]; then
    cat >> QUICK_XCODE_SETUP.txt << EOF
Runpath Search Paths:
  @executable_path/../Frameworks
  @loader_path/../Frameworks

Build Phases - Copy Files:
  Destination: Frameworks
  Files:
EOF
    [ "$OIIO_NEEDS_COPY" = true ] && echo "    Vendor/OpenImageIO/lib/libOpenImageIO.dylib" >> QUICK_XCODE_SETUP.txt
    [ "$OIIO_NEEDS_COPY" = true ] && echo "    Vendor/OpenImageIO/lib/libOpenImageIO_Util.dylib" >> QUICK_XCODE_SETUP.txt
    [ "$OCIO_NEEDS_COPY" = true ] && echo "    Vendor/OpenColorIO/lib/libOpenColorIO.dylib" >> QUICK_XCODE_SETUP.txt
    echo "  ✅ Check 'Code Sign On Copy'" >> QUICK_XCODE_SETUP.txt
fi

echo "✅ Quick reference saved to: QUICK_XCODE_SETUP.txt"
echo ""
echo "🎉 Setup complete! Follow the steps above in Xcode."
