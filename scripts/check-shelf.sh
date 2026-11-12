#!/bin/bash
set -euo pipefail

cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/boring-shelf-check.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -o "$scratch/check-shelf" \
  boringNotch/helpers/Log.swift \
  boringNotch/extensions/{URL+SecurityScoped,NSItemProvider+LoadHelpers}.swift \
  boringNotch/components/Shelf/Models/{Bookmark,ShelfItem}.swift \
  boringNotch/components/Shelf/ViewModels/{ShelfStateViewModel,ShelfSelectionModel}.swift \
  boringNotch/components/Shelf/Services/{TemporaryFileStorageService,ShelfPersistenceService,ShelfDropService,ThumbnailService}.swift \
  Tests/ShelfChecks.swift
"$scratch/check-shelf"
