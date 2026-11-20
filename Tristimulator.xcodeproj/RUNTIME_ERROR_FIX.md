# Runtime Error: Dylibs Not Copied to App Bundle

## The Error

```
dyld[43715]: Library not loaded: @rpath/libOpenImageIO.dylib
  Referenced from: .../Tristimulator.app/Contents/MacOS/Tristimulator.debug.dylib
  Reason: tried: 
    '.../Tristimulator.app/Contents/Frameworks/libOpenImageIO.dylib' (no such file)
```

## What This Means

✅ **Great progress:** Build succeeded! No more linker errors!

❌ **Current issue:** The dylibs exist in `Dylibs/` folder but weren't copied into your app bundle.

## What Should Happen

During build, Xcode should:

1. **Compile** your code ✅ (This worked!)
2. **Link** with dylibs ✅ (This worked!)
3. **Copy** dylibs to `Tristimulator.app/Contents/Frameworks/` ❌ (This didn't happen!)
4. **Sign** the copied dylibs
5. **Sign** the app bundle

Step 3 failed or was skipped.

## Diagnose the Problem

```bash
chmod +x check_built_app.sh fix_dylib_copying.sh
./fix_dylib_copying.sh
```

This will tell you exactly what's wrong with your Copy Files phase.

## The Fix: Configure Copy Files Phase in Xcode

### Check if Phase Exists

1. Open Xcode
2. Select **Tristimulator target** (top left, next to Run button)
3. Click **Build Phases** tab
4. Look for a phase called "Copy Dylibs" or "Copy Files"

### Option A: Phase Exists But Is Empty

If you see the phase but it has no files in it:

1. Click the **`+`** button in that phase
2. Navigate to your `Dylibs` folder
3. Select **ALL** `.dylib` files (⌘A to select all)
4. Click **Add**
5. Verify:
   - ✅ "Code Sign On Copy" checkbox is **CHECKED**
   - Destination shows: **Frameworks**
   - Subpath is: **(empty)**

### Option B: Phase Doesn't Exist

If there's no Copy Files phase at all:

1. Click **`+`** at the top of Build Phases
2. Select **"New Copy Files Phase"**
3. Rename it to: **Copy Dylibs** (optional but clear)
4. Configure the phase:
   - **Destination:** `Frameworks`
   - **Subpath:** (leave empty)
   - **Copy only when installing:** ❌ UNCHECK
5. Click **`+`** to add files
6. Navigate to: `Tristimulator/Dylibs`
7. Select **ALL** `.dylib` files (⌘A)
8. Click **Add**
9. **IMPORTANT:** Check "Code Sign On Copy" for all files

### Visual Guide

Your Copy Files phase should look like:

```
Copy Dylibs
  Destination: Frameworks
  Subpath: 
  
  ☑️ Code Sign On Copy
  
  [+] libaom.3.dylib
  [+] libaribb24.0.dylib
  [+] libavcodec.62.dylib
  [+] libavformat.62.dylib
  [+] libavutil.60.dylib
  ... (all 93 dylibs)
  [+] libOpenImageIO.dylib
  [+] libOpenImageIO_Util.dylib
  [+] libOpenColorIO.dylib
  [+] libzstd.1.dylib
```

## After Fixing

1. **Clean Build Folder:** ⌘⇧K
2. **Build:** ⌘B
3. **Verify:** Run `./check_built_app.sh`
4. **Run your app:** ⌘R

## How to Verify It Worked

### Method 1: Run the Check Script

```bash
./check_built_app.sh
```

Should show:
```
✅ Frameworks directory exists
Dylibs in app bundle: 93

Key dylibs status:
  ✅ libOpenImageIO.dylib
  ✅ libOpenImageIO_Util.dylib
  ✅ libOpenColorIO.dylib
```

### Method 2: Manually Check

```bash
# Find your built app
APP=$(find ~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug -name "Tristimulator.app" -type d | head -1)

# Check if dylibs are there
ls -la "$APP/Contents/Frameworks/"
```

Should show ~93 `.dylib` files.

### Method 3: Run the App

If it launches without crashing, it worked! 🎉

## Common Issues

### Issue 1: "Copy only when installing" Is Checked

**Problem:** Dylibs only copy during Archive/Install, not Debug builds.

**Fix:** 
1. Build Phases → Copy Dylibs
2. **Uncheck** "Copy only when installing"
3. Clean and rebuild

### Issue 2: Wrong Destination

**Problem:** Destination set to "Products Directory" or "Resources" instead of "Frameworks"

**Fix:**
1. Build Phases → Copy Dylibs
2. Change Destination to: **Frameworks**
3. Clean and rebuild

### Issue 3: Dylibs Added as References Not Files

**Problem:** Dylibs show in project navigator but aren't actually copied.

**Fix:**
1. Make sure they're in the Copy Files phase, not just the project
2. The Copy Files phase is what actually copies them

### Issue 4: Build Phases Run in Wrong Order

**Problem:** Copy Files runs before linking.

**Fix:**
1. Drag "Copy Dylibs" phase to be **after** "Link Binary With Libraries"
2. Clean and rebuild

## Understanding @rpath

When your code references `@rpath/libOpenImageIO.dylib`, the dynamic linker searches:

1. `@executable_path/../Frameworks/` 
   → `Tristimulator.app/Contents/Frameworks/libOpenImageIO.dylib`
2. `@loader_path/../Frameworks/`
   → (relative to the loading binary)

This is configured in **Build Settings → Runpath Search Paths**.

Verify it's set to:
```
@executable_path/../Frameworks
@loader_path/../Frameworks
```

## Full Build Process

Here's what should happen:

```
1. Compile Swift/Obj-C code
   ✅ Creates .o files

2. Link executable
   ✅ Looks in Dylibs/ for libraries
   ✅ Creates Tristimulator binary
   ✅ Binary references @rpath/libOpenImageIO.dylib

3. Copy Files (Dylibs)
   ❌ THIS FAILED - dylibs not copied!
   → Should copy Dylibs/*.dylib to app bundle
   → Should sign each dylib

4. Sign app bundle
   ✅ Works but dylibs are missing

5. Run app
   ❌ Can't find dylibs at runtime
```

Fix step 3, and everything works!

## Quick Reference: Step-by-Step Fix

| Step | Action | Where |
|------|--------|-------|
| 1 | Open project | Xcode |
| 2 | Select Tristimulator target | Top left |
| 3 | Open Build Phases tab | Top of editor |
| 4 | Find or create "Copy Files" phase | Click + if needed |
| 5 | Set Destination to "Frameworks" | Phase settings |
| 6 | Add all .dylib files from Dylibs/ | Click + in phase |
| 7 | Check "Code Sign On Copy" | Checkbox |
| 8 | Clean (⌘⇧K) and Build (⌘B) | Product menu |
| 9 | Verify with script | `./check_built_app.sh` |
| 10 | Run app (⌘R) | Should work! |

## Success Checklist

After fixing, you should see:

- ✅ Build succeeds
- ✅ `~/Library/Developer/Xcode/DerivedData/.../Tristimulator.app/Contents/Frameworks/` contains ~93 dylibs
- ✅ App launches without dyld errors
- ✅ No "Library not loaded" messages

## Next Steps After This Works

Once your app runs successfully:

1. **Test on another Mac** without Homebrew to verify true independence
2. **Archive for distribution** (Product → Archive)
3. **Sign for distribution** if needed
4. **Create installer/DMG** for sharing

You're almost there! Just need to configure that Copy Files phase properly. 🚀
