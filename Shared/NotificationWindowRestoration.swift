import AppKit
import ApplicationServices
import OSLog
import Darwin

// Only windows at a registered, per-lease parking position may be restored.
enum NotificationWindowRestoration {
    static func position(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func move(_ element: AXUIElement, to position: CGPoint) -> Bool {
        var point = position
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private typealias AXWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowIDFunction: AXWindowID? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: AXWindowID.self)
    }()

    static func identifier(of window: AXUIElement, pid: Int32) -> UInt32? {
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid,
              let windowIDFunction else { return nil }
        var id: CGWindowID = 0
        return windowIDFunction(window, &id) == .success && id != 0 ? id : nil
    }
    static func restore(_ lease: NotificationWindowLease) -> Bool {
        guard lease.isValid,
              let app = NSRunningApplication(processIdentifier: lease.pid),
              app.bundleIdentifier == "com.apple.notificationcenterui", !app.isTerminated else { return true }
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(lease.pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return false }
        for window in elements {
            guard identifier(of: window, pid: lease.pid) == lease.windowID else { continue }
            guard let point = position(of: window) else { return false }
            if abs(point.x - lease.origin.x) < 1 && abs(point.y - lease.origin.y) < 1 { return true }
            guard abs(point.x - lease.hidden.x) < 1, abs(point.y - lease.hidden.y) < 1 else { return false }
            guard identifier(of: window, pid: lease.pid) == lease.windowID,
                  move(window, to: lease.origin), let restored = position(of: window) else { return false }
            return abs(restored.x - lease.origin.x) < 1 && abs(restored.y - lease.origin.y) < 1
        }
        // AX may omit ordered-out windows; absence alone is not proof of restoration.
        return false
    }

}

final class NotificationWindowBackup: @unchecked Sendable {
    private let log = Logger(subsystem: "local.notchtwo.app", category: "NotificationMirror")
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "notch.notification.window-recovery", qos: .userInitiated)
    private var session: String?
    private var leases: [String: NotificationWindowLease] = [:]

    func begin() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let session { return session }
        let next = UUID().uuidString
        session = next
        let pending = Array(leases.values)
        if !pending.isEmpty { worker.async { [self] in pending.forEach { restoreStored($0, remove: false) } } }
        return next
    }

    var isWatching: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session != nil
    }

    func isCurrent(_ candidate: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return session == candidate
    }

    private final class Reply: @unchecked Sendable {
        let call: (Bool) -> Void
        init(_ call: @escaping (Bool) -> Void) { self.call = call }
    }

    func prepare(_ encoded: String, reply: @escaping (Bool) -> Void) {
        guard encoded.utf8.count < 2048, let data = encoded.data(using: .utf8),
              let lease = try? JSONDecoder().decode(NotificationWindowLease.self, from: data), lease.isValid else {
            reply(false)
            return
        }
        let completion = Reply(reply)
        worker.async { [self] in
            guard AXIsProcessTrusted(), NSRunningApplication(processIdentifier: lease.pid)?.bundleIdentifier == "com.apple.notificationcenterui" else {
                log.notice("Window backup refused: app AX trust or source identity unavailable")
                completion.call(false)
                return
            }
            lock.lock()
            let accepted = session == lease.session && (leases[lease.id] != nil || leases.count < 16)
            if accepted { leases[lease.id] = lease }
            lock.unlock()
            log.notice("Window backup registration: \(accepted, privacy: .public)")
            completion.call(accepted)
        }
    }

    private func restoreStored(_ lease: NotificationWindowLease, remove: Bool = true) {
        guard NotificationWindowRestoration.restore(lease), remove else { return }
        lock.lock()
        if leases[lease.id] == lease { leases[lease.id] = nil }
        lock.unlock()
    }

    // The helper sends this only after verified restoration or an abandoned pre-move handoff.
    func release(_ id: String) {
        lock.lock()
        leases[id] = nil
        lock.unlock()
    }

    func pendingRestorations() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return leases.values.filter { $0.session != session }.compactMap {
            guard let data = try? JSONEncoder().encode($0) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    func stopAndRestore() {
        lock.lock()
        session = nil
        let pending = Array(leases.values)
        guard !pending.isEmpty else { lock.unlock(); return }
        worker.async { [self] in
            pending.forEach { restoreStored($0, remove: false) }
            // Retain backups across an ACK already in flight when the switch was turned off.
            worker.asyncAfter(deadline: .now() + 1.5) { [self] in
                pending.forEach { restoreStored($0) }
            }
        }
        lock.unlock()
    }
}
