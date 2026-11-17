# Track L status

Track L is the part of plan.md that can be built and verified in a Linux container
(no iPhone, no Mac, no real room). Progress is tracked here; plan.md is not edited.

Toolchain used: Swift 6.4.2 (swift.org release for Ubuntu 26.04), Python 3.12 via uv, PyAV 19 (FFmpeg with libx265/libx264), OpenCV 5.1.

| # | Scope item | Status | Notes |
|---|---|---|---|
| 1 | Packages/FlyCamKit: pure-Swift core | done | see below |
| 2 | Tools/ Python tools | done | see below |
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

## 2. Tools (Python)

uv project in `Tools/`, library in `Tools/src/flycam_tools/`, CLI wrappers named as in plan.md.

| Item | Module | Verified by (ground truth, tolerance) |
|---|---|---|
| Synthetic session generator | `scene.py`, `synth.py` | `tests/test_synth.py`: floor pixels unproject to y = floor (1 mm), person mask/depth consistent, video vs. render > 30 dB, mono-depth affine < 2 % median |
| inspect_session | `inspection.py` | handheld path length equals ground truth (1e-6 rel.), detects missing line, non-monotonic t, non-rigid c2w, bad index, gaps |
| session_to_nerfstudio | `nerfstudio.py` | `transform_matrix` rows equal c2w exactly, world frame unchanged (point cloud visible), limited-tracking frames skipped |
| reprojection_check | `reprojection.py` | exact poses: median offset < 0.3 px; 0.5 deg yaw error: offset = fx tan(0.5 deg) +-20 % |
| refine_pose | `refine.py` | reported pose off by 0.6 deg / 3 cm, real frame = HEVC frame with person: recovered within 0.05 deg and 1 cm on both cameras |
| Depth alignment (Phase 7) | `depth_align.py` | a within 2 %, person metric depth < 3 % median error, exact under 30 % outliers |
| Floor-contact placement (Phase 6) | `placement.py` | contact point on the floor, within radius + 6 cm of the true foot centre on all three cameras, association across cameras |

Decisions taken while building (also in code comments):

- SIFT contrast threshold 0.02 instead of OpenCV's 0.04: the default found only about 40 keypoints per 384x216 frame.
- PnP RANSAC threshold 1 px: at 2 px the rotation error was 0.055 deg on cam0, at 1 px 0.02-0.03 deg on both cameras.
- Render depth exchange format for the DirectorApp: raw little-endian float32 `.f32`, H x W, depth along the viewing axis (documented in `refine.py`).
