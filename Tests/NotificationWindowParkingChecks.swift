import Foundation
import CoreGraphics

@main
struct NotificationWindowParkingChecks {
    @MainActor static func main() async throws {
        let now = Date(timeIntervalSince1970: 1000)
        let lease = NotificationWindowLease(session: UUID().uuidString, pid: 42, windowID: 1, origin: CGPoint(x: 800, y: 50))
        var state = NotificationWindowParkingState()
        state.insert(lease, for: 1)
        let first = state.scheduleRestore(for: 1, at: now)!
        assert(state.leaseToRestore(first, at: now.addingTimeInterval(0.69)) == nil)
        assert(state.leaseToRestore(first, at: now.addingTimeInterval(0.71)) == lease)
        let settling = state.scheduleSettledRetry(for: 1, at: now)!
        assert(state.leaseToRestore(settling, at: now.addingTimeInterval(0.11)) == lease)
        state.keepHidden(1)
        assert(state.leaseToRestore(settling, at: now.addingTimeInterval(1)) == nil)
        assert(state.leaseToRestore(first, at: now.addingTimeInterval(1)) == nil)
        let replacement = state.scheduleRestore(for: 1, at: now.addingTimeInterval(2))!
        assert(state.scheduleRestore(for: 1, at: now.addingTimeInterval(2.1)) == nil)
        assert(state.leaseToRestore(replacement, at: now.addingTimeInterval(2.71)) == lease)
        for _ in 0..<20 {
            state.keepHidden(1)
            let late = state.scheduleRestore(for: 1, at: now)!
            assert(state.takeAll() == [lease])
            assert(state.leaseToRestore(late, at: now.addingTimeInterval(5)) == nil)
            state.insert(lease, for: 1)
        }
        let other = NotificationWindowLease(session: lease.session, pid: 42, windowID: 2, origin: CGPoint(x: 900, y: 60))
        state.insert(other, for: 2)
        assert(state.restoredWindows(pid: 42, windowID: 1, position: lease.origin) == [1])
        assert(state.restoredWindows(pid: 42, windowID: 2, position: lease.origin).isEmpty)
        assert(state.restoredWindows(pid: 43, windowID: 1, position: lease.origin).isEmpty)
        assert(state.restoredWindows(pid: 42, windowID: 1, position: lease.hidden).isEmpty)
        let one = state.scheduleRestore(for: 1, at: now)!
        state.keepHidden(2)
        assert(state.leaseToRestore(one, at: now.addingTimeInterval(1)) == lease)
        assert(Set(state.takeAll().map(\.id)) == [lease.id, other.id])
        state.insert(lease, for: 1)
        let staleWindow = state.scheduleRestore(for: 1, at: now)!
        state.insert(other, for: 1)
        assert(state.leaseToRestore(staleWindow, at: now.addingTimeInterval(1)) == nil)
        assert(state.lease(for: 1)?.windowID == 2)
        state.expectReplyLayoutChange(for: 1, at: now)
        assert(!state.consumeReplyLayoutChange(for: 2, at: now))
        assert(state.consumeReplyLayoutChange(for: 1, at: now.addingTimeInterval(0.1)))
        assert(!state.consumeReplyLayoutChange(for: 1, at: now.addingTimeInterval(0.2)))
        state.expectReplyLayoutChange(for: 1, at: now)
        assert(!state.consumeReplyLayoutChange(for: 1, at: now.addingTimeInterval(1)))
        state.expectReplyLayoutChange(for: 1, at: now, duration: NotificationReplyReadiness.timeout)
        assert(state.consumeReplyLayoutChange(for: 1, at: now.addingTimeInterval(0.5)))

        var checks = 0
        let ready = await NotificationReplyReadiness.wait {
            checks += 1
            return checks >= 4 ? .ready : .waiting
        }
        assert(ready && checks == 4, "A slow native editor should become ready after the old 150 ms cutoff")
        checks = 0
        let cancelled = await NotificationReplyReadiness.wait {
            checks += 1
            return .invalid
        }
        assert(!cancelled && checks == 1, "A cancelled reply must stop checking immediately")
        let timedOut = await NotificationReplyReadiness.wait { .waiting }
        assert(!timedOut, "An unavailable editor must time out")
        let encoded = try JSONEncoder().encode(lease)
        let decoded = try JSONDecoder().decode(NotificationWindowLease.self, from: encoded)
        assert(decoded == lease)
        assert(lease.isValid && lease.hidden != other.hidden)
        let invalid = NotificationWindowLease(session: "bad", pid: -1, windowID: 1, origin: CGPoint(x: Double.infinity, y: 0))
        assert(!invalid.isValid)
        print("PASS: per-window restoration, reply readiness, 20 stops and validated backup payloads")
    }
}
