"""Analytic synthetic scene and ray caster.

Stands in for both the real room (to make "phone" frames) and the trained splat (to make
"renders"). A box-shaped room with textured walls, a few boxes as furniture and a person
stand-in (vertical cylinder with a sphere head) that moves along a straight line.

Shading is view-independent (diffuse), so the same surface point has the same colour from
every camera, like a splat with only the DC colour term.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .geometry import Camera

LIGHT = np.array([0.3, 0.8, 0.5]) / np.linalg.norm([0.3, 0.8, 0.5])


@dataclass
class Box:
    lo: list[float]
    hi: list[float]
    color: list[float]
    seed: int


@dataclass
class Person:
    """Person stand-in. The foot point (centre of the footprint) moves linearly in Mac time
    from `start` to `end` (x, z) between `t0` and `t1`."""

    start: list[float]
    end: list[float]
    t0: float
    t1: float
    radius: float = 0.22
    body_height: float = 1.45
    head_radius: float = 0.13
    color: list[float] = field(default_factory=lambda: [0.75, 0.2, 0.15])

    @property
    def height(self) -> float:
        return self.body_height + 2 * self.head_radius

    def foot_xz(self, t: float) -> np.ndarray:
        a = 0.0 if self.t1 == self.t0 else min(1.0, max(0.0, (t - self.t0) / (self.t1 - self.t0)))
        return (1 - a) * np.asarray(self.start, float) + a * np.asarray(self.end, float)


@dataclass
class Scene:
    room_lo: list[float]
    room_hi: list[float]
    boxes: list[Box]
    person: Person | None
    texture_seed: int = 7

    @property
    def floor_y(self) -> float:
        return float(self.room_lo[1])

    def foot(self, t: float) -> np.ndarray:
        xz = self.person.foot_xz(t)
        return np.array([xz[0], self.floor_y, xz[1]])

    # ------------------------------------------------------------------ io

    def to_json(self) -> dict:
        return {
            "room_lo": self.room_lo,
            "room_hi": self.room_hi,
            "boxes": [b.__dict__ for b in self.boxes],
            "person": None if self.person is None else dict(self.person.__dict__),
            "texture_seed": self.texture_seed,
        }

    @classmethod
    def from_json(cls, d: dict) -> "Scene":
        return cls(d["room_lo"], d["room_hi"], [Box(**b) for b in d["boxes"]],
                   None if d["person"] is None else Person(**d["person"]), d.get("texture_seed", 7))

    def save(self, path: Path) -> None:
        Path(path).write_text(json.dumps(self.to_json(), indent=2) + "\n")

    @classmethod
    def load(cls, path: Path) -> "Scene":
        return cls.from_json(json.loads(Path(path).read_text()))

    # --------------------------------------------------------------- render

    def render(self, cam: Camera, t: float | None = None, person: bool = True):
        """Ray-cast the scene. Returns rgb float32 (H, W, 3) in [0, 1], depth along the viewing
        axis float32 (H, W), person mask bool (H, W)."""
        dirs, cos = cam.rays()
        o = cam.position
        h, w = dirs.shape[:2]
        d = dirs.reshape(-1, 3)
        n = d.shape[0]
        best_t = np.full(n, np.inf)
        rgb = np.zeros((n, 3))
        mask = np.zeros(n, bool)
        tex = _Texture(self.texture_seed)

        # Room (camera inside): exit distance.
        with np.errstate(divide="ignore", invalid="ignore"):
            inv = 1.0 / d
            t_lo = (np.asarray(self.room_lo) - o) * inv
            t_hi = (np.asarray(self.room_hi) - o) * inv
        t_far = np.maximum(t_lo, t_hi)
        t_far = np.where(np.isfinite(t_far), t_far, np.inf)
        axis = np.argmin(t_far, axis=1)
        t_room = t_far[np.arange(n), axis]
        positive = d[np.arange(n), axis] > 0
        face = axis * 2 + positive  # 0 -x wall, 1 +x, 2 floor, 3 ceiling, 4 -z, 5 +z
        best_t = t_room
        p = o + d * t_room[:, None]
        normals = np.zeros((n, 3))
        normals[np.arange(n), axis] = np.where(positive, -1.0, 1.0)
        uv = _face_uv(p, axis)
        base = np.array([[0.62, 0.6, 0.55], [0.55, 0.6, 0.65], [0.45, 0.38, 0.3],
                         [0.85, 0.85, 0.85], [0.6, 0.65, 0.55], [0.65, 0.55, 0.6]])[face]
        albedo = base * tex.sample(uv, 10 + face)
        floor = face == 2
        albedo[floor] *= _grid_lines(uv[floor], 0.5, 0.015)[:, None]
        rgb = albedo

        # Boxes.
        for b in self.boxes:
            t_b, ax_b = _ray_box(o, d, np.asarray(b.lo), np.asarray(b.hi))
            hit = t_b < best_t
            if not hit.any():
                continue
            pb = o + d[hit] * t_b[hit, None]
            nb = np.zeros((hit.sum(), 3))
            sign = -np.sign(d[hit, :][np.arange(hit.sum()), ax_b[hit]])
            nb[np.arange(hit.sum()), ax_b[hit]] = sign
            rgb[hit] = np.asarray(b.color) * tex.sample(_face_uv(pb, ax_b[hit]), 100 + b.seed)
            normals[hit] = nb
            best_t = np.where(hit, t_b, best_t)

        # Person.
        if person and self.person is not None and t is not None:
            pr = self.person
            foot = self.foot(t)
            t_c, n_c, uv_c = _ray_person(o, d, foot, pr)
            hit = t_c < best_t
            if hit.any():
                rgb[hit] = np.asarray(pr.color) * tex.sample(uv_c[hit], 500)
                normals[hit] = n_c[hit]
                best_t = np.where(hit, t_c, best_t)
                mask = hit

        shade = 0.55 + 0.45 * np.clip(normals @ LIGHT, 0, None)
        out = np.clip(rgb * shade[:, None], 0, 1)
        depth = best_t.reshape(h, w) * cos
        return out.reshape(h, w, 3).astype(np.float32), depth.astype(np.float32), mask.reshape(h, w)


def to_uint8(rgb: np.ndarray) -> np.ndarray:
    return np.clip(np.round(rgb * 255), 0, 255).astype(np.uint8)


# ------------------------------------------------------------------------- helpers


def _face_uv(p: np.ndarray, axis: np.ndarray) -> np.ndarray:
    """2D surface coordinates in metres for points on axis-aligned faces."""
    uv = np.empty((len(p), 2))
    for a, (i, j) in enumerate(((2, 1), (0, 2), (0, 1))):
        m = axis == a
        uv[m, 0] = p[m, i]
        uv[m, 1] = p[m, j]
    return uv


def _grid_lines(uv: np.ndarray, spacing: float, width: float) -> np.ndarray:
    f = np.abs(((uv / spacing) + 0.5) % 1.0 - 0.5) * spacing
    on = (f < width / 2).any(axis=1)
    return np.where(on, 0.35, 1.0)


def _ray_box(o, d, lo, hi):
    """Entry distance (inf when missed or camera inside) and entry axis for an AABB."""
    with np.errstate(divide="ignore", invalid="ignore"):
        inv = 1.0 / d
        t1 = (lo - o) * inv
        t2 = (hi - o) * inv
    tmin = np.minimum(t1, t2)
    tmax = np.maximum(t1, t2)
    tmin = np.where(np.isnan(tmin), -np.inf, tmin)
    tmax = np.where(np.isnan(tmax), np.inf, tmax)
    axis = np.argmax(tmin, axis=1)
    t_in = tmin.max(axis=1)
    t_out = tmax.min(axis=1)
    hit = (t_in <= t_out) & (t_in > 1e-6)
    return np.where(hit, t_in, np.inf), axis


def _ray_person(o, d, foot, pr: Person):
    n = len(d)
    t_best = np.full(n, np.inf)
    normal = np.zeros((n, 3))
    uv = np.zeros((n, 2))
    # Body: vertical cylinder from foot height to foot + body_height.
    dx, dz = o[0] - foot[0], o[2] - foot[2]
    a = d[:, 0] ** 2 + d[:, 2] ** 2
    b = 2 * (dx * d[:, 0] + dz * d[:, 2])
    c = dx * dx + dz * dz - pr.radius**2
    disc = b * b - 4 * a * c
    ok = (disc >= 0) & (a > 1e-12)
    with np.errstate(invalid="ignore", divide="ignore"):
        tc = (-b - np.sqrt(np.where(ok, disc, 0))) / (2 * a)
    y = o[1] + d[:, 1] * tc
    ok &= (tc > 1e-6) & (y >= foot[1]) & (y <= foot[1] + pr.body_height)
    t_best = np.where(ok, tc, t_best)
    p = o + d * np.where(ok, tc, 0)[:, None]
    nr = np.stack([p[:, 0] - foot[0], np.zeros(n), p[:, 2] - foot[2]], axis=1) / pr.radius
    ang = np.arctan2(nr[:, 2], nr[:, 0])
    normal[ok] = nr[ok]
    uv[ok] = np.stack([ang * pr.radius, p[:, 1]], axis=1)[ok]
    # Top cap.
    y_top = foot[1] + pr.body_height
    with np.errstate(invalid="ignore", divide="ignore"):
        tt = (y_top - o[1]) / d[:, 1]
    pt = o + d * np.where(np.isfinite(tt), tt, 0)[:, None]
    cap = np.isfinite(tt) & (tt > 1e-6) & ((pt[:, 0] - foot[0]) ** 2 + (pt[:, 2] - foot[2]) ** 2 <= pr.radius**2) & (tt < t_best)
    t_best = np.where(cap, tt, t_best)
    normal[cap] = [0, 1, 0]
    uv[cap] = pt[cap][:, [0, 2]]
    # Head: sphere on top of the body.
    hc = np.array([foot[0], y_top + pr.head_radius, foot[2]])
    oc = o - hc
    bs = d @ oc
    cs = oc @ oc - pr.head_radius**2
    ds = bs * bs - cs
    with np.errstate(invalid="ignore"):
        ts = -bs - np.sqrt(np.where(ds >= 0, ds, 0))
    sph = (ds >= 0) & (ts > 1e-6) & (ts < t_best)
    t_best = np.where(sph, ts, t_best)
    ps = o + d * np.where(sph, ts, 0)[:, None]
    ns = (ps - hc) / pr.head_radius
    normal[sph] = ns[sph]
    uv[sph] = (np.stack([np.arctan2(ns[:, 2], ns[:, 0]), np.arcsin(np.clip(ns[:, 1], -1, 1))], axis=1) * pr.head_radius)[sph] + 5.0
    return t_best, normal, uv


class _Texture:
    """Multi-octave value noise, deterministic per seed. Values around 1 (0.55 ... 1.45)."""

    OCTAVES = ((1.3, 0.35), (3.7, 0.3), (9.1, 0.22), (17.0, 0.13))

    def __init__(self, seed: int):
        self.seed = seed
        self.cache: dict[int, np.ndarray] = {}

    def lattice(self, key: int) -> np.ndarray:
        if key not in self.cache:
            rng = np.random.default_rng([self.seed, key])
            self.cache[key] = rng.uniform(-1, 1, size=(len(self.OCTAVES), 64, 64, 3))
        return self.cache[key]

    def sample(self, uv: np.ndarray, key) -> np.ndarray:
        keys = np.broadcast_to(np.asarray(key), (len(uv),))
        out = np.ones((len(uv), 3))
        for k in np.unique(keys):
            m = keys == k
            lat = self.lattice(int(k))
            acc = np.zeros((m.sum(), 3))
            for o, (freq, amp) in enumerate(self.OCTAVES):
                acc += amp * _value_noise(uv[m] * freq, lat[o])
            out[m] = 1 + 0.45 * acc / 0.5
        return np.clip(out, 0.2, 1.8)


def _value_noise(xy: np.ndarray, lat: np.ndarray) -> np.ndarray:
    x0 = np.floor(xy).astype(np.int64)
    f = xy - x0
    f = f * f * (3 - 2 * f)
    n = lat.shape[0]
    i0, j0 = x0[:, 0] % n, x0[:, 1] % n
    i1, j1 = (i0 + 1) % n, (j0 + 1) % n
    fx, fy = f[:, :1], f[:, 1:]
    a = lat[i0, j0] * (1 - fx) + lat[i1, j0] * fx
    b = lat[i0, j1] * (1 - fx) + lat[i1, j1] * fx
    return a * (1 - fy) + b * fy


def default_scene(t0: float = 0.0, t1: float = 3.0) -> Scene:
    """Room 6 m x 7.5 m x 2.7 m, floor at y = -1.3 (ARKit origin at about phone height)."""
    return Scene(
        room_lo=[-3.0, -1.3, -6.0],
        room_hi=[3.0, 1.4, 1.5],
        boxes=[
            Box([0.6, -1.3, -4.6], [1.6, -0.55, -3.9], [0.55, 0.4, 0.3], 1),     # table
            Box([-2.2, -1.3, -5.2], [-1.4, -0.2, -4.5], [0.35, 0.45, 0.6], 2),   # cabinet
            Box([-2.7, -1.3, -3.1], [-2.2, -0.9, -2.6], [0.4, 0.55, 0.35], 3),   # crate
            Box([1.9, -1.3, -2.0], [2.6, 0.4, -1.6], [0.6, 0.6, 0.4], 4),        # shelf
        ],
        person=Person(start=[-0.9, -3.6], end=[0.5, -3.5], t0=t0, t1=t1),
    )
