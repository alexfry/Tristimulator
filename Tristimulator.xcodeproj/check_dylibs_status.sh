#!/bin/bash
# check_dylibs_status.sh
# Check what's in the Dylibs folder and if _Util is there

echo "🔍 Checking Dylibs Status"
echo "========================="
echo ""

DYLIBS_DIR="./Dylibs"

if [ ! -d "$DYLIBS_DIR" ]; then
    echo "❌ Dylibs directory not found"
    exit 1
fi

echo "OpenImageIO libraries in Dylibs/:"
echo "---------------------------------"

OIIO_LIBS=$(ls -1 "$DYLIBS_DIR" | grep -i openimageio || true)

if [ -z "$OIIO_LIBS" ]; then
    echo "  ❌ No OpenImageIO libraries found!"
else
    echo "$OIIO_LIBS" | while read lib; do
        echo "  ✅ $lib"
        
        # Check if it's signed
        if codesign --verify "$DYLIBS_DIR/$lib" 2>/dev/null; then
            echo "     Signed: ✅"
        else
            echo "     Signed: ❌"
        fi
        
        # Check install name
        INSTALL_NAME=$(otool -D "$DYLIBS_DIR/$lib" 2>/dev/null | tail -1)
        if echo "$INSTALL_NAME" | grep -q "@rpath"; then
            echo "     Install name: ✅ $INSTALL_NAME"
        else
            echo "     Install name: ⚠️  $INSTALL_NAME"
        fi
    done
fi

echo ""
echo "Checking for OpenImageIO_Util:"
echo "------------------------------"

if ls "$DYLIBS_DIR"/*OpenImageIO_Util* 2>/dev/null; then
    echo "  ✅ Found OpenImageIO_Util library"
else
    echo "  ❌ OpenImageIO_Util library NOT FOUND"
    echo ""
    echo "  This is why you're getting linker errors!"
    echo "  Run: ./fix_linker_error.sh"
fi

echo ""
echo "Total dylibs: $(ls -1 "$DYLIBS_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ')"
echo ""
