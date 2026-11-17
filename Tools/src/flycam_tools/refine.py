"""Pose refinement for fixed phones (plan.md Phase 3).

Inputs: the real frame, the splat render (colour and depth) from the phone's reported pose,
intrinsics and the reported pose. Match features between real frame and render, lift the
render keypoints to 3D with the render depth, solve PnP with RANSAC against the real-frame
keypoints. The result is written to pose_override.json.

Render depth from the DirectorApp: raw little-endian float32, row-major H x W, depth along the
viewing axis in metres, 0 or non-finite where the splat has no content (`.f32`), or `.npy`.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

from .features import match_features
from .geometry import Intrinsics, c2w_to_opencv_w2c, opencv_w2c_to_c2w, rigid, rotation_angle, unproject
from .session import frame_camera, image_path, read_frames, read_image, read_video, write_pose_override


@dataclass
class RefineResult:
    c2w: np.ndarray
    matches: int
    lifted: int
    inliers: int
    median_reprojection_px: float
    rotation_change_deg: float
    translation_change_m: float


def load_depth(path: Path, width: int, height: int) -> np.ndarray:
    path = Path(path)
    if path.suffix == ".npy":
        d = np.load(path).astype(np.float32)
    else:
        d = np.fromfile(path, dtype="<f4")
        if d.size != width * height:
            raise ValueError(f"{path}: expected {width}x{height} float32 values, got {d.size}")
        d = d.reshape(height, width)
    if d.shape != (height, width):
        raise ValueError(f"depth is {d.shape}, expected {(height, width)}")
    return d


def save_depth_f32(path: Path, depth: np.ndarray) -> None:
    np.ascontiguousarray(depth, dtype="<f4").tofile(path)


def _sample_depth(depth: np.ndarray, pts: np.ndarray, max_rel_range: float = 0.03):
    """Nearest-pixel depth at keypoints; rejects missing depth and depth discontinuities."""
    h, w = depth.shape
    u = np.clip(np.round(pts[:, 0]).astype(int), 0, w - 1)
    v = np.clip(np.round(pts[:, 1]).astype(int), 0, h - 1)
    z = depth[v, u].astype(np.float64)
    ok = np.isfinite(z) & (z > 0)
    for du in (-1, 0, 1):
        for dv in (-1, 0, 1):
            zn = depth[np.clip(v + dv, 0, h - 1), np.clip(u + du, 0, w - 1)]
            ok &= np.isfinite(zn) & (np.abs(zn - z) <= max_rel_range * z)
    return z, ok


def refine_pose(real: np.ndarray, render: np.ndarray, render_depth: np.ndarray, K: Intrinsics,
                c2w_reported: np.ndarray, reproj_px: float = 1.0, min_inliers: int = 12) -> RefineResult:
    pr, pd = match_features(real, render)
    z, ok = _sample_depth(render_depth, pd)
    if ok.sum() < min_inliers:
        raise RuntimeError(f"only {ok.sum()} usable matches with depth (of {len(pr)})")
    obj = unproject(pd[ok, 0], pd[ok, 1], z[ok], K, c2w_reported)
    img = pr[ok]
    w2c0 = c2w_to_opencv_w2c(c2w_reported)
    rvec0, _ = cv2.Rodrigues(w2c0[:3, :3])
    tvec0 = w2c0[:3, 3].reshape(3, 1)
    found, rvec, tvec, inl = cv2.solvePnPRansac(obj, img, K.K, None, rvec0.copy(), tvec0.copy(), useExtrinsicGuess=True,
                                                iterationsCount=2000, reprojectionError=reproj_px, confidence=0.999,
                                                flags=cv2.SOLVEPNP_ITERATIVE)
    if not found or inl is None or len(inl) < min_inliers:
        raise RuntimeError("PnP failed")
    inl = inl[:, 0]
    rvec, tvec = cv2.solvePnPRefineLM(obj[inl], img[inl], K.K, None, rvec, tvec)
    R, _ = cv2.Rodrigues(rvec)
    c2w = opencv_w2c_to_c2w(rigid(R, tvec[:, 0]))
    proj, _ = cv2.projectPoints(obj[inl], rvec, tvec, K.K, None)
    err = np.linalg.norm(proj[:, 0, :] - img[inl], axis=1)
    return RefineResult(c2w, len(pr), int(ok.sum()), len(inl), float(np.median(err)),
                        float(np.degrees(rotation_angle(c2w_reported[:3, :3], c2w[:3, :3]))),
                        float(np.linalg.norm(c2w[:3, 3] - c2w_reported[:3, 3])))


def _real_frame(session: Path, i: int) -> np.ndarray:
    p = image_path(session, i)
    if p is not None:
        return read_image(p)
    for k, img in enumerate(read_video(session / "video.mov")):
        if k == i:
            return img
    raise IndexError(f"frame {i} not in video")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session", type=Path, help="clip session of the fixed phone")
    ap.add_argument("--frame", type=int, default=0, help="frame index the render was made for")
    ap.add_argument("--render-color", type=Path, required=True)
    ap.add_argument("--render-depth", type=Path, required=True)
    ap.add_argument("--dry-run", action="store_true", help="do not write pose_override.json")
    a = ap.parse_args(argv)
    rec = read_frames(a.session)[a.frame]
    cam = frame_camera(rec)
    render = read_image(a.render_color)
    depth = load_depth(a.render_depth, cam.K.width, cam.K.height)
    res = refine_pose(_real_frame(a.session, a.frame), render, depth, cam.K, cam.c2w)
    print(json.dumps({k: v for k, v in res.__dict__.items() if k != "c2w"}, indent=2))
    if not a.dry_run:
        write_pose_override(a.session, res.c2w, frame_index=a.frame, inliers=res.inliers,
                            median_reprojection_px=res.median_reprojection_px)
        print(f"wrote {a.session / 'pose_override.json'}")
    return 0
