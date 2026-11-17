"""Wire protocol codec (docs/protocol.md section 3). Mirrors FlyCamKit/Wire."""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass, field

MAGIC = b"FCAM"
VERSION = 1
HEADER_SIZE = 110
MAX_PAYLOAD = 16 * 1024 * 1024
MAX_MESSAGE = 1024 * 1024
PREAMBLE_CONTROL = b"FCC1"
PREAMBLE_MEDIA = b"FCM1"

# magic, version, camera, frame, t, c2w[16], fx fy cx cy, w, h, flags, payload length
_HEADER = struct.Struct("<4sHHId16f4fHHHI")
assert _HEADER.size == HEADER_SIZE

TRACKING_TO_WIRE = {"notAvailable": 0, "limited": 1, "normal": 2}
WIRE_TO_TRACKING = {v: k for k, v in TRACKING_TO_WIRE.items()}


class WireError(Exception):
    pass


@dataclass
class PacketHeader:
    camera_id: int
    frame_index: int
    timestamp: float
    c2w: list[float]  # 16, column-major (float32 on the wire)
    fx: float
    fy: float
    cx: float
    cy: float
    width: int
    height: int
    keyframe: bool
    tracking: str
    has_parameter_sets: bool
    payload_length: int = 0
    version: int = VERSION

    @property
    def flags(self) -> int:
        f = 1 if self.keyframe else 0
        f |= TRACKING_TO_WIRE[self.tracking] << 1
        if self.has_parameter_sets:
            f |= 1 << 3
        return f

    def encode(self) -> bytes:
        if len(self.c2w) != 16:
            raise WireError("c2w needs 16 values")
        return _HEADER.pack(
            MAGIC,
            self.version,
            self.camera_id,
            self.frame_index,
            self.timestamp,
            *self.c2w,
            self.fx,
            self.fy,
            self.cx,
            self.cy,
            self.width,
            self.height,
            self.flags,
            self.payload_length,
        )

    @classmethod
    def decode(cls, data: bytes) -> "PacketHeader":
        if len(data) < HEADER_SIZE:
            raise WireError("truncated header")
        v = _HEADER.unpack_from(data, 0)
        magic, version, cam, frame, t = v[:5]
        if magic != MAGIC:
            raise WireError(f"bad magic {magic!r}")
        if version != VERSION:
            raise WireError(f"unsupported version {version}")
        c2w = list(v[5:21])
        fx, fy, cx, cy = v[21:25]
        w, h, flags, plen = v[25:29]
        if plen > MAX_PAYLOAD:
            raise WireError(f"payload too large {plen}")
        tb = (flags >> 1) & 3
        if tb not in WIRE_TO_TRACKING:
            raise WireError(f"invalid tracking state {tb}")
        return cls(cam, frame, t, c2w, fx, fy, cx, cy, w, h, bool(flags & 1), WIRE_TO_TRACKING[tb], bool(flags & 8), plen, version)

    def to_json(self) -> dict:
        return {
            "camera_id": self.camera_id,
            "frame_index": self.frame_index,
            "timestamp": self.timestamp,
            "c2w": self.c2w,
            "fx": self.fx,
            "fy": self.fy,
            "cx": self.cx,
            "cy": self.cy,
            "width": self.width,
            "height": self.height,
            "keyframe": self.keyframe,
            "tracking": self.tracking,
            "has_parameter_sets": self.has_parameter_sets,
            "payload_length": self.payload_length,
        }

    @classmethod
    def from_json(cls, d: dict) -> "PacketHeader":
        return cls(
            d["camera_id"], d["frame_index"], d["timestamp"], list(d["c2w"]), d["fx"], d["fy"], d["cx"], d["cy"],
            d["width"], d["height"], d["keyframe"], d["tracking"], d["has_parameter_sets"], d.get("payload_length", 0),
        )


def f32(x: float) -> float:
    """Round to float32 as the wire does."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


@dataclass
class Packet:
    header: PacketHeader
    payload: bytes

    def __post_init__(self):
        self.header.payload_length = len(self.payload)

    def encode(self) -> bytes:
        return self.header.encode() + self.payload

    @classmethod
    def decode(cls, data: bytes) -> "Packet":
        h = PacketHeader.decode(data)
        end = HEADER_SIZE + h.payload_length
        if len(data) < end:
            raise WireError("truncated payload")
        return cls(h, bytes(data[HEADER_SIZE:end]))


# ----------------------------------------------------------------------- HEVC payload


def join_nals(nals: list[bytes]) -> bytes:
    return b"".join(struct.pack(">I", len(n)) + n for n in nals)


def split_nals(payload: bytes) -> list[bytes]:
    out, i = [], 0
    while i < len(payload):
        if len(payload) - i < 4:
            raise WireError("invalid NAL length")
        n = struct.unpack_from(">I", payload, i)[0]
        i += 4
        if n == 0 or i + n > len(payload):
            raise WireError("invalid NAL length")
        out.append(bytes(payload[i : i + n]))
        i += n
    return out


def nal_type(nal: bytes) -> int:
    return (nal[0] >> 1) & 0x3F


def starts_with_parameter_sets(payload: bytes) -> bool:
    try:
        nals = split_nals(payload)
    except WireError:
        return False
    return [nal_type(n) for n in nals[:3]] == [32, 33, 34]


# --------------------------------------------------------------------------- control


def encode_control(msg: dict) -> bytes:
    """Length-prefixed control frame. `msg` must contain "type"."""
    if "type" not in msg:
        raise WireError("control message needs a type")
    body = json.dumps(msg, sort_keys=True, separators=(",", ":")).encode()
    return struct.pack("<I", len(body)) + body


class PreambleReader:
    def __init__(self):
        self.buf = b""

    def feed(self, data: bytes):
        """Returns (channel, rest) once the 4-byte preamble arrived, else None."""
        self.buf += data
        if len(self.buf) < 4:
            return None
        pre, rest = self.buf[:4], self.buf[4:]
        self.buf = b""
        if pre == PREAMBLE_CONTROL:
            return "control", rest
        if pre == PREAMBLE_MEDIA:
            return "media", rest
        raise WireError(f"bad preamble {pre!r}")


@dataclass
class MediaStreamParser:
    buf: bytearray = field(default_factory=bytearray)
    pending: PacketHeader | None = None

    def feed(self, data: bytes) -> list[Packet]:
        self.buf += data
        out = []
        while True:
            if self.pending is None:
                if len(self.buf) < HEADER_SIZE:
                    break
                self.pending = PacketHeader.decode(bytes(self.buf[:HEADER_SIZE]))
                del self.buf[:HEADER_SIZE]
            n = self.pending.payload_length
            if len(self.buf) < n:
                break
            payload = bytes(self.buf[:n])
            del self.buf[:n]
            out.append(Packet(self.pending, payload))
            self.pending = None
        return out


@dataclass
class ControlStreamParser:
    buf: bytearray = field(default_factory=bytearray)

    def feed(self, data: bytes) -> list[dict]:
        self.buf += data
        out = []
        while len(self.buf) >= 4:
            n = struct.unpack_from("<I", self.buf, 0)[0]
            if n == 0:
                raise WireError("empty message")
            if n > MAX_MESSAGE:
                raise WireError(f"message too large {n}")
            if len(self.buf) < 4 + n:
                break
            body = bytes(self.buf[4 : 4 + n])
            del self.buf[: 4 + n]
            try:
                msg = json.loads(body)
            except json.JSONDecodeError as e:
                raise WireError(f"invalid JSON: {e}") from e
            if not isinstance(msg, dict) or not isinstance(msg.get("type"), str):
                raise WireError("control message without type")
            out.append(msg)
        return out


# Control message constructors (docs/protocol.md 3.2).


def hello(device_id: str, device_model: str, os_version: str, width: int, height: int, fps: float) -> dict:
    return {"type": "hello", "protocol_version": 1, "device_id": device_id, "device_model": device_model,
            "os_version": os_version, "video_format": {"width": width, "height": height, "fps": fps}}


def hello_ack(camera_id: int) -> dict:
    return {"type": "hello_ack", "protocol_version": 1, "camera_id": camera_id}


def ping(seq: int, t1: float) -> dict:
    return {"type": "ping", "seq": seq, "t1": t1}


def pong(seq: int, t1: float, t2: float, t3: float) -> dict:
    return {"type": "pong", "seq": seq, "t1": t1, "t2": t2, "t3": t3}


def status(battery: float, thermal_state: str, tracking: str, fps: float, recording: bool) -> dict:
    return {"type": "status", "battery": battery, "thermal_state": thermal_state, "tracking": tracking, "fps": fps, "recording": recording}


def ack(ref: str, ok: bool, message: str | None = None) -> dict:
    m = {"type": "ack", "ref": ref, "ok": ok}
    if message is not None:
        m["message"] = message
    return m


def set_camera_settings(lock: bool, iso=None, shutter=None, wb_temperature=None, wb_tint=None) -> dict:
    m = {"type": "set_camera_settings", "lock": lock}
    for k, v in (("iso", iso), ("shutter", shutter), ("wb_temperature", wb_temperature), ("wb_tint", wb_tint)):
        if v is not None:
            m[k] = v
    return m


def start_recording(session_name: str, clock_offset: float) -> dict:
    return {"type": "start_recording", "session_name": session_name, "clock_offset": clock_offset}


def stop_recording() -> dict:
    return {"type": "stop_recording"}


def normalize_control(msg: dict) -> dict:
    """Drop null optional values so messages compare equal regardless of null vs. absent."""
    return {k: v for k, v in msg.items() if v is not None}
