//
//  NotificationWatcher.swift
//  BoringNotchXPCHelper
//
import AppKit
import ApplicationServices
import Foundation
import OSLog

private let notificationCenterBundleID = "com.apple.notificationcenterui"
private let orderedChildrenAttribute = "AXOrderedChildren"
private let stackingIdentifierAttribute = "AXStackingIdentifier"
private let maxAccessibilityNodes = 1_024
private let maxTextNodes = 256
private let structuralIdentifiers: Set<String> = [
    "AXNotificationListItems",
    "widgets-overlay-view"
]
private let settleDelay: TimeInterval = 0.15

private extension AXUIElement {
    subscript(attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    func string(_ attribute: String) -> String? {
        self[attribute] as? String
    }

    func children() -> [AXUIElement] {
        (self[kAXChildrenAttribute] as? [AXUIElement] ?? [])
            + (self[orderedChildrenAttribute] as? [AXUIElement] ?? [])
    }

    func point(_ attribute: String) -> CGPoint? {
        guard let value = self[attribute],
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint
        else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }
}

struct CapturedNotification: Equatable {
    let token: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?
}

// State is confined to the main queue; AX callbacks hop there from the observer run loop.
final class NotificationWatcher: @unchecked Sendable {
    private final class ObserverContext: @unchecked Sendable {
        weak var watcher: NotificationWatcher?
        let observer: AXObserver

        init(observer: AXObserver) { self.observer = observer }
    }

    private let log = Logger(subsystem: "local.notchtwo.app", category: "NotificationMirror")

    var onBanner: ((CapturedNotification, String) -> Void)?
    var clientSession = ""
    var prepareWindow: ((String, @escaping (Bool) -> Void) -> Void)?
    var windowRestored: ((String) -> Void)?
    var useNative: (([String]) -> Void)?
    private var parking = NotificationWindowParkingState()
    private var parkedWindows: [UInt: AXUIElement] = [:]
    private var recoveryLeases: [String: NotificationWindowLease] = [:]
    private var windowTokens: [UInt: Set<String>] = [:]
    private final class WindowHandle: @unchecked Sendable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
    }
    private var pendingWindows: [UInt: UUID] = [:]
    private var nativeOnlyTokens = Set<String>()
    private let moveLock = NSLock()
    private var movesAllowed = false

    func restoreWindows(_ encoded: [String]) -> [String] {
        for text in encoded.prefix(16) where text.utf8.count < 2048 {
            guard let data = text.data(using: .utf8),
                  let lease = try? JSONDecoder().decode(NotificationWindowLease.self, from: data), lease.isValid else { continue }
            if recoveryLeases.count < 16 || recoveryLeases[lease.id] != nil { recoveryLeases[lease.id] = lease }
        }
        return restoreRecoveryWindows()
    }

    @discardableResult
    private func restoreRecoveryWindows() -> [String] {
        let restored = recoveryLeases.values.filter(NotificationWindowRestoration.restore).map(\.id)
        for id in restored {
            recoveryLeases[id] = nil
            windowRestored?(id)
        }
        return restored
    }

    func cancelPendingMoves() {
        moveLock.lock()
        movesAllowed = false
        moveLock.unlock()
    }
    private var mayMove: Bool {
        moveLock.lock()
        defer { moveLock.unlock() }
        return movesAllowed
    }
    private var restoreWork: [UInt: DispatchWorkItem] = [:]

    private var appElement: AXUIElement?
    private var axObserver: AXObserver?
    private var observerRunLoop: NotificationObserverRunLoop?
    private var observerContext: ObserverContext?
    private var scanScheduled = false
    private var settleWorkItem: DispatchWorkItem?
    private var observedWindows: [CFHashCode: AXUIElement] = [:]
    private struct LiveNotification {
        let content: CapturedNotification
        let element: AXUIElement
        let windowKey: UInt
        var actionID: String?
    }
    private var liveNotifications: [String: LiveNotification] = [:]
    private var replyTarget: LiveNotification?
    private(set) var replyAttempt = UUID()
    private var filter = NotificationAppFilter(bundleIDs: [], allApps: false)
    private var bundleIDCache: [String: String] = [:]

    private var wanted = false
    private var generation = UUID()
    private var processExit: DispatchSourceProcess?
    private var retryTask: DispatchWorkItem?
    private var retries = NotificationRetryBudget()

    var isRunning: Bool { appElement != nil }

    func configureFilter(bundleIDs: Set<String>, allApps: Bool) {
        let next = NotificationAppFilter(bundleIDs: bundleIDs, allApps: allApps)
        guard filter != next else { return }
        filter = next
        if let target = replyTarget, !next.allows(bundleID: target.content.bundleID, appName: target.content.appName) {
            collapseReply()
        }
        liveNotifications = liveNotifications.filter { next.allows(bundleID: $0.value.content.bundleID, appName: $0.value.content.appName) }
        if isRunning { scheduleScan() }
    }

    @discardableResult
    func start() -> Bool {
        moveLock.lock()
        movesAllowed = true
        moveLock.unlock()
        if isRunning { return true }
        wanted = true
        guard AXIsProcessTrusted(), let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: notificationCenterBundleID
        ).first(where: { !$0.isTerminated }) else { scheduleRetry(); return false }

        appElement = AXUIElementCreateApplication(application.processIdentifier)
        if let appElement { AXUIElementSetMessagingTimeout(appElement, 0.3) }
        guard installObserver(for: application.processIdentifier) else {
            appElement = nil
            scheduleRetry()
            return false
        }

        watchProcessExit(application.processIdentifier)
        retries.connected(at: Date())
        refreshObservedWindows()
        scan()
        return true
    }

    func stop() {
        cancelPendingMoves()
        wanted = false
        retryTask?.cancel()
        retryTask = nil
        processExit?.cancel()
        processExit = nil
        retries = .init()
        detach()
    }

    private func watchProcessExit(_ pid: pid_t) {
        processExit?.cancel()
        let session = generation
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.wanted, self.generation == session else { return }
            self.processExit?.cancel()
            self.processExit = nil
            self.reattach()
        }
        processExit = source
        source.resume()
    }

    private func reattach() {
        guard wanted else { return }
        retryTask?.cancel()
        retryTask = nil
        detach()
        retries = .init()
        _ = start()
    }

    private func scheduleRetry() {
        guard wanted, retryTask == nil, let delay = retries.nextDelay(at: Date()) else { return }
        let session = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.wanted, self.generation == session else { return }
            self.retryTask = nil
            _ = self.start()
        }
        retryTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func detach() {
        generation = UUID()
        collapseReply()
        pendingWindows.removeAll()
        nativeOnlyTokens.removeAll()
        restoreWork.values.forEach { $0.cancel() }
        restoreWork.removeAll()
        for key in parking.windows { restoreWindow(key, settledRetryAllowed: false) }
        restoreRecoveryWindows()
        _ = parking.takeAll()
        parkedWindows.removeAll()
        windowTokens.removeAll()
        settleWorkItem?.cancel()
        settleWorkItem = nil
        if let observer = axObserver {
            if let appElement {
                removeObserverNotifications(from: appElement, observer: observer)
            }
            for window in observedWindows.values {
                removeObserverNotifications(from: window, observer: observer)
            }
        }
        observedWindows.removeAll()
        observerRunLoop?.stop()
        observerRunLoop = nil
        axObserver = nil
        observerContext = nil
        scanScheduled = false
        liveNotifications.removeAll()
        appElement = nil
    }

    private func addObserverNotifications(to element: AXUIElement) -> Bool {
        guard let observer = axObserver, let context = observerContext else { return false }
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        var registered = false
        for notification in NotificationObservationPolicy.structuralNotifications {
            let result = AXObserverAddNotification(
                observer,
                element,
                notification as CFString,
                refcon
            )
            if result == .success {
                registered = true
            }
        }
        return registered
    }

    private func removeObserverNotifications(from element: AXUIElement, observer: AXObserver) {
        for notification in NotificationObservationPolicy.structuralNotifications {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
    }

    private func refreshObservedWindows() {
        guard let appElement else { return }
        let windows = (appElement[kAXWindowsAttribute] as? [AXUIElement]) ?? []
        var current = Set<CFHashCode>()
        for window in windows {
            let subrole = window.string(kAXSubroleAttribute)
            let identifier = window.string(kAXIdentifierAttribute)
            guard NotificationObservationPolicy.shouldObserveElement(
                subrole: subrole,
                identifier: identifier
            ) else { continue }

            let key = CFHash(window)
            current.insert(key)
            guard observedWindows[key] == nil else { continue }
            _ = addObserverNotifications(to: window)
            observedWindows[key] = window
        }

        let stale = observedWindows.keys.filter { !current.contains($0) }
        for key in stale {
            if let window = observedWindows.removeValue(forKey: key) {
                if let observer = axObserver {
                    removeObserverNotifications(from: window, observer: observer)
                }
            }
        }
    }

    private func installObserver(for processIdentifier: pid_t) -> Bool {
        var observer: AXObserver?
        let result = AXObserverCreate(processIdentifier, { @Sendable _, element, notification, refcon in
            autoreleasepool {
            guard let refcon else { return }
            let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            let subrole = name == "AXUIElementDestroyed"
                ? nil
                : element.string(kAXSubroleAttribute)
            let identifier = name == "AXUIElementDestroyed"
                ? nil
                : element.string(kAXIdentifierAttribute)
            DispatchQueue.main.async { [weak context] in
                guard let context, let watcher = context.watcher, watcher.observerContext === context else { return }
                watcher.handleObserverEvent(notification: name, subrole: subrole, identifier: identifier)
            }
            }
        }, &observer)
        guard result == .success, let observer, let appElement else { return false }

        let context = ObserverContext(observer: observer)
        context.watcher = self
        observerContext = context
        axObserver = observer
        guard addObserverNotifications(to: appElement) else {
            axObserver = nil
            observerContext = nil
            return false
        }

        let runner = NotificationObserverRunLoop(source: AXObserverGetRunLoopSource(observer), lifetime: context)
        guard runner.start() else {
            removeObserverNotifications(from: appElement, observer: observer)
            axObserver = nil
            observerContext = nil
            return false
        }
        observerRunLoop = runner
        return true
    }

    private func handleObserverEvent(
        notification: String,
        subrole: String?,
        identifier: String?
    ) {
        guard NotificationObservationPolicy.shouldScan(
            notification: notification,
            subrole: subrole,
            identifier: identifier
        ) else { return }

        scheduleScan()
        scheduleSettleScan()
    }

    private func scheduleSettleScan() {
        guard settleWorkItem == nil else { return }
        let session = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == session else { return }
            self.settleWorkItem = nil
            self.scan()
        }
        settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: workItem)
    }

    private func scheduleScan() {
        guard isRunning, !scanScheduled else { return }
        scanScheduled = true
        let session = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.generation == session else { return }
            self.scanScheduled = false
            self.scan()
        }
    }

    private func scan() {
        autoreleasepool {
            guard mayMove, let appElement else { return }
            restoreRecoveryWindows()
            refreshObservedWindows()
            var seen = Set<String>()
            var occupied = Set<UInt>()
            let windows = (appElement[kAXWindowsAttribute] as? [AXUIElement]) ?? []
            for window in windows {
                guard mayMove else { break }
                let contents = inspect(window)
                let key = CFHash(window)
                if case .panel = contents {
                    useNative?(Array(windowTokens[key] ?? []))
                    restoreWindow(key)
                    continue
                }
                guard case .banners(let banners) = contents else { continue }
                let notifications = banners.map { capture($0, token: token(for: $0)) }
                seen.formUnion(notifications.map(\.token))
                // A shared window with an excluded app must remain entirely native.
                guard notifications.allSatisfy({ $0.bundleID != nil && filter.allows(bundleID: $0.bundleID, appName: $0.appName) }) else {
                    useNative?(notifications.map(\.token))
                    restoreWindow(key)
                    continue
                }
                guard nativeOnlyTokens.isDisjoint(with: notifications.map(\.token)) else {
                    useNative?(notifications.map(\.token))
                    restoreWindow(key)
                    continue
                }
                occupied.insert(key)
                windowTokens[key] = Set(notifications.map(\.token))
                if let lease = parking.lease(for: key) {
                    let hasNewContent = notifications.contains { liveNotifications[$0.token]?.content != $0 }
                    let isStillHidden = window.point(kAXPositionAttribute).map {
                        abs($0.x - lease.hidden.x) < 1 && abs($0.y - lease.hidden.y) < 1
                    } == true
                    guard (isStillHidden || hasNewContent || parking.consumeReplyLayoutChange(for: key, at: Date())),
                          ensureHidden(window, lease: lease) else {
                        nativeOnlyTokens.formUnion(notifications.map(\.token))
                        useNative?(notifications.map(\.token))
                        restoreWindow(key)
                        continue
                    }
                    parking.keepHidden(key)
                    restoreWork.removeValue(forKey: key)?.cancel()
                    publish(notifications, elements: banners, windowKey: key)
                } else {
                    prepareToPark(window, key: key)
                }
            }
            for key in parking.windows.subtracting(occupied) {
                guard let ticket = parking.scheduleRestore(for: key, at: Date()) else { continue }
                scheduleExpiryRestore(ticket)
            }
            for token in Array(liveNotifications.keys) where !seen.contains(token) { liveNotifications[token] = nil }
            nativeOnlyTokens.formIntersection(seen)
        }
    }

    private func scheduleExpiryRestore(_ ticket: NotificationWindowParkingState.Ticket) {
        let session = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == session, self.mayMove,
                  self.parking.leaseToRestore(ticket, at: Date()) != nil else { return }
            self.restoreWork[ticket.window] = nil
            self.restoreWindow(ticket.window)
        }
        restoreWork[ticket.window] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ticket.deadline.timeIntervalSinceNow), execute: work)
    }

    private func publish(_ notifications: [CapturedNotification], elements: [AXUIElement], windowKey: UInt) {
        guard mayMove else { return }
        for (notification, element) in zip(notifications, elements) {
            if let previous = liveNotifications[notification.token],
               previous.content == notification, previous.windowKey == windowKey {
                if !CFEqual(previous.element, element) {
                    let current = LiveNotification(content: notification, element: element, windowKey: windowKey, actionID: previous.actionID)
                    liveNotifications[notification.token] = current
                    if let actionID = current.actionID, replyTarget?.actionID == actionID { replyTarget = current }
                }
                continue
            }
            let actionID = UUID().uuidString
            liveNotifications[notification.token] = LiveNotification(content: notification, element: element, windowKey: windowKey, actionID: actionID)
            onBanner?(notification, actionID)
        }
    }

    func openNotification(_ actionID: String) -> Bool {
        guard replyTarget?.actionID != actionID, let target = liveTarget(for: actionID) else { return false }
        guard actions(of: target.element).contains(kAXPressAction), mayMove else { return false }
        liveNotifications[target.content.token]?.actionID = nil
        return AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success
    }

    private func liveTarget(for actionID: String) -> LiveNotification? {
        guard mayMove, let target = liveNotifications.values.first(where: { $0.actionID == actionID }),
              !nativeOnlyTokens.contains(target.content.token), parking.lease(for: target.windowKey) != nil,
              windowTokens[target.windowKey]?.contains(target.content.token) == true,
              NotificationPanelDetection.isIndividualNotification(subrole: target.element.string(kAXSubroleAttribute)),
              token(for: target.element) == target.content.token,
              capture(target.element, token: target.content.token) == target.content else { return nil }
        return target
    }

    private func actions(of element: AXUIElement) -> [String] {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success else { return [] }
        return actions as? [String] ?? []
    }

    private func action(in actions: [String], named labels: Set<String>) -> String? {
        actions.first { raw in
            let name = raw.hasPrefix("Name:") ? String(raw.dropFirst(5).prefix { !$0.isNewline }) : raw
            return labels.contains(name)
        }
    }

    private func replySubmitAction(on banner: AXUIElement) -> String? {
        let names = actions(of: banner)
        guard action(in: names, named: ["Hide Details", "Скрыть детали"]) != nil else { return nil }
        return action(in: names, named: ["Send", "Reply", "Ответ", "Отправить"])
    }

    func notificationReply(_ actionID: String, operation: NotificationReplyOperation, text: String) -> NotificationReplyResult {
        switch operation {
        case .begin:
            guard replyTarget == nil, let target = liveTarget(for: actionID),
                  target.content.bundleID == "ru.keepcoder.Telegram" else {
                log.notice("Reply preparation refused: original banner is no longer available or a reply is already open")
                return .unavailable
            }
            guard let reveal = action(in: actions(of: target.element), named: ["Reply", "Ответить"]), mayMove else {
                log.notice("Reply preparation refused: native reply action missing")
                return .unavailable
            }
            replyAttempt = UUID()
            replyTarget = target
            let result = AXUIElementPerformAction(target.element, reveal as CFString)
            // Notification Center can open the editor even when AX reports a failure.
            if result == .success || result == .cannotComplete || result == .failure {
                expectReplyLayoutChange(for: target.windowKey, duration: NotificationReplyReadiness.timeout)
                return .accepted
            }
            collapseReply()
            log.notice("Reply preparation refused: native action returned AX error \(result.rawValue)")
            return .unavailable
        case .cancel:
            if replyTarget?.actionID == actionID { collapseReply() }
            return .accepted
        case .submit:
            guard text.utf8.count <= 16_384, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let composing = replyTarget, composing.actionID == actionID,
                  let target = liveTarget(for: actionID), CFEqual(target.element, composing.element),
                  let field = replyField(in: target.element),
                  replySubmitAction(on: target.element) != nil,
                  mayMove else { return .unavailable }
            guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success,
                  field[kAXValueAttribute] as? String == text,
                  let current = liveTarget(for: actionID), CFEqual(current.element, target.element),
                  let send = replySubmitAction(on: current.element)
            else { return .unavailable }

            // Consume the action before submitting. An AX timeout can still have sent the reply.
            moveLock.lock()
            guard movesAllowed else {
                moveLock.unlock()
                return .unavailable
            }
            liveNotifications[target.content.token]?.actionID = nil
            let result = AXUIElementPerformAction(target.element, send as CFString)
            moveLock.unlock()
            expectReplyLayoutChange(for: target.windowKey)
            collapseReply()
            return result == .success ? .accepted : .uncertain
        }
    }

    func replyReadiness(_ actionID: String, attempt: UUID) -> NotificationReplyReadiness {
        guard replyAttempt == attempt, let composing = replyTarget, composing.actionID == actionID,
              let current = liveNotifications[composing.content.token], current.actionID == actionID,
              CFEqual(current.element, composing.element), mayMove else { return .invalid }
        return replySubmitAction(on: current.element) != nil && replyField(in: current.element) != nil ? .ready : .waiting
    }

    private func replyField(in banner: AXUIElement) -> AXUIElement? {
        var pending = banner.children()
        var visited = Set<CFHashCode>()
        var field: AXUIElement?
        while let element = pending.popLast(), visited.count < 64 {
            guard visited.insert(CFHash(element)).inserted else { continue }
            switch element.string(kAXRoleAttribute) {
            case kAXTextFieldRole, kAXTextAreaRole:
                guard field == nil else { return nil }
                field = element
            default:
                pending.append(contentsOf: element.children())
            }
        }
        return pending.isEmpty ? field : nil
    }

    private func collapseReply() {
        guard let target = replyTarget else { return }
        replyTarget = nil
        guard token(for: target.element) == target.content.token,
              let collapse = action(in: actions(of: target.element), named: ["Hide Details", "Скрыть детали"]) else { return }
        let result = AXUIElementPerformAction(target.element, collapse as CFString)
        if result == .success || result == .cannotComplete {
            expectReplyLayoutChange(for: target.windowKey)
        }
    }

    private func expectReplyLayoutChange(for key: UInt, duration: TimeInterval = 0.35) {
        guard mayMove else { return }
        parking.expectReplyLayoutChange(for: key, at: Date(), duration: duration)
        scheduleScan()
    }

    private func prepareToPark(_ window: AXUIElement, key: UInt) {
        guard pendingWindows[key] == nil,
              let origin = window.point(kAXPositionAttribute), origin.x > -1000, origin.y > -1000,
              let appElement, let prepareWindow else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success else { return }
        guard let windowID = NotificationWindowRestoration.identifier(of: window, pid: pid) else {
            log.notice("Parking refused: WindowServer identity unavailable")
            return
        }
        // AX may give the reused WindowServer window a new element after ordering it out.
        for restoredKey in parking.restoredWindows(pid: pid, windowID: windowID, position: origin) {
            liveNotifications = liveNotifications.filter { $0.value.windowKey != restoredKey }
            releaseParkingLease(restoredKey)
        }
        guard parking.windows.count < 16 else { return }
        let lease = NotificationWindowLease(session: clientSession, pid: pid, windowID: windowID, origin: origin)
        guard lease.isValid, let data = try? JSONEncoder().encode(lease),
              let encoded = String(data: data, encoding: .utf8) else { return }
        let request = UUID()
        let session = generation
        let deadline = Date().addingTimeInterval(1)
        pendingWindows[key] = request
        let handle = WindowHandle(window)
        prepareWindow(encoded) { [weak self] accepted in
            guard let self else { return }
            DispatchQueue.main.async { [self, handle] in
                let window = handle.element
                guard self.mayMove, self.generation == session, self.pendingWindows[key] == request,
                      self.clientSession == lease.session, Date() < deadline else {
                    self.windowRestored?(lease.id)
                    return
                }
                self.pendingWindows[key] = nil
                guard accepted, case .banners(let banners) = self.inspect(window) else {
                    self.log.notice("Parking refused: backup rejected or banner disappeared")
                    self.nativeOnlyTokens.formUnion(self.windowTokens[key] ?? [])
                    self.windowRestored?(lease.id)
                    return
                }
                let notifications = banners.map { self.capture($0, token: self.token(for: $0)) }
                guard notifications.allSatisfy({ $0.bundleID != nil && self.filter.allows(bundleID: $0.bundleID, appName: $0.appName) }) else {
                    self.windowRestored?(lease.id)
                    return
                }
                guard Date() < deadline else {
                    self.windowRestored?(lease.id)
                    return
                }
                AXUIElementSetMessagingTimeout(window, 0.3)
                self.parking.insert(lease, for: key)
                self.parkedWindows[key] = window
                guard self.ensureHidden(window, lease: lease) else {
                    self.log.notice("Parking refused: move or position verification failed")
                    self.nativeOnlyTokens.formUnion(notifications.map(\.token))
                    self.restoreWindow(key)
                    self.useNative?(notifications.map(\.token))
                    return
                }
                self.windowTokens[key] = Set(notifications.map(\.token))
                self.publish(notifications, elements: banners, windowKey: key)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == session, self.pendingWindows[key] == request else { return }
            self.pendingWindows[key] = nil
            self.nativeOnlyTokens.formUnion(self.windowTokens[key] ?? [])
            self.windowRestored?(lease.id)
        }
    }

    private func ensureHidden(_ window: AXUIElement, lease: NotificationWindowLease) -> Bool {
        guard mayMove, NotificationWindowRestoration.identifier(of: window, pid: lease.pid) == lease.windowID else { return false }
        func isHidden() -> Bool {
            guard let point = window.point(kAXPositionAttribute) else { return false }
            return abs(point.x - lease.hidden.x) < 1 && abs(point.y - lease.hidden.y) < 1
        }
        moveLock.lock()
        defer { moveLock.unlock() }
        guard movesAllowed else { return false }
        return isHidden() || (NotificationWindowRestoration.move(window, to: lease.hidden) && isHidden())
    }

    private func restoreWindow(_ key: UInt, settledRetryAllowed: Bool = true) {
        guard let lease = parking.lease(for: key) else { return }
        if replyTarget?.windowKey == key { collapseReply() }
        let restored = parkedWindows[key].map { window in
            guard NotificationWindowRestoration.identifier(of: window, pid: lease.pid) == lease.windowID,
                  NotificationWindowRestoration.move(window, to: lease.origin),
                  let point = window.point(kAXPositionAttribute) else { return false }
            return abs(point.x - lease.origin.x) < 1 && abs(point.y - lease.origin.y) < 1
        } == true || NotificationWindowRestoration.restore(lease)
        guard restored else {
            guard settledRetryAllowed, let ticket = parking.scheduleSettledRetry(for: key, at: Date()) else { return }
            let session = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == session,
                      self.parking.leaseToRestore(ticket, at: Date()) != nil else { return }
                self.restoreWork[key] = nil
                self.restoreWindow(key, settledRetryAllowed: false)
            }
            restoreWork.removeValue(forKey: key)?.cancel()
            restoreWork[key] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            return
        }
        releaseParkingLease(key)
    }

    private func releaseParkingLease(_ key: UInt) {
        guard let lease = parking.lease(for: key) else { return }
        if replyTarget?.windowKey == key { replyTarget = nil }
        parking.remove(key)
        parkedWindows[key] = nil
        windowTokens[key] = nil
        restoreWork.removeValue(forKey: key)?.cancel()
        windowRestored?(lease.id)
    }

    private enum WindowContents {
        case panel
        case ignored
        case banners([AXUIElement])
    }

    private func inspect(_ root: AXUIElement) -> WindowContents {
        var pending: [(element: AXUIElement, insideBanner: Bool, insideList: Bool)] = [
            (root, false, false)
        ]
        var visited = Set<CFHashCode>()
        var banners: [AXUIElement] = []

        while let node = pending.popLast() {
            guard mayMove else { return .ignored }
            let element = node.element
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard visited.count <= maxAccessibilityNodes else { return .ignored }

            let subrole = element.string(kAXSubroleAttribute)
            let identifier = element.string(kAXIdentifierAttribute)
            let stackingIdentifier = node.insideList && subrole == "AXButton"
                ? element.string(stackingIdentifierAttribute)
                : nil
            if NotificationPanelDetection.isPanel(
                subrole: subrole,
                identifier: identifier,
                stackingIdentifier: stackingIdentifier,
                insideNotificationList: node.insideList && !node.insideBanner
            ) || NotificationPanelDetection.isDesktopWidget(identifier: identifier) {
                return .panel
            }

            if !node.insideBanner, NotificationPanelDetection.isBanner(subrole: subrole) {
                banners.append(element)
            }

            let childInsideBanner = node.insideBanner || NotificationPanelDetection.isBanner(subrole: subrole)
            let childInsideList = node.insideList
                || identifier == NotificationPanelDetection.panelListIdentifier
            pending.append(contentsOf: element.children().reversed().map {
                ($0, childInsideBanner, childInsideList)
            })
        }

        return banners.isEmpty ? .ignored : .banners(banners)
    }

    private func token(for banner: AXUIElement) -> String {
        if let identifier = banner.string(kAXIdentifierAttribute),
           !identifier.isEmpty,
           !structuralIdentifiers.contains(identifier) {
            return identifier
        }
        if let stackingIdentifier = banner.string(stackingIdentifierAttribute),
           !stackingIdentifier.isEmpty {
            return stackingIdentifier
        }

        return "ax-\(CFHash(banner))"
    }

    private func capture(_ banner: AXUIElement, token: String) -> CapturedNotification {
        let parts = collectText(in: banner)
        let description = (banner["AXAttributedDescription"] as? NSAttributedString)?.string
            ?? banner["AXAttributedDescription"] as? String
        let appName = description.flatMap { value in
            value.split(separator: ",", maxSplits: 1)
                .first
                .map { Self.cleanedAppName(String($0)) }
        }

        return CapturedNotification(
            token: token,
            appName: appName,
            bundleID: appName.flatMap(bundleID(forAppNamed:)),
            title: parts["title"],
            subtitle: parts["subtitle"],
            body: parts["body"]
        )
    }

    private func collectText(in root: AXUIElement) -> [String: String] {
        var parts: [String: String] = [:]
        var pending = [root]
        var visited = Set<CFHashCode>()

        while let element = pending.popLast() {
            guard mayMove else { break }
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard visited.count <= maxTextNodes else { break }

            if let identifier = element.string(kAXIdentifierAttribute),
               let value = element[kAXValueAttribute] as? String {
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                switch identifier {
                case "title":
                    parts["title"] = value
                case "header" where parts["title"] == nil:
                    parts["title"] = value
                case "subtitle":
                    parts["subtitle"] = value
                case "body":
                    parts["body"] = value
                default:
                    break
                }
            }

            pending.append(contentsOf: element.children().reversed())
        }

        return parts
    }

    private func bundleID(forAppNamed name: String) -> String? {
        let target = Self.normalizedAppName(name)
        guard !target.isEmpty else { return nil }
        if let cached = bundleIDCache[target] { return cached }
        // AppleScript banners use Script Editor's localized name even when it is not running.
        if ["script editor", "редактор скриптов"].contains(target),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScriptEditor2") != nil {
            bundleIDCache[target] = "com.apple.ScriptEditor2"
            return "com.apple.ScriptEditor2"
        }

        let running = NSWorkspace.shared.runningApplications
            .filter {
                guard let localizedName = $0.localizedName else { return false }
                return Self.normalizedAppName(localizedName) == target
            }
            .sorted(by: Self.preferRegularApplication)
            .compactMap { $0.bundleIdentifier }
            .first

        if let resolved = resolveBundleID(
            forRunningBundleID: running,
            appName: name,
            target: target
        ) {
            bundleIDCache[target] = resolved
            return resolved
        }
        return nil
    }

    private func resolveBundleID(
        forRunningBundleID runningBundleID: String?,
        appName: String,
        target: String
    ) -> String? {
        if let runningBundleID {
            return normalizedBundleIdentifier(runningBundleID)
        }

        let displayName = Self.cleanedAppName(appName)
        let withoutSpaces = displayName.replacingOccurrences(of: " ", with: "")
        let filenameCandidates = withoutSpaces == displayName
            ? [displayName]
            : [displayName, withoutSpaces]
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]

        for directory in directories {
            for candidate in filenameCandidates where !candidate.isEmpty {
                let appURL = directory.appendingPathComponent(candidate).appendingPathExtension("app")
                if let bundleID = bundleIdentifier(at: appURL) {
                    return normalizedBundleIdentifier(bundleID)
                }
            }
        }

        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension == "app" {
                guard let bundle = Bundle(url: entry), let bundleID = bundle.bundleIdentifier else { continue }
                let names = [
                    entry.deletingPathExtension().lastPathComponent,
                    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                    bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ]
                if names.contains(where: { name in
                    guard let name else { return false }
                    return Self.normalizedAppName(name) == target
                }) {
                    return normalizedBundleIdentifier(bundleID)
                }
            }
        }
        return nil
    }

    private func bundleIdentifier(at appURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    private func normalizedBundleIdentifier(_ bundleID: String) -> String {
        let lower = bundleID.lowercased()
        if lower.hasPrefix("com.apple.safaritechnologypreview.") {
            return "com.apple.SafariTechnologyPreview"
        }
        if lower.hasPrefix("com.apple.webkit.") || lower.hasPrefix("com.apple.safari.") {
            return "com.apple.Safari"
        }
        let components = bundleID.components(separatedBy: ".")
        if let helperIndex = components.firstIndex(where: { $0.lowercased() == "helper" }) {
            return components[0..<helperIndex].joined(separator: ".")
        }
        return bundleID
    }

    private static func normalizedAppName(_ name: String) -> String {
        cleanedAppName(name).lowercased()
    }

    private static func cleanedAppName(_ name: String) -> String {
        name.filter { !$0.unicodeScalars.allSatisfy(bidiControlCharacters.contains) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let bidiControlCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "\u{200E}\u{200F}")
        set.insert(charactersIn: "\u{2066}"..."\u{2069}")
        set.insert(charactersIn: "\u{202A}"..."\u{202E}")
        return set
    }()

    private static func preferRegularApplication(
        _ lhs: NSRunningApplication,
        _ rhs: NSRunningApplication
    ) -> Bool {
        if lhs.activationPolicy == .regular, rhs.activationPolicy != .regular {
            return true
        }
        if rhs.activationPolicy == .regular, lhs.activationPolicy != .regular {
            return false
        }
        return lhs.processIdentifier < rhs.processIdentifier
    }

}
