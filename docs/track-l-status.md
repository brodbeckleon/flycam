# Track L status

Track L is the part of plan.md that can be built and verified in a Linux container
(no iPhone, no Mac, no real room). Progress is tracked here; plan.md is not edited.

Toolchain used: Swift 6.4.2 (swift.org release for Ubuntu 26.04), Python 3.12 via uv, PyAV 19 (FFmpeg with libx265/libx264), OpenCV 5.1.

| # | Scope item | Status | Notes |
|---|---|---|---|
| 1 | Packages/FlyCamKit: pure-Swift core | done | see below |
| 2 | Tools/ Python tools | in progress | |
| 3 | Tools/simulator | todo | |
| 4 | Tools/prototype | todo | |
| 5 | Golden files Swift <-> Python | todo | |
| 6 | docs/protocol.md, docs/manual-tests.md | in progress | protocol.md written |

## 1. FlyCamKit

Builds on Linux with Foundation only (no simd, ARKit, Metal, ...). Contents:

- `Math/`: `Vec2`, `Vec3`, `Vec4`, `Mat3`, `Mat4` (column-major like simd), `Quat` (Hamilton, slerp), `slerpDirection`.
- `Camera/PinholeCamera.swift`: `Intrinsics`, `project`, `unproject`, `rayDirection`, Metal projection matrix from fx, fy, cx, cy (off-centre frustum, z in [0, 1]).
- `Transition/TransitionPath.swift`: interest point with fallbacks, orbit position, rotation slerp, log-space focal length, floor guard, smootherstep, video/render blend weights, people weights. Endpoints are exact.
- `Wire/`: media packet header (110 bytes), HEVC length-prefixed payload helpers, control messages (JSON), channel preambles, incremental stream parsers.
- `Clock/ClockOffsetEstimator.swift`: four-timestamp samples, minimum-round-trip estimate over a window.
- `FrameStore/FrameStore.swift`: per-camera ring buffers keyed by Mac time, nearest-frame pairing, residual.
- `Session/Session.swift`: `meta.json`, `frames.jsonl` (reader, writer, streaming writer), `pose_override.json`, validation.

Tests: 50 XCTest cases, including the three unit tests required by plan.md section 5
(project/unproject round trip, matrix serialisation round trip, clock offset estimation on synthetic data).
