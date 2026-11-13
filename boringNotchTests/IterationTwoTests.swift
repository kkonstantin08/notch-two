import AppKit
import Defaults
import XCTest
@testable import boringNotch

@MainActor
final class IterationTwoTests: XCTestCase {
    func testNotificationEnableDisableTwentyTimesRejectsLatePayloads() async {
        let enabled = Defaults[.notificationLiveActivity]
        let duration = Defaults[.notificationDisplayDuration]
        let all = Defaults[.notificationsFromAllApps]
        let excluded = Defaults[.notificationExcludedApps]
        let manager = SystemNotificationManager.shared
        defer {
            manager.stop()
            Defaults[.notificationDisplayDuration] = duration
            Defaults[.notificationsFromAllApps] = all
            Defaults[.notificationExcludedApps] = excluded
            Defaults[.notificationLiveActivity] = enabled
        }
        Defaults[.notificationDisplayDuration] = 0
        Defaults[.notificationsFromAllApps] = true
        Defaults[.notificationExcludedApps] = []
        for index in 0..<20 {
            Defaults[.notificationLiveActivity] = true
            await manager.start()
            NotificationCenter.default.post(name: .systemNotificationDidAppear, object: nil,
                userInfo: ["token": "fixture-\(index)", "appName": "Test fixture", "bundleID": "local.notchtwo.fixture", "title": "Synthetic notification"])
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(manager.activeNotification?.id, "fixture-\(index)")
            manager.holdActive()
            manager.dismissActive()
            XCTAssertNil(manager.activeNotification)
            Defaults[.notificationLiveActivity] = false
            manager.stop()
            NotificationCenter.default.post(name: .systemNotificationDidAppear, object: nil,
                userInfo: ["token": "late-\(index)", "appName": "Test fixture"])
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertNil(manager.activeNotification)
            XCTAssertTrue(manager.queuedNotifications.isEmpty)
        }
    }

    func testTelegramCardDoesNotFallBackToTheAppWhenItsChatIsUnavailable() async throws {
        let enabled = Defaults[.notificationLiveActivity]
        let duration = Defaults[.notificationDisplayDuration]
        let all = Defaults[.notificationsFromAllApps]
        let excluded = Defaults[.notificationExcludedApps]
        let manager = SystemNotificationManager.shared
        manager.stop()
        defer {
            manager.stop()
            Defaults[.notificationLiveActivity] = enabled
            Defaults[.notificationDisplayDuration] = duration
            Defaults[.notificationsFromAllApps] = all
            Defaults[.notificationExcludedApps] = excluded
        }

        Defaults[.notificationLiveActivity] = true
        Defaults[.notificationDisplayDuration] = 0
        Defaults[.notificationsFromAllApps] = true
        Defaults[.notificationExcludedApps] = []
        await manager.start()
        NotificationCenter.default.post(name: .systemNotificationDidAppear, object: nil,
            userInfo: ["token": "telegram-expired", "appName": "Telegram", "bundleID": "ru.keepcoder.Telegram"])
        try await Task.sleep(for: .milliseconds(30))
        let notice = try XCTUnwrap(manager.activeNotification)
        XCTAssertTrue(notice.isTelegram)

        let opened = await manager.openAndDismiss(notice)
        XCTAssertFalse(opened)
        XCTAssertEqual(manager.activeNotification?.id, notice.id)
    }

    func testNativeFallbackWithdrawsOnlyAffectedCards() async {
        let enabled = Defaults[.notificationLiveActivity]
        let all = Defaults[.notificationsFromAllApps]
        let excluded = Defaults[.notificationExcludedApps]
        let manager = SystemNotificationManager.shared
        manager.stop()
        defer {
            manager.stop()
            Defaults[.notificationLiveActivity] = enabled
            Defaults[.notificationsFromAllApps] = all
            Defaults[.notificationExcludedApps] = excluded
        }
        Defaults[.notificationLiveActivity] = true
        Defaults[.notificationsFromAllApps] = true
        Defaults[.notificationExcludedApps] = []
        await manager.start()
        for token in ["native-fallback", "keep-in-notch"] {
            NotificationCenter.default.post(name: .systemNotificationDidAppear, object: nil,
                userInfo: ["token": token, "appName": "Fixture", "bundleID": "local.notchtwo.fixture"])
        }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(manager.activeNotification?.id, "native-fallback")
        NotificationCenter.default.post(name: .systemNotificationUsesNative, object: nil,
            userInfo: ["tokens": ["native-fallback"]])
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(manager.activeNotification?.id, "keep-in-notch")
        XCTAssertTrue(manager.queuedNotifications.isEmpty)
    }

    func testQuickLookKeepsPreviousSelectionUntilPreviewCloses() async throws {
        let storage = TemporaryFileStorageService.shared
        let firstValue = await storage.createTempFile(for: .text("first preview fixture"))
        let secondValue = await storage.createTempFile(for: .text("second preview fixture"))
        let first = try XCTUnwrap(firstValue)
        let second = try XCTUnwrap(secondValue)
        let preview = QuickLookService()
        defer {
            preview.hide()
            storage.removeTemporaryFileIfNeeded(at: first)
            storage.removeTemporaryFileIfNeeded(at: second)
        }
        preview.show(urls: [first])
        preview.show(urls: [second])
        storage.removeTemporaryFileIfNeeded(at: first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        preview.hide()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(preview.selectedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testWellnessAndMusicEnableDisableTwentyTimes() async {
        let features = Defaults[.customFeatures]
        let music = Defaults[.enableSneakPeek]
        let always = Defaults[.alwaysShowSneakPeek]
        let custom = CustomFeatures.shared
        defer {
            Defaults[.customFeatures] = features
            Defaults[.enableSneakPeek] = music
            Defaults[.alwaysShowSneakPeek] = always
        }
        custom.start()
        for _ in 0..<20 {
            Defaults[.customFeatures] = [CustomFeature.wellness.rawValue]
            Defaults[.enableSneakPeek] = true
            Defaults[.alwaysShowSneakPeek] = true
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertNotNil(custom.wellness.deadline)
            Defaults[.customFeatures] = []
            Defaults[.enableSneakPeek] = false
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertNil(custom.wellness.deadline)
            XCTAssertNil(custom.wellnessActivity)
            for screen in NSScreen.screens {
                let state = BoringViewCoordinator.shared.sneakPeekState(for: screen.displayUUID)
                if state.type == .music { XCTAssertFalse(state.show) }
            }
        }
    }
}
