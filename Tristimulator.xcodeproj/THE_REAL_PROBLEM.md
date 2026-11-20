# The Real Problem: Invalid Framework Structure

## What Went Wrong

The error **"bundle format unrecognized, invalid, or unsuitable"** means `codesign` doesn't recognize the frameworks as valid macOS bundles.

Looking at your output:
```
./Frameworks/aom.3.framework: bundle format unrecognized, invalid, or unsuitable
```

This happened because the `internalize_dependencies.sh` script tried to convert Linux/Homebrew `.dylib` files into macOS frameworks, but **something went wrong with the structure**.

## Why Framework Conversion Failed

macOS frameworks require:
1. Specific directory structure: `Framework.framework/Versions/A/Framework`
2. Symlinks pointing to `Versions/Current`
3. Info.plist with correct bundle identifiers
4. Proper executable flags and permissions

The script created these, but likely:
- Symlinks are broken
- Info.plist references are wrong
- The binary isn't in the expected location
- File permissions are incorrect

This makes them **unsignable** - `codesign` can't even recognize them as bundles.

## The Better Solution: Skip Frameworks Entirely

**For Homebrew/system libraries, you don't need frameworks.**

Instead, just embed the `.dylib` files directly:
- ✅ Simpler - no conversion needed
- ✅ More reliable - codesign understands dylibs
- ✅ Standard practice for third-party libs
- ✅ Works exactly the same at runtime

Frameworks are for:
- Apple's system frameworks
- Your own custom frameworks
- Third-party frameworks designed as frameworks

**Not for**: Converting random dylibs from Homebrew!

## The Fix

### Quick Fix (Recommended)

```bash
cd /Users/afry/GitHub/Tristimulator/Tristimulator

# Run the all-in-one script
chmod +x switch_to_dylibs.sh
./switch_to_dylibs.sh
```

This will:
1. Remove the broken `Frameworks` directory
2. Create a new `Dylibs` directory
3. Copy all dependencies as `.dylib` files
4. Fix their install names to use `@rpath`
5. **Sign them properly** (this will work!)
6. Show you Xcode configuration steps

### Manual Steps (If You Want Control)

```bash
# 1. Remove broken frameworks
rm -rf ./Frameworks

# 2. Run the new dylibs script
chmod +x embed_dylibs_simple.sh
./embed_dylibs_simple.sh
```

## Xcode Configuration Changes

After running the script, you need to update your Xcode project:

### 1. Remove Old Frameworks
- In Xcode project navigator
- Find `Frameworks` folder (if it exists)
- Right-click → Delete → Move to Trash

### 2. Add Dylibs Folder
- Drag `Dylibs` folder into Xcode
- ✅ Check "Create folder references"
- ✅ Add to Tristimulator target
- Click "Finish"

### 3. Update Copy Files Phase

**Delete old phase:**
- Target → Build Phases
- Find "Copy Files (Frameworks)" or similar
- Delete it (click X)

**Create new phase:**
- Click `+` → "New Copy Files Phase"
- Rename to "Copy Dylibs"
- Destination: **Frameworks** (yes, even though they're dylibs!)
- Click `+` to add files
- Select all `.dylib` files from `Dylibs` folder
- ✅ Check "Code Sign On Copy"

### 4. Update Build Settings

| Setting | Old Value | New Value |
|---------|-----------|-----------|
| Framework Search Paths | `$(PROJECT_DIR)/Frameworks` | **DELETE** (not needed) |
| Library Search Paths | `$(PROJECT_DIR)/Frameworks`<br>`/opt/homebrew/lib` | **DELETE** (embedded now) |
| Header Search Paths | Various | `/opt/homebrew/include`<br>`/opt/homebrew/include/OpenImageIO`<br>`/opt/homebrew/include/OpenColorIO` |
| Runpath Search Paths | (may be empty) | `@executable_path/../Frameworks`<br>`@loader_path/../Frameworks` |
| Other Linker Flags | `-lOpenImageIO`<br>`-lOpenColorIO` | **KEEP THESE** (they'll find embedded dylibs) |
| Other Code Signing Flags | `--deep` | **DELETE** (leave empty) |

### 5. Clean Everything

```bash
# In Xcode
Product → Clean Build Folder (⌘⇧K)

# In Terminal
rm -rf ~/Library/Developer/Xcode/DerivedData/Tristimulator-*
```

### 6. Build

```bash
Product → Build (⌘B)
```

## Why This Works

### Before (Broken)
```
Frameworks/
  aom.3.framework/          ← Invalid bundle structure
    (broken symlinks)
    (wrong Info.plist)
    → codesign: "bundle format unrecognized"
```

### After (Working)
```
Dylibs/
  libaom.3.dylib           ← Regular signed dylib
  libOpenImageIO.dylib     ← Regular signed dylib
  libOpenColorIO.dylib     ← Regular signed dylib
  (etc...)
  
→ Copied to: Tristimulator.app/Contents/Frameworks/
→ codesign: ✅ Works perfectly!
```

## Verification

After building, verify it worked:

```bash
chmod +x verify_embedded_dylibs.sh
./verify_embedded_dylibs.sh
```

Should show:
```
✅ libOpenImageIO.dylib
   Signature: Valid
   Install name: @rpath/libOpenImageIO.dylib

✅ No Homebrew dependencies (good!)
   All dependencies use @rpath
```

## Comparison: What Changed

| Aspect | Frameworks Approach | Dylibs Approach |
|--------|-------------------|-----------------|
| **Conversion** | dylib → framework<br>(complex, error-prone) | Copy dylib as-is<br>(simple) |
| **Structure** | Framework bundle<br>(can be invalid) | Plain binary<br>(always valid) |
| **Signing** | `codesign Framework.framework`<br>❌ Failed: "bundle format unrecognized" | `codesign library.dylib`<br>✅ Works |
| **Xcode Config** | Framework Search Paths<br>Link Binary with Libraries | Library Search Paths<br>Other Linker Flags |
| **Runtime** | Identical | Identical |
| **Distribution** | Identical | Identical |

**Result: Same functionality, way more reliable!**

## Technical Details

### Why Codesign Failed on Frameworks

`codesign` validates framework structure by checking:

1. **Bundle structure**: Is `CFBundleExecutable` where it should be?
   ```
   Framework.framework/
     Versions/Current/Framework  ← Must exist at this path
   ```

2. **Info.plist**: Is it valid XML with required keys?
   ```xml
   <key>CFBundleExecutable</key>
   <string>Framework</string>  ← Must match binary name
   ```

3. **Symlinks**: Do they point to valid targets?
   ```
   Framework.framework/Framework → Versions/Current/Framework
   Versions/Current → Versions/A
   ```

If **any** of these are wrong, codesign rejects the whole bundle.

### Why Dylibs Work

A `.dylib` is just a Mach-O binary. `codesign` only checks:
1. Is it a valid Mach-O file? ✅
2. Does it have a code directory? ✅ (created during signing)

No bundles, no symlinks, no Info.plist to validate. **Much simpler!**

### What About Real Frameworks?

Apple's frameworks (Foundation, AppKit, etc.) are **different**:
- Built by Apple with proper structure
- Signed by Apple
- Installed in system locations
- Include headers, resources, multiple architectures

Your Homebrew dylibs:
- Built as Linux-style shared libraries
- Never meant to be macOS frameworks
- Don't have framework resources
- Single architecture (arm64 or x86_64)

**Don't force dylibs to be frameworks - embrace what they are!**

## Summary

| ❌ Problem | ✅ Solution |
|-----------|-----------|
| Frameworks have invalid structure | Use dylibs directly |
| Can't sign frameworks | Sign dylibs (works perfectly) |
| Complex conversion script | Simple copy + install_name_tool |
| `codesign` errors | Clean codesign success |
| Hours of debugging | Works in 5 minutes |

**Bottom line:** Stop trying to make frameworks. Use dylibs. They work.

---

## Next Steps

1. Run: `./switch_to_dylibs.sh`
2. Follow the Xcode configuration steps above
3. Build and verify
4. Delete old framework backups once confirmed working

You should have a working build in < 10 minutes! 🎉
