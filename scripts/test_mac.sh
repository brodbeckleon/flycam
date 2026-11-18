#!/bin/bash
# Runs the DirectorCore unit and integration tests on this Mac (offscreen Metal, localhost networking),
# then an end-to-end run of director-cli without a window: generated fixture -> render-transition -> verify.
source "$(dirname "$0")/common.sh"
generate_project
echo "== test DirectorCore (macOS)"
run_xcodebuild -project "$PROJECT" -scheme DirectorCore -configuration Debug \
    -destination "platform=macOS" -derivedDataPath "$DERIVED" test "$@"

# Extra xcodebuild arguments (e.g. -only-testing) skip the CLI run.
if [ $# -gt 0 ]; then exit 0; fi

echo "== build director-cli"
run_xcodebuild -project "$PROJECT" -scheme director-cli -configuration Debug \
    -destination "platform=macOS" -derivedDataPath "$DERIVED" build
CLI="$MAC_PRODUCTS/director-cli"
WORK="$ROOT/Apps/.build/cli-smoke"
rm -rf "$WORK"
mkdir -p "$WORK"
echo "== director-cli make-fixture"
"$CLI" make-fixture "$WORK/fixture" --frames 60 --fps 30
echo "== director-cli render-transition"
"$CLI" render-transition "$WORK/fixture/session_synth_A" "$WORK/fixture/session_synth_B" \
    "$WORK/fixture/splat.ply" --out "$WORK/transition.mp4"
echo "== director-cli verify-transition"
"$CLI" verify-transition "$WORK/fixture/session_synth_A" "$WORK/fixture/session_synth_B" \
    "$WORK/fixture/splat.ply" "$WORK/transition.mp4"
echo "== director-cli render-frame"
"$CLI" render-frame "$WORK/fixture/splat.ply" "$WORK/fixture/session_synth_A" --frame 0 \
    --out "$WORK/frame0.png" --depth "$WORK/frame0.f32"
echo "== test_mac.sh: all passed"
