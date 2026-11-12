import Foundation

private final class Recorder: @unchecked Sendable {
    let called = DispatchSemaphore(value: 0)
}

@main struct NotificationRunLoopChecks {
    static func main() {
        for _ in 0..<20 {
            let recorder = Recorder()
            var context = CFRunLoopSourceContext(version: 0,
                info: Unmanaged.passUnretained(recorder).toOpaque(), retain: nil, release: nil,
                copyDescription: nil, equal: nil, hash: nil, schedule: nil, cancel: nil,
                perform: { @Sendable value in
                    guard let value else { return }
                    Unmanaged<Recorder>.fromOpaque(value).takeUnretainedValue().called.signal()
                })
            let source = CFRunLoopSourceCreate(nil, 0, &context)!
            let runner = NotificationObserverRunLoop(source: source, lifetime: recorder)
            assert(runner.start())
            assert(!runner.start())
            CFRunLoopSourceSignal(source)
            runner.wake()
            assert(recorder.called.wait(timeout: .now() + 1) == .success)
            assert(runner.stop())
            assert(runner.stop())
            CFRunLoopSourceSignal(source)
            runner.wake()
            assert(recorder.called.wait(timeout: .now() + .milliseconds(10)) == .timedOut)
        }
        print("PASS: 20 native run-loop source lifecycles deliver once and stop without queued callbacks")
    }
}
