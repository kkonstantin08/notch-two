import CoreWLAN
import Foundation
import Network

// CoreWLAN and path callbacks converge on one utility queue. Queued callbacks
// from a stopped session can only reach that session, never its replacement.
final class CustomNetwork: NSObject, CWEventDelegate, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "notch.custom.network", qos: .utility)
    private let monitor = NWPathMonitor()
    private let showName: Bool
    private let observeWiFi: Bool
    private let reportConnection: Bool
    private let publish: @Sendable (NetworkTransition.Event) -> Void
    private var path: NWPath?
    private var client: CWWiFiClient?
    private var pending: DispatchWorkItem?
    private var transition = NetworkTransition()
    private var active = false
    private var ssidChanged = false

    init(showName: Bool, observeWiFi: Bool, reportConnection: Bool,
         publish: @escaping @Sendable (NetworkTransition.Event) -> Void) {
        self.showName = showName
        self.observeWiFi = observeWiFi
        self.reportConnection = reportConnection
        self.publish = publish
        super.init()

        Self.queue.async { [self] in
            active = true
            if observeWiFi {
                let wifi = CWWiFiClient.shared()
                client = wifi
                wifi.delegate = self
                try? wifi.startMonitoringEvent(with: .linkDidChange)
                try? wifi.startMonitoringEvent(with: .ssidDidChange)
            }
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self, active else { return }
                self.path = path
                settle()
            }
            monitor.start(queue: Self.queue)
        }
    }

    func stop() {
        Self.queue.async { [self] in
            active = false
            monitor.pathUpdateHandler = nil
            monitor.cancel()
            try? client?.stopMonitoringAllEvents()
            client?.delegate = nil
            client = nil
            pending?.cancel()
            pending = nil
        }
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        refresh(interfaceName: interfaceName, ssidChanged: true)
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        refresh(interfaceName: interfaceName, ssidChanged: false)
    }

    private func refresh(interfaceName: String, ssidChanged: Bool) {
        Self.queue.async { [weak self] in
            guard let self, active, client?.interface()?.interfaceName == interfaceName else { return }
            self.ssidChanged = self.ssidChanged || ssidChanged
            settle()
        }
    }

    private func settle() {
        guard path != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, active, let path else { return }
            pending = nil
            let changed = ssidChanged
            ssidChanged = false
            let online = path.status == .satisfied
            let interface = client?.interface()
            let wifi = online && path.usesInterfaceType(.wifi)
                || (interface?.activePHYMode() ?? .none) != .none
            let ssid = showName && wifi ? interface?.ssid() : nil
            let events = transition.update(online: online, wifi: wifi, ssid: ssid,
                                           ssidChanged: changed && ssid == nil,
                                           reportConnection: reportConnection)
            events.forEach(publish)
        }
        pending = work
        Self.queue.asyncAfter(deadline: .now() + .milliseconds(750), execute: work)
    }
}
