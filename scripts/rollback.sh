#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/deployment.sh

lock_deployment
[[ -r "$state/latest" ]] || fail "No successful installation backup was found."
backup=$(cat "$state/latest")
[[ "$backup" == "$state"/install-* && -d "$backup" && ! -L "$backup" ]] || fail "Invalid backup pointer."
[[ "$(cat "$backup/path")" == "$target" ]] || fail "Installed location differs from the saved one."
[[ -d "$backup/original.app" ]] || fail "The first Notch Two installation has no previous Notch Two build. Open the official Boring Notch to switch back."
verify_bundle "$target"
verify_bundle "$backup/original.app"
[[ "$(bundle_hash "$target")" == "$(cat "$backup/candidate-hash")" ]] || fail "Installed app differs from the saved custom build."
stage_bundle "$backup/original.app"
quit_target
swap_and_launch
[[ "$(bundle_hash "$target")" == "$(bundle_hash "$backup/original.app")" ]] || fail "Restored signature differs."
printf 'Restored %s\n' "$target"
if [[ -d "$backup/Data" ]]; then printf 'Saved data snapshot: %s/Data\n' "$backup"; fi
