# Proper Code Signing Setup for Tristimulator

## Overview

To properly sign your app, you need:
1. An Apple ID (free)
2. Personal Team certificate (free, automatic)
3. Proper Xcode configuration

For distribution outside your Mac, you'll eventually need:
- Apple Developer Program membership ($99/year)
- Developer ID Application certificate

But let's start with free development signing that works for testing.

---

## Step 1: Set Up Your Apple ID in Xcode

### 1.1 Add Your Apple ID

1. **Xcode** → **Settings** (or **Preferences**)
2. Click **Accounts** tab
3. Click **"+"** at bottom left
4. Choose **Apple ID**
5. Sign in with your Apple ID
6. Xcode will automatically create a **Personal Team**

### 1.2 Verify Your Team

You should see:
- **Team Name**: "Your Name (Personal Team)"
- **Role**: User
- **Team ID**: A 10-character ID

---

## Step 2: Configure Project Signing

### 2.1 Select Your Target

1. Click on your **project** in the navigator (blue icon)
2. Select **Tristimulator target**
3. Go to **Signing & Capabilities** tab

### 2.2 Enable Automatic Signing

1. ✅ Check **"Automatically manage signing"**
2. **Team**: Select your Personal Team from dropdown
3. **Bundle Identifier**: Make sure it's unique
   - Change from default if needed
   - Example: `com.yourname.Tristimulator`

### 2.3 Verify Signing Certificate

You should see:
- ✅ **Signing Certificate**: "Apple Development: your@email.com"
- ✅ **Provisioning Profile**: "Xcode Managed Profile"
- ✅ No errors or warnings

---

## Step 3: Configure Build Settings for Embedded Frameworks

### 3.1 Main App Signing

In **Build Settings** (make sure "All" is selected):

**Search for: "Code Signing Identity"**
- Debug: `Apple Development`
- Release: `Apple Development` (for now)

**Search for: "Code Signing Style"**
- Set to: `Automatic`

**Search for: "Development Team"**
- Set to: Your team ID (from Step 1.2)

### 3.2 Framework Signing

Frameworks need special handling. In **Build Settings**:

**Search for: "Other Code Signing Flags"**

Add:
```
--deep
```

This tells Xcode to sign embedded content properly.

---

## Step 4: Fix the Copy Frameworks Phase

### 4.1 Update Copy Frameworks Phase

1. **Build Phases** → Find **"Copy Files"** (your frameworks phase)
2. Make sure:
   - Destination: **Frameworks**
   - ✅ **Code Sign On Copy** is **CHECKED**
   - All your `.framework` files are listed

### 4.2 Order Matters

Make sure phases are in this order:
1. Compile Sources
2. Link Binary With Libraries
3. **Copy Files (Frameworks)** ← Should be here
4. Embed Frameworks (if you have this)

Drag to reorder if needed.

---

## Step 5: Create Proper Entitlements (Optional but Recommended)

### 5.1 Add Entitlements File

1. **File** → **New** → **File**
2. Choose **Property List**
3. Name it: `Tristimulator.entitlements`
4. **Add to target**: Tristimulator

### 5.2 Add Required Entitlements

Add these keys to the entitlements file:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Allow hardened runtime for notarization -->
    <key>com.apple.security.cs.allow-jit</key>
    <false/>
    
    <!-- Allow loading of unsigned executable memory (for JIT if needed) -->
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>
    
    <!-- Disable library validation for embedded frameworks -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    
    <!-- File access for opening images -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

### 5.3 Link Entitlements

1. **Build Settings** → Search for **"Code Signing Entitlements"**
2. Set to: `Tristimulator/Tristimulator.entitlements`

---

## Step 6: Clean and Rebuild

### 6.1 Clean Everything

```bash
# Delete derived data
rm -rf ~/Library/Developer/Xcode/DerivedData/Tristimulator-*

# In Xcode
# Product → Clean Build Folder (⌘⇧K)
```

### 6.2 Build

```bash
# Product → Build (⌘B)
```

---

## Step 7: Verify Signing

After successful build:

```bash
# Find your built app
APP_PATH="~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug/Tristimulator.app"

# Verify code signature
codesign -dv --verbose=4 "$APP_PATH"

# Should show:
# - Authority=Apple Development: your@email.com
# - TeamIdentifier=YOUR_TEAM_ID
# - Sealed Resources version=2
```

---

## Troubleshooting

### Issue: "No signing certificate found"

**Solution:**
1. Xcode → Settings → Accounts
2. Select your Apple ID
3. Click **"Manage Certificates..."**
4. Click **"+"** → **"Apple Development"**
5. A certificate will be created automatically

### Issue: "Failed to register bundle identifier"

**Solution:**
1. Change your bundle identifier to something unique
2. Go to Signing & Capabilities
3. Change **Bundle Identifier** to:
   ```
   com.yourname.Tristimulator
   ```
   (Replace `yourname` with your actual name or username)

### Issue: "Unable to install embedded frameworks"

**Solution:**
1. Make sure "Copy Files" phase destination is **"Frameworks"**
2. Make sure "Code Sign On Copy" is **checked**
3. Clean and rebuild

### Issue: Frameworks still failing to sign

**Solution:**

Run this script to manually sign frameworks first:

```bash
#!/bin/bash
# presign_frameworks.sh

TEAM_ID="YOUR_TEAM_ID"  # Replace with your team ID
IDENTITY="Apple Development"

cd Frameworks
for fw in *.framework; do
    echo "Signing $fw..."
    codesign --force --deep \
             --sign "$IDENTITY" \
             --team-identifier "$TEAM_ID" \
             "$fw"
done
```

Then in Xcode, **uncheck** "Code Sign On Copy" since they're already signed.

---

## For Future: Distribution Setup

When you're ready to distribute your app publicly:

### 1. Join Apple Developer Program

- Cost: $99/year
- Sign up at: https://developer.apple.com/programs/

### 2. Get Developer ID Certificate

1. Xcode → Settings → Accounts
2. Select your paid team
3. Manage Certificates → "+" → **"Developer ID Application"**

### 3. Update Signing

- Change from "Apple Development" to "Developer ID Application"
- Build for distribution

### 4. Notarize

```bash
# Build Release
# Product → Archive

# Export with Developer ID
# Organizer → Distribute App → Developer ID

# Submit for notarization
xcrun notarytool submit Tristimulator.dmg \
      --apple-id "your@email.com" \
      --team-id "TEAM_ID" \
      --password "app-specific-password"
```

---

## Quick Checklist

For development signing to work:

- [ ] Apple ID added to Xcode
- [ ] Personal Team visible in Accounts
- [ ] "Automatically manage signing" enabled
- [ ] Team selected in Signing & Capabilities
- [ ] Unique bundle identifier
- [ ] "Code Sign On Copy" checked in Copy Frameworks phase
- [ ] Build Settings: Code Signing Identity = "Apple Development"
- [ ] Build Settings: Development Team = Your team ID
- [ ] Clean build folder
- [ ] Build succeeds without signing errors

---

## Current State

Based on your error, the issue is likely one of:

1. **No signing identity configured** - Fix with Step 1 & 2
2. **Framework signing mismatch** - Fix with Step 4
3. **Missing entitlements** - Fix with Step 5 (optional but helps)

Start with Steps 1-2 (adding your Apple ID and enabling automatic signing), then try building. That alone might fix it!

---

## Need Help?

If you get stuck:

1. Check **Signing & Capabilities** tab for specific error messages
2. Check **Build Settings** → Search "signing" → Make sure nothing is set to "Don't Code Sign"
3. Run the verification command from Step 7 to see what's actually wrong

The most common fix is just enabling automatic signing with your Apple ID!
