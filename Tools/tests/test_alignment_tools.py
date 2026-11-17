"""reprojection_check, refine_pose, depth alignment, floor-contact placement against ground truth."""

import json
import math

import numpy as np
import pytest

from flycam_tools.depth_align import AffineSmoother, anchor_check, fit_inverse_depth
from flycam_tools.geometry import Camera, axis_angle, rotation_angle
from flycam_tools.placement import associate, floor_contact, mask_bottom_centre
from flycam_tools.refine import load_depth, main as refine_main, refine_pose, save_depth_f32
from flycam_tools.reprojection import frame_offset, reprojection_check
from flycam_tools.scene import Scene, to_uint8
from flycam_tools.session import frame_camera, read_frames, read_meta, read_pose_override, read_video, write_image


def perturb(c2w, deg, axis, shift):
    m = c2w.copy()
    m[:3, :3] = m[:3, :3] @ axis_angle(axis, math.radians(deg))
    m[:3, 3] = m[:3, 3] + np.asarray(shift)
    return m


def write_renders(synth, out, frames, pose_fn):
    scene = Scene.load(synth / "scene.json")
    out.mkdir(parents=True, exist_ok=True)
    for rec in frames:
        cam = frame_camera(rec)
        rgb, _, _ = scene.render(cam.with_pose(pose_fn(cam.c2w)), None, person=False)
        write_image(out / f"{rec['i']:05d}.png", to_uint8(rgb))


# ------------------------------------------------------------------ reprojection check


def test_reprojection_exact_poses(synth, tmp_path):
    frames = read_frames(synth / "scan")[::6]
    write_renders(synth, tmp_path / "r", frames, lambda m: m)
    rep = reprojection_check(synth / "scan", tmp_path / "r", n_frames=60)
    assert len(rep.frames) == len(frames)
    assert all(f.inliers >= 20 for f in rep.frames)
    assert rep.median_px < 0.3


def test_reprojection_detects_rotation_error(synth, tmp_path):
    """A 0.5 degree yaw error shifts the image by about fx * tan(0.5 deg) = 2.9 px."""
    frames = read_frames(synth / "scan")[::6]
    write_renders(synth, tmp_path / "r", frames, lambda m: perturb(m, 0.5, [0, 1, 0], [0, 0, 0]))
    rep = reprojection_check(synth / "scan", tmp_path / "r", n_frames=60)
    expected = 330 * math.tan(math.radians(0.5))
    assert rep.median_px == pytest.approx(expected, rel=0.2)
    # Rotating the camera to the left moves image content to the right (+u) in the render.
    assert all(f.mean_vector[0] > 0 for f in rep.frames)


# ----------------------------------------------------------------------- pose refinement


@pytest.mark.parametrize("name", ["cam0", "cam1"])
def test_refine_pose_recovers_true_pose(synth, name):
    """Real frame: decoded HEVC video frame with the person in it (true pose). Reported pose:
    off by 0.6 degrees and 3 cm. Render colour and depth from the reported pose."""
    rec = read_frames(synth / name)[0]
    true_cam = frame_camera(rec)
    reported = perturb(true_cam.c2w, 0.6, [0.3, 1, 0.2], [0.02, -0.01, 0.02])
    real = next(iter(read_video(synth / name / "video.mov")))
    scene = Scene.load(synth / "scene.json")
    rgb, depth, _ = scene.render(true_cam.with_pose(reported), None, person=False)
    res = refine_pose(real, to_uint8(rgb), depth, true_cam.K, reported)
    rot_err = math.degrees(rotation_angle(res.c2w[:3, :3], true_cam.c2w[:3, :3]))
    pos_err = float(np.linalg.norm(res.c2w[:3, 3] - true_cam.c2w[:3, 3]))
    assert rot_err < 0.05, rot_err
    assert pos_err < 0.01, pos_err
    assert res.inliers >= 50
    assert res.median_reprojection_px < 0.7
    # Pixel error at 4 m that the refined pose would leave (Phase 3 target: about 3 px at 1080p).
    assert rot_err * math.pi / 180 * 330 < 0.3


def test_refine_pose_cli_writes_override(synth, tmp_path):
    import shutil

    sess = tmp_path / "cam0"
    shutil.copytree(synth / "cam0", sess)
    rec = read_frames(sess)[0]
    cam = frame_camera(rec)
    scene = Scene.load(synth / "scene.json")
    reported = cam.c2w  # the stored (reported) pose; ground truth here, so refinement must not move it
    rgb, depth, _ = scene.render(cam, None, person=False)
    write_image(tmp_path / "rc.png", to_uint8(rgb))
    save_depth_f32(tmp_path / "rd.f32", depth)
    np.testing.assert_array_equal(load_depth(tmp_path / "rd.f32", 384, 216), depth)
    assert refine_main([str(sess), "--frame", "0", "--render-color", str(tmp_path / "rc.png"),
                        "--render-depth", str(tmp_path / "rd.f32")]) == 0
    m = read_pose_override(sess)
    assert math.degrees(rotation_angle(m[:3, :3], reported[:3, :3])) < 0.05
    assert np.linalg.norm(m[:3, 3] - reported[:3, 3]) < 0.01
    d = json.loads((sess / "pose_override.json").read_text())
    assert d["frame_index"] == 0 and d["inliers"] > 0


def test_refine_rejects_bad_depth_file(tmp_path):
    np.zeros(10, "<f4").tofile(tmp_path / "x.f32")
    with pytest.raises(ValueError):
        load_depth(tmp_path / "x.f32", 384, 216)


# ----------------------------------------------------------------------- depth alignment


def test_depth_alignment_recovers_affine(synth):
    gt = synth / "cam0" / "ground_truth"
    mono = np.load(gt / "mono_inv_depth.npy")
    sdepth = np.load(gt / "static_depth.npy")
    depth = np.load(gt / "depth.npy")
    mask = np.load(gt / "mask.npy")
    aff = json.loads((gt / "mono_affine.json").read_text())
    for k in (0, 17, 45):
        fit = fit_inverse_depth(mono[k], sdepth[k], ~mask[k])
        assert fit.a == pytest.approx(aff[k]["a"], rel=0.02)
        assert fit.b == pytest.approx(aff[k]["b"], abs=0.02 * aff[k]["b"] + 2e-3)
        assert fit.inliers > 0.8 * fit.total
        # Metric depth of the person (never used in the fit) within 3 % (median).
        z = fit.apply(mono[k])[mask[k]]
        rel = np.abs(z - depth[k][mask[k]]) / depth[k][mask[k]]
        assert np.median(rel) < 0.03


def test_depth_alignment_robust_to_outliers():
    rng = np.random.default_rng(0)
    z = rng.uniform(1, 8, 5000)
    a, b = 0.07, 0.03
    d = (1 / z - b) / a
    d[:1500] = rng.uniform(d.min(), d.max(), 1500)  # 30 % outliers
    fit = fit_inverse_depth(d, z)
    assert fit.a == pytest.approx(a, rel=1e-6) and fit.b == pytest.approx(b, rel=1e-6)


def test_affine_smoother_reduces_jitter():
    rng = np.random.default_rng(1)
    from flycam_tools.depth_align import AffineFit

    raw = [AffineFit(0.05 * (1 + 0.05 * rng.standard_normal()), 0.02, 1, 1) for _ in range(200)]
    sm = AffineSmoother(0.2)
    smooth = [sm.update(f).a for f in raw]
    assert np.std(np.diff(smooth)) < 0.5 * np.std(np.diff([f.a for f in raw]))
    assert np.mean(smooth[50:]) == pytest.approx(0.05, rel=0.02)


def test_anchor_check():
    assert anchor_check(3.0, 3.2) == (True, 1.0)
    ok, scale = anchor_check(4.0, 3.0)
    assert not ok and scale == pytest.approx(0.75)


# --------------------------------------------------------------------------- placement


def test_floor_contact_against_ground_truth(synth):
    floor = read_meta(synth / "cam0")["floor_y"]
    for name in ("cam0", "cam1", "handheld"):
        gt = synth / name / "ground_truth"
        mask = np.load(gt / "mask.npy")
        people = [json.loads(l) for l in (gt / "person.jsonl").read_text().splitlines()]
        frames = read_frames(synth / name)
        for k in range(0, len(frames), 5):
            cam = frame_camera(frames[k])
            fc = floor_contact(mask[k], cam, floor)
            assert fc is not None
            foot = np.array(people[k]["foot"])
            r = people[k]["radius"]
            assert fc.point[1] == pytest.approx(floor, abs=1e-9)
            horiz = np.hypot(*(fc.point - foot)[[0, 2]])
            # The mask's lowest point is the near edge of the footprint: about one radius in front
            # of the foot centre, towards the camera.
            assert horiz < r + 0.06, (name, k, horiz)
            to_cam = (cam.position - foot)[[0, 2]]
            assert (fc.point - foot)[[0, 2]] @ to_cam > 0


def test_association_between_cameras(synth):
    floor = read_meta(synth / "cam0")["floor_y"]
    m0 = np.load(synth / "cam0" / "ground_truth" / "mask.npy")
    m1 = np.load(synth / "cam1" / "ground_truth" / "mask.npy")
    f0, f1 = read_frames(synth / "cam0"), read_frames(synth / "cam1")
    for k in range(0, 60, 10):
        a = floor_contact(m0[k], frame_camera(f0[k]), floor).point
        b = floor_contact(m1[k], frame_camera(f1[k]), floor).point
        decoy = np.array([a[0] + 2, floor, a[2]])
        assert associate([a], [decoy, b]) == [(0, 1)]
    assert associate([np.zeros(3)], [np.array([0.6, 0, 0])]) == []


def test_placement_edge_cases():
    m = np.zeros((10, 10), bool)
    assert mask_bottom_centre(m) is None
    m[2:10, 4:6] = True  # touches the bottom border: feet not visible
    assert mask_bottom_centre(m) is None
    m[9] = False
    assert mask_bottom_centre(m) == (4.5, 8.0)
    # Camera looking up: no floor intersection.
    from flycam_tools.geometry import Intrinsics, look_at

    cam = Camera(Intrinsics(10, 10, 5, 5, 10, 10), look_at([0, 0, 0], [0, 5, -1]))
    mm = np.zeros((10, 10), bool)
    mm[0:3, 4:6] = True
    assert floor_contact(mm, cam, -1.0) is None
