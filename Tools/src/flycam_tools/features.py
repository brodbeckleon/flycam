"""Feature matching between a real frame and a splat render (SIFT, ratio test, mutual check)."""

from __future__ import annotations

import cv2
import numpy as np


def _gray(img: np.ndarray) -> np.ndarray:
    if img.ndim == 2:
        return img
    return cv2.cvtColor(img, cv2.COLOR_RGB2GRAY)


def match_features(img_a: np.ndarray, img_b: np.ndarray, ratio: float = 0.75, max_features: int = 4000,
                   mask_a: np.ndarray | None = None, mask_b: np.ndarray | None = None,
                   contrast_threshold: float = 0.02) -> tuple[np.ndarray, np.ndarray]:
    """Returns matched pixel coordinates (N, 2) in A and in B (u, v), pixel-centre convention.
    The contrast threshold is half of OpenCV's default (0.04): indoor footage and splat renders are
    low in contrast, and the default leaves only a few dozen keypoints per frame."""
    sift = cv2.SIFT_create(nfeatures=max_features, contrastThreshold=contrast_threshold)
    ma = None if mask_a is None else mask_a.astype(np.uint8) * 255
    mb = None if mask_b is None else mask_b.astype(np.uint8) * 255
    ka, da = sift.detectAndCompute(_gray(img_a), ma)
    kb, db = sift.detectAndCompute(_gray(img_b), mb)
    if da is None or db is None or len(ka) < 2 or len(kb) < 2:
        return np.zeros((0, 2)), np.zeros((0, 2))
    bf = cv2.BFMatcher(cv2.NORM_L2)
    ab = bf.knnMatch(da, db, k=2)
    ba = {m[0].queryIdx: m[0].trainIdx for m in bf.knnMatch(db, da, k=2) if len(m) == 2}
    pa, pb = [], []
    for m in ab:
        if len(m) < 2:
            continue
        best, second = m
        if best.distance < ratio * second.distance and ba.get(best.trainIdx) == best.queryIdx:
            pa.append(ka[best.queryIdx].pt)
            pb.append(kb[best.trainIdx].pt)
    return np.asarray(pa, float).reshape(-1, 2), np.asarray(pb, float).reshape(-1, 2)


def robust_displacements(pa: np.ndarray, pb: np.ndarray, k: float = 3.0) -> np.ndarray:
    """Boolean inlier mask: displacement vectors within k robust standard deviations of the median.
    Small misalignments shift all static features by similar amounts; mismatches are far off."""
    if len(pa) == 0:
        return np.zeros(0, bool)
    d = pb - pa
    med = np.median(d, axis=0)
    r = np.linalg.norm(d - med, axis=1)
    mad = np.median(r) * 1.4826 + 0.25
    return r <= k * mad
