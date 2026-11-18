"""Session folders (docs/protocol.md section 2): meta.json, frames.jsonl, video, images, points.ply."""

from __future__ import annotations

import datetime as _dt
import json
from fractions import Fraction
from pathlib import Path
from typing import Iterable, Iterator

import av
import cv2
import numpy as np

from .geometry import Camera, Intrinsics, c2w_from_list, c2w_to_list

META = "meta.json"
FRAMES = "frames.jsonl"
VIDEO = "video.mov"
POSE_OVERRIDE = "pose_override.json"
TRACKING_STATES = ("normal", "limited", "notAvailable")


def utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def make_meta(kind: str, width: int, height: int, fps: float, *, device_model="Synthetic", os_version="0",
              camera_id=None, floor_y=None, clock_offset=None, camera_settings=None, created=None) -> dict:
    return {
        "format_version": 1,
        "kind": kind,
        "device_model": device_model,
        "os_version": os_version,
        "camera_id": camera_id,
        "video_format": {"width": width, "height": height, "fps": fps},
        "camera_settings": camera_settings
        or {"locked": True, "iso": None, "shutter": None, "wb_temperature": None, "wb_tint": None},
        "floor_y": floor_y,
        "clock_offset": clock_offset,
        "created": created or utc_now(),
    }


def make_frame(i: int, t: float, c2w: np.ndarray, K: Intrinsics, tracking: str = "normal", iso=None, shutter=None) -> dict:
    rec = {"i": i, "t": float(t), "c2w": c2w_to_list(c2w), "fx": float(K.fx), "fy": float(K.fy),
           "cx": float(K.cx), "cy": float(K.cy), "w": int(K.width), "h": int(K.height), "tracking": tracking}
    if iso is not None:
        rec["iso"] = float(iso)
    if shutter is not None:
        rec["shutter"] = float(shutter)
    return rec


def frame_camera(rec: dict) -> Camera:
    return Camera(Intrinsics(rec["fx"], rec["fy"], rec["cx"], rec["cy"], rec["w"], rec["h"]), c2w_from_list(rec["c2w"]))


def write_meta(session: Path, meta: dict) -> None:
    Path(session).mkdir(parents=True, exist_ok=True)
    (Path(session) / META).write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")


def read_meta(session: Path) -> dict:
    return json.loads((Path(session) / META).read_text())


def encode_frames(frames: Iterable[dict]) -> str:
    return "".join(json.dumps(f, sort_keys=True, separators=(",", ":")) + "\n" for f in frames)


def write_frames(session: Path, frames: Iterable[dict]) -> None:
    Path(session).mkdir(parents=True, exist_ok=True)
    (Path(session) / FRAMES).write_text(encode_frames(frames))


class FramesFormatError(ValueError):
    pass


def parse_frames(text: str) -> list[dict]:
    out = []
    for n, line in enumerate(text.split("\n"), start=1):
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError as e:
            raise FramesFormatError(f"line {n}: {e}") from e
        for key in ("i", "t", "c2w", "fx", "fy", "cx", "cy", "w", "h", "tracking"):
            if key not in rec:
                raise FramesFormatError(f"line {n}: missing {key}")
        if len(rec["c2w"]) != 16:
            raise FramesFormatError(f"line {n}: c2w needs 16 values")
        out.append(rec)
    return out


def read_frames(session: Path) -> list[dict]:
    return parse_frames((Path(session) / FRAMES).read_text())


def write_pose_override(session: Path, c2w: np.ndarray, **extra) -> dict:
    d = {"format_version": 1, "c2w": c2w_to_list(c2w), "source": "refine_pose", "created": utc_now()}
    d.update(extra)
    (Path(session) / POSE_OVERRIDE).write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
    return d


def read_pose_override(session: Path) -> np.ndarray | None:
    p = Path(session) / POSE_OVERRIDE
    if not p.exists():
        return None
    return c2w_from_list(json.loads(p.read_text())["c2w"])


# ------------------------------------------------------------------------------ video


def write_video(path: Path, frames: Iterable[np.ndarray], fps: float, *, codec: str = "hevc", crf: int = 18,
                keyint: int | None = None) -> int:
    """Encode RGB uint8 frames. HEVC: no B-frames, parameter sets repeated at every keyframe
    (docs/protocol.md 2.3). Returns the number of frames written."""
    keyint = keyint or max(1, round(fps))
    rate = Fraction(fps).limit_denominator(1001)
    n = 0
    with av.open(str(path), "w") as out:
        if codec == "hevc":
            st = out.add_stream("libx265", rate=rate)
            st.options = {"crf": str(crf), "preset": "fast",
                          "x265-params": f"bframes=0:keyint={keyint}:min-keyint={keyint}:scenecut=0:repeat-headers=1:log-level=error"}
            st.codec_tag = "hvc1"
        elif codec == "h264":
            st = out.add_stream("libx264", rate=rate)
            st.options = {"crf": str(crf), "preset": "fast", "bf": "0", "g": str(keyint)}
        else:
            raise ValueError(codec)
        st.pix_fmt = "yuv420p"
        for img in frames:
            if n == 0:
                st.height, st.width = img.shape[:2]
            vf = av.VideoFrame.from_ndarray(np.ascontiguousarray(img, dtype=np.uint8), format="rgb24")
            for pkt in st.encode(vf):
                out.mux(pkt)
            n += 1
        for pkt in st.encode():
            out.mux(pkt)
    return n


def read_video(path: Path) -> Iterator[np.ndarray]:
    with av.open(str(path)) as cont:
        for f in cont.decode(video=0):
            yield f.to_ndarray(format="rgb24")


def count_video_frames(path: Path) -> int:
    """Number of video packets (one per frame, no B-frames), without decoding."""
    with av.open(str(path)) as cont:
        return sum(1 for p in cont.demux(video=0) if p.size > 0)


# ----------------------------------------------------------------------------- images


def image_path(session: Path, i: int) -> Path | None:
    for ext in (".jpg", ".png", ".jpeg"):
        p = Path(session) / "images" / f"{i:05d}{ext}"
        if p.exists():
            return p
    return None


def write_image(path: Path, rgb: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(path), cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)):
        raise OSError(f"could not write {path}")


def read_image(path: Path) -> np.ndarray:
    bgr = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if bgr is None:
        raise OSError(f"could not read {path}")
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)


# -------------------------------------------------------------------------------- ply


def write_ply(path: Path, xyz: np.ndarray, rgb: np.ndarray) -> None:
    """Binary little-endian PLY with float xyz and uchar rgb (docs/protocol.md 2.4)."""
    xyz = np.asarray(xyz, np.float32)
    rgb = np.asarray(rgb, np.uint8)
    header = (
        "ply\nformat binary_little_endian 1.0\n"
        f"element vertex {len(xyz)}\n"
        "property float x\nproperty float y\nproperty float z\n"
        "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
    )
    rec = np.empty(len(xyz), dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("r", "u1"), ("g", "u1"), ("b", "u1")])
    rec["x"], rec["y"], rec["z"] = xyz[:, 0], xyz[:, 1], xyz[:, 2]
    rec["r"], rec["g"], rec["b"] = rgb[:, 0], rgb[:, 1], rgb[:, 2]
    with open(path, "wb") as f:
        f.write(header.encode("ascii"))
        f.write(rec.tobytes())


def read_ply(path: Path) -> tuple[np.ndarray, np.ndarray]:
    data = Path(path).read_bytes()
    end = data.index(b"end_header\n") + len(b"end_header\n")
    header = data[:end].decode("ascii").split("\n")
    if "format binary_little_endian 1.0" not in header:
        raise ValueError("only binary little-endian PLY is supported")
    n = next(int(line.split()[2]) for line in header if line.startswith("element vertex"))
    rec = np.frombuffer(data, dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("r", "u1"), ("g", "u1"), ("b", "u1")],
                        count=n, offset=end)
    xyz = np.stack([rec["x"], rec["y"], rec["z"]], axis=1).astype(np.float64)
    rgb = np.stack([rec["r"], rec["g"], rec["b"]], axis=1)
    return xyz, rgb


