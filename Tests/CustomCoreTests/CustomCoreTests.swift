import XCTest
@testable import CustomCore

final class CustomCoreTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    func testSourceStopsOncePerCycleAndRejectsLateCallbacks() {
        var source = SourceLifecycle()
        for _ in 0..<20 {
            let session = source.start()
            XCTAssertNotNil(session)
            XCTAssertNil(source.start())
            XCTAssertTrue(source.accepts(session!))
            XCTAssertTrue(source.stop())
            XCTAssertFalse(source.stop())
            XCTAssertFalse(source.accepts(session!))
        }
    }

    func testNoticesQueueDeduplicateExpireAndCancelByFeature() {
        var queue = CustomNoticeQueue()
        let first = CustomNotice(source: .wifi, key: "on", title: "Wi-Fi", detail: "Connected", icon: "wifi")
        let second = CustomNotice(source: .bluetooth, key: "one", title: "Headphones", detail: "", icon: "headphones")
        queue.push(first, at: now, duration: 3)
        queue.push(first, at: now, duration: 3)
        queue.push(second, at: now, duration: 5)
        XCTAssertEqual(queue.current?.notice, first)
        queue.advance(at: now.addingTimeInterval(3))
        XCTAssertEqual(queue.current?.notice, second)
        queue.remove(.bluetooth, at: now.addingTimeInterval(4))
        XCTAssertNil(queue.current)
        queue.push(first, at: now.addingTimeInterval(4), duration: 3)
        XCTAssertNil(queue.current)
    }

    func testPomodoroSettlesOnlyOnePhaseAfterSleep() {
        var clock = PomodoroClock()
        clock.toggle(at: now, duration: 60)
        XCTAssertFalse(clock.finishIfDue(at: now.addingTimeInterval(59)))
        XCTAssertTrue(clock.finishIfDue(at: now.addingTimeInterval(3600)))
        XCTAssertEqual(clock.phase, .shortBreak)
        XCTAssertFalse(clock.finishIfDue(at: now.addingTimeInterval(3600)))
    }

    func testPauseKeepsRemainingAndFourthFocusGivesLongBreak() {
        var clock = PomodoroClock()
        clock.toggle(at: now, duration: 60)
        clock.toggle(at: now.addingTimeInterval(15), duration: 60)
        XCTAssertEqual(clock.remaining, 45)
        clock.toggle(at: now.addingTimeInterval(100), duration: 60)
        XCTAssertEqual(clock.deadline, now.addingTimeInterval(145))
        for _ in 0..<3 {
            clock.skip()
            clock.skip()
        }
        clock.skip()
        XCTAssertEqual(clock.phase, .longBreak)
    }

    func testPomodoroAppliesEditedDurationWhileRunningAndPaused() {
        var clock = PomodoroClock()
        clock.applyDuration(120, at: now)
        XCTAssertEqual(clock, PomodoroClock())
        clock.toggle(at: now, duration: 3_000)
        let editTime = now.addingTimeInterval(244)
        clock.applyDuration(60, at: editTime)
        XCTAssertEqual(clock.deadline, editTime.addingTimeInterval(60))
        XCTAssertEqual(clock.phase, .focus)
        clock.toggle(at: editTime.addingTimeInterval(10), duration: 60)
        clock.applyDuration(120, at: editTime.addingTimeInterval(20))
        XCTAssertNil(clock.deadline)
        XCTAssertEqual(clock.remaining, 120)
        clock.toggle(at: editTime, duration: 120)
        XCTAssertEqual(clock.deadline, editTime.addingTimeInterval(120))
    }

    func testCalendarSelectsSoonestEndingAndHandlesNewSnapshot() {
        let early = CalendarOccurrence(id: "a", start: now.addingTimeInterval(-100), end: now.addingTimeInterval(100))
        let late = CalendarOccurrence(id: "b", start: now.addingTimeInterval(-200), end: now.addingTimeInterval(200))
        XCTAssertEqual(CalendarOccurrence.active(in: [late, early], at: now), early)
        XCTAssertEqual(CalendarOccurrence.active(in: [late], at: now), late)
        XCTAssertNil(CalendarOccurrence.active(in: [early, late], at: now.addingTimeInterval(200)))
    }


}

extension CustomCoreTests {
    func testMonthStartsOnConfiguredWeekdayAndContainsLeapDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let february = calendar.date(from: DateComponents(year: 2024, month: 2, day: 1))!
        let days = CalendarMonthGeometry.days(containing: february, calendar: calendar)
        XCTAssertEqual(days.prefix(3).compactMap { $0 }.count, 0)
        XCTAssertEqual(days.compactMap { $0 }.count, 29)
        XCTAssertEqual(days[3], february)
        XCTAssertEqual(days.count % 7, 0)
    }
}

extension CustomCoreTests {
    func testEyeBreakExcludesSleepAndStopsWithoutADeadline() {
        var clock = EyeBreakClock()
        for _ in 0..<20 {
            clock.start(at: now, interval: 1200)
            clock.suspend(at: now.addingTimeInterval(300))
            XCTAssertNil(clock.deadline)
            clock.resume(at: now.addingTimeInterval(3900))
            XCTAssertEqual(clock.deadline, now.addingTimeInterval(4800))
            XCTAssertFalse(clock.advance(at: now.addingTimeInterval(4799), interval: 1200, rest: 20))
            XCTAssertTrue(clock.advance(at: now.addingTimeInterval(4800), interval: 1200, rest: 20))
            XCTAssertTrue(clock.isResting)
            clock.postpone(at: now.addingTimeInterval(4801), seconds: 300)
            XCTAssertFalse(clock.isResting)
            XCTAssertEqual(clock.deadline, now.addingTimeInterval(5101))
            clock.stop()
            XCTAssertNil(clock.deadline)
            XCTAssertFalse(clock.advance(at: now.addingTimeInterval(99999), interval: 1200, rest: 20))
        }
    }
}

extension CustomCoreTests {
    func testNetworkReportsRouteChangesWithoutInventingWiFiChanges() {
        var transition = NetworkTransition()
        XCTAssertEqual(transition.update(online: true, wifi: true, ssid: "Home"), [])
        XCTAssertEqual(transition.update(online: true, wifi: true, ssid: nil), [])
        XCTAssertEqual(transition.update(online: true, wifi: true, ssid: "Home"), [])
        XCTAssertEqual(transition.update(online: true, wifi: true, ssid: "Work"), [.wifiChanged("Work")])
        // Ethernet can become the default route while Wi-Fi remains associated.
        XCTAssertEqual(transition.update(online: true, wifi: true, ssid: "Work"), [])
        XCTAssertEqual(transition.update(online: true, wifi: false, ssid: nil), [.wifiDisconnected])
        XCTAssertEqual(transition.update(online: false, wifi: false, ssid: nil), [.connectionLost])
        XCTAssertEqual(transition.update(online: false, wifi: false, ssid: nil), [])
        XCTAssertEqual(transition.update(online: true, wifi: true, ssid: nil),
                       [.connectionRestored, .wifiConnected(nil)])
        XCTAssertEqual(transition.update(online: false, wifi: false, ssid: nil),
                       [.connectionLost, .wifiDisconnected])
    }

    func testNetworkPreservesWiFiOnlyAlertsWithoutPermission() {
        var transition = NetworkTransition()
        XCTAssertEqual(transition.update(online: true, wifi: true, ssid: nil), [])
        XCTAssertEqual(transition.update(online: true, wifi: true, ssid: nil, ssidChanged: true), [.wifiChanged(nil)])
        XCTAssertEqual(transition.update(online: false, wifi: false, ssid: nil, reportConnection: false), [.wifiDisconnected])
        XCTAssertEqual(transition.update(online: true, wifi: true, ssid: nil, reportConnection: false), [.wifiConnected(nil)])
    }
}
