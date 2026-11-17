"""Render layers for the offline transition reference (plan.md Phases 4, 6, 7).

Every layer is (rgb float32 H x W x 3 in [0, 1], alpha H x W, depth H x W) seen from the
virtual camera. Depth is along the virtual camera's viewing axis; inf where empty.
"""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from flycam_tools.geometry import Camera, project, unproject


@dataclass
class Layer:
    rgb: np.ndarray
    alpha: np.ndarray
    depth: np.ndarray


def empty_layer(h: int, w: int) -> Layer:
    return Layer(np.zeros((h, w, 3), np.float32), np.zeros((h, w), np.float32), np.full((h, w), np.inf, np.float32))


def feather(mask: np.ndarray, sigma: float = 0.8) -> np.ndarray:
    """Soft matte from a binary mask (plan.md Phase 6: feather the matte edge)."""
    return np.clip(cv2.GaussianBlur(mask.astype(np.float32), (0, 0), sigma), 0, 1)


def bilinear(img: np.ndarray, u: np.ndarray, v: np.ndarray) -> np.ndarray:
    """Sample img (H, W, C) or (H, W) at pixel-centre coordinates; edges clamp."""
    h, w = img.shape[:2]
    u = np.clip(u, 0, w - 1)
    v = np.clip(v, 0, h - 1)
    u0 = np.floor(u).astype(int)
    v0 = np.floor(v).astype(int)
    u1 = np.minimum(u0 + 1, w - 1)
    v1 = np.minimum(v0 + 1, h - 1)
    fu = (u - u0)
    fv = (v - v0)
    if img.ndim == 3:
        fu = fu[..., None]
        fv = fv[..., None]
    a = img[v0, u0] * (1 - fu) + img[v0, u1] * fu
    b = img[v1, u0] * (1 - fu) + img[v1, u1] * fu
    return a * (1 - fv) + b * fv


# ----------------------------------------------------------------------- billboards


def billboard_layer(view: Camera, src: Camera, src_rgb: np.ndarray, matte: np.ndarray, anchor: np.ndarray,
                    floor_y: float, max_height: float = 2.5, margin: float = 2.0) -> Layer:
    """Phase 6 billboard: a vertical plane through `anchor` (floor contact point), rotated about
    the vertical axis to face the virtual camera, textured projectively from the source camera
    with the source frame and matte, limited to the matte's bounding box in the source image.
    Projective texturing makes the billboard reproject exactly onto the source pixels when the
    virtual camera equals the source camera."""
    h, w = view.K.height, view.K.width
    out = empty_layer(h, w)
    vs, us = np.nonzero(matte > 0.01)
    if len(vs) == 0:
        return out
    u_lo, u_hi = us.min() - margin, us.max() + margin
    v_lo, v_hi = vs.min() - margin, vs.max() + margin

    n = view.position - anchor
    n[1] = 0
    if np.linalg.norm(n) < 1e-9:
        n = -view.forward
        n[1] = 0
    n /= np.linalg.norm(n)

    dirs, cos = view.rays()
    o = view.position
    denom = dirs @ n
    with np.errstate(divide="ignore", invalid="ignore"):
        t = ((anchor - o) @ n) / denom
    q = o + dirs * t[..., None]
    ok = np.isfinite(t) & (t > 0) & (q[..., 1] >= floor_y) & (q[..., 1] <= floor_y + max_height)
    su, sv, sz = project(q, src.K, src.c2w)
    ok &= (sz > 0) & (su >= u_lo) & (su <= u_hi) & (sv >= v_lo) & (sv <= v_hi)
    if not ok.any():
        return out
    a = np.zeros((h, w), np.float32)
    a[ok] = bilinear(matte, su[ok], sv[ok])
    out.rgb[ok] = bilinear(src_rgb, su[ok], sv[ok])
    out.alpha = a
    out.depth[ok] = (t * cos)[ok]
    return out


# ------------------------------------------------------------------ depth Gaussians


@dataclass
class PersonPoints:
    xyz: np.ndarray       # (N, 3) world
    rgb: np.ndarray       # (N, 3) in [0, 1]
    opacity: np.ndarray   # (N,)
    scale: np.ndarray     # (N,) world-space size: z * stride / f


def person_points(src: Camera, src_rgb: np.ndarray, matte: np.ndarray, depth: np.ndarray, stride: int = 2,
                  min_matte: float = 0.5, max_jump: float = 0.05) -> PersonPoints:
    """Phase 7: one point per `stride` pixels in each direction inside the matte, positioned by
    unprojection with metric depth. Pixels at depth discontinuities (relative jump > max_jump to
    any 8-neighbour) are dropped so that no points are smeared between person and background."""
    h, w = depth.shape
    v, u = np.mgrid[0:h:stride, 0:w:stride]
    v, u = v.ravel(), u.ravel()
    z = depth[v, u].astype(np.float64)
    keep = (matte[v, u] >= min_matte) & np.isfinite(z) & (z > 0)
    zpad = np.pad(depth.astype(np.float64), 1, mode="edge")
    for dv in (-1, 0, 1):
        for du in (-1, 0, 1):
            zn = zpad[v + 1 + dv, u + 1 + du]
            keep &= np.abs(zn - z) <= max_jump * z
    v, u, z = v[keep], u[keep], z[keep]
    xyz = unproject(u.astype(float), v.astype(float), z, src.K, src.c2w)
    f = 0.5 * (src.K.fx + src.K.fy)
    return PersonPoints(xyz, src_rgb[v, u].astype(np.float32), matte[v, u].astype(np.float32), z * stride / f)


def splat_layer(view: Camera, pts: PersonPoints, factor: float = 1.0) -> Layer:
    """Opaque discs with a z-buffer (no sorting, plan.md Phase 7). Disc radius in pixels:
    0.75 * scale * factor * f / z, which for stride 2 and factor 1 covers the 2 x 2 pixel cell."""
    h, w = view.K.height, view.K.width
    out = empty_layer(h, w)
    if len(pts.xyz) == 0:
        return out
    u, v, z = project(pts.xyz, view.K, view.c2w)
    front = z > 0.05
    u, v, z = u[front], v[front], z[front]
    rgb, op = pts.rgb[front], pts.opacity[front]
    r = 0.75 * pts.scale[front] * factor * 0.5 * (view.K.fx + view.K.fy) / z
    rmax = int(np.ceil(r.max())) if len(r) else 0
    pix, zs, idx = [], [], []
    for dv in range(-rmax, rmax + 1):
        for du in range(-rmax, rmax + 1):
            pu = np.round(u).astype(int) + du
            pv = np.round(v).astype(int) + dv
            inside = (pu >= 0) & (pu < w) & (pv >= 0) & (pv < h)
            covered = inside & ((pu - u) ** 2 + (pv - v) ** 2 <= r**2)
            pix.append(pv[covered] * w + pu[covered])
            zs.append(z[covered])
            idx.append(np.nonzero(covered)[0])
    pix = np.concatenate(pix)
    zs = np.concatenate(zs)
    idx = np.concatenate(idx)
    order = np.lexsort((zs, pix))
    pix, zs, idx = pix[order], zs[order], idx[order]
    first = np.ones(len(pix), bool)
    first[1:] = pix[1:] != pix[:-1]
    pix, zs, idx = pix[first], zs[first], idx[first]
    out.rgb.reshape(-1, 3)[pix] = rgb[idx]
    out.alpha.reshape(-1)[pix] = op[idx]
    out.depth.reshape(-1)[pix] = zs
    return out


# ------------------------------------------------------------------------ composite


def composite_people(static_rgb: np.ndarray, static_depth: np.ndarray, layers: list[tuple[Layer, float]],
                     depth_eps: float = 0.02, normalise: bool = True) -> np.ndarray:
    """Static splat first, then people layers with depth test against the static depth and
    alpha blending. Layers are weighted by (1 - s) for A and s for B (plan.md Phases 6, 7).

    Coverage-normalised blend: colour = sum(w a c) / sum(w a), alpha = max(w a) / max(w).
    Each source only sees the side of a person that faces it, so a plain weighted sum makes
    a half-transparent ghost of each side in mid-flight. With this blend a pixel covered by one
    source keeps that source's full opacity at s = 0.5, while the weights still fade A out and
    B in. With weight 0 for B (s = 0) the result is exactly A's layer, and vice versa.

    `normalise=False` is the plain weighted sum (alpha = sum(w a)), used for billboards: each
    billboard covers the whole person, so the union of two silhouettes would double the outline."""
    weights = [w for _, w in layers if w > 0]
    if not weights:
        return static_rgb
    wmax = max(weights)
    num = np.zeros_like(static_rgb)
    den = np.zeros(static_rgb.shape[:2], np.float32)
    cover = np.zeros(static_rgb.shape[:2], np.float32)
    for layer, weight in layers:
        if weight <= 0:
            continue
        visible = layer.depth <= static_depth * (1 + depth_eps)
        a = np.where(visible, layer.alpha, 0) * weight
        num += layer.rgb * a[..., None]
        den += a
        cover = np.maximum(cover, a)
    alpha = np.clip(cover / wmax if normalise else den, 0, 1)
    colour = np.where(den[..., None] > 0, num / np.maximum(den, 1e-12)[..., None], 0)
    return static_rgb * (1 - alpha[..., None]) + colour * alpha[..., None]
