"""Scan session -> Nerfstudio dataset (plan.md Phase 2, docs/protocol.md section 5).

Writes images/ (copied), transforms.json (per-frame intrinsics, c2w as four rows) and
points.ply (initial point cloud). The world frame is not re-oriented or re-scaled:
ARKit and Nerfstudio both use the OpenGL camera convention (-Z forward, +Y up).
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import numpy as np

from .geometry import c2w_from_list
from .session import image_path, read_frames, read_meta


def session_to_nerfstudio(session: Path, out: Path, skip_limited: bool = True) -> dict:
    session, out = Path(session), Path(out)
    meta = read_meta(session)
    if meta.get("kind") != "scan":
        raise ValueError(f"{session} is not a scan session (kind={meta.get('kind')})")
    (out / "images").mkdir(parents=True, exist_ok=True)
    frames = []
    skipped = 0
    for rec in read_frames(session):
        if skip_limited and rec["tracking"] != "normal":
            skipped += 1
            continue
        src = image_path(session, rec["i"])
        if src is None:
            raise FileNotFoundError(f"image for frame {rec['i']} missing")
        dst = out / "images" / src.name
        shutil.copyfile(src, dst)
        m = c2w_from_list(rec["c2w"])
        frames.append({
            "file_path": f"images/{src.name}",
            "transform_matrix": [[float(x) for x in row] for row in m],
            "fl_x": rec["fx"], "fl_y": rec["fy"], "cx": rec["cx"], "cy": rec["cy"],
            "w": rec["w"], "h": rec["h"],
            "k1": 0.0, "k2": 0.0, "p1": 0.0, "p2": 0.0,
        })
    tj = {"camera_model": "OPENCV", "frames": frames}
    if (session / "points.ply").exists():
        shutil.copyfile(session / "points.ply", out / "points.ply")
        tj["ply_file_path"] = "points.ply"
    if meta.get("floor_y") is not None:
        tj["flycam_floor_y"] = meta["floor_y"]  # extra key, ignored by trainers
    (out / "transforms.json").write_text(json.dumps(tj, indent=2) + "\n")
    tj["_skipped"] = skipped
    return tj


def transforms_c2w(transforms: dict) -> list[np.ndarray]:
    return [np.array(f["transform_matrix"], float) for f in transforms["frames"]]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--keep-limited", action="store_true", help="keep frames with limited tracking")
    a = ap.parse_args(argv)
    tj = session_to_nerfstudio(a.session, a.out, skip_limited=not a.keep_limited)
    print(f"wrote {a.out / 'transforms.json'}: {len(tj['frames'])} frames, {tj['_skipped']} skipped")
    return 0
