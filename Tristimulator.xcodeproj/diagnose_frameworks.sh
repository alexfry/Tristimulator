#!/bin/bash
# diagnose_frameworks.sh
# Check if frameworks contain actual binary code

echo "🔍 Diagnosing Framework Contents"
echo "=================================="
echo ""

# Try to find Frameworks directory
if [ -d "./Frameworks" ]; then
    FRAMEWORKS_DIR="./Frameworks"
elif [ -d "../Frameworks" ]; then
    FRAMEWORKS_DIR="../Frameworks"
elif [ -d "Frameworks" ]; then
    FRAMEWORKS_DIR="Frameworks"
else
    echo "❌ Frameworks directory not found!"
    echo ""
    echo "Please run this script from:"
    echo "  - The same directory as the Frameworks folder"
    echo "  - Or specify the path: ./diagnose_frameworks.sh path/to/Frameworks"
    echo ""
    echo "Current directory: $(pwd)"
    echo "Contents:"
    ls -la
    exit 1
fi

echo "Using Frameworks directory: $FRAMEWORKS_DIR"
echo ""

echo "📊 Checking OpenImageIO frameworks..."
echo ""

for fw in "$FRAMEWORKS_DIR"/OpenImageIO*.framework; do
    if [ -d "$fw" ]; then
        fw_name=$(basename "$fw" .framework)
        binary="$fw/Versions/A/$fw_name"
        
        echo "Framework: $(basename $fw)"
        
        if [ -f "$binary" ]; then
            echo "  ✅ Binary exists: $binary"
            
            # Check if it's actually a binary or a symlink
            if [ -L "$binary" ]; then
                echo "  ⚠️  Binary is a SYMLINK"
                echo "      Target: $(readlink $binary)"
            fi
            
            # Check file type
            file_type=$(file "$binary")
            echo "  Type: $file_type"
            
            # Check size
            size=$(du -h "$binary" | cut -f1)
            echo "  Size: $size"
            
            # Check if it has symbols
            symbol_count=$(nm -gU "$binary" 2>/dev/null | grep -c "OpenImageIO" || echo "0")
            echo "  OpenImageIO symbols: $symbol_count"
            
            if [ $symbol_count -eq 0 ]; then
                echo "  ❌ NO SYMBOLS FOUND - This is the problem!"
            fi
            
            # Check what it's linked to
            echo "  Dependencies:"
            otool -L "$binary" | head -10 | sed 's/^/    /'
            
        else
            echo "  ❌ Binary NOT found: $binary"
        fi
        echo ""
    fi
done

echo "📊 Checking OpenColorIO frameworks..."
echo ""

for fw in "$FRAMEWORKS_DIR"/OpenColorIO*.framework; do
    if [ -d "$fw" ]; then
        fw_name=$(basename "$fw" .framework)
        binary="$fw/Versions/A/$fw_name"
        
        echo "Framework: $(basename $fw)"
        
        if [ -f "$binary" ]; then
            echo "  ✅ Binary exists: $binary"
            
            # Check if it's actually a binary or a symlink
            if [ -L "$binary" ]; then
                echo "  ⚠️  Binary is a SYMLINK"
                echo "      Target: $(readlink $binary)"
            fi
            
            # Check file type
            file_type=$(file "$binary")
            echo "  Type: $file_type"
            
            # Check size
            size=$(du -h "$binary" | cut -f1)
            echo "  Size: $size"
            
            # Check if it has symbols
            symbol_count=$(nm -gU "$binary" 2>/dev/null | grep -c "OpenColorIO" || echo "0")
            echo "  OpenColorIO symbols: $symbol_count"
            
            if [ $symbol_count -eq 0 ]; then
                echo "  ❌ NO SYMBOLS FOUND - This is the problem!"
            fi
            
            # Check what it's linked to
            echo "  Dependencies:"
            otool -L "$binary" | head -10 | sed 's/^/    /'
            
        else
            echo "  ❌ Binary NOT found: $binary"
        fi
        echo ""
    fi
done

echo "💡 Checking original Homebrew libraries for comparison..."
echo ""

HOMEBREW_PREFIX="/opt/homebrew"

if [ -f "$HOMEBREW_PREFIX/lib/libOpenImageIO.dylib" ]; then
    echo "Original OpenImageIO:"
    size=$(du -h "$HOMEBREW_PREFIX/lib/libOpenImageIO.dylib" | cut -f1)
    echo "  Size: $size"
    symbol_count=$(nm -gU "$HOMEBREW_PREFIX/lib/libOpenImageIO.dylib" 2>/dev/null | grep -c "OpenImageIO" || echo "0")
    echo "  Symbols: $symbol_count"
else
    echo "⚠️  Original libOpenImageIO.dylib not found"
fi

echo ""

if [ -f "$HOMEBREW_PREFIX/lib/libOpenColorIO.dylib" ]; then
    echo "Original OpenColorIO:"
    size=$(du -h "$HOMEBREW_PREFIX/lib/libOpenColorIO.dylib" | cut -f1)
    echo "  Size: $size"
    symbol_count=$(nm -gU "$HOMEBREW_PREFIX/lib/libOpenColorIO.dylib" 2>/dev/null | grep -c "OpenColorIO" || echo "0")
    echo "  Symbols: $symbol_count"
else
    echo "⚠️  Original libOpenColorIO.dylib not found"
fi

echo ""
echo "=================================="
echo "Diagnosis complete!"
echo ""
echo "Expected results:"
echo "  ✅ Framework binaries should be 20-100 MB"
echo "  ✅ Should have thousands of symbols"
echo "  ✅ Should NOT be symlinks"
echo ""
echo "If frameworks are small or have no symbols,"
echo "the internalize script didn't copy them correctly."
