import Combine
import Defaults
import Foundation

struct TimedCalendarEvent: Sendable {
    let id: String
    let title: String
    let location: String?
    let start: Date
    let end: Date
    let alarms: [Date]

    var occurrence: CalendarOccurrence {
        .init(id: id, start: start, end: end)
    }
}

@MainActor
final class CustomEventSchedule {
    private var changes: AnyCancellable?
    private var fetch: Task<Void, Never>?
    private var alarm: Task<Void, Never>?
    private var events: [TimedCalendarEvent] = []
    private var delivered: Set<String> = []
    private var horizon: Date?
    private var publish: ((CustomActivity?) -> Void)?
    private var notify: ((CustomNotice, Bool) -> Void)?

    func start(
        publish: @escaping (CustomActivity?) -> Void,
        notify: @escaping (CustomNotice, Bool) -> Void,
        clearNotices: @escaping () -> Void
    ) {
        guard changes == nil else { return }
        self.publish = publish
        self.notify = notify
        CalendarManager.shared.startObservingStore()
        changes = CalendarManager.shared.storeRevision.sink { [weak self] in
            clearNotices()
            self?.reload()
        }
    }

    func stop() {
        if changes != nil { CalendarManager.shared.stopObservingStore() }
        changes = nil
        fetch?.cancel()
        fetch = nil
        alarm?.cancel()
        alarm = nil
        events.removeAll()
        delivered.removeAll()
        horizon = nil
        publish = nil
        notify = nil
    }

    func reload() {
        guard changes != nil else { return }
        fetch?.cancel()
        alarm?.cancel()
        alarm = nil
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now.addingTimeInterval(172800)
        let ids = Defaults[.customCalendarOptions].calendarIDs
        fetch = Task { [weak self] in
            let result = await CalendarManager.shared.customTimedEvents(from: now, to: end, calendarIDs: ids)
            guard let self, !Task.isCancelled else { return }
            fetch = nil
            events = result
            horizon = end.addingTimeInterval(-86400)
            evaluate()
        }
    }

    private func evaluate() {
        alarm?.cancel()
        alarm = nil
        let now = Date()
        let options = Defaults[.customCalendarOptions]
        var next = horizon ?? now.addingTimeInterval(86400)
        let active = CalendarOccurrence.active(in: events.map(\.occurrence), at: now)
        let countdownEnabled = CustomFeature.eventCountdown.isEnabled
        if countdownEnabled, let active, let event = events.first(where: { $0.id == active.id }),
           options.showTitle || options.showCountdown {
            publish?(.init(id: "event", title: options.showTitle ? event.title : "Calendar",
                           detail: "", icon: "calendar", deadline: options.showCountdown ? event.end : nil))
        } else {
            publish?(nil)
        }

        var validKeys = Set<String>()
        for event in events {
            if event.start > now { next = min(next, event.start) }
            if event.end > now { next = min(next, event.end) }
            if CustomFeature.eventAlerts.isEnabled, event.start > now.addingTimeInterval(-60) {
                let dates = options.useEventAlarms ? event.alarms : [
                    event.start.addingTimeInterval(-60 * Double(max(1, min(options.leadMinutes, 60))))
                ]
                for date in dates where date <= event.start {
                    let detail = ([event.start.formatted(date: .omitted, time: .shortened)] +
                                  [event.location].compactMap { $0 }).joined(separator: " · ")
                    schedule(event, at: date, now: now, next: &next, validKeys: &validKeys, source: .eventAlerts,
                             detail: detail, sound: options.sound)
                }
            }
            if countdownEnabled, event.end > now, options.endWarningMinutes > 0 {
                let warning = max(event.start, event.end.addingTimeInterval(-60 * Double(options.endWarningMinutes)))
                if active?.id == event.id || event.start > now {
                    schedule(event, at: warning, now: now, next: &next, validKeys: &validKeys,
                             source: .eventCountdown, detail: "Ends at \(event.end.formatted(date: .omitted, time: .shortened))",
                             sound: options.sound)
                }
            }
        }
        delivered.formIntersection(validKeys)

        alarm = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            if let horizon, horizon <= Date() { reload() } else { evaluate() }
        }
    }

    private func schedule(
        _ event: TimedCalendarEvent, at date: Date, now: Date, next: inout Date, validKeys: inout Set<String>,
        source: CustomFeature, detail: String, sound: Bool
    ) {
        let key = "\(source.rawValue):\(event.id):\(date.timeIntervalSinceReferenceDate)"
        validKeys.insert(key)
        if date > now {
            next = min(next, date)
        } else if now.timeIntervalSince(date) < 60, delivered.insert(key).inserted {
            notify?(.init(source: source, key: key, title: event.title, detail: detail, icon: "calendar"), sound)
        }
    }
}
