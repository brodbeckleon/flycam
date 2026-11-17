"""Fake phone: plays a session folder to a receiver over TCP with the FlyCam wire protocol.

It behaves like CaptureApp in live mode (docs/protocol.md 3): control connection with hello,
answers pings with its own clock, acknowledges commands, sends status once per second; media
connection with one packet per frame (header from frames.jsonl, HEVC access unit from video.mov),
paced in real time.

The phone clock is `time.monotonic() - true_offset`, so `t_mac = t_phone + true_offset` when the
receiver uses `time.monotonic()` as its Mac clock. Tests compare the receiver's estimate with it.

    uv run python -m simulator.fake_phone out/synth/cam0 --port 7777
"""

from __future__ import annotations

import argparse
import socket
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from flycam_tools import wire
from flycam_tools.hevc import access_units
from flycam_tools.session import read_frames, read_meta


@dataclass
class PhoneLog:
    camera_id: int | None = None
    pings_answered: int = 0
    acks: list[str] = field(default_factory=list)
    settings: dict | None = None
    recording: bool = False
    recording_clock_offset: float | None = None
    sent_frames: list[int] = field(default_factory=list)
    unknown: list[str] = field(default_factory=list)


class FakePhone:
    def __init__(self, session: Path, host: str = "127.0.0.1", port: int = 7777, *, device_id: str | None = None,
                 true_offset: float = 0.0, speed: float = 1.0, capture_latency: float = 0.030,
                 status_interval: float = 1.0, ping_settle: float = 0.25):
        self.session = Path(session)
        self.host, self.port = host, port
        self.device_id = device_id or f"fake-{self.session.name}"
        self.true_offset = true_offset
        self.speed = speed
        self.capture_latency = capture_latency
        self.status_interval = status_interval
        self.ping_settle = ping_settle
        self.frames = read_frames(self.session)
        self.meta = read_meta(self.session)
        self.log = PhoneLog()
        self._stop = threading.Event()
        self._send_lock = threading.Lock()
        self._ctrl: socket.socket | None = None
        self._threads: list[threading.Thread] = []

    def phone_now(self) -> float:
        return time.monotonic() - self.true_offset

    # ---------------------------------------------------------------- control

    def _send_control(self, msg: dict) -> None:
        with self._send_lock:
            self._ctrl.sendall(wire.encode_control(msg))

    def _control_loop(self, parser: wire.ControlStreamParser, first: list[dict]) -> None:
        pending = list(first)
        while not self._stop.is_set():
            for msg in pending:
                self._handle(msg)
            try:
                data = self._ctrl.recv(65536)
            except OSError:
                return
            if not data:
                return
            t_recv = self.phone_now()
            pending = parser.feed(data)
            for m in pending:
                m.setdefault("_t_recv", t_recv)

    def _handle(self, msg: dict) -> None:
        t2 = msg.pop("_t_recv", self.phone_now())
        typ = msg["type"]
        if typ == "ping":
            self._send_control(wire.pong(msg["seq"], msg["t1"], t2, self.phone_now()))
            self.log.pings_answered += 1
        elif typ == "set_camera_settings":
            self.log.settings = msg
            self._send_control(wire.ack(typ, True))
        elif typ == "start_recording":
            self.log.recording = True
            self.log.recording_clock_offset = msg["clock_offset"]
            self._send_control(wire.ack(typ, True))
        elif typ == "stop_recording":
            self.log.recording = False
            self._send_control(wire.ack(typ, True))
        elif typ == "hello_ack":
            pass
        else:
            self.log.unknown.append(typ)

    def _status_loop(self) -> None:
        while not self._stop.wait(self.status_interval):
            try:
                self._send_control(wire.status(0.9, "nominal", "normal", self.meta["video_format"]["fps"], self.log.recording))
            except OSError:
                return

    # ------------------------------------------------------------------ run

    def connect(self) -> None:
        self._ctrl = socket.create_connection((self.host, self.port))
        self._ctrl.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self._ctrl.sendall(wire.PREAMBLE_CONTROL)
        vf = self.meta["video_format"]
        self._send_control(wire.hello(self.device_id, self.meta.get("device_model", "Synthetic"),
                                      self.meta.get("os_version", "0"), vf["width"], vf["height"], vf["fps"]))
        parser = wire.ControlStreamParser()
        msgs: list[dict] = []
        while not any(m["type"] == "hello_ack" for m in msgs):
            data = self._ctrl.recv(65536)
            if not data:
                raise ConnectionError("receiver closed the connection before hello_ack")
            t = self.phone_now()
            new = parser.feed(data)
            for m in new:
                m["_t_recv"] = t
            msgs += new
        ack = next(m for m in msgs if m["type"] == "hello_ack")
        self.log.camera_id = ack["camera_id"]
        rest = [m for m in msgs if m is not ack]
        for target in (lambda: self._control_loop(parser, rest), self._status_loop):
            th = threading.Thread(target=target, daemon=True)
            th.start()
            self._threads.append(th)

    def stream(self) -> None:
        """Send all frames, paced at capture rate / speed."""
        media = socket.create_connection((self.host, self.port))
        media.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        media.sendall(wire.PREAMBLE_MEDIA)
        time.sleep(self.ping_settle)  # let the initial clock sync finish first, like a real phone warming up
        t0_session = self.frames[0]["t"]
        start = time.monotonic()
        try:
            for au, rec in zip(access_units(self.session / "video.mov"), self.frames):
                due = start + (rec["t"] - t0_session) / self.speed + self.capture_latency
                delay = due - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                header = wire.PacketHeader(
                    camera_id=self.log.camera_id, frame_index=rec["i"],
                    timestamp=self.phone_now() - self.capture_latency,  # capture happened before encoding
                    c2w=rec["c2w"], fx=rec["fx"], fy=rec["fy"], cx=rec["cx"], cy=rec["cy"],
                    width=rec["w"], height=rec["h"], keyframe=au.keyframe, tracking=rec["tracking"],
                    has_parameter_sets=au.keyframe)
                media.sendall(wire.Packet(header, au.payload).encode())
                self.log.sent_frames.append(rec["i"])
        finally:
            media.close()

    def close(self) -> None:
        self._stop.set()
        if self._ctrl is not None:
            try:
                self._ctrl.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self._ctrl.close()

    def run(self) -> PhoneLog:
        self.connect()
        try:
            self.stream()
        finally:
            time.sleep(0.05)
            self.close()
        return self.log


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session", type=Path)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7777)
    ap.add_argument("--offset", type=float, default=-5000.0, help="true clock offset t_mac - t_phone")
    ap.add_argument("--speed", type=float, default=1.0)
    a = ap.parse_args(argv)
    log = FakePhone(a.session, a.host, a.port, true_offset=a.offset, speed=a.speed).run()
    print(f"camera {log.camera_id}: sent {len(log.sent_frames)} frames, answered {log.pings_answered} pings")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
