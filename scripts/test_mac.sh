#!/bin/bash
# Runs the DirectorCore unit and integration tests on this Mac (offscreen Metal, localhost networking).
source "$(dirname "$0")/common.sh"
generate_project
echo "== test DirectorCore (macOS)"
run_xcodebuild -project "$PROJECT" -scheme DirectorCore -configuration Debug \
    -destination "platform=macOS" -derivedDataPath "$DERIVED" test "$@"
