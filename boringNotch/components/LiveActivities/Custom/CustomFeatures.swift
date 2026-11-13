import AppKit
import Combine
import Defaults

struct CustomCalendarOptions: Codable, Defaults.Serializable, Equatable {
    var leadMinutes = 10
    var useEventAlarms = false
    var sound = false
    var calendarIDs: Set<String>?
    var endWarningMinutes = 5
    var showTitle = true
    var showCountdown = true
}

struct CustomPomodoroOptions: Codable, Defaults.Serializable, Equatable {
    var focus = 25
    var shortBreak = 5
    var longBreak = 15
    var countdown = true
    var notice = true

    func duration(_ phase: PomodoroClock.Phase) -> TimeInterval {
        let minutes = switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
        return TimeInterval(max(1, min(minutes, 180))) * 60
    }
}

struct CustomWellnessOptions: Codable, Defaults.Serializable, Equatable {
    var intervalMinutes = 20
    var breakSeconds = 20
    var snoozeMinutes = 5
    var sound = false
    var pauseMusic = false

    var interval: TimeInterval { TimeInterval(max(1, min(intervalMinutes, 180))) * 60 }
    var duration: TimeInterval { TimeInterval(max(5, min(breakSeconds, 300))) }
    var snooze: TimeInterval { TimeInterval(max(1, min(snoozeMinutes, 60))) * 60 }
}

struct CustomNetworkOptions: Codable, Defaults.Serializable, Equatable {
    var wifiConnections = true
    var connectionLoss = false
    var showName = false
    var seconds: Int?
}

extension Defaults.Keys {
    static let customNetworkOptions = Key<CustomNetworkOptions>("customNetworkOptions", default: .init())

    static let customWellnessOptions = Key<CustomWellnessOptions>("customWellnessOptions", default: .init())
    static let customFeatures = Key<Set<String>>("customFeatures", default: [])
    static let customCalendarOptions = Key<CustomCalendarOptions>("customCalendarOptions", default: .init())
    static let customPomodoroOptions = Key<CustomPomodoroOptions>("customPomodoroOptions", default: .init())
    static let customNoticeSeconds = Key<Int>("customNoticeSeconds", default: 4)
    static let customBluetoothSeconds = Key<Int>("customBluetoothSeconds", default: 4)
}

extension CustomFeature {
    var isEnabled: Bool { Defaults[.customFeatures].contains(rawValue) }
}

struct CustomActivity: Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    var deadline: Date?
}

@MainActor
final class CustomFeatures: ObservableObject {
    static let shared = CustomFeatures()

    @Published private(set) var wellness = EyeBreakClock()
    private var wellnessEnabled = false
    private var wellnessTask: Task<Void, Never>?
    private var wellnessObservers: [NSObjectProtocol] = []
    private var wellnessSuspensions: Set<String> = []
    private var wellnessSession = UUID()
    private var resumeMusic: (@MainActor () async -> Void)?

    @Published private(set) var notice: CustomNotice?
    @Published private(set) var capsLock = false
    @Published private(set) var pomodoro = PomodoroClock()
    @Published private(set) var eventActivity: CustomActivity?
    @Published private(set) var pomodoroActivity: CustomActivity?

    private var subscriptions = Set<AnyCancellable>()
    private var notices = CustomNoticeQueue()
    private var noticeTask: Task<Void, Never>?
    private var pomodoroTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?
    private var wifiMonitor: CustomNetwork?
    private var wifiLife = SourceLifecycle()
    private var wifiSleepObservers: [NSObjectProtocol] = []
    private var wifiAsleep = false
    private var capsLife = SourceLifecycle()
    private var capsGlobal: Any?
    private var capsLocal: Any?
    private let bluetooth = CustomBluetooth.shared
    private let calendar = CustomEventSchedule()
    private var calendarFlags: Set<String> = []

    private init() {}

    func start() {
        guard subscriptions.isEmpty else { return }
        Defaults.publisher(.customFeatures).sink { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }.store(in: &subscriptions)
        Defaults.publisher(.customCalendarOptions).sink { [weak self] _ in
            Task { @MainActor in self?.calendar.reload() }
        }.store(in: &subscriptions)
        Defaults.publisher(.customPomodoroOptions).sink { [weak self] change in
            Task { @MainActor in
                guard let self, CustomFeature.pomodoro.isEnabled else { return }
                let phase = self.pomodoro.phase
                let duration = change.newValue.duration(phase)
                guard duration != change.oldValue.duration(phase) else {
                    self.publishPomodoro()
                    return
                }
                var clock = self.pomodoro
                clock.applyDuration(duration, at: Date())
                if clock != self.pomodoro { self.pomodoro = clock }
                self.armPomodoro()
            }
        }.store(in: &subscriptions)
        Defaults.publisher(.customWellnessOptions).sink { [weak self] _ in
            Task { @MainActor in self?.restartWellness() }
        }.store(in: &subscriptions)
        Defaults.publisher(.customNetworkOptions, options: []).sink { [weak self] change in
            Task { @MainActor in
                guard let self, !self.subscriptions.isEmpty, CustomFeature.wifi.isEnabled else { return }
                if change.oldValue.showName != change.newValue.showName
                    || change.oldValue.wifiConnections != change.newValue.wifiConnections
                    || change.oldValue.connectionLoss != change.newValue.connectionLoss {
                    self.resetWiFi()
                    self.startWiFi()
                }
            }
        }.store(in: &subscriptions)
        reconcile()
    }

    func stop() {
        subscriptions.removeAll()
        stopWellness()
        stopWiFi()
        stopCapsLock()
        bluetooth.stop()
        calendar.stop()
        calendarFlags = []
        updateClockObservers(enabled: false)
        pomodoroTask?.cancel()
        pomodoroTask = nil
        pomodoro = .init()
        publishPomodoro()
        noticeTask?.cancel()
        noticeTask = nil
        notices = .init()
        notice = nil
        eventActivity = nil
    }

    private func reconcile() {
        guard !subscriptions.isEmpty else { return }
        let calendarFlags = Defaults[.customFeatures].intersection([
            CustomFeature.eventAlerts.rawValue, CustomFeature.eventCountdown.rawValue
        ])
        let eventEnabled = !calendarFlags.isEmpty
        if calendarFlags != self.calendarFlags {
            self.calendarFlags = calendarFlags
            if eventEnabled {
                calendar.start(publish: { [weak self] activity in
                    guard let self, eventActivity != activity else { return }
                    eventActivity = activity
                }, notify: { [weak self] notice, sound in self?.enqueue(notice, sound: sound) },
                clearNotices: { [weak self] in self?.clearCalendarNotices() })
                if !CustomFeature.eventCountdown.isEnabled { eventActivity = nil }
                calendar.reload()
            } else {
                calendar.stop()
                if eventActivity != nil { eventActivity = nil }
            }
        }

        if CustomFeature.bluetooth.isEnabled || CustomFeature.accessoryBattery.isEnabled {
            bluetooth.start { [weak self] notice in self?.enqueue(notice) }
        } else {
            bluetooth.stop()
        }
        if CustomFeature.wifi.isEnabled { startWiFi() } else { stopWiFi() }
        if CustomFeature.capsLock.isEnabled { startCapsLock() } else { stopCapsLock() }
        if !CustomFeature.pomodoro.isEnabled {
            pomodoroTask?.cancel()
            pomodoroTask = nil
            if pomodoro != PomodoroClock() { pomodoro = .init() }
            publishPomodoro()
        }
        if CustomFeature.wellness.isEnabled {
            if !wellnessEnabled { startWellness() }
        } else if wellnessEnabled { stopWellness() }
        updateClockObservers(enabled: eventEnabled || CustomFeature.pomodoro.isEnabled)
        let now = Date()
        for feature in CustomFeature.allCases where !feature.isEnabled {
            notices.remove(feature, at: now)
        }
        publishNotice()
    }

    var wellnessActivity: CustomActivity? {
        guard wellnessEnabled, wellness.isResting, let deadline = wellness.deadline else { return nil }
        return CustomActivity(id: "wellness", title: "Eye break", detail: "Look away from the screen", icon: "eye", deadline: deadline)
    }

    private func startWellness() {
        wellnessEnabled = true
        wellnessSession = UUID()
        wellness.start(at: Date(), interval: Defaults[.customWellnessOptions].interval)
        let center = NSWorkspace.shared.notificationCenter
        for (name, reason, suspend) in [
            (NSWorkspace.willSleepNotification, "sleep", true),
            (NSWorkspace.didWakeNotification, "sleep", false),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session", false),
            (NSWorkspace.screensDidSleepNotification, "display", true),
            (NSWorkspace.screensDidWakeNotification, "display", false)
        ] {
            wellnessObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspendWellness(reason: reason, suspended: suspend) }
            })
        }
        armWellness()
    }

    private func stopWellness() {
        wellnessEnabled = false
        wellnessSession = UUID()
        wellnessTask?.cancel()
        wellnessTask = nil
        wellnessObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        wellnessObservers.removeAll()
        wellnessSuspensions.removeAll()
        wellness.stop()
        restoreBreakMusic()
    }

    private func restartWellness() {
        guard wellnessEnabled else { return }
        wellnessSession = UUID()
        restoreBreakMusic()
        wellness.start(at: Date(), interval: Defaults[.customWellnessOptions].interval)
        if !wellnessSuspensions.isEmpty { wellness.suspend(at: Date()) }
        armWellness()
    }

    func suspendWellness(reason: String, suspended: Bool) {
        guard wellnessEnabled else { return }
        if suspended {
            guard wellnessSuspensions.insert(reason).inserted else { return }
            if wellness.isResting {
                restoreBreakMusic()
                wellness.start(at: Date(), interval: Defaults[.customWellnessOptions].interval)
            }
            wellness.suspend(at: Date())
        } else {
            wellnessSuspensions.remove(reason)
            if wellnessSuspensions.isEmpty { wellness.resume(at: Date()) }
        }
        armWellness()
    }

    func skipEyeBreak(snooze: Bool = false) {
        guard wellnessEnabled, wellness.isResting else { return }
        wellnessSession = UUID()
        restoreBreakMusic()
        let options = Defaults[.customWellnessOptions]
        wellness.postpone(at: Date(), seconds: snooze ? options.snooze : options.interval)
        armWellness()
    }

    private func armWellness() {
        wellnessTask?.cancel()
        wellnessTask = nil
        guard wellnessEnabled, let deadline = wellness.deadline else { return }
        let session = wellnessSession
        wellnessTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled, self.wellnessSession == session else { return }
            let options = Defaults[.customWellnessOptions]
            guard self.wellness.advance(at: Date(), interval: options.interval, rest: options.duration) else { self.armWellness(); return }
            if self.wellness.isResting {
                if options.sound { NSSound.beep() }
                if options.pauseMusic {
                    Task { [weak self] in
                        let resume = await MusicManager.shared.pauseForEyeBreak()
                        guard let self, self.wellnessSession == session, self.wellness.isResting else {
                            await resume?()
                            return
                        }
                        self.resumeMusic = resume
                    }
                }
            } else { self.restoreBreakMusic() }
            self.armWellness()
        }
    }

    private func restoreBreakMusic() {
        let resume = resumeMusic
        resumeMusic = nil
        if let resume { Task { await resume() } }
    }

    private func clearCalendarNotices() {
        let now = Date()
        notices.remove(.eventAlerts, at: now)
        notices.remove(.eventCountdown, at: now)
        publishNotice()
    }

    private func enqueue(_ message: CustomNotice, sound: Bool = false) {
        guard message.source.isEnabled else { return }
        let duration = switch message.source {
        case .bluetooth: Defaults[.customBluetoothSeconds]
        case .wifi: Defaults[.customNetworkOptions].seconds ?? Defaults[.customNoticeSeconds]
        default: Defaults[.customNoticeSeconds]
        }
        notices.push(message, at: Date(), duration: TimeInterval(duration), sound: sound)
        publishNotice()
    }

    private func publishNotice() {
        let next = notices.current?.notice
        guard notice != next || (next != nil && noticeTask == nil) else { return }
        if notice != next, notices.current?.sound == true { NSSound.beep() }
        notice = next
        noticeTask?.cancel()
        noticeTask = nil
        guard let expires = notices.expires else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expires.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            noticeTask = nil
            notices.advance(at: Date())
            publishNotice()
        }
    }

    func togglePomodoro() {
        guard CustomFeature.pomodoro.isEnabled else { return }
        settlePomodoro()
        var clock = pomodoro
        clock.toggle(at: Date(), duration: Defaults[.customPomodoroOptions].duration(clock.phase))
        pomodoro = clock
        armPomodoro()
    }

    func resetPomodoro() {
        guard CustomFeature.pomodoro.isEnabled else { return }
        pomodoro = .init()
        armPomodoro()
    }

    func skipPomodoro() {
        guard CustomFeature.pomodoro.isEnabled else { return }
        pomodoro.skip()
        armPomodoro()
    }

    private func settlePomodoro() {
        guard CustomFeature.pomodoro.isEnabled else { return }
        var clock = pomodoro
        guard clock.finishIfDue(at: Date()) else { return }
        pomodoro = clock
        if Defaults[.customPomodoroOptions].notice {
            enqueue(.init(source: .pomodoro, key: UUID().uuidString, title: "Pomodoro complete",
                          detail: clock.phase.label, icon: "timer"))
        }
    }

    private func publishPomodoro() {
        let activity: CustomActivity? = if CustomFeature.pomodoro.isEnabled,
                                          Defaults[.customPomodoroOptions].countdown,
                                          let deadline = pomodoro.deadline {
            CustomActivity(id: "pomodoro", title: pomodoro.phase.label, detail: "", icon: "timer", deadline: deadline)
        } else {
            nil
        }
        if activity != pomodoroActivity { pomodoroActivity = activity }
    }

    private func armPomodoro() {
        pomodoroTask?.cancel()
        pomodoroTask = nil
        publishPomodoro()
        guard let deadline = pomodoro.deadline else { return }
        pomodoroTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            settlePomodoro()
            armPomodoro()
        }
    }

    private func updateClockObservers(enabled: Bool) {
        let workspace = NSWorkspace.shared.notificationCenter
        if enabled, wakeObserver == nil {
            wakeObserver = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in self?.clockChanged() }
            }
            clockObserver = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in self?.clockChanged() }
            }
        } else if !enabled {
            if let wakeObserver { workspace.removeObserver(wakeObserver) }
            if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
            wakeObserver = nil
            clockObserver = nil
        }
    }

    private func clockChanged() {
        guard wakeObserver != nil else { return }
        settlePomodoro()
        armPomodoro()
        calendar.reload()
    }

    private func startWiFi() {
        let options = Defaults[.customNetworkOptions]
        guard options.wifiConnections || options.connectionLoss else { stopWiFi(); return }
        if wifiSleepObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
                wifiSleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, CustomFeature.wifi.isEnabled, !self.wifiSleepObservers.isEmpty else { return }
                        self.wifiAsleep = sleeping
                        self.resetWiFi()
                        if !sleeping { self.startWiFi() }
                    }
                })
            }
        }
        guard !wifiAsleep, let session = wifiLife.start() else { return }
        wifiMonitor = CustomNetwork(showName: options.showName, observeWiFi: options.wifiConnections,
                                    reportConnection: options.connectionLoss) { [weak self] event in
            Task { @MainActor in
                guard let self, self.wifiLife.accepts(session) else { return }
                self.handleNetworkEvent(event)
            }
        }
    }

    private func handleNetworkEvent(_ event: NetworkTransition.Event) {
        let options = Defaults[.customNetworkOptions]
        let title: String
        let detail: String
        let icon: String
        switch event {
        case .wifiConnected(let name), .wifiChanged(let name):
            guard options.wifiConnections else { return }
            if case .wifiChanged = event { title = String(localized: "Wi-Fi network changed") }
            else { title = String(localized: "Wi-Fi connected") }
            detail = (options.showName ? name : nil) ?? String(localized: "Connected")
            icon = "wifi"
        case .wifiDisconnected:
            guard options.wifiConnections else { return }
            title = "Wi-Fi"
            detail = String(localized: "Disconnected")
            icon = "wifi.slash"
        case .connectionLost:
            guard options.connectionLoss else { return }
            title = String(localized: "Network")
            detail = String(localized: "Connection lost")
            icon = "wifi.slash"
        case .connectionRestored:
            guard options.connectionLoss else { return }
            title = String(localized: "Network")
            detail = String(localized: "Connection restored")
            icon = "network"
        }
        enqueue(.init(source: .wifi, key: UUID().uuidString, title: title, detail: detail, icon: icon))
    }

    private func resetWiFi() {
        if wifiLife.stop() {
            wifiMonitor?.stop()
            wifiMonitor = nil
        }
        notices.remove(.wifi, at: Date())
        publishNotice()
    }

    private func stopWiFi() {
        guard !wifiSleepObservers.isEmpty else { return }
        wifiSleepObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        wifiSleepObservers = []
        wifiAsleep = false
        resetWiFi()
    }

    private func startCapsLock() {
        guard let session = capsLife.start() else { return }
        setCaps(CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift))
        let handle: (NSEvent) -> Void = { [weak self] event in
            let active = event.modifierFlags.contains(.capsLock)
            Task { @MainActor in
                guard let self, self.capsLife.accepts(session) else { return }
                self.setCaps(active)
            }
        }
        capsGlobal = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle)
        capsLocal = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event)
            return event
        }
    }

    private func stopCapsLock() {
        guard capsLife.stop() else { return }
        if let capsGlobal { NSEvent.removeMonitor(capsGlobal) }
        if let capsLocal { NSEvent.removeMonitor(capsLocal) }
        capsGlobal = nil
        capsLocal = nil
        setCaps(false)
    }

    private func setCaps(_ active: Bool) {
        if capsLock != active { capsLock = active }
    }
}

extension PomodoroClock.Phase {
    var label: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }
}
