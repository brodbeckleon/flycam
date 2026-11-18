# Track M: manual tests on the iPhones and in the room

What the Track M code cannot verify on this Mac by itself: everything that needs an iPhone, the access point or the
real room. Per phase: what to do with the Track M apps and tools, and what counts as a pass. Write every
measurement to `docs/log.md` with the date. Track L's `docs/manual-tests.md` has the general tests per phase
(and the Python tool side); the IDs in brackets refer to it where a test here carries one out.

Already verified on the Mac by `scripts/test_mac.sh` (generated fixtures, offscreen, localhost), so not repeated here:
projection with an off-centre principal point (< 1 px), splat depth readback (< 2 %), recorded-session decoding by
timestamp, transition endpoints (> 35 dB) and mid-flight splat, encode/packetise/send/decode over localhost with
intact headers and timestamps, clock offset estimation, control messages, the phone-side logic (keyframe rule, floor
choice, points.ply, recorder). Not verified there: ARKit, the camera hardware, Wi-Fi, Bonjour between devices, real
splats, real rooms, frame rates at 1080p.

## Setup (once)

| # | Step | Pass |
|---|---|---|
| S-1 | `brew install xcodegen` (if missing), `scripts/generate.sh`, open `Apps/FlyCam.xcodeproj`, set your team for CaptureApp, install on each iPhone from Xcode (Track M never installs on a device) | app starts in landscape, asks for camera and local network access |
| S-2 | `scripts/build_mac.sh`, start `Apps/.build/DerivedData/Build/Products/Debug/DirectorApp.app` | window opens; sidebar shows "listening on port …, Bonjour _flycam._tcp"; macOS asks for local network access, allow it |
| S-3 | Optional: install the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) and point project.yml back at upstream MetalSplatter 1.0.1 (`Apps/Vendor/MetalSplatter/VENDORED.md`) | `scripts/test_mac.sh` still passes |

## Phase 0: skeleton and feasibility

| # | Test | Pass |
|---|---|---|
| M0-1 (0-1) | DirectorApp: "Load splat…" with a real splat (or `director-cli make-fixture /tmp/fx` and load `/tmp/fx/splat.ply`), tab "Splat viewer", drag to orbit, scroll to zoom | renders and orbits smoothly; measure fps with the Metal HUD (`MTL_HUD_ENABLED=1`) at 1920x1080: 60 fps. Log Mac model and splat size |
| M0-2 (0-2) | Splat viewer uses fx 1400, cx 975, cy 530 (off-centre). Compare with `director-cli render-frame` of the same pose | identical image (automated equivalent passed at < 0.01 px) |
| M0-3 (0-4) | CaptureApp on each phone: preview, pose line, tracking, thermal, screen stays awake for 5 min | moving the phone 1 m forward changes "pos" by about 1 m along "fwd"; tracking `normal`; display never sleeps |
| M0-4 (0-5) | CaptureApp "Camera…" sheet lists the supported video formats | copy the list per phone model to `docs/log.md`; the header line shows the chosen format (16:9, 60 fps if offered) |

## Phase 1: capture app, recording

| # | Test | Pass |
|---|---|---|
| M1-1 (1-1) | "Lock camera", then film a bright and a dark area; also "Camera…" with manual ISO 200, 1/120 s, 5000 K, "Apply and lock" | the image brightness does not change; `meta.json` `camera_settings.locked` is true with the values; `frames.jsonl` `iso`/`shutter` constant |
| M1-2 (1-2) | Mode "Clip", "Record", walk a measured 2 m line for 30 s, "Stop"; "Sessions" → "Export" (AirDrop to the Mac); then `director-cli inspect <session>` and `Tools$ inspect_session.py <session>` | inspect shows video frames = frames.jsonl lines; inspect_session OK, path length about 2 m |
| M1-3 | `director-cli render-transition <session> <session> <any splat> --out t.mp4 --pre 1 --post 1` on that real session | runs; first frame of `t.mp4` looks like the recording (decoding of real phone HEVC works) |
| M1-4 (1-4) | Watch "now - frame.timestamp" in the overlay for 5 min | constant small value (< 50 ms) without drift; log it. If it drifts, ARFrame.timestamp is not CACurrentMediaTime and streaming must convert |
| M1-5 (1-5) | Mode "Scan", "Start scan", two or three slow loops; watch "stills" and "floor y"; "Stop" (keep moving until "mapped") | message "Scan saved … N points"; folder has `images/`, `frames.jsonl`, `meta.json` with `floor_y`, `worldmap.bin`, `points.ply`; stills only when moved 10 cm / 8 degrees, none during fast turns (check timestamps in frames.jsonl against the motion) |
| M1-6 | Open `points.ply` in a viewer (e.g. MeshLab) | points lie on the room surfaces, floor at `floor_y` |
| M1-7 (1-6) | First still of the scan, phone in landscape (home indicator right) | image upright, no rotation |

## Phase 2: static scene splat (Track M side)

| # | Test | Pass |
|---|---|---|
| M2-1 (2-2, 2-3) | Train with Brush (Track L tools), load the splat in DirectorApp; `director-cli render-frame <splat> <scan> --frame 0 --out r.png` and compare with `images/00000.jpg` at 50 % | static edges coincide; log any constant offset |
| M2-2 (2-4) | For every 10th still: `director-cli render-frame <splat> <scan> --frame i --out renders/<i:05d>.png`, then `Tools$ reprojection_check.py` | median <= 3 px at 1080p |

## Phase 3: phones in the scan's frame

| # | Test | Pass |
|---|---|---|
| M3-1 (3-1) | Copy the scan session to each phone (AirDrop into Files → On My iPhone → CaptureApp → Sessions, or Finder file sharing). "Sessions" → "Use for live"; look around the scanned area | "relocalisation: relocalised" within 30 s; log the time per phone; then clamp into the tripod |
| M3-2 | Record a 10 s clip per phone in live mode | `meta.json` has the scan's `floor_y` |
| M3-3 (3-3) | `director-cli render-frame <splat> <clip> --frame 0 --out c.png --depth d.f32`, then `Tools$ refine_pose.py <clip> --frame 0 --render-color c.png --render-depth d.f32` | `pose_override.json` written; inliers > 100; median reprojection < 1 px |
| M3-4 (3-4) | Re-render with the override (`render-frame` uses it automatically) and overlay on frame 0 and on a frame 10 min later | static edges within about 3 px |

## Phase 4: static fly-through with recorded clips (M1)

| # | Test | Pass |
|---|---|---|
| M4-1 | `director-cli render-transition <clipA> <clipB> <splat> --out take.mp4`, `director-cli verify-transition <clipA> <clipB> <splat> take.mp4` | verify PASS (endpoints > 35 dB, middle shows the splat); watch `take.mp4`: one continuous move, no jump at take or landing. Clips recorded without the Mac have no clock offset and are aligned by their first frames |
| M4-2 (4-2) | DirectorApp: add both clips, load the splat, select preview, press space | same as M4-1 live in the program view at 60 fps (Metal HUD); log fps during the flight |
| M4-3 (4-4) | Low tripod (camera below 0.3 m above the floor) | `take.mp4.json`: minimum virtual camera height >= floor_y + 0.3 m except near the ends |

## Phase 5: live streaming and sync (M2)

| # | Test | Pass |
|---|---|---|
| M5-1 | DirectorApp running; on each phone "Connect to Mac" | phone shows "streaming as camera N"; DirectorApp lists the phone with offset ± uncertainty (< 5 ms on the AP), frames counting up, battery/thermal/fps |
| M5-2 | Disconnect and reconnect a phone | same camera number again |
| M5-3 | DirectorApp: preview a live camera, space | program switches with a flight between the live pictures |
| M5-4 | Enter ISO/shutter/K/tint read on the reference phone, "Push camera settings to all phones" | all phones show "locked" with the values; brightness matches visually |
| M5-5 | "Record on all phones", 20 s, stop; export all clips | each clip's `meta.json` has `clock_offset`; `director-cli render-transition` between two of them uses time base `macClock` |
| M5-6 | Latency: phone films a millisecond timer on the Mac screen next to DirectorApp's program view; photo of the screen | latency < 250 ms; log it |
| M5-7 | Sync: both phones film the same timer; record on all phones; compare the frames with the same Mac time | sync error < 20 ms; log it |
| M5-8 | 15 min of two phones streaming 1080p | no stalls (frame counters increase steadily), thermal state below serious; log fps and thermal |
| M5-9 | Record R1 (static room), R2 (one person walking), R3 (two people crossing), R4 (one phone handheld) with "Record on all phones" | sessions exported and listed in `docs/log.md` |

Phases 6 to 9 are outside Track M.
