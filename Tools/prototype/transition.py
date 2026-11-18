"""Offline reference of the camera-to-camera transition on a synthetic dataset.

Program output before the take is the live (decoded) video of camera A, after the flight the
live video of camera B. During the flight (duration T) a virtual camera follows the FlyCamKit
path; the mix is video A -> render -> video B (plan.md Phase 4). The render is the static
scene (stand-in for the splat: the analytic scene without the person) plus the people from
the live frames of A and B:

    static      no people (Phase 4)
    billboard   flat billboards placed by floor contact (Phase 6)
    gaussians   per-pixel points from aligned monocular depth (Phase 7)

    uv run python -m prototype.transition out/synth --out out/prototype

writes transition_<mode>.mp4 and a JSON summary per mode.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from flycam_tools.clock import FrameStore
from flycam_tools.depth_align import AffineSmoother, anchor_check, fit_inverse_depth
from flycam_tools.geometry import Camera
from flycam_tools.placement import floor_contact
from flycam_tools.scene import Scene
from flycam_tools.session import frame_camera, read_frames, read_meta, read_video, write_video
from flycam_tools.transition import TransitionConfig, TransitionPath, people_weights

from .layers import Layer, billboard_layer, composite_people, feather, person_points, splat_layer

MODES = ("static", "billboard", "gaussians")


@dataclass
class Source:
    """One camera of the dataset with everything the Mac would have per frame."""

    name: str
    frames: list[dict]
    video: list[np.ndarray]            # decoded HEVC frames (uint8)
    masks: np.ndarray                  # person segmentation (stand-in for Vision)
    mono: np.ndarray                   # monocular relative inverse depth (stand-in for Depth Anything)
    clock_offset: float
    store: FrameStore = field(init=False)

    def __post_init__(self):
        self.store = FrameStore(capacity=1e9)
        for k, rec in enumerate(self.frames):
            self.store.insert(0, rec["t"] + self.clock_offset, k)

    @classmethod
    def load(cls, session: Path) -> "Source":
        gt = session / "ground_truth"
        return cls(session.name, read_frames(session), list(read_video(session / "video.mov")),
                   np.load(gt / "mask.npy"), np.load(gt / "mono_inv_depth.npy"), read_meta(session)["clock_offset"])

    def nearest(self, t_mac: float) -> int:
        return self.store.pair(t_mac)[0][1]

    def camera(self, k: int) -> Camera:
        return frame_camera(self.frames[k])

    def mac_time(self, k: int) -> float:
        return self.frames[k]["t"] + self.clock_offset


@dataclass
class FrameInfo:
    index: int
    t_mac: float
    u: float               # time fraction of the flight, <0 before, >1 after
    s: float               # eased progress
    w_video_a: float
    w_render: float
    w_video_b: float
    c2w: list[float] | None = None


class TransitionRenderer:
    def __init__(self, dataset: Path, a: str = "cam0", b: str = "cam1", config: TransitionConfig | None = None):
        self.dataset = Path(dataset)
        self.scene = Scene.load(self.dataset / "scene.json")
        self.floor_y = self.scene.floor_y
        self.A = Source.load(self.dataset / a)
        self.B = Source.load(self.dataset / b)
        self.cfg = config or TransitionConfig()
        self.smoothers = {a: AffineSmoother(0.5), b: AffineSmoother(0.5)}
        self.anchor_log: list[dict] = []

    # ------------------------------------------------------------ building blocks

    def static_render(self, cam: Camera) -> tuple[np.ndarray, np.ndarray]:
        rgb, depth, _ = self.scene.render(cam, None, person=False)
        return rgb, depth

    def matte(self, src: Source, k: int) -> np.ndarray:
        return feather(src.masks[k])

    def billboard(self, view: Camera, src: Source, k: int, anchor: np.ndarray) -> Layer:
        return billboard_layer(view, src.camera(k), src.video[k].astype(np.float32) / 255, self.matte(src, k),
                               anchor, self.floor_y)

    def anchor(self, src: Source, k: int) -> np.ndarray | None:
        fc = floor_contact(src.masks[k], src.camera(k), self.floor_y)
        return None if fc is None else fc.point

    def metric_depth(self, src: Source, k: int) -> np.ndarray:
        """Align monocular depth to the static splat depth rendered from the source pose (Phase 7)."""
        cam = src.camera(k)
        _, static_depth = self.static_render(cam)
        fit = fit_inverse_depth(src.mono[k], static_depth, ~src.masks[k])
        fit = self.smoothers[src.name].update(fit)
        z = fit.apply(src.mono[k])
        fc = floor_contact(src.masks[k], cam, self.floor_y)
        if fc is not None:
            person_z = float(np.median(z[src.masks[k]]))
            ok, scale = anchor_check(person_z, fc.depth)
            self.anchor_log.append({"source": src.name, "frame": k, "person_depth": person_z,
                                    "anchor_depth": fc.depth, "agrees": ok})
            if not ok:
                z = np.where(src.masks[k], z * scale, z)
        return z

    def gaussians(self, view: Camera, src: Source, k: int, factor: float) -> Layer:
        pts = person_points(src.camera(k), src.video[k].astype(np.float32) / 255, self.matte(src, k), self.metric_depth(src, k))
        return splat_layer(view, pts, factor)

    def render(self, view: Camera, mode: str, s: float, kA: int, kB: int) -> np.ndarray:
        """Reconstructed image for the virtual camera (no video mixed in), float32 in [0, 1]."""
        rgb, depth = self.static_render(view)
        if mode == "static":
            return rgb
        wA, wB = people_weights(s)
        layers = []
        if mode == "billboard":
            pa, pb = self.anchor(self.A, kA), self.anchor(self.B, kB)
            if pa is not None and pb is not None:
                shared = (1 - s) * pa + s * pb
                pa = pb = shared
            if pa is not None:
                layers.append((self.billboard(view, self.A, kA, pa), wA))
            if pb is not None:
                layers.append((self.billboard(view, self.B, kB, pb), wB))
        elif mode == "gaussians":
            factor = 1.0 + 0.4 * math.sin(math.pi * s)  # inflate slightly in mid-flight to close holes
            if wA > 0:
                layers.append((self.gaussians(view, self.A, kA, factor), wA))
            if wB > 0:
                layers.append((self.gaussians(view, self.B, kB, factor), wB))
        else:
            raise ValueError(mode)
        return composite_people(rgb, depth, layers, normalise=(mode == "gaussians"))

    # ------------------------------------------------------------------- sequence

    def run(self, mode: str, take_frame: int = 9, out_frames: int | None = None):
        """Output frames at camera A's frame times. The take starts at A's frame `take_frame`."""
        n = out_frames or len(self.A.frames)
        t_start = self.A.mac_time(take_frame)
        frames, infos = [], []
        for i in range(n):
            t = self.A.mac_time(min(i, len(self.A.frames) - 1))
            kA, kB = self.A.nearest(t), self.B.nearest(t)
            camA, camB = self.A.camera(kA), self.B.camera(kB)
            # Path rebuilt every frame from the latest poses (supports moving phones, Phase 8).
            path = TransitionPath(camA, camB, self.floor_y, self.cfg)
            elapsed = t - t_start
            # Timestamps are not meaningful below a microsecond: snap to the ends of the flight so
            # that rounding cannot turn the landing frame into a 99.99999 % mix.
            if abs(elapsed) < 1e-6:
                elapsed = 0.0
            elif abs(elapsed - self.cfg.duration) < 1e-6:
                elapsed = self.cfg.duration
            u = elapsed / self.cfg.duration
            w = path.blend_weights(elapsed)
            s = path.progress(elapsed)
            info = FrameInfo(i, t, u, s, w.video_a, w.render, w.video_b)
            vidA = self.A.video[kA].astype(np.float32) / 255
            vidB = self.B.video[kB].astype(np.float32) / 255
            if u <= 0:
                out = vidA
            elif u >= 1:
                out = vidB
            else:
                view = path.camera_at_progress(s)
                info.c2w = view.c2w.T.reshape(16).tolist()
                render = self.render(view, mode, s, kA, kB) if w.render > 0 else 0
                out = w.video_a * vidA + w.render * render + w.video_b * vidB
            frames.append(np.clip(np.round(np.asarray(out) * 255), 0, 255).astype(np.uint8))
            infos.append(info)
        return frames, infos


def write_outputs(dataset: Path, out: Path, modes=MODES, take_frame: int = 9, keep_frames: bool = False) -> dict:
    """Render every mode, write transition_<mode>.mp4 (H.264) and transition_<mode>.json.
    With keep_frames the returned summary also holds the uint8 frames and the renderer."""
    out.mkdir(parents=True, exist_ok=True)
    r = TransitionRenderer(dataset)
    fps = read_meta(dataset / "cam0")["video_format"]["fps"]
    summary = {}
    for mode in modes:
        frames, infos = r.run(mode, take_frame)
        mp4 = out / f"transition_{mode}.mp4"
        write_video(mp4, frames, fps, codec="h264", crf=12)
        summary[mode] = {"mp4": str(mp4), "take_frame": take_frame, "frames": [i.__dict__ for i in infos]}
        (out / f"transition_{mode}.json").write_text(json.dumps(summary[mode], indent=1) + "\n")
        if keep_frames:
            summary[mode]["_frames"] = frames
            summary[mode]["_infos"] = infos
    if keep_frames:
        summary["_renderer"] = r
    return summary


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dataset", type=Path, help="synthetic dataset folder (synth.py --out)")
    ap.add_argument("--out", type=Path, default=Path("out/prototype"))
    ap.add_argument("--mode", choices=MODES, action="append")
    ap.add_argument("--take-frame", type=int, default=9)
    a = ap.parse_args(argv)
    s = write_outputs(a.dataset, a.out, a.mode or MODES, a.take_frame)
    for mode, v in s.items():
        print(f"{mode}: {v['mp4']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
