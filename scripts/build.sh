#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/bundle.sh
rm -f "$release_receipt"
scripts/xcode.sh -configuration Release build
verify_custom "$release_app"
hash=$(bundle_hash "$release_app")
printf '%s\n' "$hash" > "$release_receipt.tmp"
mv "$release_receipt.tmp" "$release_receipt"
printf '\nVerified arm64 bundle: %s\n' "$release_app"
printf 'Bundle CDHash: %s\n' "$hash"
