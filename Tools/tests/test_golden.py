"""docs/protocol.md section 6: Swift and Python encode and decode the same packets and session files."""

import shutil

from flycam_tools.golden import verify_golden, write_golden
from tests.conftest import GOLDEN

FILES = ["packets.bin", "packets.json", "control.bin", "control.json", "session/meta.json", "session/frames.jsonl",
         "camera.json", "transition.json", "clock.json"]


def test_swift_golden_files_verify_in_python():
    d = GOLDEN / "from_swift"
    assert (d / "packets.bin").exists(), "run `swift run flycam-golden` in Packages/FlyCamKit"
    assert verify_golden(d) == []


def test_python_golden_files_verify_in_python():
    assert verify_golden(GOLDEN / "from_python") == []


def test_python_golden_files_are_up_to_date(tmp_path):
    write_golden(tmp_path)
    for f in FILES:
        assert (tmp_path / f).read_bytes() == (GOLDEN / "from_python" / f).read_bytes(), f"{f} is stale: run make_golden.py"


def test_verifier_detects_corruption(tmp_path):
    shutil.copytree(GOLDEN / "from_swift", tmp_path / "g")
    d = tmp_path / "g"
    b = bytearray((d / "packets.bin").read_bytes())
    b[4 + 12] ^= 1  # first packet's timestamp
    (d / "packets.bin").write_bytes(bytes(b))
    t = (d / "transition.json").read_text().replace('"axes_midpoint"', '"median_depth"')
    (d / "transition.json").write_text(t)
    problems = verify_golden(d)
    assert any("timestamp" in p for p in problems), problems
    assert any("interest point" in p for p in problems), problems


def test_both_sets_cover_every_message_and_tracking_state():
    import json

    for side in ("from_python", "from_swift"):
        msgs = json.loads((GOLDEN / side / "control.json").read_text())["messages"]
        types = {m["type"] for m in msgs}
        assert {"hello", "hello_ack", "ping", "pong", "status", "ack", "set_camera_settings", "start_recording",
                "stop_recording"} <= types, side
        packets = json.loads((GOLDEN / side / "packets.json").read_text())["packets"]
        assert any(p["keyframe"] for p in packets) and any(not p["keyframe"] for p in packets)
    trackings = set()
    for side in ("from_python", "from_swift"):
        trackings |= {p["tracking"] for p in json.loads((GOLDEN / side / "packets.json").read_text())["packets"]}
    assert trackings == {"normal", "limited", "notAvailable"}
