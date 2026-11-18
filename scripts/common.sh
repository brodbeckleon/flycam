#!/bin/bash
# Shared settings for the build scripts. Source, do not run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Apps/FlyCam.xcodeproj"
DERIVED="$ROOT/Apps/.build/DerivedData"
MAC_PRODUCTS="$DERIVED/Build/Products/Debug"

generate_project() {
    if ! command -v xcodegen >/dev/null; then
        echo "xcodegen not found: brew install xcodegen" >&2
        exit 1
    fi
    (cd "$ROOT" && xcodegen generate --spec project.yml --project Apps --quiet)
}

# Pipe xcodebuild output through xcbeautify/xcpretty when available, keep the exit code.
run_xcodebuild() {
    local log="$DERIVED/../last-xcodebuild.log"
    mkdir -p "$(dirname "$log")"
    set +e
    xcodebuild "$@" >"$log" 2>&1
    local status=$?
    set -e
    grep -E "error:|warning: .*(DirectorCore|DirectorApp|DirectorCLI|CaptureApp|Shared)/|Test Suite|Test Case .*(passed|failed)|Executed|\*\* .* \*\*" "$log" | grep -v "^$" || true
    if [ $status -ne 0 ]; then
        echo "xcodebuild failed ($status), last 40 lines of $log:" >&2
        tail -40 "$log" >&2
    fi
    return $status
}
