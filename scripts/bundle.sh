#!/bin/bash
# Sourced by the build and deployment entry points.
bundle_id=local.notchtwo.app
release_dir="${BORING_NOTCH_DERIVED_DATA:-$PWD/.build/xcode}/Build/Products/Release"
release_app="$release_dir/Notch Two.app"
release_receipt="$release_dir/Notch-Two.cdhash"

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }

bundle_hash() {
    /usr/bin/codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'
}

verify_bundle() {
    local app=$1
    [[ -d "$app" && ! -L "$app" ]] || fail "Missing app bundle: $app"
    [[ "$(plist "$app" CFBundleIdentifier)" == "$bundle_id" ]] || fail "Unexpected bundle identifier: $app"
    /usr/bin/codesign --verify --deep --strict "$app" || fail "Signature verification failed: $app"
    [[ -n "$(bundle_hash "$app")" ]] || fail "Could not read bundle CDHash: $app"
}

verify_custom() {
    local app=$1
    verify_bundle "$app"
    local helper="$app/Contents/XPCServices/BoringNotchXPCHelper.xpc"
    [[ "$(plist "$helper" CFBundleIdentifier)" == "$bundle_id.BoringNotchXPCHelper" ]] \
        || fail "The XPC helper does not belong to the Notch Two bundle."
    local description
    description=$(/usr/bin/codesign -dvvv "$app" 2>&1)
    [[ "$description" == *$'\nSignature=adhoc\n'* ]] || fail "Expected the locally built ad-hoc signature."
    local library_validation_exception
    library_validation_exception=$(/usr/bin/codesign -d --entitlements - --xml "$app" 2>/dev/null \
        | /usr/bin/plutil -extract 'com\.apple\.security\.cs\.disable-library-validation' raw -expect bool -o - - 2>/dev/null) \
        || fail "Missing the local library-validation exception required by the bundled ad-hoc frameworks."
    [[ "$library_validation_exception" == true ]] || fail "The local library-validation exception is disabled."
    [[ "$(plist "$app" BNCustomBuild)" == true ]] || fail "The artifact is missing the custom-build marker."
    if plist "$app" SUFeedURL >/dev/null 2>&1; then
        fail "The artifact still has an official update feed."
    fi
    [[ "$(xcrun lipo -archs "$app/Contents/MacOS/$(plist "$app" CFBundleExecutable)")" == arm64 ]] \
        || fail "Expected a native arm64-only app binary."
}
