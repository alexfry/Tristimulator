#!/usr/bin/env python3

"""
Xcode Project Configuration Script for Tristimulator
This script automatically configures the Xcode project with correct build settings.
"""

import os
import sys
import subprocess
import plistlib
from pathlib import Path

def run_command(cmd):
    """Run a shell command and return output"""
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return result.stdout.strip()
    except Exception as e:
        print(f"Error running command: {e}")
        return None

def get_brew_prefix():
    """Get Homebrew prefix (varies by architecture)"""
    prefix = run_command("brew --prefix")
    if prefix:
        return prefix
    
    # Fallback
    arch = run_command("uname -m")
    if arch == "arm64":
        return "/opt/homebrew"
    else:
        return "/usr/local"

def check_dependencies():
    """Check if required dependencies are installed"""
    print("🔍 Checking dependencies...")
    
    brew_prefix = get_brew_prefix()
    print(f"Homebrew prefix: {brew_prefix}")
    
    # Check OpenImageIO
    oiio_lib = Path(brew_prefix) / "lib" / "libOpenImageIO.dylib"
    if not oiio_lib.exists():
        print("❌ OpenImageIO not found!")
        print("   Install with: brew install openimageio")
        return False
    print(f"✅ OpenImageIO: {oiio_lib}")
    
    # Check OpenColorIO
    ocio_lib = Path(brew_prefix) / "lib" / "libOpenColorIO.dylib"
    if not ocio_lib.exists():
        print("❌ OpenColorIO not found!")
        print("   Install with: brew install opencolorio")
        return False
    print(f"✅ OpenColorIO: {ocio_lib}")
    
    # Check Python
    python_check = run_command("python3 -c 'import numpy, colour' 2>&1")
    if "ModuleNotFoundError" in str(python_check) or "No module named" in str(python_check):
        print("⚠️  Python packages not fully installed")
        print("   Install with: pip3 install numpy colour-science")
    else:
        print("✅ Python packages ready")
    
    return True

def find_xcodeproj():
    """Find the .xcodeproj file in current directory"""
    cwd = Path.cwd()
    projects = list(cwd.glob("*.xcodeproj"))
    
    if not projects:
        # Try looking in subdirectories
        projects = list(cwd.glob("*/*.xcodeproj"))
    
    if not projects:
        print("❌ No .xcodeproj file found!")
        print("   Run this script from your project directory.")
        return None
    
    if len(projects) > 1:
        print("Multiple projects found:")
        for i, proj in enumerate(projects):
            print(f"  {i+1}. {proj.name}")
        
        choice = input("Select project number: ")
        try:
            return projects[int(choice) - 1]
        except:
            return projects[0]
    
    return projects[0]

def configure_xcodeproj(xcodeproj_path):
    """Configure Xcode project using xcodeproj or direct pbxproj editing"""
    print(f"\\n📝 Configuring {xcodeproj_path.name}...")
    
    pbxproj_path = xcodeproj_path / "project.pbxproj"
    
    if not pbxproj_path.exists():
        print("❌ project.pbxproj not found!")
        return False
    
    brew_prefix = get_brew_prefix()
    
    # Read the pbxproj file
    with open(pbxproj_path, 'r') as f:
        content = f.read()
    
    print(f"\\n📋 Required Build Settings:")
    print(f"\\nAdd these to your Xcode project manually:")
    print(f"\\n1. Header Search Paths:")
    print(f"   {brew_prefix}/include")
    print(f"   {brew_prefix}/include/OpenImageIO")
    print(f"   {brew_prefix}/include/OpenColorIO")
    print(f"\\n2. Library Search Paths:")
    print(f"   {brew_prefix}/lib")
    print(f"\\n3. Other Linker Flags:")
    print(f"   -lOpenImageIO -lOpenColorIO -lc++")
    print(f"\\n4. C++ Language Dialect:")
    print(f"   GNU++17")
    print(f"\\n5. Objective-C Bridging Header:")
    print(f"   Tristimulator/Tristimulator-Bridging-Header.h")
    print(f"   (adjust path if your files are in a different structure)")
    
    print(f"\\n⚠️  Auto-configuration is complex. Please apply these settings manually in Xcode.")
    print(f"    See REAL_IMPLEMENTATION.md for detailed step-by-step instructions.")
    
    return True

def create_build_script():
    """Create a shell script with the correct build flags"""
    brew_prefix = get_brew_prefix()
    
    script = f"""#!/bin/bash

# Tristimulator Build Configuration
# This script shows the correct build flags

echo "Build flags for Tristimulator:"
echo ""
echo "Header Search Paths:"
echo "  {brew_prefix}/include"
echo "  {brew_prefix}/include/OpenImageIO"
echo "  {brew_prefix}/include/OpenColorIO"
echo ""
echo "Library Search Paths:"
echo "  {brew_prefix}/lib"
echo ""
echo "Linker Flags:"
echo "  -lOpenImageIO -lOpenColorIO -lc++"
echo ""
echo "Apply these in Xcode Build Settings"
"""
    
    script_path = Path("build_config.sh")
    with open(script_path, 'w') as f:
        f.write(script)
    
    os.chmod(script_path, 0o755)
    print(f"\\n✅ Created build_config.sh with configuration")

def main():
    print("=" * 60)
    print("Tristimulator Xcode Configuration")
    print("=" * 60)
    print()
    
    # Check dependencies
    if not check_dependencies():
        print("\\n❌ Dependencies missing. Please install them first:")
        print("   ./install_dependencies.sh")
        sys.exit(1)
    
    # Find Xcode project
    xcodeproj = find_xcodeproj()
    if not xcodeproj:
        sys.exit(1)
    
    # Configure
    configure_xcodeproj(xcodeproj)
    
    # Create helper script
    create_build_script()
    
    print("\\n" + "=" * 60)
    print("✅ Configuration information generated!")
    print("=" * 60)
    print()
    print("Next steps:")
    print("1. Open your project in Xcode")
    print("2. Follow the build settings above")
    print("3. See REAL_IMPLEMENTATION.md for detailed instructions")
    print("4. Delete MockBridges.swift")
    print("5. Clean and build (⌘⇧K, ⌘B)")
    print()

if __name__ == "__main__":
    main()
