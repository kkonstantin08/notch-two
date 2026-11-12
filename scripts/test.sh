#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
scripts/check-shelf.sh
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
xcrun swiftc -swift-version 6 Shared/NotificationObserverRunLoop.swift Tests/NotificationRunLoopChecks.swift -o "$test_tmp/notification-runloop"
"$test_tmp/notification-runloop"
xcrun swiftc -swift-version 6 Shared/NotificationWindowParking.swift Tests/NotificationWindowParkingChecks.swift -o "$test_tmp/notification-parking"
"$test_tmp/notification-parking"
xcrun swiftc -swift-version 6 Shared/NotificationPresentation.swift Tests/NotificationLifecycleChecks.swift -o "$test_tmp/notification-lifecycle"
"$test_tmp/notification-lifecycle"
xcrun swiftc -swift-version 6 Shared/MediaControlRules.swift Tests/MediaControlChecks.swift -o "$test_tmp/media-controls"
"$test_tmp/media-controls"
xcrun swiftc -swift-version 6 Shared/NotificationAppFilter.swift Tests/NotificationFilterChecks.swift -o "$test_tmp/notifications"
"$test_tmp/notifications"
xcrun swiftc -swift-version 6 -O Shared/JSONLinesPipeHandler.swift \
    boringNotch/MediaControllers/NowPlayingStreamSupport.swift \
    boringNotch/MediaControllers/MediaAppBundleID.swift \
    boringNotch/models/PlaybackState.swift Tests/MediaCoreChecks.swift -o "$test_tmp/check"
"$test_tmp/check"
case "${1:-}" in
    "") ;;
    --compile-app-tests) scripts/xcode.sh -configuration Debug build-for-testing ;;
    --run-app-tests) scripts/xcode.sh -configuration Debug -parallel-testing-enabled NO test ;;
    *) echo "Usage: $0 [--compile-app-tests | --run-app-tests]" >&2; exit 2 ;;
esac
