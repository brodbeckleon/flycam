import json
import shutil

import numpy as np
import pytest

from flycam_tools.geometry import c2w_from_list, project
from flycam_tools.inspection import inspect_session, main as inspect_main
from flycam_tools.nerfstudio import session_to_nerfstudio, transforms_c2w
from flycam_tools.session import read_frames, read_ply, write_frames
from flycam_tools.synth import handheld_pose


def test_inspect_good_sessions(synth, tmp_path):
    for name in ("scan", "cam0", "handheld"):
        rep = inspect_session(synth / name, plot=tmp_path / f"{name}.png")
        assert rep.ok, rep.errors
        assert rep.media_frames == rep.frame_lines
        assert (tmp_path / f"{name}.png").stat().st_size > 10_000
    rep = inspect_session(synth / "cam0")
    assert rep.mean_fps == pytest.approx(30, rel=1e-6)
    assert rep.path_length == pytest.approx(0, abs=1e-9)  # tripod


def test_inspect_trajectory_matches_ground_truth(synth):
    """Phase 1 'Done when' analogue: the reported trajectory matches how the phone moved."""
    rep = inspect_session(synth / "handheld")
    n = rep.frame_lines
    gt = np.array([handheld_pose(k / (n - 1))[:3, 3] for k in range(n)])
    gt_len = np.linalg.norm(np.diff(gt, axis=0), axis=1).sum()
    assert rep.path_length == pytest.approx(gt_len, rel=1e-6)
    assert rep.path_length > 0.3


def corrupt(synth, tmp_path, name, fn):
    dst = tmp_path / name
    shutil.copytree(synth / "cam0", dst, ignore=shutil.ignore_patterns("ground_truth"))
    frames = read_frames(dst)
    fn(frames)
    write_frames(dst, frames)
    return inspect_session(dst)


def test_inspect_detects_problems(synth, tmp_path):
    rep = corrupt(synth, tmp_path, "missing", lambda f: f.pop())
    assert not rep.ok and any("media has 60 frames" in e for e in rep.errors)

    def swap_t(f):
        f[10]["t"], f[11]["t"] = f[11]["t"], f[10]["t"]
    rep = corrupt(synth, tmp_path, "nonmono", swap_t)
    assert any("not after" in e for e in rep.errors)

    def bad_pose(f):
        f[3]["c2w"][0] = 1.5
    rep = corrupt(synth, tmp_path, "pose", bad_pose)
    assert any("rigid" in e for e in rep.errors)

    def bad_index(f):
        f[4]["i"] = 40
    rep = corrupt(synth, tmp_path, "index", bad_index)
    assert any("index 40" in e for e in rep.errors)

    def gap(f):
        for r in f[30:]:
            r["t"] += 0.5
    rep = corrupt(synth, tmp_path, "gap", gap)
    assert rep.ok and any("gaps" in w for w in rep.warnings)


def test_inspect_cli(synth, tmp_path, capsys):
    assert inspect_main([str(synth / "cam1"), "--plot", str(tmp_path / "p.png")]) == 0
    assert "OK" in capsys.readouterr().out


def test_nerfstudio_export(synth, tmp_path):
    out = tmp_path / "ns"
    tj = session_to_nerfstudio(synth / "scan", out)
    frames = read_frames(synth / "scan")
    assert len(tj["frames"]) == len(frames)
    on_disk = json.loads((out / "transforms.json").read_text())
    assert on_disk["camera_model"] == "OPENCV" and on_disk["ply_file_path"] == "points.ply"
    for rec, m in zip(frames, transforms_c2w(on_disk)):
        # transform_matrix is c2w as rows: equal to the column-major list read back as a matrix.
        np.testing.assert_array_equal(m, c2w_from_list(rec["c2w"]))
        np.testing.assert_array_equal(np.array(m).T.ravel(), rec["c2w"])
    f0 = on_disk["frames"][0]
    assert (out / f0["file_path"]).exists() and f0["fl_x"] == frames[0]["fx"] and f0["w"] == 384
    # The point cloud is in the same (unchanged) world frame: points are visible in the frames.
    xyz, _ = read_ply(out / "points.ply")
    from flycam_tools.geometry import Intrinsics

    K = Intrinsics(f0["fl_x"], f0["fl_y"], f0["cx"], f0["cy"], f0["w"], f0["h"])
    u, v, z = project(xyz, K, np.array(f0["transform_matrix"]))
    inside = (z > 0) & (u >= 0) & (u < 384) & (v >= 0) & (v < 216)
    assert inside.mean() > 0.05


def test_nerfstudio_skips_limited_and_rejects_clips(synth, tmp_path):
    scan = tmp_path / "scan"
    shutil.copytree(synth / "scan", scan)
    frames = read_frames(scan)
    frames[2]["tracking"] = "limited"
    write_frames(scan, frames)
    tj = session_to_nerfstudio(scan, tmp_path / "ns")
    assert len(tj["frames"]) == len(frames) - 1 and tj["_skipped"] == 1
    with pytest.raises(ValueError):
        session_to_nerfstudio(synth / "cam0", tmp_path / "ns2")
