import AVFoundation
import XCTest
@testable import boringNotch

private final class NotificationCameraEngine: CameraSessionEngine, @unchecked Sendable {
    var eventHandler: (@MainActor @Sendable (CameraSessionEvent) -> Void)?
    func refresh() {}
    func requestAccess() {}
    func start(selection: CameraSelection) {}
    func stop() {}
    func shutdown() {}
}

@MainActor
final class NotificationPresentationOwnershipTests: XCTestCase {
    func testEndingNotificationClosesOnlyItsOwnPresentation() {
        let coordinator = BoringViewCoordinator.shared
        let firstLaunch = coordinator.firstLaunch
        coordinator.firstLaunch = false
        defer { coordinator.firstLaunch = firstLaunch }
        let vm = BoringViewModel(camera: CameraModel(engine: NotificationCameraEngine(), authorizationStatus: .denied))
        XCTAssertTrue(vm.open(forNotification: true))
        vm.closeNotificationPresentation()
        XCTAssertEqual(vm.notchState, .closed)

        XCTAssertTrue(vm.open(forNotification: true))
        _ = vm.open() // Explicit opening transfers ownership to the user.
        vm.closeNotificationPresentation()
        XCTAssertEqual(vm.notchState, .open)
        vm.close()
    }
}
