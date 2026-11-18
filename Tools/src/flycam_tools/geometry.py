"""Camera and rotation math with ARKit conventions (plan.md section 5, docs/protocol.md 1).

Mirrors Packages/FlyCamKit (Swift). Golden files in Tools/testdata/golden check that both agree.

Conventions: world +Y up, metres. c2w is camera-to-world, camera looks along -Z, +Y up,
+X right. Pixel (u, v): origin top-left, u right, v down, integer = pixel centre.
c2w is serialised as 16 numbers in column-major order.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace

import numpy as np

# --------------------------------------------------------------------------- c2w


def c2w_from_list(values) -> np.ndarray:
    """16 numbers, column-major (simd order) -> 4x4 matrix (numpy, row-indexed m[row, col])."""
    a = np.asarray(values, dtype=np.float64)
    if a.shape != (16,):
        raise ValueError(f"c2w needs 16 values, got shape {a.shape}")
    return a.reshape(4, 4).T.copy()


def c2w_to_list(m: np.ndarray) -> list[float]:
    """4x4 matrix -> 16 floats, column-major."""
    m = np.asarray(m, dtype=np.float64)
    if m.shape != (4, 4):
        raise ValueError("need a 4x4 matrix")
    return [float(x) for x in m.T.reshape(16)]


def rigid(rotation: np.ndarray, translation) -> np.ndarray:
    m = np.eye(4)
    m[:3, :3] = rotation
    m[:3, 3] = translation
    return m


def rigid_inverse(m: np.ndarray) -> np.ndarray:
    r = m[:3, :3]
    t = m[:3, 3]
    return rigid(r.T, -r.T @ t)


def rigidity_error(m: np.ndarray) -> float:
    m = np.asarray(m, dtype=np.float64)
    r = m[:3, :3]
    err = np.abs(r.T @ r - np.eye(3)).max()
    err = max(err, abs(np.linalg.det(r) - 1))
    err = max(err, np.abs(m[3] - [0, 0, 0, 1]).max())
    return float(err)


def look_at(eye, target, up=(0.0, 1.0, 0.0)) -> np.ndarray:
    """c2w at `eye` whose -Z axis points at `target` (same as the Swift test helper)."""
    eye = np.asarray(eye, float)
    back = eye - np.asarray(target, float)
    back /= np.linalg.norm(back)
    right = np.cross(np.asarray(up, float), back)
    right /= np.linalg.norm(right)
    cam_up = np.cross(back, right)
    return rigid(np.stack([right, cam_up, back], axis=1), eye)


def axis_angle(axis, angle: float) -> np.ndarray:
    """Rotation matrix for `angle` radians about `axis`."""
    return quat_to_matrix(quat_from_axis_angle(axis, angle))


# ---------------------------------------------------------------------- intrinsics


@dataclass(frozen=True)
class Intrinsics:
    fx: float
    fy: float
    cx: float
    cy: float
    width: int
    height: int

    @property
    def K(self) -> np.ndarray:
        """OpenCV camera matrix (for OpenCV calls, which use +Y down, +Z forward)."""
        return np.array([[self.fx, 0, self.cx], [0, self.fy, self.cy], [0, 0, 1]], dtype=np.float64)

    def scaled(self, width: int, height: int) -> "Intrinsics":
        sx = width / self.width
        sy = height / self.height
        return Intrinsics(self.fx * sx, self.fy * sy, (self.cx + 0.5) * sx - 0.5, (self.cy + 0.5) * sy - 0.5, width, height)


@dataclass(frozen=True)
class Camera:
    K: Intrinsics
    c2w: np.ndarray

    @property
    def position(self) -> np.ndarray:
        return self.c2w[:3, 3].copy()

    @property
    def forward(self) -> np.ndarray:
        f = -self.c2w[:3, 2]
        return f / np.linalg.norm(f)

    def with_pose(self, c2w: np.ndarray) -> "Camera":
        return replace(self, c2w=np.asarray(c2w, float))

    def unproject(self, u, v, z) -> np.ndarray:
        return unproject(u, v, z, self.K, self.c2w)

    def project(self, p) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        return project(p, self.K, self.c2w)

    def rays(self) -> tuple[np.ndarray, np.ndarray]:
        """Unit ray directions (H, W, 3) through every pixel centre and the per-ray factor
        `depth = t * cos_factor` that converts ray length t to depth along the viewing axis."""
        h, w = self.K.height, self.K.width
        v, u = np.mgrid[0:h, 0:w].astype(np.float64)
        d_cam = np.stack([(u - self.K.cx) / self.K.fx, -(v - self.K.cy) / self.K.fy, -np.ones_like(u)], axis=-1)
        norm = np.linalg.norm(d_cam, axis=-1, keepdims=True)
        d_cam = d_cam / norm
        d_world = d_cam @ self.c2w[:3, :3].T
        return d_world, 1.0 / norm[..., 0]


def unproject_to_camera(u, v, z, K: Intrinsics) -> np.ndarray:
    """plan.md section 5. Works on scalars or arrays; returns (..., 3)."""
    u = np.asarray(u, float)
    v = np.asarray(v, float)
    z = np.asarray(z, float)
    return np.stack([(u - K.cx) / K.fx * z, -(v - K.cy) / K.fy * z, -z * np.ones_like(u)], axis=-1)


def unproject(u, v, z, K: Intrinsics, c2w: np.ndarray) -> np.ndarray:
    p = unproject_to_camera(u, v, z, K)
    return p @ c2w[:3, :3].T + c2w[:3, 3]


def project(p, K: Intrinsics, c2w: np.ndarray):
    """World points (..., 3) -> (u, v, depth). depth <= 0 means behind the camera."""
    p = np.asarray(p, float)
    w2c = rigid_inverse(c2w)
    pc = p @ w2c[:3, :3].T + w2c[:3, 3]
    depth = -pc[..., 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        u = K.cx + K.fx * pc[..., 0] / depth
        v = K.cy - K.fy * pc[..., 1] / depth
    return u, v, depth


def projection_matrix(K: Intrinsics, near: float, far: float) -> np.ndarray:
    """Metal projection matrix, off-centre frustum from fx, fy, cx, cy (docs/protocol.md 1.3)."""
    w, h = float(K.width), float(K.height)
    return np.array(
        [
            [2 * K.fx / w, 0, 1 - (2 * K.cx + 1) / w, 0],
            [0, 2 * K.fy / h, (2 * K.cy + 1) / h - 1, 0],
            [0, 0, far / (near - far), near * far / (near - far)],
            [0, 0, -1, 0],
        ]
    )


# OpenCV camera axes (x right, y down, z forward) = diag(1, -1, -1) * ARKit camera axes.
CV_FROM_ARKIT = np.diag([1.0, -1.0, -1.0, 1.0])


def c2w_to_opencv_w2c(c2w: np.ndarray) -> np.ndarray:
    """ARKit c2w -> OpenCV world-to-camera [R|t] (4x4)."""
    return CV_FROM_ARKIT @ rigid_inverse(c2w)


def opencv_w2c_to_c2w(w2c_cv: np.ndarray) -> np.ndarray:
    return rigid_inverse(CV_FROM_ARKIT @ w2c_cv)


# ----------------------------------------------------------------------- quaternions
# (x, y, z, w), Hamilton convention. Same formulas as FlyCamKit/Math/Quaternion.swift.


def quat_from_axis_angle(axis, angle: float) -> np.ndarray:
    a = np.asarray(axis, float)
    a = a / np.linalg.norm(a)
    s = math.sin(angle / 2)
    return np.array([a[0] * s, a[1] * s, a[2] * s, math.cos(angle / 2)])


def quat_from_matrix(m: np.ndarray) -> np.ndarray:
    """Shepperd's method, result normalised with w >= 0."""
    m = np.asarray(m, float)
    trace = m[0, 0] + m[1, 1] + m[2, 2]
    if trace > 0:
        s = math.sqrt(trace + 1) * 2
        q = [(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, s / 4]
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = math.sqrt(1 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = [s / 4, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s]
    elif m[1, 1] > m[2, 2]:
        s = math.sqrt(1 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = [(m[0, 1] + m[1, 0]) / s, s / 4, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s]
    else:
        s = math.sqrt(1 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = [(m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, s / 4, (m[1, 0] - m[0, 1]) / s]
    q = np.array(q)
    q /= math.sqrt(float(q @ q))
    if q[3] < 0:
        q = -q
    return q


def quat_to_matrix(q) -> np.ndarray:
    x, y, z, w = (float(c) for c in q)
    xx, yy, zz = x * x, y * y, z * z
    xy, xz, yz = x * y, x * z, y * z
    wx, wy, wz = w * x, w * y, w * z
    return np.array(
        [
            [1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy)],
            [2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx)],
            [2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)],
        ]
    )


def quat_angle(a, b) -> float:
    d = min(1.0, abs(float(np.dot(a, b))))
    return 2 * math.acos(d)


def rotation_angle(r1: np.ndarray, r2: np.ndarray) -> float:
    """Angle in radians of the rotation r1^T r2."""
    c = (np.trace(np.asarray(r1).T @ np.asarray(r2)) - 1) / 2
    return float(math.acos(max(-1.0, min(1.0, c))))


def quat_slerp(a, b, t: float) -> np.ndarray:
    a = np.asarray(a, float)
    b = np.asarray(b, float)
    if t == 0:
        return a.copy()
    d = float(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3])
    if d < 0:
        b = -b
        d = -d
    if t == 1:
        return b.copy()
    if d > 0.9995:
        q = a + (b - a) * t
        return q / math.sqrt(float(q @ q))
    theta = math.acos(d)
    s = math.sin(theta)
    return a * (math.sin((1 - t) * theta) / s) + b * (math.sin(t * theta) / s)


def slerp_direction(a, b, t: float, fallback_axis=(0.0, 1.0, 0.0)) -> np.ndarray:
    a = np.asarray(a, float)
    b = np.asarray(b, float)
    if t == 0:
        return a.copy()
    if t == 1:
        return b.copy()
    d = max(-1.0, min(1.0, float(a @ b)))
    theta = math.acos(d)
    if theta < 1e-9:
        v = a + (b - a) * t
        return v / np.linalg.norm(v)
    if math.pi - theta < 1e-6:
        f = np.asarray(fallback_axis, float)
        axis = f - a * float(f @ a)
        if np.linalg.norm(axis) < 1e-9:
            axis = np.array([1.0, 0, 0]) - a * a[0]
        return quat_to_matrix(quat_from_axis_angle(axis, theta * t)) @ a
    s = math.sin(theta)
    return a * (math.sin((1 - t) * theta) / s) + b * (math.sin(t * theta) / s)
