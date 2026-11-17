# Measurements and decisions

Format: date, phase, what was measured, value, setup. Newest at the bottom.

## 2026-11-17, Track L (Linux container, synthetic data)

These are container results on synthetic data with ground truth. They are not device measurements.

- Clock offset (Phase 5 simulator, localhost): estimate within about 0.01 ms of the true offset; test bound 2 ms.
- Latency (simulator): arrival minus capture equals the simulated 30 ms capture delay plus about 0.3 ms on localhost.
- Pose refinement (Phase 3 tool): 0.6 deg / 3 cm error in the reported pose reduced to 0.02-0.03 deg / 2-3 mm at 384x216 with an HEVC frame.
- Reprojection check (Phase 2 tool): exact poses give a median offset < 0.3 px; a 0.5 deg yaw error gives about 2.9 px at fx = 330.
- Transition reference (Phases 4, 6, 7): render vs. source frame at s = 0 / 1: billboards 35.0 / 35.3 dB, Gaussians 30.2 / 30.5 dB.
  Silhouette IoU vs. ground truth during the flight: Gaussians 0.85, billboards 0.64 (mean).
- Decision: SIFT contrast threshold 0.02 (OpenCV default 0.04 found about 40 keypoints per frame).
- Decision: PnP RANSAC threshold 1 px.
- Decision: render depth for refine_pose is exchanged as raw little-endian float32 `.f32`.
- Finding: `JSONSerialization` on Linux mis-parses about half of all doubles; use `JSONDecoder` (docs/protocol.md 6.1).
