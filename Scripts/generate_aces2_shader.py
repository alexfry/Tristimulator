#!/usr/bin/env python3
"""
generate_aces2_shader.py
========================
Generates the pre-baked ACES 2 Metal compute shader for the Tristimulator Quick Look
extension.  Run this once on a developer Mac whenever the ACES OCIO config changes.

Output (committed to the repo):
    Tristimulator/TristimulatorQuickLook/Shaders/aces2_ap0_displayp3.metal
    Tristimulator/TristimulatorQuickLook/Shaders/aces2_ap0_displayp3.metallib

Requirements:
    • macOS 14+
    • PyOpenColorIO 2.4+  (pip install opencolorio  or  conda install -c conda-forge opencolorio)
    • Xcode command-line tools  (xcrun metal / xcrun metallib)

Usage:
    python3 Scripts/generate_aces2_shader.py [--ocio-config PATH]

    --ocio-config  Path to the OCIO config.ocio to use.
                   Defaults to the config bundled inside the built Tristimulator.app,
                   or to the OCIO environment variable if set.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT   = Path(__file__).resolve().parent.parent
SHADERS_DIR = REPO_ROOT / "Tristimulator" / "TristimulatorQuickLook" / "Shaders"
OUT_METAL   = SHADERS_DIR / "aces2_ap0_displayp3.metal"
OUT_METALLIB = SHADERS_DIR / "aces2_ap0_displayp3.metallib"

# Seed value used to generate the shader.  Any valid nit level works; we patch
# the baked constant into a Metal uniform afterward.
SEED_PEAK_NITS = 1000.0

# ---------------------------------------------------------------------------
# OCIO config search
# ---------------------------------------------------------------------------

def find_ocio_config(explicit: str | None) -> str:
    if explicit:
        return explicit
    if env := os.environ.get("OCIO"):
        return env
    # Try the built app bundle
    app_config = Path(
        "/Applications/Tristimulator.app/Contents/Resources/ocio/config.ocio"
    )
    if app_config.exists():
        return str(app_config)
    # Try a local build
    for candidate in REPO_ROOT.rglob("config.ocio"):
        return str(candidate)
    sys.exit(
        "ERROR: Could not find an OCIO config.  Pass --ocio-config or set $OCIO."
    )

# ---------------------------------------------------------------------------
# OCIO shader generation
# ---------------------------------------------------------------------------

def generate_ocio_shader(config_path: str) -> str:
    try:
        import PyOpenColorIO as OCIO
    except ImportError:
        sys.exit(
            "ERROR: PyOpenColorIO not installed.\n"
            "  pip install opencolorio\n"
            "  or: conda install -c conda-forge opencolorio"
        )

    cfg = OCIO.Config.CreateFromFile(config_path)

    # ── Build ACES 2 output transform: AP0 → Display P3 (Extended Linear) ──
    # The FixedFunctionTransform with ACES_OUTPUT_TRANSFORM_20 takes:
    #   params[0] = peakLuminance
    #   params[1..8] = Rx,Ry, Gx,Gy, Bx,By, Wx,Wy  (output gamut chromaticities)
    #
    # Display P3 chromaticities (same primaries as P3-D65, D65 white):
    display_p3_chroma = [
        0.680, 0.320,   # R
        0.265, 0.690,   # G
        0.150, 0.060,   # B
        0.3127, 0.3290, # W (D65)
    ]
    params = [SEED_PEAK_NITS] + display_p3_chroma

    try:
        ff = OCIO.FixedFunctionTransform(
            style=OCIO.FIXED_FUNCTION_ACES_OUTPUT_TRANSFORM_20,
            params=params,
        )
    except AttributeError:
        sys.exit(
            "ERROR: OCIO build does not support FIXED_FUNCTION_ACES_OUTPUT_TRANSFORM_20.\n"
            "       Requires OpenColorIO 2.4 or later."
        )

    proc   = cfg.getProcessor(ff)
    gpuProc = proc.getDefaultGPUProcessor()

    desc = OCIO.GpuShaderDesc.CreateShaderDesc(language=OCIO.GPU_LANGUAGE_MSL_2_0)
    desc.setFunctionName("ocioACES2Transform")
    gpuProc.extractGpuShaderInfo(desc)

    shader_code = desc.getShaderText()

    # Sanity-check: ACES 2 is analytic — no LUT textures expected.
    n_tex   = desc.getNumTextures()
    n_3dtex = desc.getNum3DTextures()
    if n_tex > 0 or n_3dtex > 0:
        print(
            f"WARNING: ACES 2 processor returned {n_tex} 1D/2D + {n_3dtex} 3D textures.\n"
            "         This is unexpected.  The extension will not load these at runtime.\n"
            "         Check the OCIO config; the shader may produce incorrect output."
        )

    return shader_code

# ---------------------------------------------------------------------------
# Patch peakNits from baked constant → Metal uniform
# ---------------------------------------------------------------------------

def patch_peak_nits(shader_code: str, seed_nits: float) -> tuple[str, str]:
    """
    Replaces the baked peakLuminance constant with a reference to an external
    Metal uniform `peakNits` (bound to [[buffer(2)]] in the wrapper kernel).

    Returns (patched_ocio_code, uniform_name_used).
    The float literal in the OCIO output may appear as e.g. "1000.000000" or "1000.0f".
    We search for the seed value with a tolerance so minor floating-point formatting
    differences don't break the match.

    If no exact match is found the raw seed literal is also tried, and finally the
    script prints the relevant section of the shader for manual inspection.
    """
    # Patterns to try, in order of specificity:
    patterns = [
        # e.g.  float peakLuminance = 1000.000000;
        (r'((?:float\s+\w*[Pp]eak\w*\s*=\s*))([\d.]+(?:f)?)(;)',
         r'\1peakNits\3'),
        # e.g.  , 1000.000000f,
        (rf'(\b)({re.escape(f"{seed_nits:.6f}")}f?)(\b)',
         r'\1peakNits\3'),
        (rf'(\b)({re.escape(str(int(seed_nits)))}\.0+f?)(\b)',
         r'\1peakNits\3'),
    ]

    for pattern, replacement in patterns:
        patched, n = re.subn(pattern, replacement, shader_code, count=1)
        if n == 1:
            print(f"  ✓ Patched peakNits constant (pattern: {pattern!r[:60]})")
            return patched, "peakNits"

    # Fallback: show the shader around numeric literals close to seed_nits so
    # the developer can find the constant manually.
    print("\n  ⚠  Could not automatically patch peakNits.")
    print(f"     Searched for ~{seed_nits} in the OCIO-generated shader.")
    print("     Relevant lines containing large float literals:\n")
    for i, line in enumerate(shader_code.splitlines()):
        if re.search(r'\b(?:9\d\d|1[0-9]{3})\b', line):
            print(f"     {i+1:4}: {line}")
    print(
        "\n     After locating the correct line, manually edit the .metal file\n"
        "     to replace the baked constant with `peakNits`.\n"
        "     Then re-run: xcrun metal / xcrun metallib (see bottom of this script)."
    )
    return shader_code, "NOT_PATCHED"

# ---------------------------------------------------------------------------
# Kernel wrapper
# ---------------------------------------------------------------------------

KERNEL_WRAPPER = '''
// ── ACES 2 Output Transform wrapper kernel ────────────────────────────────
// Input:  scene-linear AP0  (ACES2065-1)
// Output: Extended Linear Display P3
//
// peakNits   [[buffer(2)]] — current display peak in nits, updated per-frame
// inputMatrix [[buffer(3)]] — source colour space → AP0,   updated per-file

kernel void ocioColorTransform(
    texture2d<float, access::read>  inputTexture  [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant float&    exposure     [[buffer(0)]],
    constant float4&   channelMask  [[buffer(1)]],
    constant float&    peakNits     [[buffer(2)]],
    constant float3x3& inputMatrix  [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) { return; }

    float4 color = inputTexture.read(gid);

    // Convert source colour space → AP0 scene-linear
    color.rgb = inputMatrix * color.rgb;

    // Exposure in scene-linear space
    color.rgb *= exp2(exposure);

    // Channel isolation
    if (channelMask.w > 0.5)
        color.rgb = float3(color.a);
    else if (channelMask.x + channelMask.y + channelMask.z < 3.0)
        color.rgb = float3(dot(color.rgb, channelMask.xyz));

    // ACES 2 Output Transform: AP0 → Extended Linear Display P3
    float4 result = ocioACES2Transform(color);

    outputTexture.write(result, gid);
}
'''

# ---------------------------------------------------------------------------
# Metal compilation
# ---------------------------------------------------------------------------

def compile_metallib(metal_src: str, out_metal: Path, out_metallib: Path) -> None:
    out_metal.parent.mkdir(parents=True, exist_ok=True)
    out_metal.write_text(metal_src, encoding="utf-8")
    print(f"  ✓ Wrote {out_metal}")

    with tempfile.TemporaryDirectory() as tmp:
        air = Path(tmp) / "aces2_ap0_displayp3.air"

        result = subprocess.run(
            [
                "xcrun", "metal",
                "-c", str(out_metal),
                "-o", str(air),
                # Disable fast-math: ACES uses pow/log/exp that fast-math can miscompile.
                "-fno-fast-math",
                "-target", "air64-apple-macos15.0",
            ],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print("ERROR: metal compilation failed:\n", result.stderr)
            sys.exit(1)
        print("  ✓ Compiled to AIR")

        result = subprocess.run(
            ["xcrun", "metallib", str(air), "-o", str(out_metallib)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print("ERROR: metallib failed:\n", result.stderr)
            sys.exit(1)
        print(f"  ✓ Linked to {out_metallib}")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ocio-config", metavar="PATH",
                        help="Path to OCIO config.ocio")
    args = parser.parse_args()

    config_path = find_ocio_config(args.ocio_config)
    print(f"Using OCIO config: {config_path}")

    print(f"\n[1/4] Generating ACES 2 Metal shader (peakNits seed = {SEED_PEAK_NITS})...")
    ocio_code = generate_ocio_shader(config_path)
    print(f"      {len(ocio_code.splitlines())} lines of OCIO-generated Metal code")

    print("\n[2/4] Patching peakNits baked constant → uniform...")
    patched_code, uniform_name = patch_peak_nits(ocio_code, SEED_PEAK_NITS)

    print("\n[3/4] Assembling final Metal source...")
    metal_src = (
        "#include <metal_stdlib>\n"
        "using namespace metal;\n\n"
        "// ── OCIO-generated ACES 2 Output Transform function ─────────────────────────\n"
        + patched_code
        + "\n"
        + KERNEL_WRAPPER
    )

    print("\n[4/4] Compiling .metal → .metallib...")
    compile_metallib(metal_src, OUT_METAL, OUT_METALLIB)

    print("\n✅  Done.")
    print(f"    Commit both files to the repo:")
    print(f"      {OUT_METAL.relative_to(REPO_ROOT)}")
    print(f"      {OUT_METALLIB.relative_to(REPO_ROOT)}")

    if uniform_name == "NOT_PATCHED":
        print("\n⚠   The peakNits constant was NOT automatically patched.")
        print("    Edit the .metal file manually before committing.")


if __name__ == "__main__":
    main()
