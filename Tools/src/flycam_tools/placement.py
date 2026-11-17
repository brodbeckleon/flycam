"""Person placement by floor contact (plan.md Phase 6, option A) and cross-camera association."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .geometry import Camera


@dataclass
class FloorContact:
    point: np.ndarray       # world point on the floor plane
    pixel: tuple[float, float]
    depth: float            # depth along the source camera's viewing axis


def mask_bottom_centre(mask: np.ndarray, band: int = 2) -> tuple[float, float] | None:
    """Bottom centre of the mask: lowest mask row v_max, mean u of mask pixels in rows
    v_max - band ... v_max. None for an empty mask or when the mask touches the bottom image
    border (feet not visible)."""
    vs, us = np.nonzero(mask)
    if len(vs) == 0:
        return None
    v_max = int(vs.max())
    if v_max >= mask.shape[0] - 1:
        return None
    sel = vs >= v_max - band
    return float(us[sel].mean()), float(v_max)


def floor_contact(mask: np.ndarray, cam: Camera, floor_y: float) -> FloorContact | None:
    """Intersect the ray through the bottom centre of the mask with the floor plane y = floor_y."""
    px = mask_bottom_centre(mask)
    if px is None:
        return None
    u, v = px
    p1 = cam.unproject(u, v, 1.0)
    o = cam.position
    d = p1 - o
    if d[1] >= -1e-9:
        return None  # ray does not go down: horizon or above
    t = (floor_y - o[1]) / d[1]
    point = o + t * d
    return FloorContact(point, (u, v), float(t))  # unproject at depth 1 -> t is depth


def associate(points_a: list[np.ndarray], points_b: list[np.ndarray], max_dist: float = 0.5) -> list[tuple[int, int]]:
    """Greedy matching of people between two cameras by horizontal floor distance (< max_dist)."""
    cands = []
    for i, pa in enumerate(points_a):
        for j, pb in enumerate(points_b):
            dist = float(np.hypot(pa[0] - pb[0], pa[2] - pb[2]))
            if dist < max_dist:
                cands.append((dist, i, j))
    used_a, used_b, out = set(), set(), []
    for _, i, j in sorted(cands):
        if i not in used_a and j not in used_b:
            used_a.add(i)
            used_b.add(j)
            out.append((i, j))
    return out
