#!/bin/bash
# Builds CaptureApp for generic iOS without code signing (never installs on a device).
source "$(dirname "$0")/common.sh"
generate_project
echo "== build CaptureApp (generic/platform=iOS, CODE_SIGNING_ALLOWED=NO)"
run_xcodebuild -project "$PROJECT" -scheme CaptureApp -configuration Debug \
    -destination "generic/platform=iOS" -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO build
