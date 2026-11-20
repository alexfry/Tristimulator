#!/bin/bash
# cleanup_scripts.sh
# Move all scripts and documentation to the correct locations

set -e

echo "🧹 Cleaning up and organizing files"
echo "===================================="
echo ""

# Detect where we are
if [ -d "Tristimulator" ] && [ -d "Tristimulator.xcodeproj" ]; then
    # We're in the project root
    echo "✅ Running from project root"
    ROOT_DIR="."
    SOURCE_DIR="Tristimulator"
elif [ -d "../Tristimulator.xcodeproj" ] && [ -f "TristimulatorApp.swift" ]; then
    # We're in the Tristimulator directory
    echo "✅ Running from Tristimulator directory"
    ROOT_DIR=".."
    SOURCE_DIR="."
else
    echo "❌ Can't determine project structure"
    echo "Please run this script from either:"
    echo "  - Project root (where Tristimulator/ and Tristimulator.xcodeproj/ are)"
    echo "  - Tristimulator/ directory (where source files are)"
    exit 1
fi

echo ""
echo "📁 Moving scripts to Tristimulator directory..."

# Scripts that should be in Tristimulator/ (where Frameworks folder is)
SCRIPTS=(
    "check_dependencies.sh"
    "internalize_dependencies.sh"
    "build_static_libs.sh"
    "diagnose_frameworks.sh"
    "fix_frameworks.sh"
    "install_dependencies.sh"
    "verify_app.sh"
)

for script in "${SCRIPTS[@]}"; do
    # Check if it exists in xcodeproj directory
    if [ -f "$ROOT_DIR/Tristimulator.xcodeproj/$script" ]; then
        echo "  Moving $script from Tristimulator.xcodeproj/ to Tristimulator/"
        mv "$ROOT_DIR/Tristimulator.xcodeproj/$script" "$SOURCE_DIR/"
        chmod +x "$SOURCE_DIR/$script"
    # Check if it already exists in the right place
    elif [ -f "$SOURCE_DIR/$script" ]; then
        echo "  ✅ $script already in correct location"
        chmod +x "$SOURCE_DIR/$script"
    else
        echo "  ⚠️  $script not found"
    fi
done

echo ""
echo "📄 Organizing documentation..."

# Documentation that should stay in Tristimulator/ (accessible from Xcode)
DOCS=(
    "README.md"
    "INDEX.md"
    "START_HERE.md"
    "GETTING_STARTED.md"
    "QUICK_START.md"
    "BUILD_CHECKLIST.md"
    "BUILD_NOW.md"
    "BUILD_FIXES.md"
    "SIGNING_FIX.md"
    "CURRENT_STATUS.md"
    "HONEST_STATUS.md"
    "IMPLEMENTATION_SUMMARY.md"
    "OCIO_SETUP.md"
    "REAL_IMPLEMENTATION.md"
    "PYTHON_BRIDGE_IMPLEMENTATION.md"
    "DEPENDENCY_INTERNALIZATION_PLAN.md"
    "INTERNALIZATION_README.md"
    "INTERNALIZATION_SUMMARY.md"
    "INTERNALIZATION_QUICK_REFERENCE.md"
    "INTERNALIZATION_VISUAL_GUIDE.md"
    "BASH_COMPATIBILITY_FIX.md"
    "LINKING_FIX.md"
)

for doc in "${DOCS[@]}"; do
    # Move from xcodeproj if it's there
    if [ -f "$ROOT_DIR/Tristimulator.xcodeproj/$doc" ]; then
        echo "  Moving $doc from Tristimulator.xcodeproj/ to Tristimulator/"
        mv "$ROOT_DIR/Tristimulator.xcodeproj/$doc" "$SOURCE_DIR/"
    elif [ -f "$SOURCE_DIR/$doc" ]; then
        echo "  ✅ $doc already in correct location"
    else
        echo "  ⚠️  $doc not found"
    fi
done

echo ""
echo "🗑️  Cleaning up generated files..."

# Clean up old generated files
if [ -f "$SOURCE_DIR/xcode_config.txt" ]; then
    echo "  Keeping xcode_config.txt (reference)"
fi

if [ -f "$SOURCE_DIR/dependencies_list.txt" ]; then
    echo "  Keeping dependencies_list.txt (reference)"
fi

# Clean up backup frameworks if they exist
if [ -d "$SOURCE_DIR/Frameworks.backup."* ]; then
    echo "  Found old Frameworks backup(s)"
    echo "  You can delete these manually if no longer needed:"
    ls -d "$SOURCE_DIR"/Frameworks.backup.* 2>/dev/null || true
fi

echo ""
echo "📋 Creating helpful README in project root..."

cat > "$ROOT_DIR/PROJECT_STRUCTURE.md" << 'EOF'
# Tristimulator Project Structure

## Directory Layout

```
Tristimulator/                          # Main project directory
├── Frameworks/                      # Embedded frameworks (created by scripts)
│   ├── OpenImageIO.3.1.framework/
│   ├── OpenColorIO.2.5.framework/
│   └── ... (90+ frameworks)
│
├── Scripts/                         # Build and setup scripts
│   ├── check_dependencies.sh       # Analyze what needs embedding
│   ├── internalize_dependencies.sh # Create frameworks (recommended)
│   ├── build_static_libs.sh        # Build static libraries (alternative)
│   ├── diagnose_frameworks.sh      # Check framework health
│   ├── fix_frameworks.sh           # Fix broken frameworks
│   └── verify_app.sh               # Verify app is self-contained
│
├── Documentation/                   # Setup and reference docs
│   ├── START_HERE.md               # 👈 Read this first!
│   ├── INDEX.md                    # Navigation hub
│   ├── GETTING_STARTED.md          # Complete setup guide
│   ├── QUICK_START.md              # Quick setup (5 min)
│   └── ... (see INDEX.md for full list)
│
├── Source Files/                    # Swift and Objective-C++ code
│   ├── TristimulatorApp.swift
│   ├── ContentView.swift
│   ├── ImageManager.swift
│   ├── OpenImageIOBridge.h/.mm
│   ├── OpenColorIOBridge.h/.mm
│   └── ... (other source files)
│
└── Assets/                          # Images, icons, etc.
    └── Assets.xcassets/

Tristimulator.xcodeproj/                # Xcode project file
TristimulatorTests/                     # Unit tests
TristimulatorUITests/                   # UI tests
```

## Quick Start

1. **Read**: `Tristimulator/START_HERE.md`
2. **Run**: `cd Tristimulator && ./internalize_dependencies.sh`
3. **Follow**: Xcode configuration instructions from script output
4. **Build**: Clean (⌘⇧K) and Build (⌘B) in Xcode

## Current Status

- ✅ 92 frameworks created and embedded
- ✅ All dependencies internalized
- 🔧 Xcode configuration needed (linking/build settings)
- 📦 App will be self-contained after Xcode setup

See `Tristimulator/LINKING_FIX.md` for fixing linker errors.
EOF

echo "  ✅ Created PROJECT_STRUCTURE.md in project root"

echo ""
echo "===================================="
echo "✅ Cleanup complete!"
echo "===================================="
echo ""

echo "📂 Current structure:"
echo ""
echo "All scripts are now in: $SOURCE_DIR/"
echo "All documentation is in: $SOURCE_DIR/"
echo "Frameworks are in: $SOURCE_DIR/Frameworks/"
echo ""

echo "🎯 Next steps:"
echo "1. Go to Tristimulator directory: cd $SOURCE_DIR"
echo "2. Run diagnosis: ./diagnose_frameworks.sh"
echo "3. Fix if needed: ./fix_frameworks.sh"
echo "4. Configure Xcode (see LINKING_FIX.md)"
echo "5. Build!"
echo ""
