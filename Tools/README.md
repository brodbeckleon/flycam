# FlyCam Tools

Offline Python tools for FlyCam (plan.md section 6). Formats: `docs/protocol.md`.

```
uv sync
uv run pytest                      # full suite, generates a synthetic dataset (about 1-2 minutes)
FLYCAM_TEST_DATA=out/testdata uv run pytest   # keep and reuse the dataset between runs
```

| Script | Plan phase | What it does |
|---|---|---|
| `synth.py --out out/synth` | all | synthetic dataset with ground truth: scan, two tripod clips, a handheld clip |
| `inspect_session.py SESSION` | 1 | trajectory plot, frame count vs. metadata lines, monotonic timestamps, valid poses |
| `session_to_nerfstudio.py SCAN OUT` | 2 | images, `transforms.json` (c2w as rows, per-frame intrinsics), `points.ply` |
| `reprojection_check.py SCAN RENDERS` | 2 | feature-match photo vs. splat render, median pixel offset |
| `refine_pose.py SESSION --render-color C --render-depth D` | 3 | PnP pose refinement against the splat render, writes `pose_override.json` |
| `make_golden.py` | - | regenerates `testdata/golden/from_python/` |
| `simulator/` | 5 | fake phone and reference receiver over TCP |
| `prototype/` | 4, 6, 7 | offline transition reference, writes MP4 |

Library modules live in `src/flycam_tools/`:
`geometry` (camera model, quaternions), `transition` (same algorithm as FlyCamKit),
`wire` (packets, control messages), `clock` (offset estimation, frame store), `session`
(session folders, video, PLY), `scene` + `synth` (ground-truth scene), `features`,
`reprojection`, `refine`, `depth_align` (Phase 7 a/b fit), `placement` (Phase 6 floor contact).

The synthetic scene stands in for both the room (phone frames) and the trained splat
(renders). Results on it show that the algorithms and conventions are right. They do not
show splat quality or ARKit accuracy; those are covered by `docs/manual-tests.md`.
