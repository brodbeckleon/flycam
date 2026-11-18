"""Virtual camera path between two cameras (plan.md Phase 4).

Same algorithm as Packages/FlyCamKit/Sources/FlyCamKit/Transition/TransitionPath.swift.
Tools/testdata/golden/*/transition.json checks that both produce the same cameras.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from .geometry import Camera, Intrinsics, quat_from_matrix, quat_slerp, quat_to_matrix, rigid, slerp_direction


def smootherstep(u: float) -> float:
    x = min(1.0, max(0.0, u))
    return x * x * x * (x * (x * 6 - 15) + 10)


@dataclass(frozen=True)
class TransitionConfig:
    duration: float = 1.2
    fade_fraction: float = 0.15
    floor_clearance: float = 0.3
    max_interest_distance: float = 20.0
    parallel_angle: float = 2 * math.pi / 180
    median_scene_depth: float = 3.0


@dataclass(frozen=True)
class BlendWeights:
    video_a: float
    render: float
    video_b: float


def interest_point(a: Camera, b: Camera, cfg: TransitionConfig) -> tuple[np.ndarray, str]:
    pA, dA = a.position, a.forward
    pB, dB = b.position, b.forward
    fallback = ((pA + dA * cfg.median_scene_depth) + (pB + dB * cfg.median_scene_depth)) * 0.5
    sin_angle = float(np.linalg.norm(np.cross(dA, dB)))
    if sin_angle < math.sin(cfg.parallel_angle):
        return fallback, "median_depth"
    w0 = pA - pB
    bb = float(dA @ dB)
    d = float(dA @ w0)
    e = float(dB @ w0)
    denom = 1 - bb * bb
    t = (bb * e - d) / denom
    u = (e - bb * d) / denom
    if not (t > 0 and u > 0):
        return fallback, "median_depth"
    p = ((pA + dA * t) + (pB + dB * u)) * 0.5
    if np.linalg.norm(p - pA) > cfg.max_interest_distance or np.linalg.norm(p - pB) > cfg.max_interest_distance:
        return fallback, "median_depth"
    return p, "axes_midpoint"


def blend_weights(time_fraction: float, fade_fraction: float) -> BlendWeights:
    u = min(1.0, max(0.0, time_fraction))
    f = fade_fraction
    a = max(0.0, 1 - u / f)
    b = max(0.0, 1 - (1 - u) / f)
    return BlendWeights(a, 1 - a - b, b)


def people_weights(s: float) -> tuple[float, float]:
    c = min(1.0, max(0.0, s))
    return 1 - c, c


@dataclass
class TransitionPath:
    a: Camera
    b: Camera
    floor_y: float | None
    cfg: TransitionConfig = field(default_factory=TransitionConfig)

    def __post_init__(self):
        self.interest, self.method = interest_point(self.a, self.b, self.cfg)
        self.qA = quat_from_matrix(self.a.c2w[:3, :3])
        self.qB = quat_from_matrix(self.b.c2w[:3, :3])
        rA = self.a.position - self.interest
        rB = self.b.position - self.interest
        self.distA = float(np.linalg.norm(rA))
        self.distB = float(np.linalg.norm(rB))
        self.dirA = rA / self.distA if self.distA > 0 else -self.a.forward
        self.dirB = rB / self.distB if self.distB > 0 else -self.b.forward
        kA, kB = self.a.K, self.b.K
        self.kB = kB if (kB.width, kB.height) == (kA.width, kA.height) else kB.scaled(kA.width, kA.height)

    def progress(self, t: float) -> float:
        return smootherstep(t / self.cfg.duration)

    def camera_at_progress(self, s: float) -> Camera:
        s = min(1.0, max(0.0, s))
        if s == 0:
            return self.a
        if s == 1:
            return Camera(self.kB, self.b.c2w)
        dist = (1 - s) * self.distA + s * self.distB
        direction = slerp_direction(self.dirA, self.dirB, s)
        pos = self.interest + direction * dist
        if self.floor_y is not None:
            min_y = min(self.floor_y + self.cfg.floor_clearance, (1 - s) * self.a.position[1] + s * self.b.position[1])
            pos[1] = max(pos[1], min_y)
        q = quat_slerp(self.qA, self.qB, s)
        kA, kB = self.a.K, self.kB
        K = Intrinsics(
            fx=math.exp((1 - s) * math.log(kA.fx) + s * math.log(kB.fx)),
            fy=math.exp((1 - s) * math.log(kA.fy) + s * math.log(kB.fy)),
            cx=(1 - s) * kA.cx + s * kB.cx,
            cy=(1 - s) * kA.cy + s * kB.cy,
            width=kA.width,
            height=kA.height,
        )
        return Camera(K, rigid(quat_to_matrix(q), pos))

    def camera_at_time(self, t: float) -> Camera:
        return self.camera_at_progress(self.progress(t))

    def blend_weights(self, t: float) -> BlendWeights:
        return blend_weights(t / self.cfg.duration, self.cfg.fade_fraction)
