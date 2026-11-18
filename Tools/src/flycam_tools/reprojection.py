"""Reprojection check (plan.md Phase 2): feature-match photo and splat render for a set of
frames and report the median pixel offset.

Renders come from the DirectorApp debug view (render of the splat from the stored pose and
intrinsics, same resolution as the photo), named like the photos: renders/<i:05d>.png.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .features import match_features, robust_displacements
from .session import image_path, read_frames, read_image


@dataclass
class FrameOffset:
    frame: int
    matches: int
    inliers: int
    median_px: float
    mean_vector: tuple[float, float]


@dataclass
class ReprojectionReport:
    frames: list[FrameOffset] = field(default_factory=list)

    @property
    def median_px(self) -> float:
        vals = [f.median_px for f in self.frames if f.inliers > 0]
        return float(np.median(vals)) if vals else float("nan")

    def to_json(self) -> dict:
        return {"median_px": self.median_px, "frames": [f.__dict__ for f in self.frames]}


def frame_offset(photo: np.ndarray, render: np.ndarray, frame: int = 0, min_matches: int = 8) -> FrameOffset:
    pa, pb = match_features(photo, render)
    if len(pa) < min_matches:
        return FrameOffset(frame, len(pa), 0, float("nan"), (float("nan"), float("nan")))
    inl = robust_displacements(pa, pb)
    d = pb[inl] - pa[inl]
    return FrameOffset(frame, len(pa), int(inl.sum()), float(np.median(np.linalg.norm(d, axis=1))),
                       (float(d[:, 0].mean()), float(d[:, 1].mean())))


def select_frames(n_total: int, n: int) -> list[int]:
    if n >= n_total:
        return list(range(n_total))
    return sorted({int(round(x)) for x in np.linspace(0, n_total - 1, n)})


def reprojection_check(session: Path, renders: Path, n_frames: int = 20) -> ReprojectionReport:
    frames = read_frames(session)
    rep = ReprojectionReport()
    for k in select_frames(len(frames), n_frames):
        i = frames[k]["i"]
        photo_p = image_path(session, i)
        render_p = next((p for p in (Path(renders) / f"{i:05d}.png", Path(renders) / f"{i:05d}.jpg") if p.exists()), None)
        if photo_p is None or render_p is None:
            continue
        rep.frames.append(frame_offset(read_image(photo_p), read_image(render_p), i))
    return rep


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session", type=Path, help="scan session with images/")
    ap.add_argument("renders", type=Path, help="folder with <i:05d>.png renders from the stored poses")
    ap.add_argument("--frames", type=int, default=20)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    rep = reprojection_check(a.session, a.renders, a.frames)
    if a.json:
        print(json.dumps(rep.to_json(), indent=2))
    else:
        for f in rep.frames:
            print(f"frame {f.frame:5d}: {f.inliers:4d}/{f.matches:4d} matches, median offset {f.median_px:.2f} px")
        print(f"median offset over {len(rep.frames)} frames: {rep.median_px:.2f} px")
    return 0
