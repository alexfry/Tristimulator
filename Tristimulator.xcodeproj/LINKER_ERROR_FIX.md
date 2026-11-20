# Linker Error Fix: Missing OpenImageIO_Util

## The Current Error

```
Undefined symbols for architecture arm64:
  "OpenImageIO::v3_1::ParamValue::clear_value()"
  "OpenImageIO::v3_1::ParamValue::init_noclear(...)"
  "OpenImageIO::v3_1::ParamValue::operator=(...)"
  "OpenImageIO::v3_1::c_str(...)"
  "OpenImageIO::v3_1::ustring::empty_std_string"
  "OpenImageIO::v3_1::ParamValue::get_string(int) const"
  "OpenImageIO::v3_1::TypeDesc::basesize() const"
ld: symbol(s) not found for architecture arm64
```

## What This Means

✅ **Good news:** The build is progressing! No more framework signing errors.

❌ **Current issue:** The linker can't find symbols from `OpenImageIO_Util` library.

## Why This Happened

OpenImageIO is split into **two separate libraries**:

1. **`libOpenImageIO.dylib`** - Main image I/O functions
   - Opening/closing image files
   - Reading/writing pixels
   - Format conversions

2. **`libOpenImageIO_Util.dylib`** - Utility classes
   - `ParamValue` class (metadata)
   - `TypeDesc` class (type descriptions)
   - `ustring` class (unique strings)
   - Other utility functions

Your code uses `ParamValue` and other utilities from `OpenImageIOBridge.mm`, so it needs **both** libraries.

The `embed_dylibs_simple.sh` script likely missed `_Util` because:
- It's not always a direct dependency of the main library
- The dependency scanner didn't detect it
- It needs to be explicitly included

## The Fix

### Quick Fix (Run This Now)

```bash
cd /Users/afry/GitHub/Tristimulator/Tristimulator

# Check what you have
chmod +x check_dylibs_status.sh
./check_dylibs_status.sh

# If OpenImageIO_Util is missing, add it
chmod +x fix_linker_error.sh
./fix_linker_error.sh
```

This will:
1. Copy `libOpenImageIO_Util.dylib` to your `Dylibs/` folder
2. Fix its install name
3. Sign it
4. Tell you what to do in Xcode

### Then in Xcode

**Step 1: Add to linker flags**
- Build Settings → Search: "Other Linker Flags"
- Current value probably has:
  ```
  -lOpenImageIO
  -lOpenColorIO
  ```
- **ADD** this line:
  ```
  -lOpenImageIO_Util
  ```
- Final result:
  ```
  -lOpenImageIO
  -lOpenImageIO_Util
  -lOpenColorIO
  ```

**Step 2: Add to Copy Files phase**
- Build Phases → Copy Dylibs
- Click `+` to add files
- Select: `Dylibs/libOpenImageIO_Util.dylib` (or `libOpenImageIO_Util.3.1.dylib`)
- Make sure "Code Sign On Copy" is ✅ checked

**Step 3: Clean and rebuild**
```bash
⌘⇧K (Clean Build Folder)
⌘B (Build)
```

## How to Tell If It Worked

### Successful Build Output:
```
Build succeeded
```

No more undefined symbol errors!

### Verify the Built App:
```bash
./verify_embedded_dylibs.sh
```

Should show:
```
✅ libOpenImageIO.dylib
✅ libOpenImageIO_Util.dylib
✅ libOpenColorIO.dylib
```

## Alternative: If Script Doesn't Work

You can manually add it:

```bash
# Find the library
ls -l /opt/homebrew/lib/libOpenImageIO_Util*

# Copy it
cp /opt/homebrew/lib/libOpenImageIO_Util.dylib ./Dylibs/

# Fix install name
install_name_tool -id "@rpath/libOpenImageIO_Util.dylib" \
                  ./Dylibs/libOpenImageIO_Util.dylib

# Sign it
codesign --force --sign "Apple Development: Alex Fry (7CART63SAF)" \
         --timestamp --options runtime \
         ./Dylibs/libOpenImageIO_Util.dylib
```

Then follow Xcode steps above.

## Understanding the Error Messages

Let's break down what each undefined symbol is:

| Symbol | What It Is | Where It's From |
|--------|-----------|-----------------|
| `ParamValue::clear_value()` | Clears metadata value | OpenImageIO_Util |
| `ParamValue::init_noclear()` | Initializes metadata | OpenImageIO_Util |
| `ParamValue::operator=()` | Assigns metadata | OpenImageIO_Util |
| `ParamValue::get_string()` | Gets string from metadata | OpenImageIO_Util |
| `TypeDesc::basesize()` | Gets type size | OpenImageIO_Util |
| `ustring::empty_std_string` | Empty string constant | OpenImageIO_Util |
| `c_str(string_view)` | Converts string_view to C string | OpenImageIO_Util |

**All from `OpenImageIO_Util`!** That's why adding that one library fixes everything.

## Why Your Code Uses These

Looking at your code (`OpenImageIOBridge.mm`), you're using:

```objc
// Getting image metadata
- (OIIOImageSpec *)initWithImageSpec:(const OIIO::ImageSpec &)spec {
    // ...
    for (const auto &param : spec.extra_attribs) {
        NSString *name = [NSString stringWithUTF8String:param.name().c_str()];
        
        // param is a ParamValue - needs OpenImageIO_Util!
        if (param.type() == OIIO::TypeDesc::STRING) {
            NSString *value = [NSString stringWithUTF8String:param.get_string().c_str()];
            // ↑ get_string() is from OpenImageIO_Util
        }
    }
}
```

So your bridge code **requires** `OpenImageIO_Util` to work with metadata.

## Prevention for Future

To avoid this in future dependency embedding:

1. **Explicitly list all known libraries:**
   ```bash
   # Don't just rely on dependency scanning
   find_all_deps "libOpenImageIO.dylib"
   find_all_deps "libOpenImageIO_Util.dylib"  # Explicitly add this!
   ```

2. **Check for split libraries:**
   ```bash
   ls /opt/homebrew/lib/libOpenImageIO*
   # Shows both libOpenImageIO.dylib and libOpenImageIO_Util.dylib
   ```

3. **Test early:**
   Build immediately after embedding to catch missing libraries.

## Comparison: Before vs After Fix

### Before (Current - Fails)
```
Linker searches for ParamValue symbols...
  Looks in: libOpenImageIO.dylib ❌ Not there
  Looks in: libOpenColorIO.dylib ❌ Not there
  Looks in: System libraries ❌ Not there
→ ERROR: Undefined symbols
```

### After (With _Util - Works)
```
Linker searches for ParamValue symbols...
  Looks in: libOpenImageIO.dylib ❌ Not there
  Looks in: libOpenImageIO_Util.dylib ✅ FOUND!
→ SUCCESS: Build complete
```

## Summary

| Problem | Solution |
|---------|----------|
| Missing symbols from `ParamValue`, `TypeDesc`, `ustring` | Add `libOpenImageIO_Util.dylib` |
| Linker flag missing | Add `-lOpenImageIO_Util` to Other Linker Flags |
| Library not in app bundle | Add to Copy Files phase |
| Library not signed | Script signs it for you |

**Bottom line:** Add the `_Util` library and link it!

---

## Quick Checklist

- [ ] Run `./fix_linker_error.sh`
- [ ] Xcode: Add `-lOpenImageIO_Util` to Other Linker Flags
- [ ] Xcode: Add `libOpenImageIO_Util.dylib` to Copy Dylibs phase
- [ ] Clean Build Folder (⌘⇧K)
- [ ] Build (⌘B)
- [ ] Verify with `./verify_embedded_dylibs.sh`

You're **very close** to success! This should be the final piece. 🎯
