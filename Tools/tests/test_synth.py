"""The synthetic data is the ground truth for every other test, so check it first."""

import json

import numpy as np
import pytest

from flycam_tools.geometry import project, unproject
from flycam_tools.scene import Scene
from flycam_tools.session import frame_camera, read_frames, read_meta, read_video
from tests.conftest import psnr


def test_dataset_layout(synth):
    for name in ("scan", "cam0", "cam1", "handheld"):
        meta = read_meta(synth / name)
        assert meta["floor_y"] == -1.3
        assert len(read_frames(synth / name)) > 0
    assert read_meta(synth / "scan")["kind"] == "scan"
    assert (synth / "scan" / "points.ply").exists()
    assert len(read_frames(synth / "cam0")) == 60


def test_depth_unprojects_onto_floor(synth):
    """Pixels whose depth hits the floor unproject to y = floor_y."""
    rec = read_frames(synth / "cam0")[0]
    cam = frame_camera(rec)
    depth = np.load(synth / "cam0" / "ground_truth" / "static_depth.npy")[0]
    v, u = np.mgrid[180:216, 0:384]
    p = unproject(u.ravel(), v.ravel(), depth[v, u].ravel(), cam.K, cam.c2w)
    on_floor = np.abs(p[:, 1] + 1.3) < 1e-3
    assert on_floor.mean() > 0.6  # bottom rows mostly floor
    assert np.all(p[:, 1] >= -1.3 - 1e-3)


def test_person_ground_truth_consistent(synth):
    gt = synth / "cam0" / "ground_truth"
    mask = np.load(gt / "mask.npy")
    depth = np.load(gt / "depth.npy")
    sdepth = np.load(gt / "static_depth.npy")
    people = [json.loads(l) for l in (gt / "person.jsonl").read_text().splitlines()]
    frames = read_frames(synth / "cam0")
    assert mask[0].sum() > 500
    # Person is in front of the static scene wherever the mask is set, identical elsewhere.
    assert np.all(depth[mask] <= sdepth[mask] + 1e-5)
    np.testing.assert_array_equal(depth[~mask], sdepth[~mask])
    # Foot point projects close to the bottom of the mask.
    for k in (0, 30, 59):
        cam = frame_camera(frames[k])
        u, v, z = project(np.array(people[k]["foot"]), cam.K, cam.c2w)
        vs, us = np.nonzero(mask[k])
        assert abs(v - vs.max()) < 15 and us.min() <= u <= us.max()
    # Person moves in Mac time: t_mac = t_phone + offset.
    off = read_meta(synth / "cam0")["clock_offset"]
    assert people[10]["t_mac"] == pytest.approx(frames[10]["t"] + off, abs=1e-9)


def test_frames_follow_scene(synth):
    scene = Scene.load(synth / "scene.json")
    frames = read_frames(synth / "cam1")
    off = read_meta(synth / "cam1")["clock_offset"]
    rgb, _, _ = scene.render(frame_camera(frames[7]), frames[7]["t"] + off)
    video = list(read_video(synth / "cam1" / "video.mov"))
    assert psnr(video[7], np.round(rgb * 255)) > 30  # HEVC at crf 18 on noisy texture: ~34 dB


def test_mono_depth_affine(synth):
    gt = synth / "cam0" / "ground_truth"
    mono = np.load(gt / "mono_inv_depth.npy")
    depth = np.load(gt / "depth.npy")
    aff = json.loads((gt / "mono_affine.json").read_text())
    a, b = aff[5]["a"], aff[5]["b"]
    rel = np.abs((a * mono[5] + b) - 1 / depth[5]) / (1 / depth[5])
    assert np.median(rel) < 0.02  # noise, smooth error; outliers are 2 %


def test_cameras_are_unsynchronised(synth):
    t0 = read_frames(synth / "cam0")[0]["t"] + read_meta(synth / "cam0")["clock_offset"]
    t1 = read_frames(synth / "cam1")[0]["t"] + read_meta(synth / "cam1")["clock_offset"]
    assert abs((t1 - t0) - 0.011) < 1e-9
