"""
Tristimulator OCIO rules — example pipeline script for a show/sequence/shot facility layout.

Path convention assumed:
  /<root>/<show>/images/<shot>/<version>/<filename>
  e.g. /Volumes/studio/projects/myshow/images/abc0100/10/abc0100.comp.artist.016025.v08.1014.exr

OCIO config resolved to:
  /<root>/<show>/color/<sequence>/<shot>/config.ocio
  e.g. /Volumes/studio/projects/myshow/color/abc/abc0100/config.ocio
"""

import os
import re


def evaluate(ctx):
    path     = ctx["path"]
    filename = ctx["filename"]

    # ── 1. Extract show from the 4th path element (1-indexed) ────────────
    # /Volumes/studio/projects/myshow/images/...
    #  [1]     [2]     [3]     [4]
    parts = path.split("/")
    if len(parts) < 5:
        return None

    root = "/".join(parts[:4])   # /Volumes/studio/projects
    show = parts[4]              # myshow

    # ── 2. Extract shot from the first dot-token of the filename ─────────
    # abc0100.comp.artist.016025.v08.1014.exr  →  abc0100
    shot = filename.split(".")[0]
    if not shot:
        return None

    # ── 3. Infer sequence by stripping trailing digits from the shot name ─
    # abc0100  →  abc
    sequence = re.sub(r"\d+$", "", shot)
    if not sequence:
        return None

    # ── 4. Build and validate the shot-specific config path ───────────────
    config_path = f"{root}/{show}/color/{sequence}/{shot}/config.ocio"

    if not os.path.isfile(config_path):
        print(f"[Tristimulator rules] Config not found, using default: {config_path}")
        return None

    print(f"[Tristimulator rules] {show} / {sequence} / {shot}  →  {config_path}")
    return {"ocioConfig": config_path,"display": "rec2100"}
