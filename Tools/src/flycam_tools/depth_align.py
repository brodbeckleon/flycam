"""Metric alignment of monocular relative inverse depth (plan.md Phase 7).

The depth model outputs relative inverse depth d. Metric inverse depth is a*d + b.
a and b are fitted per frame on background pixels against 1/z of the static splat depth
rendered from the same pose (robust: RANSAC, then Huber IRLS), then smoothed over time.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class AffineFit:
    a: float
    b: float
    inliers: int
    total: int

    def apply(self, d: np.ndarray) -> np.ndarray:
        """Metric depth z from relative inverse depth d (non-positive inverse depth -> inf)."""
        inv = self.a * np.asarray(d, np.float64) + self.b
        with np.errstate(divide="ignore"):
            return np.where(inv > 1e-6, 1.0 / inv, np.inf)


def fit_inverse_depth(d: np.ndarray, z_ref: np.ndarray, mask: np.ndarray | None = None, *, rel_tol: float = 0.03,
                      iterations: int = 200, max_samples: int = 20000, seed: int = 0) -> AffineFit:
    """Fit 1/z_ref ~= a*d + b on pixels where `mask` is true (background) and both values are valid."""
    d = np.asarray(d, np.float64).ravel()
    inv = 1.0 / np.asarray(z_ref, np.float64).ravel()
    ok = np.isfinite(d) & np.isfinite(inv) & (inv > 0)
    if mask is not None:
        ok &= np.asarray(mask, bool).ravel()
    idx = np.nonzero(ok)[0]
    if len(idx) < 10:
        raise ValueError("too few valid pixels for the depth alignment")
    rng = np.random.default_rng(seed)
    if len(idx) > max_samples:
        idx = rng.choice(idx, max_samples, replace=False)
    x, y = d[idx], inv[idx]

    best, best_n = None, -1
    for _ in range(iterations):
        i, j = rng.choice(len(x), 2, replace=False)
        if abs(x[i] - x[j]) < 1e-9:
            continue
        a = (y[i] - y[j]) / (x[i] - x[j])
        b = y[i] - a * x[i]
        n = int((np.abs(a * x + b - y) <= rel_tol * y).sum())
        if n > best_n:
            best, best_n = (a, b), n
    a, b = best
    inl = np.abs(a * x + b - y) <= rel_tol * y
    # Huber IRLS on the inliers, residuals relative to y.
    xs, ys = x[inl], y[inl]
    for _ in range(10):
        r = (a * xs + b - ys) / ys
        s = 1.4826 * np.median(np.abs(r)) + 1e-12
        k = 1.345 * s
        w = np.where(np.abs(r) <= k, 1.0, k / np.maximum(np.abs(r), 1e-300)) / ys**2
        A = np.stack([xs, np.ones_like(xs)], axis=1)
        sw = np.sqrt(w)
        a, b = np.linalg.lstsq(A * sw[:, None], ys * sw, rcond=None)[0]
    return AffineFit(float(a), float(b), int(inl.sum()), len(x))


class AffineSmoother:
    """Exponential smoothing of (a, b) over time. alpha = weight of the newest fit."""

    def __init__(self, alpha: float = 0.3):
        self.alpha = alpha
        self.a: float | None = None
        self.b: float | None = None

    def update(self, fit: AffineFit) -> AffineFit:
        if self.a is None:
            self.a, self.b = fit.a, fit.b
        else:
            self.a = (1 - self.alpha) * self.a + self.alpha * fit.a
            self.b = (1 - self.alpha) * self.b + self.alpha * fit.b
        return AffineFit(self.a, self.b, fit.inliers, fit.total)


def anchor_check(person_depth: float, anchor_depth: float, tolerance: float = 0.15) -> tuple[bool, float]:
    """Compare the person's median depth with an anchor (floor placement or triangulation).
    Returns (agrees, scale) where scale moves the person to the anchor when they disagree."""
    if not (person_depth > 0 and anchor_depth > 0):
        return False, 1.0
    rel = abs(person_depth - anchor_depth) / anchor_depth
    if rel <= tolerance:
        return True, 1.0
    return False, anchor_depth / person_depth
