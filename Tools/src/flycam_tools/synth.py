"""Synthetic dataset generator with ground truth.

Writes, under one output folder:

    scene.json          scene description (ground truth geometry)
    scan/               scan session of the empty room: images/, frames.jsonl, meta.json, points.ply
    cam0/, cam1/        tripod clip sessions recorded "synchronously" (same Mac time span)
    handheld/           clip session from a moving phone
    clock.json          true clock offsets (t_mac = t_phone + offset) per session

Each clip has video.mov (HEVC) and ground_truth/ (docs/protocol.md 2.6).
Run: uv run python synth.py --out out/synth
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .geometry import Camera, Intrinsics, axis_angle, look_at, unproject
from .scene import Scene, default_scene, to_uint8
from .session import make_frame, make_meta, write_frames, write_image, write_meta, write_ply, write_video

MAC_T0 = 100.0
TARGET = (0.0, -0.6, -3.4)
CAM0_EYE = (-1.8, -0.1, -0.5)
CAM1_EYE = (1.9, 0.0, -1.0)
DEFAULT_K = Intrinsics(330.0, 330.0, 191.7, 107.9, 384, 216)

# Phone uptime clocks: t_mac = t_phone + offset. Phases make the phones unsynchronised.
CLOCKS = {
    "cam0": {"offset": -4900.0, "phase": 0.0},
    "cam1": {"offset": -7900.25, "phase": 0.011},
    "handheld": {"offset": -12000.5, "phase": 0.023},
}


@dataclass
class SynthConfig:
    K: Intrinsics = DEFAULT_K
    fps: float = 30.0
    clip_seconds: float = 3.0
    scan_frames: int = 120
    seed: int = 0


def cam0_pose() -> np.ndarray:
    return look_at(CAM0_EYE, TARGET)


def cam1_pose() -> np.ndarray:
    return look_at(CAM1_EYE, TARGET)


def handheld_pose(u: float) -> np.ndarray:
    """Moving phone, u in [0, 1]: sideways walk with hand shake."""
    eye = np.array([0.2 + 0.6 * u, -0.2 + 0.03 * math.sin(7 * u), -0.3 - 0.2 * u])
    base = look_at(eye, TARGET)
    wobble = axis_angle([1, 0.3, 0], 0.02 * math.sin(11 * u)) @ axis_angle([0, 1, 0], 0.03 * math.sin(5 * u))
    base[:3, :3] = base[:3, :3] @ wobble
    return base


def scan_poses(n: int) -> list[np.ndarray]:
    """Two loops at different heights around the room centre, plus views near both tripods."""
    poses = []
    n_near = max(4, n // 10)
    n_loop = n - 2 * n_near
    centre = np.array([0.0, -3.0])
    for k in range(n_loop):
        u = k / n_loop
        loop = 0 if u < 0.5 else 1
        ang = 2 * math.pi * (2 * u) + 0.3 * loop
        r = 1.8 if loop == 0 else 1.5
        eye = [centre[0] + r * math.cos(ang), -0.35 if loop == 0 else 0.25, centre[1] + r * math.sin(ang)]
        # Look across the room, slightly off the centre so that walls are covered too.
        tgt = [centre[0] - 1.2 * math.cos(ang + 0.4), -0.8, centre[1] - 1.2 * math.sin(ang + 0.4)]
        poses.append(look_at(eye, tgt))
    for eye0 in (CAM0_EYE, CAM1_EYE):
        for k in range(n_near):
            off = np.array([0.15 * math.cos(k), 0.08 * math.sin(2 * k), 0.15 * math.sin(k)])
            poses.append(look_at(np.asarray(eye0) + off, np.asarray(TARGET) + [0.3 * math.sin(k), 0, 0]))
    return poses


def mono_depth(depth: np.ndarray, k: int, rng: np.random.Generator) -> tuple[np.ndarray, float, float]:
    """Simulated monocular relative inverse depth d with 1/z = a*d + b (plus noise, outliers)."""
    a = 0.05 * (1 + 0.15 * math.sin(0.7 * k))
    b = 0.02 + 0.01 * math.cos(0.3 * k)
    inv = 1.0 / depth
    d = (inv - b) / a
    h, w = depth.shape
    yy, xx = np.mgrid[0:h, 0:w] / max(h, w)
    smooth = 1 + 0.01 * np.sin(3 * xx + k) * np.cos(2 * yy)
    d = d * smooth * (1 + 0.005 * rng.standard_normal(d.shape))
    out = rng.random(d.shape) < 0.02
    d[out] = rng.uniform(d.min(), d.max(), out.sum())
    return d.astype(np.float32), a, b


def generate_clip(out: Path, name: str, scene: Scene, cfg: SynthConfig, pose_fn, camera_id: int, rng) -> None:
    clock = CLOCKS[name]
    n = int(round(cfg.clip_seconds * cfg.fps))
    sess = out / name
    gt = sess / "ground_truth"
    (gt / "frames").mkdir(parents=True, exist_ok=True)
    frames, imgs = [], []
    depth = np.empty((n, cfg.K.height, cfg.K.width), np.float32)
    static_depth = np.empty_like(depth)
    mono = np.empty_like(depth)
    mask = np.empty(depth.shape, bool)
    person_lines, affine = [], []
    for i in range(n):
        t_mac = MAC_T0 + clock["phase"] + i / cfg.fps
        t_phone = t_mac - clock["offset"]
        c2w = pose_fn(i / max(1, n - 1))
        cam = Camera(cfg.K, c2w)
        rgb, d, m = scene.render(cam, t_mac)
        _, ds, _ = scene.render(cam, t_mac, person=False)
        img = to_uint8(rgb)
        imgs.append(img)
        write_image(gt / "frames" / f"{i:05d}.png", img)
        depth[i], static_depth[i], mask[i] = d, ds, m
        mono[i], a, b = mono_depth(d, i, rng)
        affine.append({"i": i, "a": a, "b": b})
        frames.append(make_frame(i, t_phone, c2w, cfg.K, "normal", iso=100.0, shutter=1 / 120))
        foot = scene.foot(t_mac)
        person_lines.append(json.dumps({"i": i, "t": t_phone, "t_mac": t_mac, "foot": foot.tolist(),
                                        "radius": scene.person.radius, "height": scene.person.height}))
    write_video(sess / "video.mov", imgs, cfg.fps)
    write_frames(sess, frames)
    write_meta(sess, make_meta("clip", cfg.K.width, cfg.K.height, cfg.fps, camera_id=camera_id,
                               floor_y=scene.floor_y, clock_offset=clock["offset"],
                               camera_settings={"locked": True, "iso": 100.0, "shutter": 1 / 120,
                                                "wb_temperature": 5000.0, "wb_tint": 0.0}))
    np.save(gt / "depth.npy", depth)
    np.save(gt / "static_depth.npy", static_depth)
    np.save(gt / "mask.npy", mask)
    np.save(gt / "mono_inv_depth.npy", mono)
    (gt / "mono_affine.json").write_text(json.dumps(affine) + "\n")
    (gt / "person.jsonl").write_text("\n".join(person_lines) + "\n")


def generate_scan(out: Path, scene: Scene, cfg: SynthConfig, rng) -> None:
    sess = out / "scan"
    frames, pts, cols = [], [], []
    for i, c2w in enumerate(scan_poses(cfg.scan_frames)):
        cam = Camera(cfg.K, c2w)
        rgb, d, _ = scene.render(cam, None, person=False)
        img = to_uint8(rgb)
        write_image(sess / "images" / f"{i:05d}.png", img)
        frames.append(make_frame(i, 2000.0 + i * 0.5, c2w, cfg.K, "normal"))
        v = rng.integers(0, cfg.K.height, 150)
        u = rng.integers(0, cfg.K.width, 150)
        pts.append(unproject(u, v, d[v, u], cfg.K, c2w))
        cols.append(img[v, u])
    write_frames(sess, frames)
    write_meta(sess, make_meta("scan", cfg.K.width, cfg.K.height, 2.0, floor_y=scene.floor_y))
    write_ply(sess / "points.ply", np.concatenate(pts), np.concatenate(cols))


def generate(out: Path, cfg: SynthConfig | None = None, sessions=("scan", "cam0", "cam1", "handheld")) -> Path:
    cfg = cfg or SynthConfig()
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(cfg.seed)
    scene = default_scene(MAC_T0, MAC_T0 + cfg.clip_seconds)
    scene.save(out / "scene.json")
    (out / "clock.json").write_text(json.dumps(CLOCKS, indent=2) + "\n")
    if "scan" in sessions:
        generate_scan(out, scene, cfg, rng)
    if "cam0" in sessions:
        generate_clip(out, "cam0", scene, cfg, lambda u: cam0_pose(), 0, rng)
    if "cam1" in sessions:
        generate_clip(out, "cam1", scene, cfg, lambda u: cam1_pose(), 1, rng)
    if "handheld" in sessions:
        generate_clip(out, "handheld", scene, cfg, handheld_pose, 2, rng)
    return out


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--seconds", type=float, default=3.0)
    ap.add_argument("--fps", type=float, default=30.0)
    ap.add_argument("--scan-frames", type=int, default=120)
    a = ap.parse_args(argv)
    generate(a.out, SynthConfig(fps=a.fps, clip_seconds=a.seconds, scan_frames=a.scan_frames))
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
