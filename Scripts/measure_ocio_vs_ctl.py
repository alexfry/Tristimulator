#!/usr/bin/env python3
"""
measure_ocio_vs_ctl.py
======================
Measures how far OpenColorIO's CPU path is from the ACES 2.0 CTL golden data, using
the same transforms the app builds (see OpenColorIOBridge.mm). Use it to choose and
re-justify the tolerances in TristimulatorTests/ACES2CTLGoldenTests.swift.

    pip install opencolorio==2.5.2 numpy     # match the OCIO version vcpkg builds
    python3 Scripts/measure_ocio_vs_ctl.py

This is a measurement aid only. The XCTest suite is the gate, and it runs the app's
own Objective-C++ bridge and Metal path, not this Python replica.
"""
import json
import os
import sys
from pathlib import Path

import numpy as np
import PyOpenColorIO as OCIO

ROOT = Path(__file__).resolve().parent.parent
GOLD = Path(os.environ.get("GOLDEN_DIR", ROOT / "TristimulatorTests" / "GoldenData" / "ACES2"))
CONFIG = ROOT / "OCIO" / "studio-config-v4.0.0_aces-v2.0_ocio-v2.5.ocio"

GAMUTS = {
    "p3d65": [0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.3127, 0.3290],
    "rec709": [0.640, 0.330, 0.300, 0.600, 0.150, 0.060, 0.3127, 0.3290],
}


def rgb_to_xyz16(Rx, Ry, Gx, Gy, Bx, By, Wx, Wy):
    xyz = lambda x, y: np.array([x / y, 1.0, (1 - x - y) / y])
    P = np.stack([xyz(Rx, Ry), xyz(Gx, Gy), xyz(Bx, By)], 1)
    S = np.linalg.solve(P, xyz(Wx, Wy))
    M = np.eye(4)
    M[:3, :3] = P * S
    return M.flatten().tolist()


def mtx(m, inverse=False):
    t = OCIO.MatrixTransform(matrix=m)
    if inverse:
        t.setDirection(OCIO.TRANSFORM_DIR_INVERSE)
    return t


def dynamic_group(peak, gamut, src="ACES2065-1"):
    """Python replica of +aces2DynamicProcessorWithConfig (OpenColorIOBridge.mm)."""
    g = GAMUTS[gamut]
    ap0 = rgb_to_xyz16(0.7347, 0.2653, 0.0, 1.0, 0.0001, -0.0770, 0.32168, 0.33767)
    ap1 = rgb_to_xyz16(0.713, 0.293, 0.165, 0.830, 0.128, 0.044, 0.32168, 0.33767)
    upper = 8.0 * (128.0 + 768.0 * (np.log(peak / 100.0) / np.log(100.0)))
    grp = OCIO.GroupTransform()
    grp.appendTransform(OCIO.ColorSpaceTransform(src=src, dst="ACES2065-1"))
    grp.appendTransform(mtx(ap0))
    grp.appendTransform(mtx(ap1, True))
    grp.appendTransform(OCIO.RangeTransform(minInValue=0, maxInValue=upper, minOutValue=0, maxOutValue=upper))
    grp.appendTransform(mtx(ap1))
    grp.appendTransform(mtx(ap0, True))
    grp.appendTransform(OCIO.FixedFunctionTransform(OCIO.FIXED_FUNCTION_ACES_OUTPUT_TRANSFORM_20, [peak] + g))
    grp.appendTransform(OCIO.RangeTransform(minInValue=0, maxInValue=peak / 100, minOutValue=0, maxOutValue=peak / 100))
    grp.appendTransform(mtx(rgb_to_xyz16(*g)))
    grp.appendTransform(OCIO.BuiltinTransform(style="DISPLAY - CIE-XYZ-D65_to_DisplayP3-HDR"))
    return grp


def app_transform(app):
    """The OCIO transform the app builds for each golden entry (CPU path)."""
    p = app["path"]
    if p == "displayView":
        return OCIO.DisplayViewTransform(src="ACES2065-1", display=app["display"], view=app["view"])
    if p == "dynamicACES2":
        # App: linearize source -> scene_linear (ACEScg), then the dynamic group from ACEScg.
        return dynamic_group(float(app["peakNits"]), app["gamut"], src="ACEScg"), "ACEScg"
    if p == "inverseDisplay":
        # App: inverse display -> scene_linear (ACEScg). The test maps ACEScg -> ACES2065-1.
        g = OCIO.GroupTransform()
        g.appendTransform(OCIO.DisplayViewTransform(src="ACEScg", display=app["display"], view=app["view"],
                                                    direction=OCIO.TRANSFORM_DIR_INVERSE))
        g.appendTransform(OCIO.ColorSpaceTransform(src="ACEScg", dst="ACES2065-1"))
        return g
    inv = OCIO.DisplayViewTransform(src="ACEScg", display=app["display"], view=app["view"],
                                    direction=OCIO.TRANSFORM_DIR_INVERSE)
    g = OCIO.GroupTransform()
    g.appendTransform(inv)
    if p == "inverseThenDisplay":
        g.appendTransform(OCIO.DisplayViewTransform(src="ACEScg", display=app["display"], view=app["view"]))
    elif p == "inverseThenDynamicACES2":
        g.appendTransform(dynamic_group(float(app["peakNits"]), app["gamut"], src="ACEScg"))
    else:
        raise ValueError(p)
    return g


def metrics(kind, got, exp):
    """Same metrics as ACES2CTLGoldenTests.swift.
    forward/roundtrip: absolute error in display code values, per sample = max over RGB.
    inverse: per sample, max RGB error / max(max |expected RGB|, 1e-3) (scene-linear, relative)."""
    d = np.abs(got.astype(np.float64) - exp.astype(np.float64)).max(1)
    if kind == "inverse":
        d = d / np.maximum(np.abs(exp).max(1), 1e-3)
    return d


def main():
    cfg = OCIO.Config.CreateFromFile(str(CONFIG))
    man = json.loads((GOLD / "manifest.json").read_text())
    inputs = {k: np.fromfile(GOLD / v["file"], np.float32).reshape(-1, 3) for k, v in man["inputs"].items()}
    res = {}
    print(f"OCIO {OCIO.__version__}  (metric: abs code value; 'inverse' rows are relative)")
    print(f"{'transform':28s} {'max':>10s} {'p99':>10s} {'median':>10s} {'neg out':>7s}")
    for t in man["transforms"]:
        exp = np.fromfile(GOLD / t["file"], np.float32).reshape(-1, 3)
        x = inputs[t["inputs"]].copy()
        tr = app_transform(t["app"])
        if isinstance(tr, tuple):  # dynamic: linearize ACES2065-1 -> ACEScg first, as the app does
            tr, lin = tr
            pre = cfg.getProcessor(OCIO.ColorSpaceTransform(src="ACES2065-1", dst=lin)).getDefaultCPUProcessor()
            pre.applyRGB(x)
        y = x.reshape(-1).copy()
        cfg.getProcessor(tr).getDefaultCPUProcessor().applyRGB(y)
        y = y.reshape(-1, 3)
        neg = int(np.count_nonzero((y < 0).any(1))) if t["kind"] != "inverse" else 0
        if t["app"]["path"] == "displayView" and "Rec.2100-PQ" in t["app"].get("display", ""):
            y = np.maximum(y, 0.0)  # known: CTL clamps negatives before PQ, OCIO's builtin mirrors them
        d = metrics(t["kind"], y, exp)
        res[t["id"]] = dict(max=float(d.max()), p99=float(np.percentile(d, 99)))
        print(f"{t['id']:28s} {d.max():10.3e} {np.percentile(d, 99):10.3e} {np.median(d):10.3e} {neg:7d}")
    return res


if __name__ == "__main__":
    main()
