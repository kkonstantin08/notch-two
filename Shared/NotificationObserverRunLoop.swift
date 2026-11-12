import Foundation

// XPC's dispatch_main does not service the main CFRunLoop. AX needs a running CFRunLoop.
final class NotificationObserverRunLoop: @unchecked Sendable {
    private let source: CFRunLoopSource
    private let lifetime: AnyObject
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?
    private var started = false
    private var stopping = false
    private var completed = false

    init(source: CFRunLoopSource, lifetime: AnyObject) {
        self.source = source
        self.lifetime = lifetime
    }

    func start() -> Bool {
        lock.lock()
        guard !started && !stopping else { lock.unlock(); return false }
        started = true
        lock.unlock()
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(loop, source, .defaultMode)
            lock.lock()
            runLoop = loop
            let stopNow = stopping
            lock.unlock()
            ready.signal()
            if !stopNow { CFRunLoopRun() }
            CFRunLoopRemoveSource(loop, source, .defaultMode)
            lock.lock()
            runLoop = nil
            completed = true
            lock.unlock()
            finished.signal()
            withExtendedLifetime(lifetime) {}
        }
        thread.name = "NotchTwo.NotificationAX"
        thread.qualityOfService = .utility
        thread.start()
        if ready.wait(timeout: .now() + 1) == .success { return true }
        _ = stop()
        return false
    }

    func wake() {
        lock.lock()
        let loop = runLoop
        lock.unlock()
        if let loop { CFRunLoopWakeUp(loop) }
    }

    @discardableResult
    func stop() -> Bool {
        lock.lock()
        stopping = true
        let loop = runLoop
        let done = completed || !started
        lock.unlock()
        if done { return true }
        if let loop {
            // A queued block also handles stop arriving just before CFRunLoopRun starts.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
        return finished.wait(timeout: .now() + 1) == .success
    }
}
