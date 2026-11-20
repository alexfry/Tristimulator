# Fixing "Undefined Symbol" Linker Errors

## Problem

After embedding frameworks, the build fails with linker errors like:

```
Undefined symbol: OpenImageIO::v3_1::ParamValue::clear_value()
Undefined symbol: OpenImageIO::v3_1::ustring::empty_std_string
```

This means the frameworks aren't being linked properly.

## Solution

### Option 1: Link the Versioned Frameworks (Recommended)

The script created versioned frameworks like `OpenImageIO.3.1.framework`. These are the actual libraries.

**Steps:**

1. **Open Xcode** → Select your target → **Build Phases**

2. **Expand "Link Binary With Libraries"**

3. **Add versioned frameworks:**
   - Click **"+"**
   - Click **"Add Other..."** → **"Add Files..."**
   - Navigate to your `Frameworks` folder
   - Add:
     - ✅ `OpenImageIO.3.1.framework`
     - ✅ `OpenColorIO.2.5.framework`

4. **Remove old entries** if present:
   - ❌ `OpenImageIO.framework` (without version)
   - ❌ `OpenColorIO.framework` (without version)
   - ❌ `libOpenImageIO.dylib`
   - ❌ `libOpenColorIO.dylib`

5. **Clean and Build:**
   - Product → Clean Build Folder (⌘⇧K)
   - Product → Build (⌘B)

### Option 2: Manually Link All Frameworks

If Option 1 doesn't work, you may need to link more frameworks.

**Steps:**

1. Go to **Build Phases** → **Link Binary With Libraries**

2. Click **"+"** → **"Add Other..."** → **"Add Files..."**

3. Navigate to your `Frameworks` folder

4. **Hold ⌘ (Command)** and select these frameworks:
   - `OpenImageIO.3.1.framework`
   - `OpenColorIO.2.5.framework`
   - `OpenEXR-3_4.33.framework`
   - `Imath-3_2.30.framework`
   - `tiff.6.framework`
   - `jpeg.8.framework`
   - `png16.16.framework`
   - `z.1.framework`
   - `zstd.1.framework`

5. Click **"Open"** to add them all

6. **Clean and Build**

### Option 3: Fix Framework Search Paths

Make sure Xcode can find your frameworks:

1. **Build Settings** → Search for **"Framework Search Paths"**

2. Make sure it includes (with quotes if there are spaces):
   ```
   $(PROJECT_DIR)/Frameworks
   ```

3. Make sure it's set to **recursive**:
   - Double-click the entry
   - Select **"recursive"** from dropdown

4. **Also check "Header Search Paths":**
   ```
   $(PROJECT_DIR)/Frameworks/OpenImageIO.3.1.framework/Headers
   $(PROJECT_DIR)/Frameworks/OpenColorIO.2.5.framework/Headers
   ```
   
   (Use versioned frameworks!)

### Option 4: Check Bridging Header

Your Objective-C++ bridge files might need updating:

1. **Open `OpenImageIOBridge.mm`**

2. Check the imports at the top:
   ```objc
   #import <OpenImageIO/imageio.h>
   ```

3. If that fails, try:
   ```objc
   #import "OpenImageIO/imageio.h"
   ```

4. Do the same for `OpenColorIOBridge.mm`:
   ```objc
   #import <OpenColorIO/OpenColorIO.h>
   // or
   #import "OpenColorIO/OpenColorIO.h"
   ```

## Verification Steps

After making changes:

### 1. Check Link Phase

```
Build Phases → Link Binary With Libraries should show:
✅ OpenImageIO.3.1.framework
✅ OpenColorIO.2.5.framework
✅ Metal.framework
✅ MetalKit.framework
✅ AppKit.framework
❌ NO libOpenImageIO.dylib
❌ NO -lOpenImageIO in Other Linker Flags
```

### 2. Check Framework Search Paths

```
Build Settings → Framework Search Paths:
✅ $(PROJECT_DIR)/Frameworks (recursive)
```

### 3. Check Header Search Paths

```
Build Settings → Header Search Paths:
✅ $(PROJECT_DIR)/Frameworks/OpenImageIO.3.1.framework/Headers
✅ $(PROJECT_DIR)/Frameworks/OpenColorIO.2.5.framework/Headers
```

### 4. Check Other Linker Flags

```
Build Settings → Other Linker Flags:
✅ Should NOT have -lOpenImageIO
✅ Should NOT have -lOpenColorIO
✅ Can keep: -lc++, system frameworks
```

### 5. Clean Build Folder

**Always do this after changing linking:**
- Product → Clean Build Folder (⌘⇧K)
- Or delete: `~/Library/Developer/Xcode/DerivedData/Tristimulator-*`

## Common Issues

### Issue: "Framework not found OpenImageIO"

**Fix:** Check Framework Search Paths includes `$(PROJECT_DIR)/Frameworks`

### Issue: Still getting undefined symbols

**Fix:** You might need to link transitive dependencies. Add these frameworks to "Link Binary With Libraries":
- `tiff.6.framework`
- `jpeg.8.framework`
- `png16.16.framework`
- `OpenEXR-3_4.33.framework`
- `Imath-3_2.30.framework`

### Issue: "library not loaded" at runtime

**Fix:** Make sure "Copy Frameworks" phase includes all linked frameworks.

### Issue: Duplicate symbol errors

**Fix:** Make sure you don't have both:
- The framework AND
- The old `-lOpenImageIO` linker flag

Remove one or the other.

## Alternative: Simpler Approach

If frameworks are too complex, consider linking the dylibs directly:

### 1. Remove Framework Search Paths

### 2. Add to Library Search Paths:
```
$(PROJECT_DIR)/Frameworks/OpenImageIO.3.1.framework/Versions/A
$(PROJECT_DIR)/Frameworks/OpenColorIO.2.5.framework/Versions/A
```

### 3. Add to Other Linker Flags:
```
-lOpenImageIO.3.1
-lOpenColorIO.2.5
```

### 4. Add to Runpath Search Paths:
```
@executable_path/../Frameworks/OpenImageIO.3.1.framework/Versions/A
@executable_path/../Frameworks/OpenColorIO.2.5.framework/Versions/A
```

But this is messier. Framework linking is cleaner if we can get it working.

## Debug: Check What Xcode Is Trying to Link

1. **Build** the project (even if it fails)

2. **Open Report Navigator** (⌘9)

3. **Click latest build**

4. **Find "Link" step** and expand it

5. **Look for:**
   - `-framework OpenImageIO` or `-lOpenImageIO`
   - What paths are being searched

6. **Share the link command** if still stuck - the full command will show what Xcode is actually doing

## Quick Test

Try this minimal configuration:

### Build Settings:
```
Framework Search Paths:
  $(PROJECT_DIR)/Frameworks

Header Search Paths:
  $(PROJECT_DIR)/Frameworks/OpenImageIO.3.1.framework/Headers
  $(PROJECT_DIR)/Frameworks/OpenColorIO.2.5.framework/Headers

Runpath Search Paths:
  @executable_path/../Frameworks

Other Linker Flags:
  (empty - remove everything)
```

### Build Phases → Link Binary With Libraries:
- Add only: `OpenImageIO.3.1.framework`
- Add only: `OpenColorIO.2.5.framework`
- Plus system frameworks (Metal, MetalKit, AppKit)

Then **Clean Build Folder** and **Build**.

---

**Most Common Solution:**

The issue is usually that `OpenImageIO.framework` (without version) is a broken symlink or empty, and you need to explicitly link `OpenImageIO.3.1.framework` instead.

Let me know which option works!
