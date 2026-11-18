"""Clock offset estimation (docs/protocol.md 3.4) and frame pairing (section 4).

Mirrors FlyCamKit/Clock and FlyCamKit/FrameStore.
"""

from __future__ import annotations

import bisect
from collections import deque
from dataclasses import dataclass


@dataclass(frozen=True)
class ClockSample:
    t1: float  # Mac, ping sent
    t2: float  # phone, ping received
    t3: float  # phone, pong sent
    t4: float  # Mac, pong received

    @property
    def offset(self) -> float:
        """t_mac - t_phone."""
        return ((self.t1 - self.t2) + (self.t4 - self.t3)) / 2

    @property
    def round_trip(self) -> float:
        return (self.t4 - self.t1) - (self.t3 - self.t2)


class ClockOffsetEstimator:
    def __init__(self, window: int = 60):
        self.samples: deque[ClockSample] = deque(maxlen=window)

    def add(self, s: ClockSample) -> bool:
        if s.round_trip < 0 or s.t4 < s.t1 or s.t3 < s.t2:
            return False
        self.samples.append(s)
        return True

    @property
    def best(self) -> ClockSample | None:
        best = None
        for s in self.samples:  # ties: most recent wins
            if best is None or s.round_trip <= best.round_trip:
                best = s
        return best

    @property
    def offset(self) -> float | None:
        b = self.best
        return None if b is None else b.offset

    @property
    def uncertainty(self) -> float | None:
        b = self.best
        return None if b is None else b.round_trip / 2


class FrameRing:
    """Frames of one camera sorted by Mac time, keeping `capacity` seconds."""

    def __init__(self, capacity: float = 0.5):
        self.capacity = capacity
        self.times: list[float] = []
        self.items: list = []

    def insert(self, mac_time: float, item) -> None:
        i = bisect.bisect_right(self.times, mac_time)
        self.times.insert(i, mac_time)
        self.items.insert(i, item)
        cutoff = self.times[-1] - self.capacity
        drop = bisect.bisect_left(self.times, cutoff)
        if drop:
            del self.times[:drop]
            del self.items[:drop]

    def nearest(self, t: float):
        """(mac_time, item) nearest to t; ties go to the earlier frame. None when empty."""
        if not self.times:
            return None
        i = bisect.bisect_left(self.times, t)
        if i == 0:
            return self.times[0], self.items[0]
        if i == len(self.times):
            return self.times[-1], self.items[-1]
        if t - self.times[i - 1] <= self.times[i] - t:
            return self.times[i - 1], self.items[i - 1]
        return self.times[i], self.items[i]


class FrameStore:
    def __init__(self, capacity: float = 0.5, playout_delay: float = 0.150):
        self.capacity = capacity
        self.playout_delay = playout_delay
        self.rings: dict[int, FrameRing] = {}

    def insert(self, camera: int, mac_time: float, item) -> None:
        self.rings.setdefault(camera, FrameRing(self.capacity)).insert(mac_time, item)

    def pair(self, render_time: float, cameras=None) -> dict:
        """camera -> (mac_time, item) nearest to render_time."""
        out = {}
        for cam in cameras if cameras is not None else sorted(self.rings):
            r = self.rings.get(cam)
            n = r.nearest(render_time) if r else None
            if n is not None:
                out[cam] = n
        return out

    @staticmethod
    def residual(pairs: dict) -> float:
        ts = [t for t, _ in pairs.values()]
        return max(ts) - min(ts) if len(ts) > 1 else 0.0
