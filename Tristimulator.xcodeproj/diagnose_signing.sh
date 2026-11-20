#!/bin/bash
# diagnose_signing.sh
# Diagnose code signing issues with frameworks

echo "🔍 Code Signing Diagnostic"
echo "=========================="
echo ""

FRAMEWORKS_DIR="./Frameworks"

if [ ! -d "$FRAMEWORKS_DIR" ]; then
    echo "❌ Frameworks directory not found"
    exit 1
fi

echo "Available Signing Identities:"
echo "=============================="
security find-identity -v -p codesigning
echo ""

echo "Framework Signature Status:"
echo "============================="
echo ""

for fw in "$FRAMEWORKS_DIR"/*.framework; do
    if [ -d "$fw" ]; then
        fw_name=$(basename "$fw")
        echo "📦 $fw_name"
        
        # Check if signed
        if codesign -dv "$fw" 2>&1 | grep -q "Signature"; then
            echo "  Status: Signed"
            
            # Get signature details
            AUTHORITY=$(codesign -dv "$fw" 2>&1 | grep "Authority=" | head -1 | sed 's/Authority=/  Authority: /')
            IDENTIFIER=$(codesign -dv "$fw" 2>&1 | grep "Identifier=" | sed 's/Identifier=/  Identifier: /')
            
            echo "$AUTHORITY"
            echo "$IDENTIFIER"
            
            # Verify signature
            if codesign --verify --deep --strict "$fw" 2>/dev/null; then
                echo "  Verification: ✅ Valid"
            else
                echo "  Verification: ❌ Invalid"
                echo "  Error: $(codesign --verify --deep --strict "$fw" 2>&1)"
            fi
        else
            echo "  Status: ⚠️  Not signed or ad-hoc signed"
        fi
        
        echo ""
    fi
done

echo "=========================="
echo "Xcode Build Settings Check"
echo "=========================="
echo ""

# Check if we can find project file
if [ -f "Tristimulator.xcodeproj/project.pbxproj" ]; then
    echo "Project file found. Checking signing configuration..."
    echo ""
    
    # Check for Code Signing Identity
    if grep -q "CODE_SIGN_IDENTITY" Tristimulator.xcodeproj/project.pbxproj; then
        echo "Code Signing Identity settings:"
        grep "CODE_SIGN_IDENTITY" Tristimulator.xcodeproj/project.pbxproj | grep -v "/\*" | head -5
    fi
    echo ""
    
    # Check for Development Team
    if grep -q "DEVELOPMENT_TEAM" Tristimulator.xcodeproj/project.pbxproj; then
        echo "Development Team settings:"
        grep "DEVELOPMENT_TEAM" Tristimulator.xcodeproj/project.pbxproj | grep -v "/\*" | head -3
    fi
    echo ""
    
    # Check for Other Code Signing Flags
    if grep -q "OTHER_CODE_SIGN_FLAGS" Tristimulator.xcodeproj/project.pbxproj; then
        echo "Other Code Signing Flags:"
        grep "OTHER_CODE_SIGN_FLAGS" Tristimulator.xcodeproj/project.pbxproj | grep -v "/\*"
    fi
    echo ""
else
    echo "⚠️  Project file not found. Run this from project root."
    echo ""
fi

echo "=========================="
echo "Recommendations"
echo "=========================="
echo ""
echo "If frameworks show as 'Not signed' or 'ad-hoc signed':"
echo "  1. Run: ./sign_frameworks_dev.sh"
echo "     This will sign all frameworks with your development certificate"
echo ""
echo "If frameworks show 'Invalid' verification:"
echo "  2. Remove the --deep flag from 'Other Code Signing Flags' in Xcode"
echo "  3. Clean build folder and rebuild"
echo ""
echo "If Xcode still fails with CodeSign error:"
echo "  4. In Build Phases → Copy Files (Frameworks):"
echo "     Set 'Code Sign On Copy' to YES"
echo "  5. Clean and rebuild"
echo ""
