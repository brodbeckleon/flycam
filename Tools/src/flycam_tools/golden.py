"""Golden files shared with FlyCamKit (docs/protocol.md section 6).

`write_golden(dir)` writes the Python-generated set; `verify_golden(dir)` checks any set (from
Python or from Swift) against this implementation and returns a list of problems.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from . import wire
from .clock import ClockOffsetEstimator, ClockSample
from .geometry import Camera, Intrinsics, c2w_from_list, c2w_to_list, look_at, project, projection_matrix, unproject
from .session import encode_frames, make_frame, parse_frames
from .transition import TransitionConfig, TransitionPath, blend_weights, smootherstep

S_VALUES = [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]
U_VALUES = [0.0, 0.05, 0.15, 0.5, 0.9, 0.95, 1.0]
TOL = 1e-9


def _dump(obj) -> str:
    return json.dumps(obj, indent=1, sort_keys=True) + "\n"


def _k_json(K: Intrinsics) -> dict:
    return {"fx": K.fx, "fy": K.fy, "cx": K.cx, "cy": K.cy, "width": K.width, "height": K.height}


def _k_from(d: dict) -> Intrinsics:
    return Intrinsics(d["fx"], d["fy"], d["cx"], d["cy"], d["width"], d["height"])


def _cfg_json(c: TransitionConfig) -> dict:
    return {"duration": c.duration, "fade_fraction": c.fade_fraction, "floor_clearance": c.floor_clearance,
            "max_interest_distance": c.max_interest_distance, "parallel_angle": c.parallel_angle,
            "median_scene_depth": c.median_scene_depth}


def _cfg_from(d: dict) -> TransitionConfig:
    return TransitionConfig(d["duration"], d["fade_fraction"], d["floor_clearance"], d["max_interest_distance"],
                            d["parallel_angle"], d["median_scene_depth"])


# ---------------------------------------------------------------------------- inputs


def _packets() -> list[wire.Packet]:
    f = wire.f32
    c2w0 = [f(x) for x in c2w_to_list(look_at([0.5, 0.25, 2.0], [0.0, -0.5, -3.0]))]
    c2w1 = [f(x) for x in c2w_to_list(look_at([-1.75, 0.1, -0.4], [0.3, -0.6, -3.5]))]
    key = wire.join_nals([bytes([0x40, 0x01, 0x0C, 0x01]), bytes([0x42, 0x01, 0x01, 0x60]), bytes([0x44, 0x01, 0xC1]),
                          bytes([0x26, 0x01, 0xAF, 0x08, 0x40, 0x00, 0xFF])])
    return [
        wire.Packet(wire.PacketHeader(0, 0, 5000.123456789, c2w0, f(1500.5), f(1499.25), f(961.3), f(538.7), 1920, 1080,
                                      True, "normal", True), key),
        wire.Packet(wire.PacketHeader(0, 1, 5000.140123456, c2w0, f(1500.5), f(1499.25), f(961.3), f(538.7), 1920, 1080,
                                      False, "limited", False), wire.join_nals([bytes([0x02, 0x01, 0xD0, 0x12, 0x34])])),
        wire.Packet(wire.PacketHeader(65535, 4294967295, -1.5, c2w1, f(330.0), f(331.5), f(191.7), f(107.9), 384, 216,
                                      False, "notAvailable", False), b""),
    ]


def _control() -> list[dict]:
    return [
        wire.hello("A1B2-C3", "iPhone15,2", "18.1", 1920, 1080, 60),
        wire.hello_ack(2),
        wire.ping(7, 100.25),
        wire.pong(7, 100.25, 5000.5, 5000.5001),
        wire.status(0.8, "fair", "limited", 59.9, False),
        wire.ack("set_camera_settings", False, "device busy"),
        wire.set_camera_settings(True, iso=200.0, shutter=0.008333333333333333, wb_temperature=5200.0, wb_tint=-3.0),
        wire.set_camera_settings(False),
        wire.start_recording("session_2026-11-17_cam0", -4321.5),
        wire.stop_recording(),
    ]


def _session() -> tuple[dict, list[dict]]:
    K = Intrinsics(1500.5, 1499.25, 961.3, 538.7, 1920, 1080)
    meta = {"format_version": 1, "kind": "clip", "device_model": "iPhone15,2", "os_version": "18.1", "camera_id": 1,
            "video_format": {"width": 1920, "height": 1080, "fps": 60.0},
            "camera_settings": {"locked": True, "iso": 100.0, "shutter": 0.008333333333333333,
                                "wb_temperature": 5000.0, "wb_tint": 0.0},
            "floor_y": -1.32, "clock_offset": 1234.5678, "created": "2026-11-17T19:00:00Z"}
    frames = [make_frame(i, 100.0 + i / 60, look_at([0.1 * i, 0.0, 0.0], [0.0, -0.5, -4.0]), K,
                         "limited" if i == 0 else "normal", iso=100.0 if i % 2 == 0 else None, shutter=0.008333333333333333)
              for i in range(5)]
    return meta, frames


def _camera_cases() -> list[dict]:
    cases = []
    for K, c2w in [
        (Intrinsics(1500.5, 1499.25, 961.3, 538.7, 1920, 1080), look_at([1.0, 1.0, 1.0], [0.0, 0.0, -3.0])),
        (Intrinsics(330.0, 331.5, 191.7, 107.9, 384, 216), look_at([-1.8, -0.1, -0.5], [0.0, -0.6, -3.4])),
    ]:
        pts = []
        for u, v, z in [(0.0, 0.0, 1.0), (100.25, 50.75, 2.5), (K.cx, K.cy, 4.0), (K.width - 1.0, K.height - 1.0, 12.0)]:
            pts.append({"u": u, "v": v, "depth": z, "world": [float(x) for x in unproject(u, v, z, K, c2w)]})
        P = projection_matrix(K, 0.05, 50.0)
        cases.append({"intrinsics": _k_json(K), "c2w": c2w_to_list(c2w), "near": 0.05, "far": 50.0,
                      "projection": c2w_to_list(P), "points": pts})
    return cases


def transition_inputs() -> list[dict]:
    K = Intrinsics(1500.0, 1500.0, 960.0, 540.0, 1920, 1080)
    K2 = Intrinsics(3000.0, 3000.0, 980.0, 520.0, 1920, 1080)
    subject = [0.0, 0.0, -4.0]
    cfg = TransitionConfig()
    return [
        {"name": "crossing_axes", "a": Camera(K, look_at([-2.0, 0.2, 0.0], subject)),
         "b": Camera(K, look_at([2.5, -0.1, -1.0], subject)), "floor_y": -1.3, "config": cfg},
        {"name": "zoom_change", "a": Camera(K, look_at([-2.0, 0.2, 0.0], subject)),
         "b": Camera(K2, look_at([2.5, -0.1, -1.0], subject)), "floor_y": None, "config": cfg},
        {"name": "parallel_axes", "a": Camera(K, np.eye(4)),
         "b": Camera(K, look_at([1.0, 0.0, 0.0], [1.0, 0.0, -1.0])), "floor_y": None,
         "config": TransitionConfig(median_scene_depth=2.0)},
        {"name": "floor_guard", "a": Camera(K, look_at([-3.0, -0.6, -3.0], [0.0, 0.3, -3.0])),
         "b": Camera(K, look_at([0.0, -0.6, 0.0], [0.0, 0.3, -3.0])), "floor_y": -1.0, "config": cfg},
        {"name": "behind_fallback", "a": Camera(K, np.eye(4)),
         "b": Camera(K, look_at([2.0, 0.0, -3.0], [4.0, 0.0, -3.0])), "floor_y": None, "config": cfg},
    ]


def _transition_case(inp: dict) -> dict:
    path = TransitionPath(inp["a"], inp["b"], inp["floor_y"], inp["config"])
    samples = []
    for s in S_VALUES:
        c = path.camera_at_progress(s)
        samples.append({"s": s, "c2w": c2w_to_list(c.c2w), "fx": c.K.fx, "fy": c.K.fy, "cx": c.K.cx, "cy": c.K.cy})
    cfg = inp["config"]
    blend = []
    for u in U_VALUES:
        w = blend_weights(u, cfg.fade_fraction)
        blend.append({"u": u, "video_a": w.video_a, "render": w.render, "video_b": w.video_b})
    progress = [{"t": t, "s": path.progress(t)} for t in (0.0, 0.3, 0.6, 0.9, 1.2)]
    return {"name": inp["name"],
            "a": {"intrinsics": _k_json(inp["a"].K), "c2w": c2w_to_list(inp["a"].c2w)},
            "b": {"intrinsics": _k_json(inp["b"].K), "c2w": c2w_to_list(inp["b"].c2w)},
            "floor_y": inp["floor_y"], "config": _cfg_json(cfg),
            "interest_point": [float(x) for x in path.interest], "method": path.method,
            "samples": samples, "blend": blend, "progress": progress}


def _clock() -> dict:
    rng = np.random.default_rng(11)
    true_offset = 1234.5678
    samples = []
    t = 50.0
    for _ in range(12):
        up, down, proc = 0.002 + rng.exponential(0.004), 0.002 + rng.exponential(0.004), rng.uniform(1e-4, 2e-3)
        t2 = t + up - true_offset
        t3 = t2 + proc
        samples.append(ClockSample(t, t2, t3, t3 + true_offset + down))
        t += 1.0
    est = ClockOffsetEstimator(window=10)
    for s in samples:
        est.add(s)
    return {"window": 10, "samples": [s.__dict__ for s in samples], "offsets": [s.offset for s in samples],
            "round_trips": [s.round_trip for s in samples], "estimate": est.offset, "uncertainty": est.uncertainty}


# ----------------------------------------------------------------------------- write


def write_golden(out: Path) -> None:
    out = Path(out)
    (out / "session").mkdir(parents=True, exist_ok=True)
    pk = _packets()
    (out / "packets.bin").write_bytes(wire.PREAMBLE_MEDIA + b"".join(p.encode() for p in pk))
    (out / "packets.json").write_text(_dump({"packets": [dict(p.header.to_json(), payload_hex=p.payload.hex()) for p in pk]}))
    msgs = _control()
    (out / "control.bin").write_bytes(wire.PREAMBLE_CONTROL + b"".join(wire.encode_control(m) for m in msgs))
    (out / "control.json").write_text(_dump({"messages": msgs}))
    meta, frames = _session()
    (out / "session" / "meta.json").write_text(_dump(meta))
    (out / "session" / "frames.jsonl").write_text(encode_frames(frames))
    (out / "camera.json").write_text(_dump({"cases": _camera_cases()}))
    (out / "transition.json").write_text(_dump({"cases": [_transition_case(i) for i in transition_inputs()]}))
    (out / "clock.json").write_text(_dump(_clock()))


# ---------------------------------------------------------------------------- verify


def _close(a, b, tol=TOL) -> bool:
    a = np.asarray(a, float)
    b = np.asarray(b, float)
    return a.shape == b.shape and bool(np.all(np.abs(a - b) <= tol * np.maximum(1, np.abs(b))))


def verify_golden(d: Path) -> list[str]:
    d = Path(d)
    problems: list[str] = []

    # Packets: decode and re-encode byte for byte.
    raw = (d / "packets.bin").read_bytes()
    pre = wire.PreambleReader().feed(raw)
    if pre is None or pre[0] != "media":
        problems.append("packets.bin: bad preamble")
    decoded = wire.MediaStreamParser().feed(pre[1]) if pre else []
    expected = json.loads((d / "packets.json").read_text())["packets"]
    if len(decoded) != len(expected):
        problems.append(f"packets: {len(decoded)} decoded, {len(expected)} expected")
    rebuilt = wire.PREAMBLE_MEDIA
    for k, (p, e) in enumerate(zip(decoded, expected)):
        got = dict(p.header.to_json(), payload_hex=p.payload.hex())
        for key, val in e.items():
            if got.get(key) != val:
                problems.append(f"packet {k}: {key} = {got.get(key)!r}, expected {val!r}")
        h = wire.PacketHeader.from_json(e)
        rebuilt += wire.Packet(h, bytes.fromhex(e["payload_hex"])).encode()
    if rebuilt != raw:
        problems.append("packets: encoding packets.json does not reproduce packets.bin")

    # Control messages: by value.
    raw = (d / "control.bin").read_bytes()
    pre = wire.PreambleReader().feed(raw)
    msgs = wire.ControlStreamParser().feed(pre[1]) if pre and pre[0] == "control" else []
    exp = json.loads((d / "control.json").read_text())["messages"]
    if [wire.normalize_control(m) for m in msgs] != [wire.normalize_control(m) for m in exp]:
        problems.append("control: control.bin does not decode to control.json")

    # Session files.
    meta = json.loads((d / "session" / "meta.json").read_text())
    ref_meta, ref_frames = _session()
    if meta != ref_meta:
        problems.append(f"session/meta.json differs: {meta} != {ref_meta}")
    frames = parse_frames((d / "session" / "frames.jsonl").read_text())
    if len(frames) != len(ref_frames):
        problems.append("session/frames.jsonl: frame count differs")
    for f, r in zip(frames, ref_frames):
        rr = {k: v for k, v in r.items() if v is not None}
        ff = {k: v for k, v in f.items() if v is not None}
        if set(ff) != set(rr):
            problems.append(f"frame {r['i']}: keys {sorted(ff)} != {sorted(rr)}")
            continue
        for k in rr:
            if isinstance(rr[k], (int, float)) and not isinstance(rr[k], bool) or isinstance(rr[k], list):
                if not _close(ff[k], rr[k], 1e-12):
                    problems.append(f"frame {r['i']}: {k} differs")
            elif ff[k] != rr[k]:
                problems.append(f"frame {r['i']}: {k} differs")

    # Camera model.
    for n, c in enumerate(json.loads((d / "camera.json").read_text())["cases"]):
        K = _k_from(c["intrinsics"])
        c2w = c2w_from_list(c["c2w"])
        if not _close(c2w_to_list(projection_matrix(K, c["near"], c["far"])), c["projection"]):
            problems.append(f"camera case {n}: projection matrix differs")
        for p in c["points"]:
            if not _close(unproject(p["u"], p["v"], p["depth"], K, c2w), p["world"]):
                problems.append(f"camera case {n}: unproject {p['u'], p['v']} differs")
            u, v, z = project(np.array(p["world"]), K, c2w)
            if not _close([u, v, z], [p["u"], p["v"], p["depth"]], 1e-8):
                problems.append(f"camera case {n}: project differs")

    # Transition.
    for c in json.loads((d / "transition.json").read_text())["cases"]:
        a = Camera(_k_from(c["a"]["intrinsics"]), c2w_from_list(c["a"]["c2w"]))
        b = Camera(_k_from(c["b"]["intrinsics"]), c2w_from_list(c["b"]["c2w"]))
        path = TransitionPath(a, b, c["floor_y"], _cfg_from(c["config"]))
        if path.method != c["method"] or not _close(path.interest, c["interest_point"]):
            problems.append(f"transition {c['name']}: interest point differs")
        for smp in c["samples"]:
            cam = path.camera_at_progress(smp["s"])
            if not _close(c2w_to_list(cam.c2w), smp["c2w"]):
                problems.append(f"transition {c['name']}: c2w at s={smp['s']} differs")
            if not _close([cam.K.fx, cam.K.fy, cam.K.cx, cam.K.cy], [smp["fx"], smp["fy"], smp["cx"], smp["cy"]]):
                problems.append(f"transition {c['name']}: intrinsics at s={smp['s']} differ")
            if smp["s"] in (0.0, 1.0):
                real = a if smp["s"] == 0.0 else b
                if c2w_to_list(real.c2w) != smp["c2w"]:
                    problems.append(f"transition {c['name']}: endpoint s={smp['s']} is not exact")
        for bl in c["blend"]:
            w = blend_weights(bl["u"], c["config"]["fade_fraction"])
            if not _close([w.video_a, w.render, w.video_b], [bl["video_a"], bl["render"], bl["video_b"]]):
                problems.append(f"transition {c['name']}: blend at u={bl['u']} differs")
        for pr in c["progress"]:
            if not _close(smootherstep(pr["t"] / c["config"]["duration"]), pr["s"]):
                problems.append(f"transition {c['name']}: progress at t={pr['t']} differs")

    # Clock.
    ck = json.loads((d / "clock.json").read_text())
    est = ClockOffsetEstimator(window=ck["window"])
    for k, s in enumerate(ck["samples"]):
        smp = ClockSample(s["t1"], s["t2"], s["t3"], s["t4"])
        est.add(smp)
        if not _close([smp.offset, smp.round_trip], [ck["offsets"][k], ck["round_trips"][k]]):
            problems.append(f"clock sample {k} differs")
    if not _close([est.offset, est.uncertainty], [ck["estimate"], ck["uncertainty"]]):
        problems.append("clock estimate differs")
    return problems


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Write the Python golden files (docs/protocol.md section 6).")
    ap.add_argument("out", nargs="?", type=Path, default=Path(__file__).resolve().parents[2] / "testdata" / "golden" / "from_python")
    a = ap.parse_args(argv)
    write_golden(a.out)
    print(f"wrote {a.out}")
    return 0
