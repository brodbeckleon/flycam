"""Offline transition reference (plan.md Phases 4, 6, 7) on the synthetic dataset.

Stated thresholds. "Render" is the reconstructed image without any video mixed in; it is
compared with the decoded HEVC source frame (which is itself about 34 dB from the lossless
ground truth):

    at s = 0 and s = 1:  billboard render >= 33 dB, Gaussian render >= 28 dB,
                         static render >= 33 dB on background pixels (it has no people)
    program output:      exactly the source video before the take and after the landing
    MP4 (H.264):         frames at the take and at the landing >= 35 dB against the source frame
"""

import json

import cv2
import numpy as np
import pytest

from flycam_tools.geometry import Camera, c2w_from_list
from flycam_tools.scene import to_uint8
from flycam_tools.session import read_video
from flycam_tools.transition import TransitionPath
from prototype.transition import MODES, main as prototype_main, write_outputs
from tests.conftest import psnr

TAKE = 9
RENDER_PSNR = {"billboard": 33.0, "gaussians": 28.0, "static": 33.0}


@pytest.fixture(scope="module")
def out(synth, tmp_path_factory):
    d = tmp_path_factory.mktemp("prototype")
    return d, write_outputs(synth, d, MODES, TAKE, keep_frames=True)


def view_of(info, K):
    return Camera(K, c2w_from_list(info.c2w))


@pytest.mark.parametrize("mode", MODES)
@pytest.mark.parametrize("s", [0.0, 1.0])
def test_render_matches_source_at_endpoints(out, mode, s):
    _, summary = out
    r = summary["_renderer"]
    k = TAKE
    src = r.A if s == 0 else r.B
    path = TransitionPath(r.A.camera(k), r.B.camera(k), r.floor_y, r.cfg)
    view = path.camera_at_progress(s)
    np.testing.assert_array_equal(view.c2w, src.camera(k).c2w)  # virtual camera == real camera
    render = to_uint8(r.render(view, mode, s, k, k))
    source = src.video[k]
    if mode == "static":
        bg = cv2.erode((~src.masks[k]).astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool)
        value = psnr(render[bg], source[bg])
    else:
        value = psnr(render, source)
    assert value >= RENDER_PSNR[mode], f"{mode} s={s}: {value:.2f} dB"


@pytest.mark.parametrize("mode", MODES)
def test_program_output_is_live_video_outside_the_flight(out, mode):
    _, summary = out
    r = summary["_renderer"]
    frames, infos = summary[mode]["_frames"], summary[mode]["_infos"]
    before = [i for i in infos if i.u <= 0]
    after = [i for i in infos if i.u >= 1]
    flight = [i for i in infos if 0 < i.u < 1]
    assert before[-1].index == TAKE and len(flight) == 35 and after
    for i in before:
        np.testing.assert_array_equal(frames[i.index], r.A.video[r.A.nearest(i.t_mac)])
    for i in after:
        np.testing.assert_array_equal(frames[i.index], r.B.video[r.B.nearest(i.t_mac)])
    # Weights: video A fades out over the first 15 % of T, video B in over the last 15 %.
    assert flight[0].w_video_a > 0.75 and flight[0].w_video_b == 0
    assert flight[-1].w_video_b > 0.75 and flight[-1].w_video_a == 0


@pytest.mark.parametrize("mode", MODES)
def test_mp4_written(out, mode):
    d, summary = out
    r = summary["_renderer"]
    mp4 = list(read_video(d / f"transition_{mode}.mp4"))
    assert len(mp4) == len(summary[mode]["_frames"]) == 60
    infos = summary[mode]["_infos"]
    landing = next(i for i in infos if i.u >= 1)
    assert psnr(mp4[TAKE], r.A.video[TAKE]) >= 35
    assert psnr(mp4[landing.index], r.B.video[r.B.nearest(landing.t_mac)]) >= 35
    meta = json.loads((d / f"transition_{mode}.json").read_text())
    assert len(meta["frames"]) == 60 and meta["take_frame"] == TAKE


@pytest.mark.parametrize("mode", MODES)
def test_no_jump_at_take_or_landing(out, mode):
    """Frame-to-frame change rises and falls smoothly: no frame differs from its predecessor much
    more than its neighbours do (a jump at the start or end would be a spike)."""
    _, summary = out
    frames = summary[mode]["_frames"]
    d = [float(np.abs(frames[i + 1].astype(float) - frames[i]).mean()) for i in range(len(frames) - 1)]
    for i in range(1, len(d) - 1):
        assert d[i] <= 1.5 * max(d[i - 1], d[i + 1]) + 1.0, (i, d[i - 1 : i + 2])
    # Around take and landing the change per frame stays small (live noise is about 1 grey level).
    assert max(d[TAKE - 1 : TAKE + 2]) < 3.0


def person_stats(summary, mode):
    """Rendered person vs. ground truth person in each full-render frame of the flight."""
    r = summary["_renderer"]
    frames, infos = summary[mode]["_frames"], summary[mode]["_infos"]
    K = r.A.camera(0).K
    out = []
    for i in infos:
        if not (0 < i.u < 1) or i.w_render < 0.999:
            continue
        view = view_of(i, K)
        _, _, gt_mask = r.scene.render(view, i.t_mac)
        static, _ = r.static_render(view)
        person = np.abs(frames[i.index].astype(float) / 255 - static).sum(-1) > 0.08
        ys, xs = np.nonzero(person)
        gy, gx = np.nonzero(gt_mask)
        out.append({"iou": (person & gt_mask).sum() / (person | gt_mask).sum(),
                    "bottom": ys.max() - gy.max(), "centroid_x": abs(xs.mean() - gx.mean())})
    return out


@pytest.mark.parametrize("mode", ["billboard", "gaussians"])
def test_person_stays_on_the_floor(out, mode):
    """Phase 6 'Done when' analogue: the person stays on the floor without sliding during the flight."""
    stats = person_stats(out[1], mode)
    assert len(stats) >= 20
    assert all(abs(s["bottom"]) <= 4 for s in stats), [s["bottom"] for s in stats]


def test_depth_gaussians_beat_billboards(out):
    """Phase 7 vs. Phase 6: the person's silhouette in the virtual view follows the ground truth
    better with per-pixel depth than with a flat billboard."""
    bb = person_stats(out[1], "billboard")
    ga = person_stats(out[1], "gaussians")
    iou_bb = np.mean([s["iou"] for s in bb])
    iou_ga = np.mean([s["iou"] for s in ga])
    assert iou_ga >= 0.75
    assert iou_ga > iou_bb + 0.1
    assert max(s["centroid_x"] for s in ga) <= 4


def test_depth_alignment_agrees_with_floor_anchor(out):
    log = out[1]["_renderer"].anchor_log
    assert len(log) > 20
    assert np.mean([a["agrees"] for a in log]) >= 0.9


def test_cli(synth, tmp_path):
    assert prototype_main([str(synth), "--out", str(tmp_path), "--mode", "static"]) == 0
    assert (tmp_path / "transition_static.mp4").stat().st_size > 10_000
