import AppKit
import XCTest
@testable import boringNotch

@MainActor
final class SharingCompletionTests: XCTestCase {
    func testUITimeoutDoesNotReleaseFilesBeforeTransferCompletion() async throws {
        let service = try XCTUnwrap(NSSharingService(named: .sendViaAirDrop))
        let manager = SharingStateManager.shared
        let wasPreventingClose = manager.preventNotchClose
        var completed = 0
        let delegate = manager.makeDelegate { completed += 1 }
        delegate.markServiceBegan()
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(completed, 0, "A UI timeout cannot prove the recipient has finished reading its files")
        XCTAssertEqual(manager.preventNotchClose, wasPreventingClose)
        delegate.sharingService(service, didShareItems: [])
        XCTAssertEqual(completed, 1)
        delegate.sharingService(service, didFailToShareItems: [], error: NSError(domain: "fixture", code: 1))
        XCTAssertEqual(completed, 1, "Late duplicate completion must not release resources twice")
    }
}
