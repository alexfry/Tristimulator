# Missing Dependencies: The Whack-A-Mole Problem

## What's Happening

You're playing dependency whack-a-mole:
1. Fixed `libOpenImageIO_Util.3.1.dylib` ✅
2. Now missing `libjxl_cms.0.11.dylib` ❌
3. After fixing that, probably something else...

This happens because the initial dependency scan **didn't find all transitive dependencies**.

## Why the Original Scan Missed These

The `embed_dylibs_simple.sh` script uses `otool -L` to find dependencies, but it only finds **direct** dependencies, not **transitive** ones (dependencies of dependencies of dependencies...).

Example chain:
```
Your App
  ↓ uses
libOpenImageIO.dylib
  ↓ uses
libOpenImageIO.3.1.dylib
  ↓ uses
libOpenImageIO_Util.3.1.dylib  ← We found this
  ↓ uses
libjxl.0.11.dylib
  ↓ uses
libjxl_cms.0.11.dylib  ← MISSED THIS!
```

## Three Solutions (Pick One)

### Solution 1: Quick Fix - Add One Missing Dep (Fastest)

```bash
# Add just the currently missing lib
cp /opt/homebrew/lib/libjxl_cms.0.11.dylib ./Dylibs/

cd Dylibs
install_name_tool -id "@rpath/libjxl_cms.0.11.dylib" libjxl_cms.0.11.dylib
codesign --force --sign "Apple Development: Alex Fry (7CART63SAF)" \
         --timestamp --options runtime libjxl_cms.0.11.dylib
cd ..
```

Then in Xcode:
- Build Phases → Copy Dylibs
- Add `libjxl_cms.0.11.dylib`
- Clean and build

**Downside:** Will probably hit another missing dep next.

### Solution 2: Smart Scan - Find All Missing Deps (Recommended)

```bash
chmod +x find_all_missing_deps.sh add_all_missing_deps.sh
./find_all_missing_deps.sh
```

This recursively scans your built app and finds ALL missing dependencies.

Then:
```bash
./add_all_missing_deps.sh
```

This adds them all to `Dylibs/` at once.

Then in Xcode:
- Build Phases → Copy Dylibs
- Add all the new files (or remove all and re-add everything)
- Clean and build

**Upside:** Fixes everything in one go.

### Solution 3: Nuclear Option - Complete Refresh (Most Thorough)

```bash
chmod +x refresh_all_dylibs.sh
./refresh_all_dylibs.sh
```

This:
1. Backs up current `Dylibs/`
2. Deletes it
3. Re-runs the complete embedding script
4. Copies **everything** fresh from Homebrew

Then in Xcode:
- Build Phases → Copy Dylibs
- Remove ALL files
- Add ALL files from new `Dylibs/` folder
- Clean and build

**Upside:** Guaranteed to work. Fresh start.
**Downside:** Takes a few minutes.

## Why This Keeps Happening

The issue is that some dylibs have dependencies on **versioned** files that weren't detected:

| What We Copied | What Was Missed |
|---------------|-----------------|
| `libjxl.0.11.dylib` | `libjxl_cms.0.11.dylib` |
| `libOpenImageIO.dylib` (symlink) | `libOpenImageIO.3.1.dylib` (real file) |
| `libOpenImageIO_Util.dylib` (symlink) | `libOpenImageIO_Util.3.1.dylib` (real file) |

The original script followed symlinks but didn't check what the **versioned** dylibs themselves depend on.

## The Permanent Fix

After you get it working, the permanent fix is to ensure the `embed_dylibs_simple.sh` script:

1. **Follows all symlinks** to get real files
2. **Recursively scans dependencies** until no new ones are found
3. **Checks both symlink AND versioned names**

The updated script (from refresh) does this.

## Quick Diagnosis

Before trying a fix, see what you're missing:

```bash
chmod +x find_all_missing_deps.sh
./find_all_missing_deps.sh
```

This will list ALL missing dependencies at once, so you know what you're dealing with.

## Recommended Approach

**If you just want it to work RIGHT NOW:**

```bash
# Nuclear option - just redo everything properly
./refresh_all_dylibs.sh
```

Then update Xcode Copy Files phase and rebuild.

**If you want to understand and fix incrementally:**

```bash
# Find what's missing
./find_all_missing_deps.sh

# Add everything that's missing
./add_all_missing_deps.sh

# Update Xcode and rebuild
```

## After It Works

Once your app launches successfully, run:

```bash
# Verify everything is good
./verify_embedded_dylibs.sh

# Check no Homebrew dependencies remain
otool -L ~/Library/Developer/Xcode/DerivedData/Tristimulator-*/Build/Products/Debug/Tristimulator.app/Contents/MacOS/Tristimulator | grep homebrew
```

Should show nothing!

## Why We Can't Just Copy Everything

You might wonder: "Why not just copy ALL of `/opt/homebrew/lib`?"

Because:
- That's ~5000+ files
- ~2GB of libraries
- 99% you don't need
- Makes your app huge
- Signing takes forever

We only want the ~100 dylibs you actually use.

## Summary

| Approach | Time | Thoroughness | Recommendation |
|----------|------|--------------|----------------|
| Add one missing lib | 2 min | ⭐ | Only if almost done |
| Smart scan & add | 5 min | ⭐⭐⭐ | **BEST** |
| Nuclear refresh | 10 min | ⭐⭐⭐⭐⭐ | If scan doesn't work |

**My recommendation:** Try the smart scan first. If it finds more than 5-10 missing libs, just do the nuclear option.

---

## Quick Commands

```bash
# Option A: Smart scan (recommended)
./find_all_missing_deps.sh
./add_all_missing_deps.sh

# Option B: Nuclear option (guaranteed to work)
./refresh_all_dylibs.sh

# Then in Xcode:
# - Update Copy Files phase
# - Clean (⌘⇧K)
# - Build (⌘B)
# - Run (⌘R)
```

Pick whichever makes sense based on your patience level! 🚀
