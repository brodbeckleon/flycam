"""HEVC access units for the media channel (docs/protocol.md 3.3).

`access_units(video.mov)` yields one wire payload per frame: NAL units with 4-byte big-endian
lengths, VPS/SPS/PPS first on keyframes. `Decoder` turns payloads back into RGB frames.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

import av
import numpy as np

from .wire import join_nals, nal_type, split_nals


def parse_hvcc(extradata: bytes) -> tuple[int, list[bytes]]:
    """hvcC box payload -> (NAL length size, [VPS, SPS, PPS, ...] in box order)."""
    if len(extradata) < 23 or extradata[0] != 1:
        raise ValueError("not an hvcC record")
    length_size = (extradata[21] & 3) + 1
    n_arrays = extradata[22]
    i = 23
    nals = []
    for _ in range(n_arrays):
        i += 1  # completeness + NAL type
        (count,) = struct.unpack_from(">H", extradata, i)
        i += 2
        for _ in range(count):
            (n,) = struct.unpack_from(">H", extradata, i)
            i += 2
            nals.append(bytes(extradata[i : i + n]))
            i += n
    order = {32: 0, 33: 1, 34: 2}
    nals.sort(key=lambda nal: order.get(nal_type(nal), 3))
    return length_size, nals


def _split_length_prefixed(data: bytes, size: int) -> list[bytes]:
    out, i = [], 0
    while i < len(data):
        n = int.from_bytes(data[i : i + size], "big")
        i += size
        out.append(bytes(data[i : i + n]))
        i += n
    return out


@dataclass
class AccessUnit:
    index: int
    keyframe: bool
    payload: bytes


def access_units(video: Path) -> Iterator[AccessUnit]:
    with av.open(str(video)) as c:
        st = c.streams.video[0]
        if st.codec_context.name != "hevc":
            raise ValueError(f"{video}: expected HEVC, got {st.codec_context.name}")
        size, params = parse_hvcc(bytes(st.codec_context.extradata))
        k = 0
        for p in c.demux(st):
            if not p.size:
                continue
            nals = _split_length_prefixed(bytes(p), size)
            if p.is_keyframe:
                # Drop in-band copies and put the parameter sets first, once.
                nals = [n for n in nals if nal_type(n) not in (32, 33, 34)]
                nals = params + nals
            yield AccessUnit(k, bool(p.is_keyframe), join_nals(nals))
            k += 1


def to_annexb(payload: bytes) -> bytes:
    return b"".join(b"\x00\x00\x00\x01" + n for n in split_nals(payload))


class Decoder:
    """Low-delay HEVC decoder for wire payloads. One frame out per payload (no reordering)."""

    def __init__(self):
        self.ctx = av.CodecContext.create("hevc", "r")
        self.ctx.thread_type = "NONE"
        self.ctx.thread_count = 1
        self.ctx.flags |= av.codec.context.Flags.low_delay

    def decode(self, payload: bytes) -> list[np.ndarray]:
        frames = self.ctx.decode(av.Packet(to_annexb(payload)))
        return [f.to_ndarray(format="rgb24") for f in frames]

    def flush(self) -> list[np.ndarray]:
        return [f.to_ndarray(format="rgb24") for f in self.ctx.decode(None)]
