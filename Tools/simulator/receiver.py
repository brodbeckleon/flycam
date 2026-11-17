"""Reference receiver: the Mac side of the wire protocol (docs/protocol.md 3-4), without UI.

Accepts control and media connections on one port, assigns camera ids, keeps a clock offset
estimate per phone (10 pings at connect, then one per second), decodes HEVC, converts capture
times to Mac time and stores frames in a FrameStore for nearest-frame pairing. The Mac clock is
`time.monotonic()`. Usable as a library (tests) or from the command line:

    uv run python -m simulator.receiver --port 7777
"""

from __future__ import annotations

import argparse
import socket
import socketserver
import threading
import time
from dataclasses import dataclass, field

import numpy as np

from flycam_tools import wire
from flycam_tools.clock import ClockOffsetEstimator, ClockSample, FrameStore
from flycam_tools.hevc import Decoder


@dataclass
class ReceivedFrame:
    camera_id: int
    frame_index: int
    t_phone: float
    t_mac: float           # t_phone + offset estimate at arrival
    arrival: float         # Mac clock at arrival
    header: wire.PacketHeader
    image: np.ndarray | None


@dataclass
class CameraState:
    camera_id: int
    hello: dict
    estimator: ClockOffsetEstimator = field(default_factory=ClockOffsetEstimator)
    statuses: list[dict] = field(default_factory=list)
    acks: list[dict] = field(default_factory=list)
    frames: list[ReceivedFrame] = field(default_factory=list)
    decode_errors: int = 0
    unknown_messages: list[str] = field(default_factory=list)
    control: socket.socket | None = None
    send_lock: threading.Lock = field(default_factory=threading.Lock)
    seq: int = 0


class Receiver:
    def __init__(self, host: str = "127.0.0.1", port: int = 0, *, keep_images: bool = True,
                 initial_pings: int = 10, ping_interval: float = 1.0, playout_delay: float = 0.150):
        self.keep_images = keep_images
        self.initial_pings = initial_pings
        self.ping_interval = ping_interval
        self.cameras: dict[int, CameraState] = {}
        self.by_device: dict[str, int] = {}
        self.store = FrameStore(capacity=0.5, playout_delay=playout_delay)
        self.lock = threading.Lock()
        self.rejected_connections = 0
        self._stop = threading.Event()
        recv = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                recv._handle_connection(self.request)

        class Server(socketserver.ThreadingTCPServer):
            daemon_threads = True
            allow_reuse_address = True

        self.server = Server((host, port), Handler)
        self.port = self.server.server_address[1]
        self._thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @staticmethod
    def now() -> float:
        return time.monotonic()

    def start(self) -> "Receiver":
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        self.server.shutdown()
        self.server.server_close()
        for cam in self.cameras.values():
            if cam.control is not None:
                try:
                    cam.control.close()
                except OSError:
                    pass

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()

    # -------------------------------------------------------------- connections

    def _handle_connection(self, sock: socket.socket) -> None:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        pre = wire.PreambleReader()
        rest = b""
        try:
            while True:
                data = sock.recv(65536)
                if not data:
                    return
                r = pre.feed(data)
                if r is not None:
                    channel, rest = r
                    break
            if channel == "control":
                self._control(sock, rest)
            else:
                self._media(sock, rest)
        except wire.WireError:
            with self.lock:
                self.rejected_connections += 1
        except OSError:
            pass
        finally:
            try:
                sock.close()
            except OSError:
                pass

    def send(self, camera_id: int, msg: dict) -> None:
        cam = self.cameras[camera_id]
        with cam.send_lock:
            cam.control.sendall(wire.encode_control(msg))

    def _ping(self, cam: CameraState) -> None:
        cam.seq += 1
        self.send(cam.camera_id, wire.ping(cam.seq, self.now()))

    def _ping_loop(self, cam: CameraState) -> None:
        try:
            for _ in range(self.initial_pings):
                self._ping(cam)
                if self._stop.wait(0.02):
                    return
            while not self._stop.wait(self.ping_interval):
                self._ping(cam)
        except (OSError, KeyError):
            return

    def _control(self, sock: socket.socket, rest: bytes) -> None:
        parser = wire.ControlStreamParser()
        cam: CameraState | None = None
        pending = parser.feed(rest)
        while True:
            for msg in pending:
                t4 = msg.pop("_t4", self.now())
                typ = msg["type"]
                if typ == "hello":
                    with self.lock:
                        cid = self.by_device.get(msg["device_id"])
                        if cid is None:
                            cid = len(self.by_device)
                            self.by_device[msg["device_id"]] = cid
                        cam = CameraState(cid, msg, control=sock)
                        self.cameras[cid] = cam
                    self.send(cid, wire.hello_ack(cid))
                    threading.Thread(target=self._ping_loop, args=(cam,), daemon=True).start()
                elif cam is None:
                    raise wire.WireError(f"{typ} before hello")
                elif typ == "pong":
                    cam.estimator.add(ClockSample(msg["t1"], msg["t2"], msg["t3"], t4))
                elif typ == "status":
                    cam.statuses.append(msg)
                elif typ == "ack":
                    cam.acks.append(msg)
                else:
                    cam.unknown_messages.append(typ)
            data = sock.recv(65536)
            if not data:
                return
            t4 = self.now()
            pending = parser.feed(data)
            for m in pending:
                m["_t4"] = t4

    def _media(self, sock: socket.socket, rest: bytes) -> None:
        parser = wire.MediaStreamParser()
        decoders: dict[int, Decoder] = {}
        data = rest
        while True:
            arrival = self.now()
            for pkt in parser.feed(data):
                h = pkt.header
                cam = self.cameras.get(h.camera_id)
                if cam is None:
                    raise wire.WireError(f"media for unknown camera {h.camera_id}")
                dec = decoders.setdefault(h.camera_id, Decoder())
                try:
                    imgs = dec.decode(pkt.payload)
                except Exception:  # noqa: BLE001 - count and continue, like a live receiver must
                    cam.decode_errors += 1
                    imgs = []
                offset = cam.estimator.offset
                t_mac = h.timestamp + (offset if offset is not None else 0.0)
                img = imgs[-1] if imgs else None
                rf = ReceivedFrame(h.camera_id, h.frame_index, h.timestamp, t_mac, arrival, h,
                                   img if self.keep_images else None)
                with self.lock:
                    cam.frames.append(rf)
                    if img is not None:
                        self.store.insert(h.camera_id, t_mac, rf)
            data = sock.recv(1 << 20)
            if not data:
                return

    # -------------------------------------------------------------------- api

    def wait_for_cameras(self, n: int, timeout: float = 10.0) -> None:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            with self.lock:
                if len(self.cameras) >= n:
                    return
            time.sleep(0.01)
        raise TimeoutError(f"only {len(self.cameras)} cameras connected")

    def broadcast(self, msg: dict) -> None:
        for cid in list(self.cameras):
            self.send(cid, msg)

    def pair(self, render_time: float) -> dict:
        with self.lock:
            return self.store.pair(render_time)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=7777)
    a = ap.parse_args(argv)
    with Receiver(a.host, a.port, keep_images=False) as r:
        print(f"listening on {a.host}:{r.port}")
        try:
            while True:
                time.sleep(1)
                for cid, cam in sorted(r.cameras.items()):
                    off = cam.estimator.offset
                    lat = [f.arrival - f.t_mac for f in cam.frames[-30:]]
                    print(f"camera {cid} {cam.hello['device_id']}: frames={len(cam.frames)} "
                          f"offset={off if off is None else round(off, 4)} "
                          f"latency={np.median(lat) * 1000 if lat else float('nan'):.1f} ms")
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
