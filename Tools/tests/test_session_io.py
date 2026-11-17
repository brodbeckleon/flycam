import json

import numpy as np
import pytest

from flycam_tools.geometry import Intrinsics, look_at
from flycam_tools.session import (
    FramesFormatError, count_video_frames, make_frame, make_meta, parse_frames, read_frames, read_meta, read_ply,
    read_pose_override, read_video, write_frames, write_meta, write_ply, write_pose_override, write_video,
)

K = Intrinsics(330, 330, 191.7, 107.9, 384, 216)


def test_meta_and_frames_round_trip(tmp_path):
    meta = make_meta("clip", 384, 216, 30, camera_id=1, floor_y=-1.3, clock_offset=12.5, created="2026-11-17T19:00:00Z")
    frames = [make_frame(i, 10 + i / 30, look_at([i * 0.1, 0, 0], [0, 0, -3]), K, "normal", iso=100) for i in range(5)]
    write_meta(tmp_path, meta)
    write_frames(tmp_path, frames)
    assert read_meta(tmp_path) == meta
    assert read_frames(tmp_path) == frames
    text = (tmp_path / "frames.jsonl").read_text()
    assert text.endswith("\n") and len(text.strip().split("\n")) == 5
    assert meta["floor_y"] == -1.3 and "camera_settings" in meta


def test_parse_frames_errors():
    with pytest.raises(FramesFormatError):
        parse_frames('{"i": 0}\n')
    with pytest.raises(FramesFormatError):
        parse_frames("not json\n")
    rec = make_frame(0, 1.0, np.eye(4), K)
    rec["c2w"] = rec["c2w"][:3]
    with pytest.raises(FramesFormatError):
        parse_frames(json.dumps(rec))
    good = make_frame(0, 1.0, np.eye(4), K)
    good["future_key"] = True
    assert parse_frames(json.dumps(good) + "\n\n")[0]["future_key"] is True


def test_ply_round_trip(tmp_path):
    rng = np.random.default_rng(0)
    xyz = rng.normal(size=(100, 3))
    rgb = rng.integers(0, 255, (100, 3)).astype(np.uint8)
    write_ply(tmp_path / "p.ply", xyz, rgb)
    x2, c2 = read_ply(tmp_path / "p.ply")
    np.testing.assert_allclose(x2, xyz.astype(np.float32), atol=0)
    np.testing.assert_array_equal(c2, rgb)
    assert (tmp_path / "p.ply").read_bytes().startswith(b"ply\nformat binary_little_endian 1.0\n")


def test_video_round_trip(tmp_path):
    rng = np.random.default_rng(1)
    base = (rng.random((64, 96, 3)) * 255).astype(np.uint8)
    base = np.repeat(np.repeat(base[::4, ::4], 4, 0), 4, 1)  # blocky, compressible
    frames = [np.roll(base, k, axis=1) for k in range(12)]
    assert write_video(tmp_path / "v.mov", frames, 30) == 12
    assert count_video_frames(tmp_path / "v.mov") == 12
    dec = list(read_video(tmp_path / "v.mov"))
    assert len(dec) == 12
    # Decode order = display order (no B-frames): frame k matches source k best.
    for k in (0, 5, 11):
        errs = [np.abs(dec[k].astype(int) - f.astype(int)).mean() for f in frames]
        assert int(np.argmin(errs)) == k


def test_hevc_has_no_bframes_and_param_sets_at_keyframes(tmp_path):
    import av

    frames = [np.full((64, 64, 3), 3 * k, np.uint8) for k in range(70)]
    write_video(tmp_path / "v.mov", frames, 30)
    with av.open(str(tmp_path / "v.mov")) as c:
        st = c.streams.video[0]
        assert st.codec_context.name == "hevc"
        pk = [p for p in c.demux(st) if p.size]
        pts = [p.pts for p in pk]
        assert pts == sorted(pts), "decode order must equal presentation order"
        keys = [i for i, p in enumerate(pk) if p.is_keyframe]
        assert keys[:3] == [0, 30, 60]


def test_pose_override(tmp_path):
    assert read_pose_override(tmp_path) is None
    m = look_at([1, 2, 3], [0, 0, 0])
    write_pose_override(tmp_path, m, inliers=5)
    np.testing.assert_allclose(read_pose_override(tmp_path), m)
