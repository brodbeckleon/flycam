#!/bin/bash
# Builds DirectorCore, DirectorApp and director-cli for macOS (Debug).
source "$(dirname "$0")/common.sh"
generate_project
for scheme in DirectorCore DirectorApp director-cli; do
    echo "== build $scheme (macOS)"
    run_xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Debug \
        -destination "platform=macOS" -derivedDataPath "$DERIVED" build
done
echo "== products in $MAC_PRODUCTS"
ls "$MAC_PRODUCTS" | grep -E "DirectorApp.app|director-cli|DirectorCore.framework"
