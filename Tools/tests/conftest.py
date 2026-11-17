import os
import shutil
from pathlib import Path

import pytest

from flycam_tools.synth import SynthConfig, generate

TOOLS = Path(__file__).resolve().parents[1]
GOLDEN = TOOLS / "testdata" / "golden"

# Test dataset: 2 s clips at 30 fps, 384x216, 60 scan frames. Generated once per test run
# (about a minute). Set FLYCAM_TEST_DATA=<dir> to keep and reuse it between runs while developing.
TEST_CONFIG = SynthConfig(clip_seconds=2.0, scan_frames=60)


@pytest.fixture(scope="session")
def synth(tmp_path_factory) -> Path:
    cached = os.environ.get("FLYCAM_TEST_DATA")
    if cached:
        root = Path(cached)
        if not (root / "handheld" / "video.mov").exists():
            shutil.rmtree(root, ignore_errors=True)
            generate(root, TEST_CONFIG)
        return root
    return generate(tmp_path_factory.mktemp("synth"), TEST_CONFIG)


def psnr(a, b) -> float:
    import numpy as np

    mse = float(((np.asarray(a, float) - np.asarray(b, float)) ** 2).mean())
    return float("inf") if mse == 0 else 10 * np.log10(255.0**2 / mse)
