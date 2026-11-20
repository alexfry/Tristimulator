# Code Signing Fix for Embedded Frameworks

## Problem

When building, you get:
```
Command CodeSign failed with a nonzero exit code
```

This happens because Xcode can't sign the embedded frameworks.

## Quick Fix: Disable Framework Signing During Development

### Option 1: Uncheck "Code Sign On Copy"

1. **Select your target** in Xcode
2. Go to **Build Phases**
3. Find **Copy Files** (or **Copy Frameworks**)
4. **Uncheck "Code Sign On Copy"** for all frameworks
5. Clean and Build

This allows development without code signing issues.

### Option 2: Ad-hoc Sign All Frameworks

Run this script to sign all frameworks with ad-hoc signature:

```bash
#!/bin/bash
cd Tristimulator/Frameworks

for fw in *.framework; do
    echo "Signing $fw..."
    codesign --force --sign "-" "$fw"
done
```

Save as `sign_frameworks.sh`, make executable, and run:
```bash
chmod +x sign_frameworks.sh
./sign_frameworks.sh
```

### Option 3: Remove Signing Requirement Entirely

In **Build Settings**:

1. Search for **"Code Signing Identity"**
2. Set to **"Sign to Run Locally"**
3. Search for **"Code Signing Required"**
4. Set to **"No"** for Debug configuration

## For Distribution (Later)

When you're ready to distribute, you'll need to properly sign everything:

### Step 1: Get a Developer ID

You need an Apple Developer account and a "Developer ID Application" certificate.

### Step 2: Sign Frameworks Properly

```bash
#!/bin/bash
IDENTITY="Developer ID Application: Your Name (TEAM_ID)"

cd Frameworks
for fw in *.framework; do
    codesign --force --deep --sign "$IDENTITY" \
             --options runtime \
             --timestamp "$fw"
done
```

### Step 3: Sign App Bundle

```bash
codesign --force --deep --sign "$IDENTITY" \
         --options runtime \
         --entitlements Tristimulator.entitlements \
         --timestamp Tristimulator.app
```

### Step 4: Notarize

```bash
# Create DMG
hdiutil create -volname "Tristimulator" -srcfolder Tristimulator.app \
        -ov -format UDZO Tristimulator.dmg

# Submit for notarization
xcrun notarytool submit Tristimulator.dmg \
      --apple-id "your@email.com" \
      --team-id "TEAM_ID" \
      --password "app-specific-password" \
      --wait

# Staple
xcrun stapler staple Tristimulator.app
xcrun stapler staple Tristimulator.dmg
```

## Troubleshooting

### "Unsealed contents present in the bundle root"

**Cause:** Extra files in framework that shouldn't be there.

**Fix:** 
```bash
# Clean up any stray files in frameworks
cd Frameworks
for fw in *.framework; do
    # Remove any files in the framework root that aren't supposed to be there
    find "$fw" -maxdepth 1 -type f -delete
done
```

### "Code signature invalid"

**Cause:** Framework was modified after signing.

**Fix:** Re-sign:
```bash
codesign --force --sign "-" path/to/framework.framework
```

### "Resource fork, Finder information, or similar detritus not allowed"

**Cause:** macOS metadata files.

**Fix:**
```bash
# Remove metadata
cd Frameworks
xattr -cr *.framework

# Re-sign
for fw in *.framework; do
    codesign --force --sign "-" "$fw"
done
```

## Current Best Solution for Development

**Just disable signing during development:**

1. **Build Phases** → **Copy Frameworks**
2. **Uncheck "Code Sign On Copy"**
3. **Build Settings** → Search "Code Signing Identity"
4. Set to **"Sign to Run Locally"**
5. Clean (⌘⇧K) and Build (⌘B)

This will work fine for local development and testing. You only need proper signing when distributing outside your Mac.
