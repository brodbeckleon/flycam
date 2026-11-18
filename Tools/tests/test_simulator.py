"""Integration test on localhost: two fake phones stream synthetic sessions to the reference receiver."""

import socket
import threading
import time

import numpy as np
import pytest

from flycam_tools import wire
from flycam_tools.session import read_frames, read_video
from simulator.fake_phone import FakePhone
from simulator.receiver import Receiver
from tests.conftest import psnr

TRUE_OFFSETS = {"cam0": -4000.0, "cam1": 1234.5}
CAPTURE_LATENCY = 0.030


@pytest.fixture(scope="module")
def live(synth):
    """Run both phones once; also exercise the control commands while streaming."""
    with Receiver() as rx:
        phones = {n: FakePhone(synth / n, port=rx.port, true_offset=o, capture_latency=CAPTURE_LATENCY,
                               status_interval=0.5)
                  for n, o in TRUE_OFFSETS.items()}
        for p in phones.values():
            p.connect()
        rx.wait_for_cameras(2)
        threads = [threading.Thread(target=p.stream) for p in phones.values()]
        for t in threads:
            t.start()
        time.sleep(0.6)
        # Push one phone's locked settings to all phones, then a Mac-triggered recording.
        rx.broadcast(wire.set_camera_settings(True, iso=100.0, shutter=1 / 120, wb_temperature=5000.0, wb_tint=0.0))
        cam_ids = {n: p.log.camera_id for n, p in phones.items()}
        for n, cid in cam_ids.items():
            rx.send(cid, wire.start_recording(f"session_{n}", rx.cameras[cid].estimator.offset))
        pairs = []
        end = time.monotonic() + 1.0
        while time.monotonic() < end:
            render_time = Receiver.now() - rx.store.playout_delay
            pairs.append((render_time, rx.pair(render_time)))
            time.sleep(1 / 60)
        rx.broadcast(wire.stop_recording())
        for t in threads:
            t.join()
        time.sleep(0.3)
        for p in phones.values():
            p.close()
        yield {"rx": rx, "phones": phones, "ids": cam_ids, "pairs": pairs}


def test_all_frames_arrive_in_order(live, synth):
    for name, cid in live["ids"].items():
        frames = live["rx"].cameras[cid].frames
        assert [f.frame_index for f in frames] == list(range(len(read_frames(synth / name))))
        assert live["rx"].cameras[cid].decode_errors == 0


def test_decoded_frames_bit_exact_and_close_to_ground_truth(live, synth):
    from flycam_tools.session import read_image

    for name, cid in live["ids"].items():
        frames = live["rx"].cameras[cid].frames
        ref = list(read_video(synth / name / "video.mov"))
        for f, r in zip(frames, ref):
            np.testing.assert_array_equal(f.image, r)  # same bitstream as the file
        gt = read_image(synth / name / "ground_truth" / "frames" / "00030.png")
        assert psnr(frames[30].image, gt) > 30


def test_pose_and_intrinsics_in_headers(live, synth):
    for name, cid in live["ids"].items():
        recs = read_frames(synth / name)
        for f, rec in zip(live["rx"].cameras[cid].frames, recs):
            h = f.header
            np.testing.assert_allclose(h.c2w, rec["c2w"], rtol=1e-6, atol=1e-6)  # float32 on the wire
            assert (h.fx, h.cx, h.width, h.height) == pytest.approx((rec["fx"], rec["cx"], rec["w"], rec["h"]), rel=1e-6)
            assert h.tracking == rec["tracking"]
            assert h.keyframe == (rec["i"] % 30 == 0) == h.has_parameter_sets


def test_clock_offset_estimate(live):
    """plan.md Phase 5 asks for < 20 ms inter-camera sync; on localhost the estimate must be far better."""
    for name, cid in live["ids"].items():
        est = live["rx"].cameras[cid].estimator
        assert len(est.samples) >= 10
        assert abs(est.offset - TRUE_OFFSETS[name]) < 0.002
        assert abs(est.offset - TRUE_OFFSETS[name]) <= est.uncertainty + 1e-6


def test_latency_measured_in_mac_time(live):
    for cid in live["ids"].values():
        lat = np.array([f.arrival - f.t_mac for f in live["rx"].cameras[cid].frames])
        # arrival - capture = simulated capture-to-send latency + localhost transfer.
        assert np.median(lat) == pytest.approx(CAPTURE_LATENCY, abs=0.005)
        assert lat.min() > CAPTURE_LATENCY - 0.003
        assert lat.max() < 0.25  # plan.md Phase 5 latency budget


def test_nearest_frame_pairing(live):
    dt = 1 / 30
    full = [(rt, p) for rt, p in live["pairs"] if len(p) == 2]
    assert len(full) > 30
    for render_time, pairs in full:
        ts = [t for t, _ in pairs.values()]
        # Each camera's frame is the nearest one: within half a frame interval of the render time
        # (+ 5 ms for thread scheduling), so the two cameras differ by at most one interval.
        assert all(abs(t - render_time) <= dt / 2 + 0.005 for t in ts)
        assert max(ts) - min(ts) <= dt + 0.005


def test_control_commands(live):
    rx = live["rx"]
    for name, p in live["phones"].items():
        cid = live["ids"][name]
        assert p.log.settings["iso"] == 100.0 and p.log.settings["lock"] is True
        assert p.log.recording is False  # started, then stopped
        assert p.log.recording_clock_offset == pytest.approx(TRUE_OFFSETS[name], abs=0.002)
        refs = [a["ref"] for a in rx.cameras[cid].acks]
        assert refs == ["set_camera_settings", "start_recording", "stop_recording"]
        assert all(a["ok"] for a in rx.cameras[cid].acks)
        assert len(rx.cameras[cid].statuses) >= 2
        assert rx.cameras[cid].statuses[-1]["thermal_state"] == "nominal"
        assert p.log.pings_answered >= 10
        assert p.log.unknown == []


def test_receiver_rejects_garbage_and_keeps_running(synth):
    with Receiver() as rx:
        s = socket.create_connection(("127.0.0.1", rx.port))
        s.sendall(b"GET / HTTP/1.1\r\n\r\n")
        assert s.recv(10) == b""  # closed
        s.close()
        # Media before hello: rejected as well.
        s = socket.create_connection(("127.0.0.1", rx.port))
        hdr = wire.PacketHeader(5, 0, 1.0, [0.0] * 16, 1, 1, 0, 0, 2, 2, True, "normal", False)
        s.sendall(wire.PREAMBLE_MEDIA + wire.Packet(hdr, b"\x00\x00\x00\x01\x26").encode())
        assert s.recv(10) == b""
        s.close()
        time.sleep(0.1)
        assert rx.rejected_connections == 2
        # A real phone still works afterwards; the same device keeps its camera id on reconnect.
        p = FakePhone(synth / "cam0", port=rx.port, speed=4.0, ping_settle=0.05)
        p.run()
        p2 = FakePhone(synth / "cam0", port=rx.port, speed=4.0, ping_settle=0.05)
        p2.run()
        assert p.log.camera_id == p2.log.camera_id == 0
        assert len(rx.cameras[0].frames) == 60
