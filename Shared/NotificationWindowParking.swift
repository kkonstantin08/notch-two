import Foundation
import CoreGraphics

struct NotificationWindowLease: Codable, Equatable, Sendable {
    let id: String
    let session: String
    let pid: Int32
    let windowID: UInt32
    let origin: CGPoint
    let hidden: CGPoint

    init(session: String, pid: Int32, windowID: UInt32, origin: CGPoint) {
        let uuid = UUID()
        id = uuid.uuidString
        self.session = session
        self.pid = pid
        self.windowID = windowID
        self.origin = origin
        let digits = id.replacingOccurrences(of: "-", with: "")
        hidden = CGPoint(x: -10000 - Double(Int(digits.prefix(4), radix: 16)!),
                         y: -10000 - Double(Int(digits.dropFirst(4).prefix(4), radix: 16)!))
    }

    var isValid: Bool {
        UUID(uuidString: id) != nil && UUID(uuidString: session) != nil && pid > 1 && windowID > 0
            && origin.x.isFinite && origin.y.isFinite && abs(origin.x) < 100000 && abs(origin.y) < 100000
            && hidden.x.isFinite && hidden.y.isFinite
            && (-75535 ... -10000).contains(hidden.x) && (-75535 ... -10000).contains(hidden.y)
    }
}

struct NotificationWindowParkingState {
    struct Ticket {
        let window: UInt
        let revision: UUID
        let deadline: Date
    }
    private struct Entry {
        let lease: NotificationWindowLease
        var ticket: Ticket?
        var replyLayoutDeadline: Date?
    }
    private var entries: [UInt: Entry] = [:]
    var windows: Set<UInt> { Set(entries.keys) }
    func lease(for window: UInt) -> NotificationWindowLease? { entries[window]?.lease }

    func restoredWindows(pid: Int32, windowID: UInt32, position: CGPoint) -> [UInt] {
        entries.compactMap { key, entry in
            let lease = entry.lease
            guard lease.pid == pid, lease.windowID == windowID,
                  abs(lease.origin.x - position.x) < 1, abs(lease.origin.y - position.y) < 1 else { return nil }
            return key
        }
    }

    mutating func insert(_ lease: NotificationWindowLease, for window: UInt) {
        entries[window] = Entry(lease: lease)
    }
    mutating func keepHidden(_ window: UInt) { entries[window]?.ticket = nil }
    mutating func scheduleRestore(for window: UInt, at now: Date) -> Ticket? {
        guard entries[window] != nil, entries[window]?.ticket == nil else { return nil }
        // The banner can disappear from AX before Notification Center finishes fading it out.
        let ticket = Ticket(window: window, revision: UUID(), deadline: now.addingTimeInterval(0.7))
        entries[window]?.ticket = ticket
        return ticket
    }
    mutating func scheduleSettledRetry(for window: UInt, at now: Date) -> Ticket? {
        guard entries[window] != nil else { return nil }
        let ticket = Ticket(window: window, revision: UUID(), deadline: now.addingTimeInterval(0.1))
        entries[window]?.ticket = ticket
        return ticket
    }
    func leaseToRestore(_ ticket: Ticket, at now: Date) -> NotificationWindowLease? {
        guard now >= ticket.deadline, entries[ticket.window]?.ticket?.revision == ticket.revision else { return nil }
        return entries[ticket.window]?.lease
    }
    mutating func expectReplyLayoutChange(for window: UInt, at now: Date, duration: TimeInterval = 0.35) {
        entries[window]?.replyLayoutDeadline = now.addingTimeInterval(duration)
    }
    func allowsReplyLayoutChange(for window: UInt, at now: Date) -> Bool {
        guard let deadline = entries[window]?.replyLayoutDeadline else { return false }
        return now <= deadline
    }
    mutating func remove(_ window: UInt) { entries[window] = nil }
    mutating func takeAll() -> [NotificationWindowLease] {
        defer { entries.removeAll() }
        return entries.values.map(\.lease)
    }
}

enum NotificationReplyReadiness {
    case waiting, ready, invalid

    static let timeout: TimeInterval = 0.9

    @MainActor
    static func wait(check: () -> Self) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
        while !Task.isCancelled {
            switch check() {
            case .ready: return true
            case .invalid: return false
            case .waiting:
                guard clock.now < deadline else { return false }
                try? await clock.sleep(until: min(deadline, clock.now + .milliseconds(100)))
            }
        }
        return false
    }
}
