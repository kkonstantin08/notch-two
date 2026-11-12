//
//  NotchUIEventTests.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Smoke tests for the seams introduced during the architecture remediation.
//

import XCTest
import Combine
import Defaults
import SwiftUI
@testable import boringNotch

final class NotchUIEventTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    @MainActor
    func testMusicPeekAllowsHoverWhileSystemOSDBlocksIt() {
        let coordinator = BoringViewCoordinator.shared
        let screen = UUID().uuidString
        let enabled = Defaults[.enableSneakPeek]
        defer {
            coordinator.sneakPeekStates[screen] = nil
            Defaults[.enableSneakPeek] = enabled
        }

        Defaults[.enableSneakPeek] = true
        coordinator.sneakPeekStates[screen] = SneakPeekState(show: true, type: .music)
        XCTAssertTrue(coordinator.shouldShowSneakPeek(on: screen))
        XCTAssertFalse(coordinator.sneakPeekBlocksHover(on: screen))

        coordinator.sneakPeekStates[screen] = SneakPeekState(show: true, type: .volume)
        XCTAssertTrue(coordinator.sneakPeekBlocksHover(on: screen))
        XCTAssertFalse(coordinator.sneakPeekBlocksHover(on: nil))

        coordinator.sneakPeekStates[screen]?.show = false
        XCTAssertFalse(coordinator.sneakPeekBlocksHover(on: screen))
    }

    /// Managers publish; the presenter subscribes — the seam that replaced
    /// direct manager->coordinator calls. This is the contract.
    func testSneakPeekEventDeliversPayload() {
        let expectation = expectation(description: "event delivered")
        NotchUIEventBus.events
            .sink { event in
                guard case .sneakPeek(let type, let value, let icon, _, let uuid, _) = event else {
                    XCTFail("unexpected event")
                    return
                }
                XCTAssertEqual(type, .volume)
                XCTAssertEqual(value, 0.5, accuracy: 0.0001)
                XCTAssertEqual(icon, "speaker.wave.2")
                XCTAssertNil(uuid)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        NotchUIEventBus.events.send(.sneakPeek(type: .volume, value: 0.5, icon: "speaker.wave.2"))
        waitForExpectations(timeout: 1.0)
    }

    func testExpandingViewEventDeliversType() {
        let expectation = expectation(description: "expanding event delivered")
        NotchUIEventBus.events
            .sink { event in
                guard case .expandingView(let type) = event else {
                    XCTFail("unexpected event")
                    return
                }
                XCTAssertEqual(type, .battery)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        NotchUIEventBus.events.send(.expandingView(type: .battery))
        waitForExpectations(timeout: 1.0)
    }
}

final class MediaAppBundleIDTests: XCTestCase {
    func testBundleIDsAreDistinctAndWellFormed() {
        let ids = [
            MediaAppBundleID.appleMusic,
            MediaAppBundleID.spotify,
            MediaAppBundleID.youTubeMusic,
        ]
        XCTAssertEqual(ids.count, Set(ids).count, "bundle IDs must be unique")
        for id in ids {
            XCTAssertFalse(id.isEmpty)
            XCTAssertTrue(id.contains("."), "malformed bundle id: \(id)")
        }
    }
}

final class PlaybackStateTests: XCTestCase {
    func testEquatableIgnoresVolatileFields() {
        var a = PlaybackState(bundleIdentifier: MediaAppBundleID.spotify, isPlaying: true)
        a.title = "Track"
        a.currentTime = 42

        var b = a
        // Volatile/monitor-side fields that must not defeat `==`:
        // volume, playbackRate and lastUpdated are intentionally excluded.
        b.volume = 0.9
        b.playbackRate = 0.75
        b.lastUpdated = Date()

        XCTAssertEqual(a, b)
    }

    func testEquatableTracksUserVisibleFields() {
        var a = PlaybackState(bundleIdentifier: MediaAppBundleID.spotify, isPlaying: true)
        a.title = "Track"

        var b = a
        b.isFavorite = true
        XCTAssertNotEqual(a, b, "isFavorite is user-visible and must be compared")

        b = a
        b.currentTime += 1
        XCTAssertNotEqual(a, b, "position changes must be visible to == to drive UI updates")
    }
}

@MainActor final class ExpandedViewPixelTests: XCTestCase {

    /// Renders NotificationExpandedView offscreen and counts non-black
    /// pixels. Guards the reported "open notch is empty with a notification"
    /// regression.
    func testNotificationExpandedViewPaintsContent() throws {
        let notification = SystemNotification(
            id: "test-token", appName: "WhatsApp", bundleID: "net.whatsapp.WhatsApp",
            title: "Sender", subtitle: nil, body: "hello",
            receivedAt: Date())

        let view = NotificationExpandedView(notification: notification, showsMore: false)
            .environmentObject(BoringViewModel(camera: CameraModel()))
            .frame(width: 400, height: 132)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(x: 0, y: 0, width: 400, height: 132)
        hostingView.layoutSubtreeIfNeeded()

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("could not create bitmap rep")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        guard let data = rep.bitmapData else {
            XCTFail("no bitmap data")
            return
        }
        var nonBlack = 0
        let bytes = rep.pixelsWide * rep.pixelsHigh * max(1, rep.samplesPerPixel)
        for i in stride(from: 0, to: bytes, by: 4 * 40) { // sample every ~10th px
            if data[i] > 30 || data[i + 1] > 30 || data[i + 2] > 30 {
                nonBlack += 1
            }
        }
        XCTAssertGreaterThan(nonBlack, 20, "expanded view rendered ~empty")
    }

    func testHoveredNotificationMakesRoomForMoreText() {
        let notification = SystemNotification(
            id: "long-message", appName: "Telegram", bundleID: "ru.keepcoder.Telegram",
            title: "Sender", subtitle: nil,
            body: (1...6).map { "Line \($0) of the message" }.joined(separator: "\n"),
            receivedAt: Date())

        let compact = NSHostingView(rootView: NotificationExpandedView(notification: notification, showsMore: false))
        let expanded = NSHostingView(rootView: NotificationExpandedView(notification: notification, showsMore: true))

        XCTAssertGreaterThan(expanded.fittingSize.height, compact.fittingSize.height + 30)
    }

    func testShortNotificationWidensWithoutGrowingTallerWhenHovered() {
        let notification = SystemNotification(
            id: "short-message", appName: "Telegram", bundleID: "ru.keepcoder.Telegram",
            title: "Sender", subtitle: nil, body: "Hi", receivedAt: Date())

        let compact = NSHostingView(rootView: NotificationExpandedView(notification: notification, showsMore: false))
        let expanded = NSHostingView(rootView: NotificationExpandedView(notification: notification, showsMore: true))

        XCTAssertGreaterThan(expanded.fittingSize.width, compact.fittingSize.width + 60)
        XCTAssertEqual(expanded.fittingSize.height, compact.fittingSize.height, accuracy: 2)
        XCTAssertLessThan(expanded.fittingSize.height, 92)
    }

    func testInlineNotificationWrapsOnlyWhenTheMessageDoesNotFit() {
        func height(_ body: String, layout: NotificationCardLayout, width: CGFloat = 477) -> CGFloat {
            let notification = SystemNotification(
                id: "layout", appName: "Telegram", bundleID: nil, title: "Папа", subtitle: nil,
                body: body, receivedAt: Date())
            let view = NotificationCardContent(
                notification: notification, layout: layout, showsMore: true, isReplying: false,
                openSource: {}, onScrollHover: { _ in }
            ) {
                Text("Ответить").padding(.horizontal, 8)
            }
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            return NSHostingView(rootView: view).fittingSize.height
        }

        let shortColumn = height("Фотография", layout: .column)
        XCTAssertLessThan(height("Фотография", layout: .inline), shortColumn)
        let message = String(repeating: "Длинное сообщение ", count: 6)
        XCTAssertGreaterThan(height(message, layout: .inline), shortColumn)
        XCTAssertGreaterThan(height("Фотография", layout: .inline, width: 180),
                             height("Фотография", layout: .inline))
    }

    func testNotificationMessageScrollsOnlyWhenTextOverflows() throws {
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(scrollView(in:)).first
        }

        for lineCount in [1, 40] {
            let message = Array(repeating: "Message line", count: lineCount).joined(separator: "\n")
            let host = NSHostingView(rootView: NotificationMessageBody(
                text: message, openSource: {}, onScrollHover: { _ in }
            ).frame(width: 460))
            let size = host.fittingSize
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()

            if lineCount == 1 {
                XCTAssertLessThan(size.height, 110)
                XCTAssertNil(scrollView(in: host))
            } else {
                let scroll = try XCTUnwrap(scrollView(in: host))
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertEqual(size.height, 106, accuracy: 1)
                XCTAssertGreaterThan(document.frame.height, 500)

                let clip = scroll.contentView
                let bottom = clip.constrainBoundsRect(CGRect(
                    origin: CGPoint(x: 0, y: document.frame.height), size: clip.bounds.size
                ))
                clip.scroll(to: bottom.origin)
                XCTAssertEqual(clip.bounds.maxY, document.frame.maxY, accuracy: 1)
            }
        }
    }
}
