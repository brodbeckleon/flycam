# FlyCam: fly-through transitions between live phone cameras

Working title, rename freely. Several iPhones film the same scene and stream to a Mac. When the operator switches from one phone to another, the picture does not cut: the viewpoint flies through the room from camera A to camera B.

- Status: plan, nothing built yet
- Last updated: 2026-11-17
- Owner: Léon

## How to use this plan

- Work one phase at a time, in order. Each phase ends with a "Done when" check. Do not start the next phase until that check passes or the listed fallback has been taken.
- Tick the checkboxes as tasks are finished and update the status table in section 7.
- Write measurements (latency, sync error, reprojection error, fps) to `docs/log.md` with the date. Later phases refer back to them.
- Items marked **Verify** are assumptions about SDKs or tools. Confirm them against the current documentation before building on them.

## 1. Goal and scope

**What the viewer sees:** the live picture of phone A. The operator selects phone B. Within about one second the viewpoint leaves A, travels through the room and lands exactly in the live picture of phone B.

In scope:

- iOS capture app that streams video plus camera pose and intrinsics
- macOS app that receives all streams, shows the selected one and renders the transitions
- A static 3D model of the scene (Gaussian splat), captured once before the session
- People in the scene, visible during the flight
- Two phones first, then more; tripods first, then handheld

Out of scope for now:

- Android clients
- Free navigation by the viewer (only camera-to-camera flights)
- Full 4D reconstruction of the whole scene per frame
- Any model that needs an NVIDIA GPU in the live path (see Phase 10)

## 2. Fixed decisions

| Topic | Decision | Consequence |
|---|---|---|
| Capture devices | iPhones without LiDAR | ARKit world tracking supplies pose and intrinsics per frame. Depth has to be estimated. |
| Central device | Mac with Apple silicon | Native Swift and Metal. No CUDA, so Core ML and Metal compute for everything live. |
| Mounting | Tripods first, handheld later | Pose is sent with every frame from the start, so moving phones need no protocol change. |
| Scene content | People moving in an otherwise static room | Static/dynamic split, see section 3. |
| Languages | Swift (apps, shared package), Metal (rendering, compute), Python (offline tools) | |
| Minimum OS | iOS 18, macOS 15 | MetalSplatter's package targets these versions. |

## 3. Core idea

The scene is split into three parts that are solved separately.

1. **Static scene.** Scanned once with one phone and trained offline into a Gaussian splat. It supplies everything the live cameras cannot see during the flight (surfaces behind objects, the space between the cameras).
2. **People.** Reconstructed per frame from the live video and placed into the splat. First as flat billboards (Phase 6), then as per-pixel Gaussians from estimated depth (Phase 7).
3. **Transition.** A virtual camera interpolates from A's pose and intrinsics to B's, renders parts 1 and 2, and cross-fades with the real video at both ends.

Design principles:

- Outside a transition the program output is the untouched live video of the selected phone. Reconstructed imagery is on screen for about one second per switch.
- Everything lives in one metric world frame: the ARKit world frame of the scan session.
- Record first, live second. Every processing step runs on recorded sessions through the same interface as live streams, so problems can be replayed.

## 4. Architecture

```
iPhone (CaptureApp)                         Mac (DirectorApp)
-------------------                         -----------------
ARKit session                               Bonjour listener, control channel
  frame + pose + intrinsics                 Clock sync (offset per phone)
  locked exposure / WB / focus     Wi-Fi    HEVC decode -> frame store per phone
VideoToolbox HEVC encoder        ========>  Person pipeline (mask, depth, Gaussians)
Network.framework client                    Static splat renderer (MetalSplatter)
Local recorder (video + metadata)           Virtual camera + transition controller
                                            Compositor -> program output
```

Mac app modules:

- `FrameSource` protocol with two implementations: `RecordedSource` (session folders) and `LiveSource` (network). Everything downstream only sees `FrameSource`.
- `FrameStore`: ring buffer per camera, keyed by Mac time.
- `SceneRenderer`: static splat pass (colour and depth), people pass, video pass, final mix.
- `TransitionController`: camera path, easing, blend weights.
- `PersonPipeline`: segmentation, depth, placement.

## 5. Conventions

Most bugs in this kind of project are convention bugs. These rules apply everywhere.

**World frame.** ARKit world frame of the scan session: right-handed, +Y up (gravity-aligned), metres. The splat, all phone poses and all people are expressed in it.

**Camera pose.** `ARCamera.transform` is camera-to-world (`c2w`), a 4x4 `simd_float4x4` in column-major order. Camera axes: +X right, +Y up, camera looks along -Z, all relative to the native landscape sensor image.

**Images.** `ARFrame.capturedImage` is always in native landscape sensor orientation. Mount phones in landscape so that this image is upright. Never rotate pixel data anywhere in the pipeline.

**Intrinsics.** `ARCamera.intrinsics` gives fx, fy, cx, cy in pixels for `imageResolution`. Pixel origin top-left, u to the right, v down. Intrinsics change slightly with focus, so focus is locked.

**Unprojection** of pixel (u, v) with depth z > 0 along the viewing direction:

```
x_cam =  (u - cx) / fx * z
y_cam = -(v - cy) / fy * z
z_cam = -z
p_world = c2w * (x_cam, y_cam, z_cam, 1)
```

**Projection matrix.** Build the Metal projection matrix from fx, fy, cx, cy (off-centre frustum), not from a FOV angle. Otherwise the principal point offset is lost and overlays are off by several pixels.

**Nerfstudio export.** `transforms.json` uses the OpenGL camera convention (camera looks along -Z, +Y up) and camera-to-world matrices, which matches ARKit. Write `c2w` as four rows (simd is column-major, so transpose when serialising). Do not re-orient the world. **Verify** with the overlay test in Phase 2.

**Time.** Each device stamps with its own monotonic uptime clock. The Mac converts: `t_mac = t_phone + offset_phone`. `ARFrame.timestamp` is expected to share its timebase with `CACurrentMediaTime()` on the phone. **Verify** in Phase 1.

**Unit tests in the shared package:** `project(unproject(u, v, z)) == (u, v)`, matrix serialisation round trip, clock offset estimation on synthetic data.

## 6. Repository layout

```
flycam/
  plan.md
  Packages/FlyCamKit/       shared Swift package (iOS + macOS): types, math, wire protocol, clock sync
  Apps/CaptureApp/          iOS app
  Apps/DirectorApp/         macOS app
  Tools/                    Python scripts (uv project): export, inspection, pose refinement
  Data/                     sessions, scans, splats (git-ignored)
  docs/log.md               measurements and decisions
```

## 7. Phases

| Phase | Title | Size | Milestone | Status |
|---|---|---|---|---|
| 0 | Skeleton and feasibility | S | | todo |
| 1 | Capture app: record posed video | M | | todo |
| 2 | Static scene splat | M | | todo |
| 3 | Phones in the scan's coordinate frame | M | | todo |
| 4 | Static fly-through with recorded clips | M | M1: transition works | todo |
| 5 | Live streaming and sync | L | M2: live | todo |
| 6 | People v1: billboards | M | | todo |
| 7 | People v2: per-pixel depth Gaussians | L | M3: people | todo |
| 8 | Moving phones | M | | todo |
| 9 | More than two phones | M | M4: multi-camera | todo |
| 10 | Stretch and research | open | | todo |

Size: S up to 2 days, M 3 to 5 days, L 1 to 2 weeks of focused work. Rough guesses.

Phases 6 and 7 need synchronised recordings, which Phase 5 provides. Apart from that, live streaming and people are independent.

### Phase 0: Skeleton and feasibility

Goal: both apps build and the two riskiest third-party pieces are proven to work on the target hardware.

- [ ] Create the repository with the layout from section 6 and an Xcode workspace containing both apps and `FlyCamKit`.
- [ ] DirectorApp: add MetalSplatter via Swift Package Manager, load a sample `.ply` splat, orbit camera with mouse.
- [ ] DirectorApp: render the splat with a projection matrix built from explicit fx, fy, cx, cy.
- [ ] **Verify** that MetalSplatter can write depth to a texture we can read in a later pass. If not, plan a fork (MIT licence).
- [ ] CaptureApp: ARKit world-tracking session, camera preview, on-screen pose, tracking state and thermal state. Screen stays awake.
- [ ] List `ARWorldTrackingConfiguration.supportedVideoFormats` on each phone model and note them in `docs/log.md`. Prefer a 16:9 format at 60 fps.
- [ ] Hardware: two tripods with phone clamps, power for the phones, a dedicated 5 GHz access point.

Done when: the Mac renders a sample splat at 60 fps with a custom-intrinsics camera, and the phone shows a live pose that changes plausibly when moved.

### Phase 1: Capture app, record posed video

Goal: a phone can record video together with everything needed to reconstruct where each frame was taken.

- [ ] Lock exposure, white balance and focus through `ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera` (iOS 16 or later). UI: lock button, manual ISO, shutter and white balance values.
- [ ] Recorder: HEVC video via `AVAssetWriter` from `capturedImage`, plus `frames.jsonl` with one line per frame (format in section 8).
- [ ] Scan mode: save still frames when the camera has moved at least 10 cm or 8 degrees since the last saved frame, skip frames taken during fast rotation. Save metadata in the same format.
- [ ] Scan mode: enable horizontal plane detection and store the floor height (largest plane classified as floor) in `meta.json`.
- [ ] Scan mode: at the end, wait for `worldMappingStatus == .mapped`, save the `ARWorldMap` and export its feature points as `points.ply`.
- [ ] Export a session folder to the Mac (share sheet, AirDrop or Files).
- [ ] `Tools/inspect_session.py`: plot camera trajectory, check frame count against metadata lines, check timestamps are monotonic.
- [ ] **Verify** the timebase of `ARFrame.timestamp` against `CACurrentMediaTime()`.

Done when: a 30 second handheld recording opens on the Mac and the plotted trajectory matches how the phone was moved.

### Phase 2: Static scene splat

Goal: a Gaussian splat of the empty scene, in ARKit world coordinates, rendered by the Mac app.

Scan protocol: no people in the scene, lighting as during the later session, exposure and white balance locked, phone in landscape. Two or three slow loops at different heights, 150 to 400 frames. Cover the area between and behind the planned camera positions and include views from near each tripod position.

- [ ] `Tools/session_to_nerfstudio.py`: scan session to `images/`, `transforms.json` (per-frame intrinsics and `c2w`) and the initial point cloud.
- [ ] Train on the Mac with Brush (reads Nerfstudio-format data with existing poses, uses an initial point cloud if present). Alternatives if needed: OpenSplat, msplat, 3D Splat App.
- [ ] **Verify** that the trainer does not re-centre, re-scale or re-orient the scene. If it does, disable that or apply the inverse transform to the exported splat.
- [ ] Clean the splat (crop, remove floaters near the camera positions), for example in SuperSplat. Keep it at or below about 1.5 million Gaussians.
- [ ] DirectorApp debug view: step through the scan frames and overlay the splat render at 50 % on each photo, using the stored pose and intrinsics.
- [ ] `Tools/reprojection_check.py`: feature-match photo and render for 20 frames, report the median pixel offset.

Done when: the overlay aligns within about 3 px at 1080p across the scan, and the splat renders at 60 fps on the Mac.

Fallback if ARKit poses give a blurry splat: run COLMAP on the scan images, train from the COLMAP poses, then align the COLMAP frame to the ARKit frame with a similarity transform fitted on the camera centres. The splat must end up in ARKit world coordinates either way.

### Phase 3: Phones in the scan's coordinate frame

Goal: every live phone reports its pose in the same world frame as the splat, accurately enough for a seamless cross-fade.

- [ ] CaptureApp live mode: load the scan's `ARWorldMap` as `initialWorldMap`, show relocalisation state. Relocalise handheld by looking around the scene, then clamp the phone into the tripod.
- [ ] Record a short clip per phone with the Phase 1 recorder.
- [ ] DirectorApp: overlay the splat render from the phone's reported pose on its video.
- [ ] Pose refinement for fixed phones (expected to be necessary: at f of about 1500 px an error of 0.2 degrees is already 5 px). DirectorApp exports render colour and depth for the reported pose. `Tools/refine_pose.py` matches features between the real frame and the render, lifts the render keypoints to 3D with the render depth and solves PnP with RANSAC. Result goes to `pose_override.json`.
- [ ] For fixed phones, freeze the refined pose. Do not use the per-frame ARKit pose, it jitters by millimetres.
- [ ] Per-camera colour match: fit a gain and 3x3 colour matrix between splat render and video on static pixels, once.

Done when: for both phones, static edges in the overlay align within about 3 px and stay there for 10 minutes.

Fallbacks if relocalisation is unreliable (few features, changed lighting): a printed fiducial visible during the scan and from each phone, or registering one frame per phone into the scan with COLMAP.

### Phase 4: Static fly-through with recorded clips (Milestone 1)

Goal: the transition itself, without people and without networking.

- [ ] `FrameSource` protocol and `RecordedSource`.
- [ ] Program view: full-screen video of the selected camera.
- [ ] Preview/program workflow: the operator first selects the next camera (preview), then triggers the take. Later phases use the preview selection to warm up processing for exactly two cameras.
- [ ] Transition controller, duration T (default 1.2 s), eased parameter s from 0 to 1 (smootherstep):
  - Interest point P: midpoint of the shortest segment between the two optical axes. If the axes are nearly parallel or P is behind a camera or further than 20 m, use a point at the median scene depth.
  - Position: orbit around P. Interpolate the distance to P linearly and the direction from P by slerp. This gives an arc instead of a straight line through the subject.
  - Rotation: quaternion slerp between the two real orientations.
  - Intrinsics: focal length interpolated in log space, principal point linearly.
  - Guard: keep the camera at least 0.3 m above the floor.
- [ ] Blend: video A to render during the first 15 % of T, render to video B during the last 15 %. At s = 0 and s = 1 the virtual camera equals the real camera exactly.
- [ ] Optional polish: slight directional blur in the middle of the flight.

Done when: switching between two recorded clips of the static scene shows one continuous move with no visible jump at the start or the end, at 60 fps.

### Phase 5: Live streaming and sync (Milestone 2)

Goal: the same result with live phones, plus synchronised recording for the later phases.

- [ ] Discovery: the Mac advertises `_flycam._tcp` with `NWListener`, phones find it with `NWBrowser`. Add `NSLocalNetworkUsageDescription` and `NSBonjourServices` to the iOS app.
- [ ] Control channel (TCP, length-prefixed JSON): hello, clock ping/pong, set camera settings, start/stop recording, status (battery, thermal state, tracking state).
- [ ] Media channel: start with TCP and length-prefixed packets. Move to QUIC or UDP only if latency measurements require it.
- [ ] Encoder: `VTCompressionSession`, HEVC, real-time mode, frame reordering off, keyframe every 1 to 2 s, 10 to 20 Mbit/s at 1080p. Input is `capturedImage` directly.
- [ ] Packet per frame: header (section 8) plus NAL units, parameter sets with every keyframe.
- [ ] Mac: `VTDecompressionSession` to Metal-compatible pixel buffers, `CVMetalTextureCache` to textures.
- [ ] Clock sync: four-timestamp exchange (NTP style), 10 pings at connect, then one per second. Use the offset from the sample with the smallest round trip.
- [ ] Frame store: ring buffer of about 0.5 s per phone. Render time is now minus a playout delay (start with 150 ms). For each display refresh take the frame nearest to render time from each phone and log the residual time difference between cameras.
- [ ] `LiveSource` implementing `FrameSource`.
- [ ] Push one phone's locked exposure and white balance to all phones.
- [ ] Mac-triggered synchronised local recording on all phones, clock offsets written to `meta.json`.
- [ ] Record the reference sessions: R1 static room, R2 one person walking, R3 two people crossing, R4 one phone handheld.

Measurements:

- Latency: the phone films a millisecond timer on the Mac screen next to its own live stream window. A photo of the screen shows both values.
- Sync: both phones film the same millisecond timer. Compare the Mac timestamps of the frames that show the same value.

Done when: two phones stream 1080p at 30 fps or more for 15 minutes without stalls, latency is below 250 ms, inter-camera sync error is below 20 ms, and the Phase 4 fly-through works live.

Notes: phones are not genlocked, so nearest-frame pairing leaves up to half a frame interval (17 ms at 30 fps, 8 ms at 60 fps). Capture at 60 fps if the phones stay cool enough. If Wi-Fi is unstable, use USB-C Ethernet adapters.

### Phase 6: People v1, billboards

Goal: people stay visible and anchored during the flight. Flat, but robust.

- [ ] Person segmentation on the Mac with Vision (person segmentation request at balanced quality, instance masks when there is more than one person). Feather the matte edge.
- [ ] Placement option A, floor contact: bottom centre of the mask, ray through that pixel, intersect with the floor plane from the scan.
- [ ] Placement option B, ARKit people occlusion: enable `personSegmentationWithDepth` on the phone and send the low-resolution `segmentationBuffer` and `estimatedDepthData` as a side channel. Use the median depth over the mask. Compare with option A on R2 and keep the better one, or A with B as fallback when the feet are not visible.
- [ ] Billboard: vertical quad at the person's position, rotated about the vertical axis towards the virtual camera, sized so that it reprojects exactly onto the mask's bounding box in the source camera, textured with the source frame and the matte.
- [ ] Association between cameras: match people by floor position (closer than 0.5 m).
- [ ] During the flight draw billboard A with weight 1 - s and billboard B with weight s at the shared position.
- [ ] Compositing: static splat first (colour and depth), then billboards with depth test against the splat depth and alpha blending.

Done when: on R2 and live, a person standing or walking slowly stays on the floor without sliding during the flight and does not pop at the start or the end.

Known limits: cardboard look when the cameras are far apart in angle, wrong placement when someone jumps.

### Phase 7: People v2, per-pixel depth Gaussians (Milestone 3)

Goal: people have real parallax during the flight.

- [ ] Depth model: Core ML Depth Anything V2 Small (F16). Output is relative inverse depth: metric inverse depth = a * d + b.
- [ ] Metric alignment per frame: render the static splat depth from the phone's pose (cache it for fixed phones). On background pixels fit a and b robustly (RANSAC or Huber) against 1 / z_splat. Smooth a and b over time.
- [ ] Anchor check: compare the person's median depth with the Phase 6 placement and with two-view triangulation of body joints (Vision body pose in both cameras). If they disagree by more than 15 %, shift the person's depth to the anchor.
- [ ] Metal compute shader: frame, matte, depth, intrinsics and pose in, Gaussian buffer out. One Gaussian per second pixel in each direction, position by unprojection (section 5), colour from the pixel, opacity from the matte, isotropic scale = z * stride / f times a factor of 1.0 to 1.4.
- [ ] Drop pixels at depth discontinuities to avoid points smeared between person and background.
- [ ] Rendering: start with opaque discs and depth test (no sorting), composite against the splat depth as in Phase 6. Move to sorted alpha blending only if edges look bad.
- [ ] Two sources: weight A's Gaussians by 1 - s and B's by s (dithered or by opacity). Inflate scale slightly in mid-flight to close small holes.
- [ ] Time budget: Apple lists about 33 ms per inference on an M1 Max, so two cameras in sequence give about 15 fps. Measure on the real Mac, then choose: depth at half rate with matte and colour at full rate, depth only for the preview and program cameras, or inference on the phones with depth sent as a second low-resolution stream.

Done when: on R2 and R3, side by side with Phase 6, limbs separate visibly in depth, the person does not move back and forth from depth flicker, and the transition runs at 25 fps or more.

Fallback: keep billboards as the default and use depth Gaussians only when the anchor check passes.

### Phase 8: Moving phones

Goal: a handheld phone can be the start or the target of a flight.

- [ ] Use the per-frame pose from the packet header instead of the frozen pose.
- [ ] Moving target: recompute the path every frame towards B's pose of the frame that will be displayed.
- [ ] Background depth for the Phase 7 alignment is rendered per frame at low resolution instead of cached.
- [ ] Drift monitor: every few seconds measure the offset between splat render and video on static pixels. Warn the operator above a threshold. Optional: re-run the Phase 3 refinement in the background and apply the correction as an offset transform.

Done when: on R4 and live, a flight from a tripod phone to a slowly moving handheld phone lands in its live picture without a jump.

### Phase 9: More than two phones (Milestone 4)

- [ ] Camera registry and multiview bar with thumbnails. Select preview by number key or click.
- [ ] Paths between cameras that are far apart: use the positions of cameras in between as spline knots.
- [ ] People Gaussians come from the two cameras closest in angle to the current virtual viewpoint.
- [ ] Load control: segmentation and depth only for the preview and program cameras.
- [ ] Optional: a lighter capture mode for fixed phones after calibration, to reduce heat.

Done when: four phones are connected and any-to-any transitions work.

### Phase 10: Stretch and research

- Learned feed-forward human reconstruction (GPS-Gaussian+ and successors such as Tele360) to replace the Phase 7 depth step. Needs an NVIDIA GPU for training and probably for inference, for example a lab or cloud machine. Evaluate offline on R2 and R3 first.
- Apple SHARP (single image to metric Gaussians in under a second, weights public) as an offline quality reference for per-frame monocular Gaussians. Too slow for live per-frame use.
- Temporal consistency: video depth models, tracked person identities.
- Frozen-time orbit ("bullet time") across the cameras.
- Program output to other software (recording, Syphon or NDI).
- Android capture client.

## 8. Data formats

Session folder:

```
session_<date>_<device>/
  meta.json        device model, iOS version, video format, locked camera settings, floorY, clock offset
  video.mov        HEVC
  frames.jsonl     one line per frame
  worldmap.bin     scan sessions only (archived ARWorldMap)
  images/          scan sessions only
  points.ply       scan sessions only
```

`frames.jsonl` line:

```json
{"i": 0, "t": 12345.678, "c2w": [16 floats, column-major], "fx": 0, "fy": 0, "cx": 0, "cy": 0, "w": 1920, "h": 1080, "tracking": "normal", "iso": 0, "shutter": 0}
```

Media packet header (little-endian): magic, version, camera id, frame index (u32), capture timestamp on the phone clock (f64), `c2w` (16 x f32), fx, fy, cx, cy (4 x f32), width, height (u16), flags (keyframe, tracking state), payload length (u32).

## 9. Risks and fallbacks

| Risk | Sign | Fallback |
|---|---|---|
| ARKit poses not accurate enough for training | Blurry splat, overlay off by many pixels | COLMAP poses plus alignment to the ARKit frame (Phase 2) |
| Relocalisation to the world map fails | Tracking stays in relocalising state | Fiducial marker, or COLMAP registration of one frame per phone |
| Monocular depth unstable | Person moves back and forth, wrong offset to the background | Anchor check, temporal smoothing, billboards as default |
| Cameras far apart in angle | People look wrong in mid-flight | Shorter flight with blur, a third phone in between, billboards |
| Sync error | Double contours on fast limbs | 60 fps capture, measure and tune the playout delay |
| Phones overheat | Thermal state serious, frame drops | 30 fps, lower bitrate, no case, external power, light capture mode |
| Wi-Fi congestion | Stalls, rising latency | Dedicated access point, wired Ethernet adapters |
| MetalSplatter lacks a needed hook (depth, second splat set) | Cannot composite people correctly | Fork it or write a minimal renderer for the people pass |
| Depth inference too slow for two cameras | Below 25 fps in transitions | Half-rate depth, inference on the phones |

## 10. Open questions

- Which iPhone models exactly? This decides the available video formats and on-device inference speed.
- Which Mac (chip, memory)? This decides the Phase 7 time budget and the splat size.
- Typical angle and distance between the cameras?
- Program output: 1080p at 30 or 60 fps?
- How many people in the scene at most?

## 11. References

Tools:

- MetalSplatter (Swift and Metal splat renderer, MIT): https://github.com/scier/MetalSplatter
- Brush (splat trainer, runs on macOS, reads COLMAP and Nerfstudio formats): https://github.com/ArthurBrussee/brush
- OpenSplat: https://radiancefields.com/platforms/opensplat
- msplat (Metal-native trainer with Swift package): https://github.com/rayanht/msplat
- 3D Splat App (macOS trainer and viewer): https://radiancefields.com/platforms/3d-splat-app
- Depth Anything V2 Core ML models: https://huggingface.co/apple/coreml-depth-anything-v2-small
- Apple Core ML model benchmarks: https://developer.apple.com/machine-learning/models/

ARKit:

- Saving and loading world data: https://developer.apple.com/documentation/arkit/saving-and-loading-world-data
- `initialWorldMap`: https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap
- Creating a multiuser AR experience: https://developer.apple.com/documentation/arkit/creating-a-multiuser-ar-experience
- `personSegmentationWithDepth`: https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/personsegmentationwithdepth
- Bringing People into AR (WWDC19): https://developer.apple.com/videos/play/wwdc2019/607/
- Camera settings in an ARKit session (forum answer): https://developer.apple.com/forums/thread/766844

Related work:

- GPS-Gaussian+ (real-time human-scene rendering from sparse views): https://yaourtb.github.io/GPS-Gaussian+
- Tele360 (real-time feed-forward human reconstruction, unposed cameras): https://www.alphaxiv.org/abs/2609.15032
- SHARP (single image to Gaussians): https://github.com/apple/ml-sharp
- ByteDance LiveGS (live Gaussian video from few synchronised cameras, including phones): https://radiancefields.com/bytedance-multimedia-lab-builds-a-4d-media-system-for-live-and-on-demand-6dof-video
- TuttiCam (synchronised multi-phone capture for splat datasets): https://radiancefields.com/tutticam-syncs-up-to-8-cameras-for-gaussian-splat-capture
- NeRFCapture (iOS app that exports ARKit poses for NeRF training), as a reference for the export in Phase 2
