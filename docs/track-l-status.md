# Track L status

Track L is the part of plan.md that can be built and verified in a Linux container
(no iPhone, no Mac, no real room). Progress is tracked here; plan.md is not edited.

Toolchain used: Swift 6.4.2 (swift.org release for Ubuntu 26.04), Python 3.12 via uv, PyAV 19 (FFmpeg with libx265/libx264), OpenCV 5.1.

| # | Scope item | Status | Notes |
|---|---|---|---|
| 1 | Packages/FlyCamKit: pure-Swift core | done | see below |
| 2 | Tools/ Python tools | done | see below |
| 3 | Tools/simulator | done | see below |
| 4 | Tools/prototype | done | see below |
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

## 3. Simulator

- `Tools/simulator/fake_phone.py`: plays a session folder like CaptureApp in live mode: control connection
  (hello, pong with its own clock, acks, status every second), media connection with one packet per frame
  (header from frames.jsonl, HEVC access unit from video.mov with VPS/SPS/PPS on keyframes), real-time pacing.
- `Tools/simulator/receiver.py`: reference Mac side: one port, preamble dispatch, camera id assignment
  (stable per device id), 10 pings at connect then 1/s, min-RTT offset, low-delay HEVC decode, Mac-time frame store,
  nearest-frame pairing. Rejects bad preambles and media before hello without stopping.
- `Tools/src/flycam_tools/hevc.py`: access units from `.mov`, hvcC parsing, wire payload decoder.
- `Tools/tests/test_simulator.py` (localhost, two phones with clock offsets -4000 s and +1234.5 s):
  all frames in order, decoded frames bit-identical to the file, poses equal frames.jsonl at float32 precision,
  offset estimate within 2 ms of truth (measured: about 0.01 ms), latency = simulated 30 ms capture delay +-5 ms,
  pairing within half a frame interval, set_camera_settings / start_recording / stop_recording acknowledged,
  start_recording carries the offset estimate. Ran 6 times in a row without a failure.

Not covered here: Wi-Fi behaviour, Bonjour discovery, VideoToolbox encoder settings, real latency and
sync numbers (docs/manual-tests.md, Phase 5).

## 4. Prototype

`Tools/prototype/transition.py` (`uv run python -m prototype.transition out/synth --out out/prototype`)
renders a take from cam0 to cam1 on a synthetic dataset and writes `transition_<mode>.mp4` (H.264) plus a
per-frame JSON (time, u, s, blend weights, virtual c2w) for three modes:

- `static`: static scene only (Phase 4). The analytic scene without the person stands in for the splat.
- `billboard`: Phase 6. Floor-contact anchor, vertical plane facing the virtual camera, projective texture from
  the source frame and feathered matte, depth test against the static depth, A weighted 1 - s, B weighted s.
- `gaussians`: Phase 7. Monocular depth aligned per frame to the static depth (RANSAC + Huber, smoothed),
  anchor check against floor contact (15 %), one point per 2 x 2 pixels, discontinuities dropped,
  opaque discs with z-buffer, inflated up to 1.4x in mid-flight.

The path is rebuilt each frame from the latest poses using the same algorithm as FlyCamKit. Inputs are what
the Mac would have: the decoded HEVC video, person masks (in place of Vision), and the simulated monocular
depth (in place of Depth Anything).

Measured (test dataset, 384x216). The thresholds are stated in `tests/test_prototype.py`:

| Check | Threshold | Measured |
|---|---|---|
| render vs. source frame at s = 0 / s = 1, billboard | >= 33 dB | 34.99 / 35.26 dB |
| same, Gaussians | >= 28 dB | 30.24 / 30.45 dB |
| same, static (background pixels) | >= 33 dB | 35.06 / 35.48 dB |
| program output before take / after landing | identical to video | identical |
| MP4 frames at take and landing vs. source | >= 35 dB | passes |
| person bottom edge vs. ground truth during flight | <= 4 px | 0-2 px |
| silhouette IoU vs. ground truth, Gaussians / billboards | >= 0.75 and > billboards + 0.1 | 0.85 / 0.64 (mean) |
| depth anchor check agrees | >= 90 % of frames | 71 / 71 |

Decisions:

- People layers for Gaussians use a coverage-normalised blend (colour = sum(w a c) / sum(w a), alpha = max(w a) / max(w)).
  Each camera only sees one side of a person, and the plain (1 - s, s) sum showed two half-transparent halves
  at mid-flight. Billboards keep the plain weighted sum because the union doubled their outline. Both blends are
  exact at s = 0 and s = 1.
- In the synthetic data the monocular depth scale now drifts slowly over time. With a large per-frame change,
  smoothing a and b (as Phase 7 asks) produced wrong depth.
- Flight times within 1 us of 0 or T are snapped, so timestamp rounding cannot turn the landing frame into a mix.
