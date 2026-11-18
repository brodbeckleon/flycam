"""Regenerate testdata/golden/from_python (docs/protocol.md section 6). Run: uv run python make_golden.py"""

from flycam_tools.golden import main

if __name__ == "__main__":
    raise SystemExit(main())
