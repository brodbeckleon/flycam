# FlyCam wire protocol and file formats

Status: version 1. Binding for `Packages/FlyCamKit` (Swift) and `Tools/` (Python).
Both implementations are checked against the same golden files in `Tools/testdata/golden/`
(see "Golden files" at the end). If this document and the code disagree, the code is wrong.

Conventions from plan.md section 5 apply throughout: ARKit world frame (right-handed,
+Y up, metres), `c2w` camera-to-world, camera looks along -Z, +Y up, +X right,
pixel origin top-left, u right, v down.

## 1. Common types

### 1.1 `c2w` (camera-to-world)

A 4x4 rigid transform. Everywhere it is serialised as a flat list of 16 numbers in
**column-major** order, the order of `simd_float4x4` columns:

```
[ m00 m10 m20 m30,  m01 m11 m21 m31,  m02 m12 m22 m32,  m03 m13 m23 m33 ]
  ---- column 0 ---  ---- column 1 ---  ---- column 2 ---  ---- column 3 ----
```

Column 3 is the camera position, `-column 2` is the viewing direction.
The only exception is Nerfstudio's `transforms.json`, which stores four rows (section 5).

### 1.2 Intrinsics

`fx, fy, cx, cy` in pixels for an image of `w x h` pixels, as delivered by
`ARCamera.intrinsics` for `ARCamera.imageResolution`. An integer pixel coordinate (u, v) is the
**centre** of a pixel, so the image covers u in [-0.5, w - 0.5] (OpenCV convention).
**Verify** on the device that ARKit uses this convention (Phase 2 overlay test; a half-pixel
error shows up as a constant 0.5 px offset).

Projection of a camera-space point (x, y, z) with z < 0 (in front of the camera):

```
u = cx + fx * x / (-z)
v = cy - fy * y / (-z)
depth = -z
```

Unprojection is the inverse, see plan.md section 5.

### 1.3 Metal projection matrix

Built from fx, fy, cx, cy with an off-centre frustum, `near` and `far` in metres. Clip space is
Metal's (x, y in [-1, 1], +y up, z in [0, 1], z = 0 at `near`). The viewport maps NDC x = -1 to
window x = 0 and NDC x = +1 to window x = w; window pixel centres are at x + 0.5.
Therefore window_x = u + 0.5 and window_y = v + 0.5:

```
P = | 2fx/w   0       1 - (2cx+1)/w     0          |
    | 0       2fy/h   (2cy+1)/h - 1     0          |
    | 0       0       far/(near-far)    near*far/(near-far) |
    | 0       0      -1                 0          |
```

(Rows shown; store column-major.) `FlyCamKit.PinholeCamera.projectionMatrix(near:far:)`
implements this and the unit tests check it against `project()`.

### 1.4 Tracking state

String values `"normal"`, `"limited"`, `"notAvailable"` (ARKit `ARCamera.TrackingState`;
the reason of `limited` is not transmitted). In binary form: 0 notAvailable, 1 limited, 2 normal.

### 1.5 Time

Seconds as IEEE-754 double. Phone timestamps are phone uptime (`ARFrame.timestamp`).
The Mac converts with `t_mac = t_phone + offset` (section 3.4).

## 2. Session folder

```
session_<date>_<device>/
  meta.json        session metadata (2.1)
  video.mov        HEVC video, clip sessions only (2.3)
  frames.jsonl     one JSON object per frame (2.2)
  worldmap.bin     scan sessions only (archived ARWorldMap, opaque here)
  images/          scan sessions only: 00000.jpg, 00001.jpg, ... (synthetic data uses .png)
  points.ply       scan sessions only: feature points, see 2.4
  pose_override.json  optional, written by Tools/refine_pose.py (2.5)
  ground_truth/    synthetic sessions only (2.6)
```

### 2.1 `meta.json`

```json
{
  "format_version": 1,
  "kind": "clip",
  "device_model": "iPhone15,2",
  "os_version": "18.1",
  "camera_id": 0,
  "video_format": {"width": 1920, "height": 1080, "fps": 60},
  "camera_settings": {"locked": true, "iso": 100.0, "shutter": 0.008333,
                      "wb_temperature": 5000.0, "wb_tint": 0.0},
  "floor_y": -1.32,
  "clock_offset": 1234.5678,
  "created": "2026-11-17T19:00:00Z"
}
```

| Key | Type | Meaning |
|---|---|---|
| `format_version` | int | 1 |
| `kind` | string | `"scan"` or `"clip"` |
| `device_model` | string | hardware identifier |
| `os_version` | string | |
| `camera_id` | int or null | camera id assigned by the Mac, null when recorded standalone |
| `video_format` | object | `width`, `height` (pixels), `fps` (number) of the ARKit video format |
| `camera_settings` | object | `locked` (bool), `iso`, `shutter` (seconds), `wb_temperature` (K), `wb_tint`; numbers may be null when unknown |
| `floor_y` | number or null | Y of the floor plane in the world frame (scan sessions; copied into clips) |
| `clock_offset` | number or null | `t_mac - t_phone` in seconds at recording start, written when recording was triggered by the Mac |
| `created` | string | ISO 8601 UTC |

Readers ignore unknown keys. Writers may add keys.

### 2.2 `frames.jsonl`

One line per frame, UTF-8, `\n` terminated, one JSON object per line:

```json
{"i": 0, "t": 12345.678, "c2w": [16 numbers, column-major], "fx": 1500.1, "fy": 1500.1, "cx": 960.2, "cy": 540.3, "w": 1920, "h": 1080, "tracking": "normal", "iso": 100.0, "shutter": 0.008333}
```

| Key | Type | Meaning |
|---|---|---|
| `i` | int | frame index, 0-based, consecutive; video frame `i` / image `images/<i:05d>.*` |
| `t` | number | capture time, phone clock, seconds |
| `c2w` | 16 numbers | camera-to-world, column-major |
| `fx fy cx cy` | number | intrinsics in pixels for `w x h` |
| `w h` | int | image size in pixels |
| `tracking` | string | 1.4 |
| `iso`, `shutter` | number, optional | actual exposure for the frame; may be omitted or null |

Key order is not significant. Number formatting is not significant: files are compared by value.

### 2.3 `video.mov`

HEVC, one video track, constant frame rate, no B-frames (decode order = presentation order),
so video frame `i` is line `i` of `frames.jsonl`. Container frame timestamps are not used for
pairing; `t` in `frames.jsonl` is authoritative.

### 2.4 `points.ply`

Binary little-endian PLY 1.0, one element `vertex` with properties
`float x, float y, float z, uchar red, uchar green, uchar blue`, world frame.
Nerfstudio `transforms.json` references it as `ply_file_path`.

### 2.5 `pose_override.json`

```json
{"format_version": 1, "c2w": [16 numbers, column-major], "source": "refine_pose",
 "frame_index": 12, "inliers": 412, "median_reprojection_px": 0.31,
 "created": "2026-11-17T19:00:00Z"}
```

When present, a fixed phone uses this pose instead of the per-frame ARKit pose (plan Phase 3).

### 2.6 `ground_truth/` (synthetic sessions only)

Written by `Tools/synth.py`; never produced by a phone.

| File | Content |
|---|---|
| `frames/<i:05d>.png` | lossless RGB frame (video.mov is lossy) |
| `depth.npy` | float32 (N, H, W), depth along the viewing axis in metres, scene with person |
| `static_depth.npy` | float32 (N, H, W), same without the person |
| `mask.npy` | bool (N, H, W), person pixels |
| `mono_inv_depth.npy` | float32 (N, H, W), simulated monocular relative inverse depth `d` with `1/z = a*d + b` |
| `mono_affine.json` | per frame true `a`, `b` |
| `person.jsonl` | per frame `{"i", "t", "foot": [x, y, z], "radius", "height"}`: centre of the person's footprint on the floor |
| `../scene.json` | scene description shared by all sessions of a synthetic dataset |

## 3. Network

The Mac listens on one TCP port and advertises it with Bonjour as `_flycam._tcp`.
A phone opens two TCP connections to that port: one control connection and one media
connection. Each connection starts with a 4-byte ASCII preamble sent by the phone:

| Preamble | Channel |
|---|---|
| `FCC1` | control channel, version 1 |
| `FCM1` | media channel, version 1 |

The phone opens the control connection first, sends `hello`, waits for `hello_ack`
(which assigns `camera_id`) and only then opens the media connection.

### 3.1 Control channel framing

After the preamble, both directions carry a sequence of messages. Each message is

```
u32 little-endian  length L of the JSON body in bytes (1 <= L <= 1 MiB)
L bytes            UTF-8 JSON object with a string key "type"
```

Receivers ignore unknown keys and skip (but log) unknown `type` values.

### 3.2 Control messages

Phone to Mac:

| type | Keys |
|---|---|
| `hello` | `protocol_version` (1), `device_id` (string, stable per phone), `device_model`, `os_version`, `video_format` {`width`, `height`, `fps`} |
| `pong` | `seq`, `t1` (echoed), `t2` (phone time ping received), `t3` (phone time pong sent) |
| `status` | `battery` (0..1), `thermal_state` (`nominal`/`fair`/`serious`/`critical`), `tracking` (1.4), `fps` (measured), `recording` (bool) |
| `ack` | `ref` (type being acknowledged), `ok` (bool), `message` (string, optional) |

Mac to phone:

| type | Keys |
|---|---|
| `hello_ack` | `protocol_version` (1), `camera_id` (int 0..65535) |
| `ping` | `seq` (int), `t1` (Mac time ping sent) |
| `set_camera_settings` | `lock` (bool), `iso`, `shutter` (s), `wb_temperature` (K), `wb_tint`; numbers may be null = leave unchanged |
| `start_recording` | `session_name` (string), `clock_offset` (number, the Mac's current estimate, written to meta.json) |
| `stop_recording` | (none) |

### 3.3 Media channel

After the preamble the phone sends packets back to back. Each packet is a fixed 110-byte
header followed by `payload_length` bytes. All fields little-endian, packed, no padding:

| Offset | Size | Type | Field |
|---|---|---|---|
| 0 | 4 | bytes | magic `FCAM` (0x46 0x43 0x41 0x4D) |
| 4 | 2 | u16 | version = 1 |
| 6 | 2 | u16 | camera_id |
| 8 | 4 | u32 | frame_index |
| 12 | 8 | f64 | capture timestamp, phone clock, s |
| 20 | 64 | 16 x f32 | `c2w`, column-major |
| 84 | 16 | 4 x f32 | fx, fy, cx, cy |
| 100 | 2 | u16 | width |
| 102 | 2 | u16 | height |
| 104 | 2 | u16 | flags |
| 106 | 4 | u32 | payload_length (<= 16 MiB) |
| 110 | | | payload |

Flags: bit 0 keyframe; bits 1-2 tracking state (1.4); bit 3 payload starts with parameter sets
(VPS, SPS, PPS); bits 4-15 reserved, must be 0 when writing and are ignored when reading.

Payload: one HEVC access unit (one frame) as a sequence of NAL units, each preceded by its
length as a **4-byte big-endian** integer (the `hvcC` / VideoToolbox sample format, no start
codes). Every keyframe carries VPS, SPS and PPS as its first NAL units and sets flag bit 3.
Frame reordering is off, so packets arrive in display order.

A receiver that sees a wrong magic or version closes the connection.

### 3.4 Clock synchronisation

Four-timestamp exchange, NTP style, initiated by the Mac:

```
t1  Mac clock, ping sent         (in ping, echoed in pong)
t2  phone clock, ping received   (in pong)
t3  phone clock, pong sent       (in pong)
t4  Mac clock, pong received     (local)

offset = ((t1 - t2) + (t4 - t3)) / 2      so that  t_mac = t_phone + offset
rtt    = (t4 - t1) - (t3 - t2)
```

10 pings at connect, then one per second. The estimate is the offset of the sample with the
smallest `rtt` among the most recent 60 samples. Both clocks are monotonic uptime clocks.

## 4. Frame store and pairing

Per camera a ring buffer of decoded frames keyed by `t_mac`, holding the last 0.5 s.
Render time `t_r = now - playout_delay` (150 ms to start). For each refresh every camera
contributes the frame whose `t_mac` is nearest to `t_r` (ties: the earlier frame). The residual
`max(t_mac) - min(t_mac)` over the selected frames is logged.

## 5. Nerfstudio export (`transforms.json`)

Written by `Tools/session_to_nerfstudio.py`:

```json
{
  "camera_model": "OPENCV",
  "ply_file_path": "points.ply",
  "frames": [
    {"file_path": "images/00000.png", "transform_matrix": [[4 numbers], [..], [..], [0, 0, 0, 1]],
     "fl_x": 1500.0, "fl_y": 1500.0, "cx": 960.0, "cy": 540.0, "w": 1920, "h": 1080,
     "k1": 0, "k2": 0, "p1": 0, "p2": 0}
  ]
}
```

`transform_matrix` is `c2w` as four **rows** (the transpose of the column-major list).
The world frame is not re-oriented or re-scaled.

## 6. Golden files

`Tools/testdata/golden/from_python/` is written by `Tools/make_golden.py`,
`Tools/testdata/golden/from_swift/` by `swift run flycam-golden <dir>`. Each directory contains:

| File | Content |
|---|---|
| `packets.bin` | `FCM1` preamble followed by several media packets |
| `packets.json` | the decoded fields of each packet (payload as hex) |
| `control.bin` | `FCC1` preamble followed by length-prefixed control messages |
| `control.json` | the messages as a JSON array |
| `session/meta.json`, `session/frames.jsonl` | a small session |
| `transition.json` | transition inputs and the expected camera at several values of s |
| `camera.json` | projection, unprojection and projection-matrix cases |
| `clock.json` | ping samples and the expected offset |

Both test suites read **both** directories and check:

- `packets.bin` decodes to `packets.json`, and encoding `packets.json` reproduces `packets.bin`
  byte for byte (the media format is fully binary, so byte equality is required);
- `control.bin` decodes to the messages in `control.json` (compared by value: JSON key order,
  whitespace and number spelling differ between the two encoders and are not significant);
- the session files parse to the same values;
- their own math reproduces `transition.json`, `camera.json` and `clock.json` within 1e-9.

Each suite also checks that regenerating its own directory gives the committed files
byte for byte, so the golden files cannot silently go stale.

### 6.1 JSON pitfalls found while building the golden files

- **Negative zero.** Swift's `JSONEncoder` and `JSONSerialization` write `-0.0` as `-0`, which Swift
  and Python both read back as `+0`. Numerically irrelevant in `frames.jsonl`, but a JSON description
  of a binary packet cannot carry `-0.0`. The Swift golden generator therefore normalises it to `+0`.
- **Parsing doubles on Linux.** On Linux (swift-corelibs-foundation, Swift 6.4.2), `JSONSerialization`
  parses about half of all doubles to a neighbouring value (`0.9845625162124634` becomes
  `0.9845625162124637`). `JSONDecoder` is correctly rounded. FlyCamKit parses all JSON with
  `JSONDecoder`; do not use `JSONSerialization` to read numbers in shared code.
