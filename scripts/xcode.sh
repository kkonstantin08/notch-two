#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -m)" != arm64 ]] || ! xcodebuild -version >/dev/null 2>&1; then
    echo "An Apple Silicon Mac with full Xcode selected is required." >&2
    exit 1
fi

exec xcodebuild -project boringNotch.xcodeproj -scheme boringNotch \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${BORING_NOTCH_DERIVED_DATA:-$PWD/.build/xcode}" \
    -disableAutomaticPackageResolution CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    CODE_SIGN_STYLE=Manual ONLY_ACTIVE_ARCH=YES BN_LOCAL_LIBRARY_VALIDATION_EXCEPTION=YES "$@"
