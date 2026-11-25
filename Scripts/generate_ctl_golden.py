#!/usr/bin/env python3
"""
generate_ctl_golden.py
======================
Regenerates the ACES 2.0 CTL golden reference data used by
TristimulatorTests/ACES2CTLGoldenTests.swift.

The reference values come from the Academy's official ACES 2.0 CTL, run through
ctlrender. Nothing here uses OpenColorIO. The app's own pipeline (OCIO) is what the
tests compare *against* these files.

Pinned sources (see TristimulatorTests/GoldenData/ACES2/README.md):
    https://github.com/aces-aswf/aces      tag v2.0.0+2025.04.04 (35e1e6a)
      aces-core   submodule 2d7af39344725aaa8ac3bf1746693c9a1d6c4792
      aces-output submodule aab74723f76728c37345ed01e51ebb24fb1f2f1f
    https://github.com/aces-aswf/CTL       tag ctl-1.5.5 (294609e) -> ctlrender

Usage:
    python3 Scripts/generate_ctl_golden.py \
        --aces /path/to/aces            # checkout of aces-aswf/aces at the tag, with submodules
        --ctlrender /path/to/ctlrender
        [--out TristimulatorTests/GoldenData/ACES2]

Requires Python 3.9+, numpy and the OpenEXR Python bindings (pip install numpy OpenEXR).
The script is deterministic: the same CTL and ctlrender give byte-identical files.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import OpenEXR

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO_ROOT / "TristimulatorTests" / "GoldenData" / "ACES2"
SEED = 20261125

# ---------------------------------------------------------------------------
# Colour maths used only to *build the input set* (never to build expected values)
# ---------------------------------------------------------------------------

AP0 = [(0.7347, 0.2653), (0.0, 1.0), (0.0001, -0.0770), (0.32168, 0.33767)]
AP1 = [(0.713, 0.293), (0.165, 0.830), (0.128, 0.044), (0.32168, 0.33767)]


def rgb_to_xyz(pri):
    """Column-vector RGB->XYZ (Y of white = 1), same construction as CTL RGBtoXYZ_f33."""
    xyz = lambda x, y: np.array([x / y, 1.0, (1.0 - x - y) / y])
    P = np.stack([xyz(*pri[0]), xyz(*pri[1]), xyz(*pri[2])], axis=1)
    S = np.linalg.solve(P, xyz(*pri[3]))
    return P * S


AP1_TO_AP0 = np.linalg.solve(rgb_to_xyz(AP0), rgb_to_xyz(AP1))


def ap1(rgb):
    return np.asarray(rgb, dtype=np.float64) @ AP1_TO_AP0.T


def scene_inputs():
    """ACES2065-1 (AP0) scene-linear samples. Returns float32 [N,3] and a label per row."""
    rows, labels = [], []

    def add(arr, label):
        arr = np.atleast_2d(np.asarray(arr, dtype=np.float64))
        rows.append(arr)
        labels.extend([label] * len(arr))

    # 1. Neutral grey ramp: exact 0, then 0.18 * 2^(s/3) for s = -42..+36 (-14..+12 stops).
    add([[0.0, 0.0, 0.0]], "grey")
    stops = np.arange(-42, 37) / 3.0
    g = 0.18 * np.exp2(stops)
    add(np.stack([g, g, g], 1), "grey")
    add([[0.18, 0.18, 0.18], [1.0, 1.0, 1.0]], "grey")

    # 2. AP1 primaries and secondaries, 0.18 * 2^k for k = -6..+8 (step 1), in ACEScg then -> AP0.
    prims = np.array([[1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 1, 1], [1, 0, 1], [1, 1, 0]], float)
    for k in range(-6, 9):
        add(ap1(prims * 0.18 * 2.0 ** k), "ap1_primary_secondary")

    # 3. AP0 primaries at a few exposures (outside AP1: exercises the AP1 clamp).
    for k in (-4, 0, 4):
        add(np.eye(3) * 0.18 * 2.0 ** k, "ap0_primary")

    # 4. Hue sweep in ACEScg: 36 hues x 3 saturations x 5 exposures.
    hues = np.arange(36) * (2 * np.pi / 36)
    for sat in (0.3, 0.7, 1.0):
        for k in (-4, -1, 1, 4, 7):
            Y = 0.18 * 2.0 ** k
            for h in hues:
                # Simple opponent construction around grey; clip at 0 so 1.0 sat hits the AP1 boundary.
                c = np.array([np.cos(h), np.cos(h - 2 * np.pi / 3), np.cos(h + 2 * np.pi / 3)])
                rgb = np.maximum(1.0 + sat * 2.0 * c, 0.0)
                rgb = rgb / max(rgb.mean(), 1e-9) * Y
                add(ap1(rgb), "ap1_hue_sweep")

    # 5. Near and beyond the AP1 boundary: ACEScg with small and large negative components.
    for k in (-2, 1, 4):
        Y = 0.18 * 2.0 ** k
        for neg in (-0.001, -0.05, -0.25):
            for perm in ([1, 1, neg], [1, neg, 1], [neg, 1, 1], [1, neg, neg], [neg, 1, neg], [neg, neg, 1]):
                add(ap1(np.array(perm) * Y), "ap1_out_of_gamut")

    # 6. Very large values around the AP1 upper clamp (8 * r_hit) for every peak tested.
    for v in (100.0, 500.0, 1000.0, 2000.0, 8000.0, 16000.0, 65504.0):
        add([[v, v, v], ap1([v, 0, 0]), ap1([0, v, 0]), ap1([0, 0, v])], "large")

    # 7. Seeded random: log-uniform luminance (-12..+10 stops from 0.18), random ACEScg chroma.
    rng = np.random.default_rng(SEED)
    n = 1000
    Y = 0.18 * np.exp2(rng.uniform(-12, 10, n))
    chroma = rng.uniform(-0.15, 1.0, (n, 3))
    chroma /= np.maximum(chroma.mean(1, keepdims=True), 1e-3)
    add(ap1(chroma * Y[:, None]), "random")

    out = np.concatenate(rows).astype(np.float32)
    return out, labels


def display_inputs():
    """Display code values (encoded, [0,1]) for the inverse output transforms."""
    rows, labels = [], []
    g = np.linspace(0, 1, 9)
    cube = np.stack(np.meshgrid(g, g, g, indexing="ij"), -1).reshape(-1, 3)
    rows.append(cube)
    labels += ["cube9"] * len(cube)
    ramp = np.linspace(0, 1, 256)
    rows.append(np.stack([ramp] * 3, 1))
    labels += ["grey_ramp"] * 256
    rng = np.random.default_rng(SEED + 1)
    r = rng.uniform(0, 1, (500, 3))
    rows.append(r)
    labels += ["random"] * 500
    return np.concatenate(rows).astype(np.float32), labels


# ---------------------------------------------------------------------------
# Transforms: (id, kind, input set, CTL path relative to aces-output, peak override, app mapping)
# ---------------------------------------------------------------------------

D65 = "d65"
TRANSFORMS = [
    # Config mode: OCIO DisplayViewTransform from the bundled studio config.
    dict(id="fwd_sdr100_rec709_srgb", kind="forward", inputs="scene",
         ctl=f"{D65}/srgb/Output.Academy.Rec709-D65_100nit_in_Rec709-D65_sRGB-Piecewise.ctl",
         app={"path": "displayView", "display": "sRGB - Display", "view": "ACES 2.0 - SDR 100 nits (Rec.709)"}),
    dict(id="fwd_sdr100_p3_srgb", kind="forward", inputs="scene",
         ctl=f"{D65}/displayP3/Output.Academy.P3-D65_100nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "displayView", "display": "Display P3 - Display", "view": "ACES 2.0 - SDR 100 nits (P3 D65)"}),
    dict(id="fwd_hdr1000_p3_srgb", kind="forward", inputs="scene",
         ctl=f"{D65}/displayP3/Output.Academy.P3-D65_1000nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "displayView", "display": "Display P3 HDR - Display", "view": "ACES 2.0 - HDR 1000 nits (P3 D65)"}),
    dict(id="fwd_hdr1000_p3_rec2100pq", kind="forward", inputs="scene",
         ctl=f"{D65}/rec2100/Output.Academy.P3-D65_1000nit_in_Rec2100-D65_ST2084.ctl",
         app={"path": "displayView", "display": "Rec.2100-PQ - Display", "view": "ACES 2.0 - HDR 1000 nits (P3 D65)"}),
    # Dynamic ACES2 mode: programmatic group (FIXED_FUNCTION_ACES_OUTPUT_TRANSFORM_20) encoded
    # with DISPLAY - CIE-XYZ-D65_to_DisplayP3-HDR. P3-D65 limiting is the app default.
    dict(id="dyn_p3_100", kind="forward", inputs="scene",
         ctl=f"{D65}/displayP3/Output.Academy.P3-D65_100nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "dynamicACES2", "peakNits": 100, "gamut": "p3d65"}),
    dict(id="dyn_p3_400", kind="forward", inputs="scene", peak=400,
         ctl=f"{D65}/displayP3/Output.Academy.P3-D65_1000nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "dynamicACES2", "peakNits": 400, "gamut": "p3d65"}),
    dict(id="dyn_p3_1000", kind="forward", inputs="scene",
         ctl=f"{D65}/displayP3/Output.Academy.P3-D65_1000nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "dynamicACES2", "peakNits": 1000, "gamut": "p3d65"}),
    dict(id="dyn_p3_1600", kind="forward", inputs="scene", peak=1600,
         ctl=f"{D65}/displayP3/Output.Academy.P3-D65_1000nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "dynamicACES2", "peakNits": 1600, "gamut": "p3d65"}),
    dict(id="dyn_p3_4000", kind="forward", inputs="scene", peak=4000,
         ctl=f"{D65}/displayP3/Output.Academy.P3-D65_1000nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "dynamicACES2", "peakNits": 4000, "gamut": "p3d65"}),
    dict(id="dyn_rec709_100", kind="forward", inputs="scene",
         ctl=f"{D65}/displayP3/Output.Academy.Rec709-D65_100nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "dynamicACES2", "peakNits": 100, "gamut": "rec709"}),
    # Inverse display (display-referred images: JPG/PNG): display code values -> ACES2065-1.
    dict(id="inv_sdr100_rec709_srgb", kind="inverse", inputs="display",
         ctl=f"{D65}/srgb/InvOutput.Academy.Rec709-D65_100nit_in_Rec709-D65_sRGB-Piecewise.ctl",
         app={"path": "inverseDisplay", "display": "sRGB - Display", "view": "ACES 2.0 - SDR 100 nits (Rec.709)"}),
    dict(id="inv_sdr100_p3_srgb", kind="inverse", inputs="display",
         ctl=f"{D65}/displayP3/InvOutput.Academy.P3-D65_100nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "inverseDisplay", "display": "Display P3 - Display", "view": "ACES 2.0 - SDR 100 nits (P3 D65)"}),
    # Round trips: CTL forward applied to the CTL inverse output (the app's combined
    # inverse-display -> display GPU pass is compared with this).
    dict(id="rt_sdr100_rec709_srgb", kind="roundtrip", inputs="display", of="inv_sdr100_rec709_srgb",
         ctl=f"{D65}/srgb/Output.Academy.Rec709-D65_100nit_in_Rec709-D65_sRGB-Piecewise.ctl",
         app={"path": "inverseThenDisplay", "display": "sRGB - Display", "view": "ACES 2.0 - SDR 100 nits (Rec.709)"}),
    dict(id="rt_sdr100_p3_srgb", kind="roundtrip", inputs="display", of="inv_sdr100_p3_srgb",
         ctl=f"{D65}/displayP3/Output.Academy.P3-D65_100nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "inverseThenDisplay", "display": "Display P3 - Display", "view": "ACES 2.0 - SDR 100 nits (P3 D65)"}),
    # Inverse display then Dynamic ACES2 (an sRGB JPG/PNG opened with the inverse-display
    # preference while the app is in Dynamic ACES2 mode, P3-D65 limiting).
    dict(id="invdyn_rec709_to_p3_100", kind="roundtrip", inputs="display", of="inv_sdr100_rec709_srgb",
         ctl=f"{D65}/displayP3/Output.Academy.P3-D65_100nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "inverseThenDynamicACES2", "display": "sRGB - Display",
              "view": "ACES 2.0 - SDR 100 nits (Rec.709)", "peakNits": 100, "gamut": "p3d65"}),
    dict(id="invdyn_rec709_to_p3_1000", kind="roundtrip", inputs="display", of="inv_sdr100_rec709_srgb",
         ctl=f"{D65}/displayP3/Output.Academy.P3-D65_1000nit_in_P3-D65_sRGB-Piecewise.ctl",
         app={"path": "inverseThenDynamicACES2", "display": "sRGB - Display",
              "view": "ACES 2.0 - SDR 100 nits (Rec.709)", "peakNits": 1000, "gamut": "p3d65"}),
]


def write_exr(path, rgb):
    n = len(rgb)
    rgba = np.ones((1, n, 4), np.float32)
    rgba[0, :, :3] = rgb
    header = {"compression": OpenEXR.NO_COMPRESSION, "type": OpenEXR.scanlineimage}
    with OpenEXR.File(header, {"RGBA": rgba}) as f:
        f.write(str(path))


def read_exr(path):
    with OpenEXR.File(str(path)) as f:
        ch = f.channels()
        if "RGBA" in ch:
            px = ch["RGBA"].pixels
        else:
            px = np.stack([ch[c].pixels for c in "RGB"], -1)
    return np.asarray(px, np.float32).reshape(-1, px.shape[-1])[:, :3]


def run_ctl(ctlrender, ctl, module_path, inp, outp):
    env = dict(os.environ, CTL_MODULE_PATH=str(module_path))
    cmd = [str(ctlrender), "-force", "-ctl", str(ctl), str(inp), "-format", "exr32", str(outp)]
    subprocess.run(cmd, check=True, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git_head(path):
    try:
        return subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--aces", required=True, type=Path, help="aces-aswf/aces checkout (with submodules)")
    ap.add_argument("--ctlrender", required=True, type=Path)
    ap.add_argument("--ctl-repo", type=Path, help="CTL source checkout, recorded in the manifest only")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    a = ap.parse_args()

    core_lib = a.aces / "aces-core" / "lib"
    out_root = a.aces / "aces-output"
    if not core_lib.is_dir() or not out_root.is_dir():
        sys.exit("--aces must contain aces-core/lib and aces-output (git submodule update --init)")

    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "expected").mkdir(exist_ok=True)

    scene, scene_labels = scene_inputs()
    disp, disp_labels = display_inputs()
    sets = {"scene": scene, "display": disp}
    scene.tofile(a.out / "input_scene_ap0.f32")
    disp.tofile(a.out / "input_display_cv.f32")

    results = {}
    manifest = {
        "format": "float32 little-endian, row-major [count][3] (RGB), no header",
        "generator": "Scripts/generate_ctl_golden.py",
        "seed": SEED,
        "sources": {
            "aces": {"url": "https://github.com/aces-aswf/aces", "commit": git_head(a.aces)},
            "aces-core": {"url": "https://github.com/aces-aswf/aces-core", "commit": git_head(a.aces / "aces-core")},
            "aces-output": {"url": "https://github.com/aces-aswf/aces-output", "commit": git_head(out_root)},
            "ctlrender": {"url": "https://github.com/aces-aswf/CTL",
                          "commit": git_head(a.ctl_repo) if a.ctl_repo else "unknown"},
        },
        "inputs": {
            "scene": {"file": "input_scene_ap0.f32", "count": len(scene), "encoding": "ACES2065-1 (AP0) linear",
                      "groups": {k: scene_labels.count(k) for k in dict.fromkeys(scene_labels)}},
            "display": {"file": "input_display_cv.f32", "count": len(disp), "encoding": "display code values",
                        "groups": {k: disp_labels.count(k) for k in dict.fromkeys(disp_labels)}},
        },
        "transforms": [],
    }

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        for t in TRANSFORMS:
            ctl = out_root / t["ctl"]
            if not ctl.is_file():
                sys.exit(f"missing CTL: {ctl}")
            derived = None
            if "peak" in t:
                # Same official CTL with only the peakLuminance constant changed. CTL cannot take
                # peak as a runtime parameter because init_ODTParams() runs at global scope.
                src = ctl.read_text()
                new, nsub = re.subn(r"const float peakLuminance = [0-9.]+;",
                                    f"const float peakLuminance = {float(t['peak']):.1f};", src)
                if nsub != 1:
                    sys.exit(f"could not patch peakLuminance in {ctl}")
                ctl_run = td / f"{t['id']}.ctl"
                ctl_run.write_text(new)
                derived = f"{t['ctl']} with peakLuminance = {t['peak']}"
            else:
                ctl_run = ctl

            if t["kind"] == "roundtrip":
                src_rgb = results[t["of"]]
            else:
                src_rgb = sets[t["inputs"]]
            inp = td / f"{t['id']}_in.exr"
            outp = td / f"{t['id']}_out.exr"
            write_exr(inp, src_rgb)
            run_ctl(a.ctlrender, ctl_run, core_lib, inp, outp)
            res = read_exr(outp)
            assert res.shape == src_rgb.shape, (res.shape, src_rgb.shape)
            nan = int(np.count_nonzero(~np.isfinite(res)))
            results[t["id"]] = res
            fn = f"expected/{t['id']}.f32"
            res.astype(np.float32).tofile(a.out / fn)
            entry = {k: v for k, v in t.items() if k not in ("peak",)}
            entry.update({"file": fn, "count": len(res), "ctl_sha256": sha256(ctl),
                          "non_finite": nan})
            if derived:
                entry["derived"] = derived
            manifest["transforms"].append(entry)
            print(f"{t['id']:28s} n={len(res):5d} nonfinite={nan} range=[{np.nanmin(res):.6g}, {np.nanmax(res):.6g}]")

    for f in sorted(a.out.rglob("*.f32")):
        manifest.setdefault("sha256", {})[str(f.relative_to(a.out))] = sha256(f)
    (a.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
