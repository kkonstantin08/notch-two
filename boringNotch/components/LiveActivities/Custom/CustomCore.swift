import Foundation

enum CustomFeature: String, CaseIterable, Hashable {
    case wellness, eventAlerts, eventCountdown, bluetooth, outputName, calendar, accessoryBattery, pomodoro, capsLock, wifi
}

struct SourceLifecycle {
    private(set) var session: UUID?

    mutating func start() -> UUID? {
        guard session == nil else { return nil }
        let id = UUID()
        session = id
        return id
    }

    mutating func stop() -> Bool {
        guard session != nil else { return false }
        session = nil
        return true
    }

    func accepts(_ id: UUID) -> Bool { session == id }
}

struct NetworkTransition {
    enum Event: Equatable {
        case wifiConnected(String?), wifiDisconnected, wifiChanged(String?)
        case connectionLost, connectionRestored
    }

    private var previous: (online: Bool, wifi: Bool, ssid: String?)?

    mutating func update(online: Bool, wifi: Bool, ssid: String?, ssidChanged: Bool = false,
                         reportConnection: Bool = true) -> [Event] {
        let old = previous
        let name = wifi ? ssid ?? (ssidChanged ? nil : old?.ssid) : nil
        previous = (online, wifi, name)
        guard let old else { return [] }
        var events: [Event] = []
        if reportConnection, old.online != online {
            events.append(online ? .connectionRestored : .connectionLost)
        }
        if old.wifi != wifi {
            events.append(wifi ? .wifiConnected(name) : .wifiDisconnected)
        } else if wifi, ssidChanged || (old.ssid != nil && name != old.ssid) {
            events.append(.wifiChanged(name))
        }
        return events
    }
}

struct CustomNotice: Equatable {
    let source: CustomFeature
    let key: String
    let title: String
    let detail: String
    let icon: String

    var id: String { "\(source.rawValue):\(key)" }
}

struct CustomNoticeQueue {
    struct Entry: Equatable {
        let notice: CustomNotice
        let duration: TimeInterval
        let sound: Bool
    }

    private(set) var current: Entry?
    private(set) var expires: Date?
    private var pending: [Entry] = []
    private var recent: [String: Date] = [:]

    mutating func push(_ notice: CustomNotice, at date: Date, duration: TimeInterval, sound: Bool = false) {
        advance(at: date)
        recent = recent.filter { date.timeIntervalSince($0.value) < 8 }
        guard recent[notice.id] == nil, current?.notice.id != notice.id,
              !pending.contains(where: { $0.notice.id == notice.id }),
              pending.count < 8 else { return }
        recent[notice.id] = date
        pending.append(Entry(notice: notice, duration: max(1, min(duration, 30)), sound: sound))
        advance(at: date)
    }

    mutating func advance(at date: Date) {
        if let expires, expires > date { return }
        current = pending.isEmpty ? nil : pending.removeFirst()
        expires = current.map { date.addingTimeInterval($0.duration) }
    }

    mutating func remove(_ source: CustomFeature, at date: Date) {
        pending.removeAll { $0.notice.source == source }
        recent = recent.filter { !$0.key.hasPrefix(source.rawValue + ":") }
        if current?.notice.source == source {
            expires = nil
            advance(at: date)
        }
    }
}

struct PomodoroClock: Equatable {
    enum Phase: String { case focus, shortBreak, longBreak }

    private(set) var phase: Phase = .focus
    private(set) var deadline: Date?
    private(set) var remaining: TimeInterval?
    private var sessions = 0

    mutating func toggle(at date: Date, duration: TimeInterval) {
        if let deadline {
            remaining = max(0, deadline.timeIntervalSince(date))
            self.deadline = nil
        } else {
            deadline = date.addingTimeInterval(remaining ?? duration)
            remaining = nil
        }
    }

    mutating func applyDuration(_ duration: TimeInterval, at date: Date) {
        if deadline != nil {
            deadline = date.addingTimeInterval(duration)
        } else if remaining != nil {
            remaining = duration
        }
    }

    mutating func skip() {
        if phase == .focus {
            sessions += 1
            phase = sessions.isMultiple(of: 4) ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }
        deadline = nil
        remaining = nil
    }

    mutating func finishIfDue(at date: Date) -> Bool {
        guard let deadline, deadline <= date else { return false }
        skip()
        return true
    }
}

struct CalendarOccurrence: Equatable {
    let id: String
    let start: Date
    let end: Date

    static func active(in events: [Self], at date: Date) -> Self? {
        events.filter { $0.start <= date && date < $0.end }.min {
            if $0.end != $1.end { return $0.end < $1.end }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }
}

enum CalendarMonthGeometry {
    static func days(containing date: Date, calendar: Calendar) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let range = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var days = Array<Date?>(repeating: nil, count: leading)
        days += (0..<range.count).map { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        days += Array(repeating: nil, count: (7 - days.count % 7) % 7)
        return days
    }
}

struct EyeBreakClock: Equatable {
    private(set) var isResting = false
    private(set) var deadline: Date?
    private var remaining: TimeInterval?

    mutating func start(at now: Date, interval: TimeInterval) {
        isResting = false
        remaining = nil
        deadline = now.addingTimeInterval(max(1, interval))
    }

    mutating func stop() { self = .init() }

    @discardableResult
    mutating func advance(at now: Date, interval: TimeInterval, rest: TimeInterval) -> Bool {
        guard let deadline, deadline <= now else { return false }
        isResting.toggle()
        self.deadline = now.addingTimeInterval(max(1, isResting ? rest : interval))
        return true
    }

    mutating func postpone(at now: Date, seconds: TimeInterval) { start(at: now, interval: seconds) }

    mutating func suspend(at now: Date) {
        guard let deadline else { return }
        remaining = max(0, deadline.timeIntervalSince(now))
        self.deadline = nil
    }

    mutating func resume(at now: Date) {
        guard let remaining else { return }
        self.remaining = nil
        deadline = now.addingTimeInterval(remaining)
    }
}
