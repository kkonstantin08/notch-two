#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/deployment.sh

candidate=$release_app
verify_custom "$candidate"
[[ -r "$release_receipt" && "$(cat "$release_receipt")" == "$(bundle_hash "$candidate")" ]] \
    || fail "The artifact differs from the verified local build. Run ./scripts/build.sh first."
lock_deployment
if [[ -e "$target" || -L "$target" ]]; then verify_bundle "$target"; fi
if [[ -d "${data%/Data}" ]]; then
    /bin/ls -A "$data" >/dev/null \
        || fail "Cannot read the Notch Two container. The installed app is intact."
fi
stage_bundle "$candidate"
quit_target

backup=$(mktemp -d "$state/install-$(date +%Y%m%d-%H%M%S).XXXXXX")
if [[ -e "$target" ]]; then
    /usr/bin/ditto "$target" "$backup/original.app"
    verify_bundle "$backup/original.app"
    [[ "$(bundle_hash "$target")" == "$(bundle_hash "$backup/original.app")" ]] || fail "Backup signature differs."
    /usr/bin/codesign -dvvv --entitlements - "$target" >"$backup/signature.txt" 2>&1
fi
if [[ -d "${data%/Data}" ]]; then
    /usr/bin/ditto "$data" "$backup/Data" || fail "Could not back up Notch Two data."
    # Confirm payloads and symlink targets without following container links.
    differences=$(/usr/bin/rsync -rlcni --delete -- "$data/" "$backup/Data/") || fail "Could not compare the data backup."
    [[ -z "$differences" ]] || fail "Data backup verification failed."
fi
printf '%s\n' "$target" > "$backup/path"
printf '%s\n' "$(bundle_hash "$candidate")" > "$backup/candidate-hash"

swap_and_launch
[[ "$(bundle_hash "$target")" == "$(cat "$backup/candidate-hash")" ]] || fail "Installed bundle signature differs."
printf '%s\n' "$backup" > "$state/.latest.tmp"
mv "$state/.latest.tmp" "$state/latest"
printf 'Installed %s\nBackup: %s\n' "$target" "$backup"
