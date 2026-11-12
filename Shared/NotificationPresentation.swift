import Foundation

struct NotificationPresentation<Notice: Identifiable & Equatable> where Notice.ID == String {
    private(set) var active: Notice?
    private(set) var queued: [Notice] = []
    private(set) var deadline: Date?
    private(set) var isHovered = false
    private(set) var isComposing = false
    private var duration: TimeInterval = 8
    private var remaining: TimeInterval?

    mutating func receive(_ notice: Notice, at now: Date) {
        if active == notice { return }
        if active?.id == notice.id, !isComposing {
            active = notice
            queued.removeAll { $0.id == notice.id }
            resetDeadline(at: now)
            return
        }
        if let index = queued.firstIndex(where: { $0.id == notice.id }) {
            queued[index] = notice
            return
        }
        if active == nil {
            active = notice
            resetDeadline(at: now)
        } else {
            if queued.count == 5 { queued.removeFirst() }
            queued.append(notice)
        }
    }

    mutating func dismiss(token: String? = nil, at now: Date) {
        guard token == nil || token == active?.id else { return }
        active = queued.isEmpty ? nil : queued.removeFirst()
        isComposing = false
        resetDeadline(at: now)
    }

    @discardableResult
    mutating func expire(token: String, at now: Date) -> Bool {
        guard active?.id == token, let deadline, deadline <= now else { return false }
        dismiss(token: token, at: now)
        return true
    }

    mutating func showNext(at now: Date) {
        guard !queued.isEmpty else { return }
        let next = queued.removeFirst()
        if let active, active.id != next.id { queued.append(active) }
        active = next
        isComposing = false
        resetDeadline(at: now)
    }

    mutating func setHovered(_ hovered: Bool, at now: Date) {
        guard hovered != isHovered else { return }
        let wasHeld = isHovered || isComposing
        isHovered = hovered
        updateHold(wasHeld: wasHeld, at: now)
    }

    mutating func setComposing(_ composing: Bool, at now: Date) {
        guard composing != isComposing, active != nil else { return }
        let wasHeld = isHovered || isComposing
        isComposing = composing
        updateHold(wasHeld: wasHeld, at: now)
    }

    private mutating func updateHold(wasHeld: Bool, at now: Date) {
        let held = isHovered || isComposing
        guard held != wasHeld else { return }
        if held {
            remaining = deadline.map { max(0, $0.timeIntervalSince(now)) }
            deadline = nil
        } else if active != nil, duration > 0 {
            deadline = now.addingTimeInterval(remaining ?? duration)
            remaining = nil
        }
    }

    mutating func setDuration(_ seconds: TimeInterval, at now: Date) {
        duration = [0.0, 2, 3, 5, 8, 10, 15, 30].contains(seconds) ? seconds : 8
        resetDeadline(at: now)
    }

    mutating func filter(_ allowed: (Notice) -> Bool, at now: Date) {
        queued.removeAll { !allowed($0) }
        if let active, !allowed(active) { dismiss(at: now) }
    }

    mutating func clear() {
        active = nil
        queued.removeAll()
        isHovered = false
        isComposing = false
        deadline = nil
        remaining = nil
    }

    private mutating func resetDeadline(at now: Date) {
        remaining = nil
        deadline = active != nil && duration > 0 && !isHovered && !isComposing ? now.addingTimeInterval(duration) : nil
    }
}

struct NotificationRetryBudget {
    private var attempts = 0
    private var connectedAt: Date?

    mutating func connected(at date: Date) { connectedAt = date }

    mutating func nextDelay(at now: Date) -> TimeInterval? {
        if let connectedAt, now.timeIntervalSince(connectedAt) >= 30 { attempts = 0 }
        connectedAt = nil
        guard attempts < 6 else { return nil }
        defer { attempts += 1 }
        return TimeInterval(1 << attempts)
    }
}
