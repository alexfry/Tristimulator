# OpenColorIO Setup for Tristimulator

## What is OpenColorIO (OCIO)?

OpenColorIO is an industry-standard color management system used in film, VFX, and professional imaging. It allows you to:

- Transform between different color spaces (sRGB, Rec.709, ACEScg, etc.)
- Apply display transforms for proper color reproduction
- Handle HDR and wide gamut imagery
- Use industry-standard ACES workflows

## Quick Setup

### Option 1: Use Environment Variable (Recommended)

Download an OCIO config and set the `OCIO` environment variable:

```bash
# Download ACES config
mkdir -p ~/ocio-configs
cd ~/ocio-configs
curl -L https://github.com/colour-science/OpenColorIO-Configs/archive/refs/heads/main.zip -o configs.zip
unzip configs.zip

# Set environment variable (add to ~/.zshrc or ~/.bash_profile)
export OCIO=~/ocio-configs/OpenColorIO-Configs-main/aces_1.2/config.ocio

# Apply immediately
source ~/.zshrc  # or source ~/.bash_profile
```

### Option 2: Use Studio Config

If you're working in a studio environment, they likely have an OCIO config. Ask your pipeline team for the path:

```bash
export OCIO=/path/to/studio/config.ocio
```

### Option 3: Simple sRGB Config

For basic testing, create a minimal config:

```bash
mkdir -p ~/ocio-configs/simple
cat > ~/ocio-configs/simple/config.ocio << 'EOF'
ocio_profile_version: 2

search_path: ""
strictparsing: true
luma: [0.2126, 0.7152, 0.0722]

roles:
  default: Linear
  scene_linear: Linear

displays:
  sRGB:
    - !<View> {name: Standard, colorspace: sRGB}

active_displays: [sRGB]
active_views: [Standard]

colorspaces:
  - !<ColorSpace>
    name: Linear
    family: ""
    equalitygroup: ""
    bitdepth: 32f
    description: Scene-linear, high dynamic range
    isdata: false
    allocation: lg2
    allocationvars: [-8, 8]

  - !<ColorSpace>
    name: sRGB
    family: ""
    equalitygroup: ""
    bitdepth: 32f
    description: sRGB display space
    isdata: false
    allocation: uniform
    from_reference: !<GroupTransform>
      children:
        - !<ColorSpaceTransform> {src: Linear, dst: sRGB}
EOF

export OCIO=~/ocio-configs/simple/config.ocio
```

## Verify Setup

Run Tristimulator and check the console output. You should see:

```
✅ OpenColorIO loaded successfully
📊 Version: 2.5.0
```

If you see:
```
⚠️ OpenColorIO config not found. Set OCIO environment variable for color management.
```

Then OCIO couldn't find a config. Make sure:
1. The `OCIO` environment variable is set
2. The path points to a valid config file
3. You've restarted Terminal (or sourced your profile)
4. You've restarted Xcode

## Running from Xcode

To make the environment variable available in Xcode:

1. **Edit Scheme**
   - In Xcode: **Product** → **Scheme** → **Edit Scheme...**
   - Select **Run** in the left sidebar
   - Click **Arguments** tab
   - Under **Environment Variables**, click **+**
   - Add: `OCIO` = `/path/to/your/config.ocio`

2. **Or Set Globally**
   - Add to `~/.zshrc` or `~/.bash_profile`
   - Restart Xcode completely

## Using OCIO in Tristimulator

Once OCIO is loaded:

1. **Load an Image**
   - Open any image (PNG, JPEG, EXR, etc.)

2. **Open Color Controls Panel**
   - If not visible, go to **View** → **Color Controls**

3. **Apply Color Space Transform**
   - Choose **Source Space** (e.g., "Linear")
   - Choose **Destination Space** (e.g., "sRGB")
   - Click **Apply Transform**

4. **Apply Display Transform**
   - Choose a **Display** (e.g., "sRGB", "Rec.709")
   - Choose a **View** (e.g., "Standard", "Film", "Log")
   - Click **Apply Display Transform**

## Common Color Spaces in ACES

If you're using the ACES config:

- **ACEScg**: Scene-linear working space (for compositing/CGI)
- **ACES2065-1**: ACES interchange format
- **sRGB**: Standard display space
- **Rec.709**: Broadcast television
- **Linear**: Generic scene-linear
- **ACES - ACEScc**: Log encoding for color grading
- **ACES - ACEScct**: Log encoding with toe

## Troubleshooting

### "OCIO not available" Error

- Environment variable not set
- Config file doesn't exist at the path
- Xcode can't see the environment variable

**Fix**: Set the environment variable in Xcode's scheme (see above)

### Color Spaces List is Empty

- Config loaded but no color spaces defined
- Check config file is valid OCIO format

**Fix**: Try the simple config above or download ACES config

### "Error applying color transform"

- Source or destination color space doesn't exist in config
- Invalid color space names

**Fix**: Use the exact names shown in the dropdown menus

### Crash When Applying Transform

- Pixel data format mismatch
- Channel count mismatch

**Fix**: Make sure image loaded successfully before applying transforms

## Resources

- [OpenColorIO Official Docs](https://opencolorio.readthedocs.io/)
- [ACES Configs](https://github.com/colour-science/OpenColorIO-Configs)
- [OCIO Config Syntax](https://opencolorio.readthedocs.io/en/latest/guides/authoring/authoring.html)

## For Developers

The OCIO integration uses three main classes:

- `OCIOConfig`: Loads and queries OCIO configurations
- `OCIOProcessor`: Creates color space processors
- `OpenColorIOBridge`: Utility methods and version info

See `OpenColorIOBridge.h` and `OpenColorIOBridge.mm` for implementation details.
