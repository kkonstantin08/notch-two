//
//  SystemNotificationManager.swift
//  boringNotch
//
import AppKit
import Combine
import Defaults
import OSLog

struct SystemNotification: Identifiable, Equatable {
    let id: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?
    let receivedAt: Date
    var nativeActionID: String? = nil

    var isTelegram: Bool { bundleID == "ru.keepcoder.Telegram" }
}

@MainActor
final class SystemNotificationManager: ObservableObject {
    static let shared = SystemNotificationManager()

    @Published private(set) var activeNotification: SystemNotification?
    @Published private(set) var queuedNotifications: [SystemNotification] = []

    private let log = Logger(subsystem: "local.notchtwo.app", category: "NotificationMirror")
    private var presentation = NotificationPresentation<SystemNotification>()
    private var dismissTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var watchingSession: UUID?
    private var retryBudget = NotificationRetryBudget()
    private var isOpeningNotification = false

    private init() {}

    func start() async {
        guard Defaults[.notificationLiveActivity], watchingSession == nil else { return }
        let session = UUID()
        watchingSession = session
        presentation.setDuration(Defaults[.notificationDisplayDuration], at: Date())
        observe()
        await connect(session: session)
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .systemNotificationDidAppear, object: nil, queue: .main) { [weak self] note in
            guard let payload = note.userInfo as? [String: String] else { return }
            Task { @MainActor in self?.add(payload) }
        })
        observers.append(center.addObserver(forName: .systemNotificationUsesNative, object: nil, queue: .main) { [weak self] note in
            let tokens = Set(note.userInfo?["tokens"] as? [String] ?? [])
            let session = note.userInfo?["mirrorSession"] as? String
            Task { @MainActor in
                guard let self, session.map({ XPCHelperClient.shared.isCurrentNotificationSession($0) }) != false else { return }
                self.presentation.filter({ !tokens.contains($0.id) }, at: Date())
                self.publish()
            }
        })
        observers.append(center.addObserver(forName: .xpcHelperConnectionLost, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.presentation.clear()
                self?.publish()
                self?.scheduleRecovery()
            }
        })
        for name in [NSApplication.didBecomeActiveNotification, .accessibilityAuthorizationChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recoverFromSystemEvent() }
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.recoverFromSystemEvent() } })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier == "com.apple.notificationcenterui" else { return }
            Task { @MainActor in self?.recoverFromSystemEvent() }
        })
        Defaults.publisher(.notificationDisplayDuration).sink { [weak self] change in
            Task { @MainActor in
                guard let self, self.watchingSession != nil else { return }
                self.presentation.setDuration(change.newValue, at: Date())
                self.publish()
            }
        }.store(in: &subscriptions)
        for publisher in [Defaults.publisher(.notificationsFromAllApps).map { _ in () }.eraseToAnyPublisher(),
                          Defaults.publisher(.notificationAllowedApps).map { _ in () }.eraseToAnyPublisher(),
                          Defaults.publisher(.notificationExcludedApps).map { _ in () }.eraseToAnyPublisher()] {
            publisher.sink { [weak self] in Task { @MainActor in self?.updateFilter() } }.store(in: &subscriptions)
        }
    }

    private func connect(session: UUID) async {
        guard !Task.isCancelled, watchingSession == session, Defaults[.notificationLiveActivity] else { return }
        let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
        guard !Task.isCancelled, watchingSession == session, Defaults[.notificationLiveActivity] else { return }
        guard authorized else {
            XPCHelperClient.shared.stopNotificationWatching()
            scheduleRecovery()
            return
        }
        let (bundleIDs, allApps) = filterSelection
        let started = await XPCHelperClient.shared.startNotificationWatching(bundleIDs: bundleIDs, allApps: allApps)
        guard !Task.isCancelled, watchingSession == session, Defaults[.notificationLiveActivity] else { return }
        if started { retryBudget.connected(at: Date()) } else { scheduleRecovery() }
    }

    private func recoverFromSystemEvent() {
        guard let session = watchingSession else { return }
        recoveryTask?.cancel()
        retryBudget = .init()
        recoveryTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.connect(session: session)
        }
    }

    private func scheduleRecovery() {
        guard let session = watchingSession else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        guard let delay = retryBudget.nextDelay(at: Date()) else { return }
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.watchingSession == session else { return }
            self.recoveryTask = nil
            await self.connect(session: session)
        }
    }

    func stop() {
        watchingSession = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        retryBudget = .init()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        subscriptions.removeAll()
        XPCHelperClient.shared.stopNotificationWatching()
        presentation.clear()
        publish()
    }

    func holdActive() {
        presentation.setHovered(true, at: Date())
        publish()
    }

    func resumeDismiss() {
        presentation.setHovered(false, at: Date())
        publish()
    }

    func beginReply(to notification: SystemNotification) -> Bool {
        guard Defaults[.telegramNotificationReplies], activeNotification == notification,
              !presentation.isComposing, !isOpeningNotification else { return false }
        presentation.setComposing(true, at: Date())
        publish()
        return true
    }

    func endReply(to notification: SystemNotification) {
        guard activeNotification == notification else { return }
        presentation.setComposing(false, at: Date())
        publish()
    }

    func dismissActive(token: String? = nil) {
        presentation.dismiss(token: token, at: Date())
        publish()
    }

    func dismiss(_ notification: SystemNotification) {
        guard activeNotification == notification else { return }
        dismissActive(token: notification.id)
    }

    func showNextQueued() {
        presentation.showNext(at: Date())
        publish()
    }

    private func publish() {
        if activeNotification != presentation.active { activeNotification = presentation.active }
        if queuedNotifications != presentation.queued { queuedNotifications = presentation.queued }
        dismissTask?.cancel()
        dismissTask = nil
        guard let deadline = presentation.deadline, let token = presentation.active?.id else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            _ = self.presentation.expire(token: token, at: Date())
            self.publish()
        }
    }

    func openAndDismiss(_ notification: SystemNotification, fromReplyFallback: Bool = false) async {
        guard (activeNotification == notification || fromReplyFallback),
              !presentation.isComposing, !isOpeningNotification else { return }
        isOpeningNotification = true
        defer { isOpeningNotification = false }
        if await open(notification) { dismiss(notification) }
    }

    private func open(_ notification: SystemNotification) async -> Bool {
        if let actionID = notification.nativeActionID,
           await XPCHelperClient.shared.openNotification(actionID) { return true }

        let workspace = NSWorkspace.shared

        for bundleID in candidateBundleIDs(for: notification) {
            let running = workspace.runningApplications.first { application in
                guard !application.isTerminated,
                      let applicationBundleID = application.bundleIdentifier else { return false }
                return normalizeBundleIdentifier(applicationBundleID) == bundleID
            }

            if let running {
                if running.activate(options: [.activateAllWindows]) {
                    return true
                }
                if let appURL = running.bundleURL,
                   await launchApplication(at: appURL) {
                    return true
                }
            }

            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID),
               await launchApplication(at: appURL) {
                return true
            }
        }

        return false
    }

    private func add(_ payload: [String: String]) {
        guard watchingSession != nil, Defaults[.notificationLiveActivity],
              let token = payload["token"], !token.isEmpty else { return }
        if let session = payload["mirrorSession"], !XPCHelperClient.shared.isCurrentNotificationSession(session) { return }
        let appName = nonEmpty(payload["appName"])
        var bundleID = nonEmpty(payload["bundleID"]).map {
            normalizeBundleIdentifier($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // The helper only has the banner's display name and can miss when the
        // source is a helper process or is no longer running. Re-resolve here
        // so both the icon and launch action get the real application.
        if bundleID.map(isLaunchable) != true,
           let appName,
           let resolved = BundleIDResolver.shared.bundleID(forAppNamed: appName) {
            let resolved = normalizeBundleIdentifier(resolved)
            bundleID = resolved
        }

        let notification = SystemNotification(
            id: token,
            appName: appName,
            bundleID: bundleID,
            title: nonEmpty(payload["title"]),
            subtitle: nonEmpty(payload["subtitle"]),
            body: nonEmpty(payload["body"]),
            receivedAt: Date(),
            nativeActionID: payload["actionID"]
        )
        guard isAllowed(notification) else { log.debug("Banner rejected by app filter"); return }
        log.debug("Visible banner accepted by app")
        presentation.receive(notification, at: Date(), prioritize: notification.isTelegram)
        publish()
    }

    private var filterSelection: (bundleIDs: Set<String>, allApps: Bool) {
        let allApps = Defaults[.notificationsFromAllApps]
        return (allApps ? Defaults[.notificationExcludedApps] : Defaults[.notificationAllowedApps], allApps)
    }

    func updateFilter() {
        let (bundleIDs, allApps) = filterSelection
        let filter = NotificationAppFilter(bundleIDs: bundleIDs, allApps: allApps)
        presentation.filter({ filter.allows(bundleID: $0.bundleID, appName: $0.appName) }, at: Date())
        publish()
        if Defaults[.notificationLiveActivity] {
            XPCHelperClient.shared.setNotificationFilter(bundleIDs: bundleIDs, allApps: allApps)
        }
    }

    private func isAllowed(_ notification: SystemNotification) -> Bool {
        let (bundleIDs, allApps) = filterSelection
        return NotificationAppFilter(bundleIDs: bundleIDs, allApps: allApps)
            .allows(bundleID: notification.bundleID, appName: notification.appName)
    }

    private func candidateBundleIDs(for notification: SystemNotification) -> [String] {
        let resolved: String?
        if let bundleID = notification.bundleID, isLaunchable(bundleID) {
            resolved = nil
        } else {
            resolved = notification.appName.flatMap {
                BundleIDResolver.shared.bundleID(forAppNamed: $0)
            }
        }
        return Self.bundleIDCandidates(for: notification, resolvedBundleID: resolved)
    }

    nonisolated static func bundleIDCandidates(
        for notification: SystemNotification,
        resolvedBundleID: String? = nil
    ) -> [String] {
        var result: [String] = []
        for candidate in [notification.bundleID, resolvedBundleID].compactMap({ $0 }) {
            let normalized = normalizeBundleIdentifier(candidate)
            guard !normalized.isEmpty, !result.contains(normalized) else { continue }
            result.append(normalized)
        }
        return result
    }

    private func isLaunchable(_ bundleID: String) -> Bool {
        let workspace = NSWorkspace.shared
        return workspace.urlForApplication(withBundleIdentifier: bundleID) != nil
            || workspace.runningApplications.contains { application in
                guard !application.isTerminated,
                      let applicationBundleID = application.bundleIdentifier else { return false }
                return normalizeBundleIdentifier(applicationBundleID) == bundleID
            }
    }

    private func launchApplication(at appURL: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
