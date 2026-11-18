# Manual tests (Mac, iPhone, real room)

What Track L cannot verify in a Linux container, phase by phase. Each test says what to do,
what counts as a pass, and which container tool helps. Write every measurement to
`docs/log.md` with the date (plan.md "How to use this plan"). The "Done when" checks in
plan.md are only ticked after the matching tests here pass.

Already verified in the container (`docs/track-l-status.md`): the math and conventions,
wire formats, clock estimation, frame pairing, the session tools, pose refinement, depth
alignment, floor placement and the transition reference, all on synthetic data with ground
truth. They are **not** verified against ARKit, VideoToolbox, Metal, Vision, Core ML,
Network.framework, Wi-Fi or a real room.

Conventions used below: `Tools$` means run in `Tools/` with `uv run python ...`.

## Before Phase 0: toolchain

| # | Test | Pass |
|---|---|---|
| T-1 | `cd Packages/FlyCamKit && swift test` on the Mac (Xcode toolchain) | all tests pass, same as on Linux |
| T-2 | Add `FlyCamKit` to both app targets (iOS 18, macOS 15) and build | builds without warnings about missing platforms |
| T-3 | `Tools$ uv run pytest` on the Mac | all tests pass (checks PyAV/OpenCV wheels on macOS) |

## Phase 0: skeleton and feasibility

| # | Test | Pass |
|---|---|---|
| 0-1 | DirectorApp renders a sample `.ply` splat with MetalSplatter, orbit with the mouse | 60 fps at window size 1920x1080 (Metal HUD or Instruments); note the Mac model |
| 0-2 | Projection matrix from `PinholeCamera.projectionMatrix(near:far:)` (convert `Mat4` to `simd_float4x4` column by column) | Render a 3D marker at a point P and draw a 2D cross at `project(P)`: they coincide within 1 px, also with cx, cy off-centre by about 50 px |
| 0-3 | **Verify** that MetalSplatter writes depth that a later pass can read | Read back the depth texture; linearise it with near and far; the depth at a known splat point matches its distance along the view axis within 1 % |
| 0-4 | CaptureApp: world tracking, preview, pose, tracking state, thermal state, screen stays awake | Moving the phone 1 m forward changes the reported position by about 1 m along -Z of the camera; tracking reads `normal` |
| 0-5 | Log `supportedVideoFormats` per phone model | List in `docs/log.md`, mark the 16:9 60 fps format |

## Phase 1: capture app, recording

| # | Test | Pass |
|---|---|---|
| 1-1 | Lock exposure, white balance and focus; film a bright and a dark area | ISO, shutter and white balance in `frames.jsonl` stay constant; no visible brightness change |
| 1-2 | Record 30 s handheld, export, `Tools$ inspect_session.py <session>` | `OK`; frame count of `video.mov` equals the line count of `frames.jsonl`; timestamps increasing; `trajectory.png` matches the walk (walk a measured 2 m line: path length about 2 m) |
| 1-3 | Check that `frames.jsonl` is written with `FramesWriter` / `FrameRecord` from FlyCamKit | the file passes `Tools$ inspect_session.py` without warnings |
| 1-4 | **Verify** the timebase of `ARFrame.timestamp`: log `CACurrentMediaTime()` next to `ARFrame.timestamp` in the session delegate | the difference is a constant small delay (< 50 ms) and does not drift over 5 minutes; otherwise convert before stamping |
| 1-5 | Scan mode: frame selection by 10 cm / 8 degrees, floor plane, world map, `points.ply` | `inspect_session.py` OK on the scan; `meta.json` has `floor_y`; `points.ply` opens in a viewer and lies on the room surfaces; `worldmap.bin` exists |
| 1-6 | Phone orientation: mount in landscape, check that the first image of the scan is upright as stored | upright; no rotation anywhere in the pipeline |

## Phase 2: static scene splat

| # | Test | Pass |
|---|---|---|
| 2-1 | `Tools$ session_to_nerfstudio.py <scan> <out>` and train with Brush | training converges; note the time and the Gaussian count |
| 2-2 | **Verify** that Brush does not re-centre, re-scale or re-orient the scene | Load the exported splat in DirectorApp and render from the pose of scan frame 0: the image matches the photo (next test). If it is off by a constant transform, apply the inverse and log it |
| 2-3 | DirectorApp overlay of the splat at 50 % on each scan photo | static edges coincide visually across the scan |
| 2-4 | Export renders from the stored poses to `renders/<i:05d>.png` (same size as the photos), then `Tools$ reprojection_check.py <scan> renders/` | median offset at or below about 3 px at 1080p (plan "Done when"); log the value |
| 2-5 | Splat frame rate | 60 fps after cleaning, at or below about 1.5 M Gaussians |
| 2-6 | Half-pixel convention: in the overlay, a constant 0.5 px offset in u and v points to a pixel-centre mismatch (docs/protocol.md 1.2) | no constant 0.5 px offset |

Fallback if 2-4 fails: COLMAP poses plus similarity alignment (plan Phase 2).

## Phase 3: phones in the scan's frame

| # | Test | Pass |
|---|---|---|
| 3-1 | CaptureApp loads `worldmap.bin` as `initialWorldMap`, relocalises handheld, then goes on the tripod | relocalisation within 30 s; log the time per phone |
| 3-2 | DirectorApp overlay of the splat from the reported pose on the live video | static edges visibly close |
| 3-3 | DirectorApp exports render colour (`.png`) and depth (`.f32`, raw little-endian float32, H x W, depth along the view axis in metres, 0 where empty) for the reported pose of frame N; `Tools$ refine_pose.py <clip> --frame N --render-color c.png --render-depth d.f32` | `pose_override.json` written; inliers > 100; median reprojection < 1 px |
| 3-4 | Overlay with the refined, frozen pose | static edges within about 3 px, and still after 10 minutes (plan "Done when") |
| 3-5 | Per-camera colour match | after applying gain and 3x3 matrix, mean colour difference on static pixels < 3 grey levels |

## Phase 4: static fly-through with recorded clips (M1)

| # | Test | Pass |
|---|---|---|
| 4-1 | DirectorApp uses `TransitionPath` from FlyCamKit; compare with the reference: `Tools$ uv run python -m prototype.transition <synthetic dataset>` | same path shape. Golden values in `Tools/testdata/golden/*/transition.json` are already identical in Swift and Python |
| 4-2 | Switch between two recorded clips of the static room | one continuous move, no visible jump at start or end, 60 fps (plan "Done when"). Record the screen and step through the frames around the take and the landing |
| 4-3 | First and last transition frames | the virtual camera equals the real camera exactly (FlyCamKit returns the input cameras at s = 0 and 1), so the cross-fade shows no shift. Check visually at 200 % zoom |
| 4-4 | Floor guard with a low tripod | the flight never goes below 0.3 m above the floor (log the minimum height) |

## Phase 5: live streaming and sync (M2)

| # | Test | Pass |
|---|---|---|
| 5-1 | Discovery: `_flycam._tcp`, `NSLocalNetworkUsageDescription`, `NSBonjourServices` | phone finds the Mac without typing an address; local network permission prompt appears once |
| 5-2 | Interop with the reference implementation: run `Tools$ uv run python -m simulator.receiver --port 7777` on the Mac and point CaptureApp at it | receiver prints frames, offset and latency per camera; no decode errors |
| 5-3 | Interop the other way: `Tools$ uv run python -m simulator.fake_phone <synthetic clip> --host <mac> --port <port>` against DirectorApp | DirectorApp shows the clip, poses match the synthetic `frames.jsonl` |
| 5-4 | VideoToolbox encoder output: dump one keyframe packet from CaptureApp and decode it with `flycam_tools.wire.Packet.decode` and `flycam_tools.hevc.Decoder` | VPS, SPS, PPS first (flag bit 3 set), NAL lengths 4-byte big-endian, decodes to an image |
| 5-5 | 15 minutes of two phones at 1080p, 30 fps or more | no stalls (log frame gaps > 100 ms), thermal state stays below `serious` |
| 5-6 | Latency: phone films a millisecond timer on the Mac screen next to its live window | below 250 ms (plan "Done when"); log the median of 10 photos |
| 5-7 | Sync: both phones film the same timer; compare the Mac timestamps of frames showing the same value | below 20 ms (plan "Done when"); also log the receiver's offset uncertainty (half the best round trip) |
| 5-8 | Push exposure and white balance from one phone to all | ack from every phone; images match in brightness |
| 5-9 | Mac-triggered recording on all phones | sessions contain `clock_offset` in `meta.json`; `inspect_session.py` OK on each |
| 5-10 | Record reference sessions R1 to R4 (plan Phase 5) | stored under `Data/`, listed in `docs/log.md` |

## Phase 6: people as billboards

| # | Test | Pass |
|---|---|---|
| 6-1 | Vision person segmentation, balanced quality, instance masks | masks cover the person; log the time per frame on the Mac |
| 6-2 | Floor contact (`flycam_tools.placement` is the reference) vs. ARKit `personSegmentationWithDepth` on R2 | log both positions for 10 frames; keep the more stable one |
| 6-3 | Billboards on R2 and live | a standing or slowly walking person stays on the floor without sliding during the flight and does not pop at start or end (plan "Done when") |
| 6-4 | Association between cameras on R3 | the two people are matched correctly in each camera when they are more than 0.5 m apart |

## Phase 7: people as depth Gaussians (M3)

| # | Test | Pass |
|---|---|---|
| 7-1 | Core ML Depth Anything V2 Small, F16: time per inference on the target Mac | log it; decides the time budget option in plan Phase 7 |
| 7-2 | Depth alignment on R2: the person's metric depth vs. the floor-contact anchor | agree within 15 % in most frames (the reference prototype agrees in all frames on synthetic data) |
| 7-3 | R2 and R3 side by side with Phase 6 | limbs separate visibly in depth, no back-and-forth from depth flicker, transition at 25 fps or more (plan "Done when") |
| 7-4 | Blend of A and B people | no half-transparent double person in mid-flight. The prototype uses a coverage-normalised blend for this (`Tools/prototype/layers.py`); compare |

## Phase 8: moving phones

| # | Test | Pass |
|---|---|---|
| 8-1 | Flight from a tripod phone to a slowly moving handheld phone (R4 and live) | lands in the live picture without a jump (plan "Done when"); the path is rebuilt every frame with B's latest pose |
| 8-2 | Drift monitor | the warning appears when the phone is pushed by 2 cm and not otherwise |

## Phase 9: more than two phones (M4)

| # | Test | Pass |
|---|---|---|
| 9-1 | Four phones connected | each gets its own camera id; the receiver's frame store pairs all four |
| 9-2 | Any-to-any transitions | every pair works; distant pairs use intermediate knots |
| 9-3 | Load control | segmentation and depth only run for preview and program cameras (check in Instruments) |
