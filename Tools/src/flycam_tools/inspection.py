"""Session inspection (plan.md Phase 1): trajectory plot, frame count vs. metadata lines,
monotonic timestamps, valid poses and intrinsics."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .geometry import c2w_from_list, rigidity_error
from .session import FRAMES, META, TRACKING_STATES, VIDEO, FramesFormatError, count_video_frames, image_path, parse_frames


@dataclass
class Report:
    session: str
    kind: str | None = None
    frame_lines: int = 0
    media_frames: int | None = None
    duration: float = 0.0
    mean_fps: float = 0.0
    path_length: float = 0.0
    total_rotation_deg: float = 0.0
    tracking_counts: dict = field(default_factory=dict)
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors

    def to_json(self) -> dict:
        d = dict(self.__dict__)
        d["ok"] = self.ok
        return d


def inspect_session(session: Path, plot: Path | None = None, rigid_tol: float = 1e-4) -> Report:
    session = Path(session)
    rep = Report(str(session))
    try:
        meta = json.loads((session / META).read_text())
        rep.kind = meta.get("kind")
    except FileNotFoundError:
        rep.errors.append("meta.json missing")
        meta = {}
    except json.JSONDecodeError as e:
        rep.errors.append(f"meta.json invalid: {e}")
        meta = {}
    try:
        frames = parse_frames((session / FRAMES).read_text())
    except FileNotFoundError:
        rep.errors.append("frames.jsonl missing")
        return rep
    except FramesFormatError as e:
        rep.errors.append(f"frames.jsonl: {e}")
        return rep
    rep.frame_lines = len(frames)
    if not frames:
        rep.errors.append("frames.jsonl is empty")
        return rep

    # Frame count against the media.
    if (session / VIDEO).exists():
        rep.media_frames = count_video_frames(session / VIDEO)
    elif (session / "images").exists():
        rep.media_frames = sum(1 for f in frames if image_path(session, f["i"]) is not None)
        n_files = len(list((session / "images").iterdir()))
        if n_files != len(frames):
            rep.errors.append(f"images/ has {n_files} files, frames.jsonl has {len(frames)} lines")
    else:
        rep.errors.append("no video.mov and no images/")
    if rep.media_frames is not None and rep.media_frames != len(frames):
        rep.errors.append(f"media has {rep.media_frames} frames, frames.jsonl has {len(frames)} lines")

    # Indices, timestamps, poses, intrinsics.
    ts = np.array([f["t"] for f in frames], float)
    for n, f in enumerate(frames):
        if f["i"] != n:
            rep.errors.append(f"line {n + 1}: index {f['i']}, expected {n}")
        if f["tracking"] not in TRACKING_STATES:
            rep.errors.append(f"line {n + 1}: unknown tracking state {f['tracking']!r}")
        if rigidity_error(c2w_from_list(f["c2w"])) > rigid_tol:
            rep.errors.append(f"line {n + 1}: c2w is not a rigid transform")
        if not (f["fx"] > 0 and f["fy"] > 0 and f["w"] > 0 and f["h"] > 0):
            rep.errors.append(f"line {n + 1}: invalid intrinsics")
        elif not (0 <= f["cx"] < f["w"] and 0 <= f["cy"] < f["h"]):
            rep.warnings.append(f"line {n + 1}: principal point outside the image")
    dt = np.diff(ts)
    bad = np.nonzero(dt <= 0)[0]
    for k in bad:
        rep.errors.append(f"line {k + 2}: timestamp {ts[k + 1]} not after {ts[k]}")
    if len(dt) and (dt > 0).all():
        med = float(np.median(dt))
        gaps = np.nonzero(dt > 2.5 * med)[0]
        if len(gaps):
            rep.warnings.append(f"{len(gaps)} gaps longer than 2.5 frame intervals (dropped frames?)")
    vf = meta.get("video_format") or {}
    for f in frames:
        if vf and (f["w"], f["h"]) != (vf.get("width"), vf.get("height")):
            rep.errors.append(f"frame size {f['w']}x{f['h']} differs from meta.json video_format")
            break

    rep.duration = float(ts[-1] - ts[0]) if len(ts) > 1 else 0.0
    rep.mean_fps = (len(ts) - 1) / rep.duration if rep.duration > 0 else 0.0
    pos = np.array([c2w_from_list(f["c2w"])[:3, 3] for f in frames])
    rep.path_length = float(np.linalg.norm(np.diff(pos, axis=0), axis=1).sum())
    rots = [c2w_from_list(f["c2w"])[:3, :3] for f in frames]
    ang = 0.0
    for r1, r2 in zip(rots, rots[1:]):
        c = (np.trace(r1.T @ r2) - 1) / 2
        ang += float(np.degrees(np.arccos(np.clip(c, -1, 1))))
    rep.total_rotation_deg = ang
    for f in frames:
        rep.tracking_counts[f["tracking"]] = rep.tracking_counts.get(f["tracking"], 0) + 1
    if plot is not None:
        plot_trajectory(frames, Path(plot), title=session.name)
    return rep


def plot_trajectory(frames: list[dict], out: Path, title: str = "") -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    c2w = np.array([c2w_from_list(f["c2w"]) for f in frames])
    pos = c2w[:, :3, 3]
    fwd = -c2w[:, :3, 2]
    t = np.array([f["t"] for f in frames]) - frames[0]["t"]
    fig, ax = plt.subplots(1, 2, figsize=(11, 4.5))
    ax[0].plot(pos[:, 0], pos[:, 2], "-", lw=1, color="0.4")
    sc = ax[0].scatter(pos[:, 0], pos[:, 2], c=t, s=8, cmap="viridis")
    step = max(1, len(frames) // 25)
    ax[0].quiver(pos[::step, 0], pos[::step, 2], fwd[::step, 0], fwd[::step, 2], angles="xy", scale=15, width=0.003)
    ax[0].set_xlabel("x (m)")
    ax[0].set_ylabel("z (m)")
    ax[0].set_title("top view (arrows: viewing direction)")
    ax[0].set_aspect("equal")
    ax[0].invert_yaxis()
    fig.colorbar(sc, ax=ax[0], label="time (s)")
    ax[1].plot(t, pos[:, 0], label="x")
    ax[1].plot(t, pos[:, 1], label="y (up)")
    ax[1].plot(t, pos[:, 2], label="z")
    ax[1].set_xlabel("time (s)")
    ax[1].set_ylabel("position (m)")
    ax[1].legend()
    fig.suptitle(title)
    fig.tight_layout()
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=100)
    plt.close(fig)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Check a session folder and plot its camera trajectory.")
    ap.add_argument("session", type=Path)
    ap.add_argument("--plot", type=Path, help="PNG path (default: <session>/trajectory.png)")
    ap.add_argument("--no-plot", action="store_true")
    ap.add_argument("--json", action="store_true", help="print the report as JSON")
    a = ap.parse_args(argv)
    plot = None if a.no_plot else (a.plot or a.session / "trajectory.png")
    rep = inspect_session(a.session, plot)
    if a.json:
        print(json.dumps(rep.to_json(), indent=2))
    else:
        print(f"{rep.session}: kind={rep.kind} lines={rep.frame_lines} media={rep.media_frames} "
              f"duration={rep.duration:.2f}s fps={rep.mean_fps:.2f} path={rep.path_length:.2f}m "
              f"rotation={rep.total_rotation_deg:.1f}deg tracking={rep.tracking_counts}")
        for w in rep.warnings:
            print("warning:", w)
        for e in rep.errors:
            print("error:", e)
        print("OK" if rep.ok else "FAILED")
    return 0 if rep.ok else 1
