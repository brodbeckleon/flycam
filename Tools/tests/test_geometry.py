import math

import numpy as np
import pytest

from flycam_tools.geometry import (
    Camera, Intrinsics, axis_angle, c2w_from_list, c2w_to_list, c2w_to_opencv_w2c, look_at, opencv_w2c_to_c2w,
    project, projection_matrix, quat_from_matrix, quat_slerp, quat_angle, quat_to_matrix, rigid, rigid_inverse,
    rigidity_error, slerp_direction, unproject,
)
from flycam_tools.transition import TransitionPath, blend_weights, smootherstep

HD = Intrinsics(1500.5, 1499.25, 961.3, 538.7, 1920, 1080)


def random_pose(rng):
    axis = rng.uniform(-1, 1, 3)
    return rigid(axis_angle(axis, rng.uniform(-math.pi, math.pi)), rng.uniform(-3, 3, 3))


def test_project_unproject_round_trip():
    """plan.md section 5: project(unproject(u, v, z)) == (u, v)."""
    rng = np.random.default_rng(0)
    for _ in range(20):
        c2w = random_pose(rng)
        u = rng.uniform(-0.5, 1919.5, 200)
        v = rng.uniform(-0.5, 1079.5, 200)
        z = rng.uniform(0.1, 30, 200)
        pu, pv, pz = project(unproject(u, v, z, HD, c2w), HD, c2w)
        np.testing.assert_allclose(pu, u, atol=1e-9)
        np.testing.assert_allclose(pv, v, atol=1e-9)
        np.testing.assert_allclose(pz, z, atol=1e-9)


def test_c2w_serialisation_round_trip_is_column_major():
    values = [float(x) for x in range(16)]
    m = c2w_from_list(values)
    assert m[0, 3] == 12 and m[1, 3] == 13 and m[2, 3] == 14  # translation = column 3
    assert m[3, 0] == 3
    assert c2w_to_list(m) == values
    with pytest.raises(ValueError):
        c2w_from_list([1, 2, 3])


def test_axis_conventions():
    cam = Camera(HD, np.eye(4))
    np.testing.assert_allclose(cam.forward, [0, 0, -1])
    u, v, z = project(np.array([0.0, 0.1, -2.0]), HD, np.eye(4))
    assert v < HD.cy and z == pytest.approx(2.0)
    u, v, z = project(np.array([0.1, 0.0, -2.0]), HD, np.eye(4))
    assert u > HD.cx
    _, _, z = project(np.array([0.0, 0.0, 1.0]), HD, np.eye(4))
    assert z < 0


def test_projection_matrix_matches_projection():
    rng = np.random.default_rng(1)
    near, far = 0.05, 50.0
    P = projection_matrix(HD, near, far)
    for _ in range(5):
        c2w = random_pose(rng)
        u = rng.uniform(0, 1919, 100)
        v = rng.uniform(0, 1079, 100)
        z = rng.uniform(near, far, 100)
        p = unproject(u, v, z, HD, c2w)
        clip = (P @ rigid_inverse(c2w) @ np.c_[p, np.ones(len(p))].T).T
        ndc = clip[:, :3] / clip[:, 3:]
        np.testing.assert_allclose((ndc[:, 0] + 1) / 2 * HD.width, u + 0.5, atol=1e-7)
        np.testing.assert_allclose((1 - ndc[:, 1]) / 2 * HD.height, v + 0.5, atol=1e-7)
        assert ((ndc[:, 2] >= -1e-12) & (ndc[:, 2] <= 1 + 1e-12)).all()


def test_opencv_conversion_round_trip():
    import cv2

    rng = np.random.default_rng(2)
    c2w = random_pose(rng)
    w2c = c2w_to_opencv_w2c(c2w)
    np.testing.assert_allclose(opencv_w2c_to_c2w(w2c), c2w, atol=1e-12)
    # cv2.projectPoints with the converted pose equals our projection.
    pts = unproject(np.array([100.0, 1500.0]), np.array([50.0, 900.0]), np.array([2.0, 7.0]), HD, c2w)
    rvec, _ = cv2.Rodrigues(w2c[:3, :3])
    proj, _ = cv2.projectPoints(pts, rvec, w2c[:3, 3], HD.K, None)
    np.testing.assert_allclose(proj[:, 0, :], [[100, 50], [1500, 900]], atol=1e-6)


def test_quaternions():
    rng = np.random.default_rng(3)
    for _ in range(100):
        r = axis_angle(rng.uniform(-1, 1, 3), rng.uniform(-math.pi, math.pi))
        q = quat_from_matrix(r)
        assert q[3] >= 0
        np.testing.assert_allclose(quat_to_matrix(q), r, atol=1e-12)
    for axis in ([1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0]):
        r = axis_angle(axis, math.pi)
        np.testing.assert_allclose(quat_to_matrix(quat_from_matrix(r)), r, atol=1e-12)
    a = quat_from_matrix(axis_angle([0, 1, 0], 0.2))
    b = quat_from_matrix(axis_angle([0, 1, 0], 1.4))
    assert quat_angle(quat_slerp(a, b, 0.25), a) == pytest.approx(0.3, abs=1e-9)
    np.testing.assert_array_equal(quat_slerp(a, b, 0), a)


def test_slerp_direction_antiparallel():
    a = np.array([1.0, 0, 0])
    m = slerp_direction(a, -a, 0.5)
    assert np.linalg.norm(m) == pytest.approx(1)
    assert abs(m[1]) < 1e-12 and abs(m @ a) < 1e-9


def test_intrinsics_scaled():
    k = HD.scaled(960, 540)
    assert k.fx == pytest.approx(HD.fx / 2)
    assert (k.cx + 0.5) * 2 == pytest.approx(HD.cx + 0.5)


def test_transition_endpoints_exact_and_weights():
    K = Intrinsics(1500, 1500, 960, 540, 1920, 1080)
    a = Camera(K, look_at([-2, 0.2, 0], [0, 0, -4]))
    b = Camera(K, look_at([2.5, -0.1, -1], [0, 0, -4]))
    path = TransitionPath(a, b, floor_y=-1.3)
    assert path.method == "axes_midpoint"
    np.testing.assert_allclose(path.interest, [0, 0, -4], atol=1e-9)
    assert path.camera_at_time(0) is a
    np.testing.assert_array_equal(path.camera_at_time(1.2).c2w, b.c2w)
    assert smootherstep(0) == 0 and smootherstep(1) == 1
    assert blend_weights(0, 0.15) == blend_weights(0.0, 0.15)
    assert blend_weights(0, 0.15).video_a == 1 and blend_weights(1, 0.15).video_b == 1
    assert blend_weights(1, 0.15).render == 0
    for u in np.linspace(0, 1, 101):
        w = blend_weights(u, 0.15)
        assert w.video_a + w.render + w.video_b == pytest.approx(1)
    mid = path.camera_at_progress(0.5)
    assert rigidity_error(mid.c2w) < 1e-12
    assert np.linalg.norm(mid.position - path.interest) == pytest.approx((path.distA + path.distB) / 2)
