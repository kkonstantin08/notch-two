import Defaults
import Foundation
import IOBluetooth

struct CustomAccessory: Equatable, Identifiable {
    let id: String
    let name: String
    let icon: String
    let left: Int?
    let right: Int?
    let caseLevel: Int?
    let single: Int?

    var levels: String {
        let format = { (level: Int?) in level.map { "\($0)%" } ?? String(localized: "Unavailable") }
        if left == nil, right == nil, caseLevel == nil, single != nil {
            return format(single)
        }
        return String(localized: "L \(format(left)) · R \(format(right)) · Case \(format(caseLevel))")
    }

    var primary: Int? { [left, right].compactMap { $0 }.min() ?? single }
}

// Native objects stay on the worker; published state and lifecycle stay on MainActor.
final class CustomBluetooth: NSObject, ObservableObject, @unchecked Sendable {
    @MainActor static let shared = CustomBluetooth()

    @MainActor @Published private(set) var accessories: [CustomAccessory] = []
    // Keep callback tokens alive across the hop. The main actor only compares object identity.
    private struct CallbackToken: @unchecked Sendable {
        let value: IOBluetoothUserNotification
        let device: IOBluetoothDevice
    }

    private var connector: IOBluetoothUserNotification?
    private var disconnectors: [String: IOBluetoothUserNotification] = [:]
    private var devices: [String: IOBluetoothDevice] = [:]
    private let worker = DispatchQueue(label: "notchtwo.bluetooth", qos: .utility)
    private let desiredLock = NSLock()
    private var desiredSession: UUID?
    private var workerSession: UUID?
    @MainActor private var lifecycle = SourceLifecycle()
    @MainActor private var notify: ((CustomNotice) -> Void)?

    @MainActor
    func start(notify: @escaping (CustomNotice) -> Void) {
        guard let session = lifecycle.start() else { return }
        self.notify = notify
        desiredLock.lock()
        desiredSession = session
        desiredLock.unlock()
        worker.async { [weak self] in self?.startSource(session: session) }
    }

    private func isDesired(_ session: UUID) -> Bool {
        desiredLock.lock()
        defer { desiredLock.unlock() }
        return desiredSession == session
    }

    private func startSource(session: UUID) {
        guard isDesired(session) else { return }
        let connector = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        guard let connector else { return }
        guard isDesired(session) else { connector.unregister(); return }
        self.connector = connector
        workerSession = session
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []) where device.isConnected() {
            track(device, announce: false)
        }
        refreshSource()
    }

    @MainActor
    func stop() {
        guard lifecycle.stop() else { return }
        desiredLock.lock()
        desiredSession = nil
        desiredLock.unlock()
        notify = nil
        if !accessories.isEmpty { accessories = [] }
        worker.async { [weak self] in
            guard let self else { return }
            self.workerSession = nil
            self.connector?.unregister()
            self.connector = nil
            self.disconnectors.values.forEach { $0.unregister() }
            self.disconnectors.removeAll()
            self.devices.removeAll()
        }
    }

    @MainActor
    func refresh() {
        guard let session = lifecycle.session else { return }
        worker.async { [weak self] in
            guard let self, self.workerSession == session else { return }
            self.refreshSource()
        }
    }

    private func refreshSource() {
        guard connector != nil, let session = workerSession else { return }
        let list = devices.compactMap { id, device in snapshot(device, id: id) }.sorted { $0.id < $1.id }
        Task { @MainActor [weak self] in
            guard let self, self.lifecycle.accepts(session) else { return }
            if self.accessories != list { self.accessories = list }
        }
    }

    @objc private func connected(_ token: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let sender = CallbackToken(value: token, device: device)
        worker.async { [weak self] in
            guard let self, let connector = self.connector, connector === sender.value,
                  let address = sender.device.addressString,
                  let device = IOBluetoothDevice(addressString: address) else { return }
            self.track(device, announce: true)
        }
    }

    @objc private func disconnected(_ token: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let sender = CallbackToken(value: token, device: device)
        worker.async { [weak self] in
            guard let self, let id = sender.device.addressString,
                  let token = self.disconnectors[id], token === sender.value else { return }
            self.disconnectors.removeValue(forKey: id)?.unregister()
            let snapshot = self.devices.removeValue(forKey: id).map { self.snapshot($0, id: id) }
            self.refreshSource()
            if let snapshot { self.announce(snapshot, connected: false) }
        }
    }

    private func track(_ device: IOBluetoothDevice, announce shouldAnnounce: Bool) {
        let name = device.name?.lowercased() ?? ""
        let isAudio = device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio)
            || name.contains("airpods") || name.contains("beats")
        guard isAudio, let id = device.addressString, devices[id] == nil, device.isConnected() else { return }
        devices[id] = device
        disconnectors[id] = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        if shouldAnnounce {
            refreshSource()
            announce(snapshot(device, id: id), connected: true)
        }
    }

    private func announce(_ device: CustomAccessory, connected: Bool) {
        guard let session = workerSession else { return }
        let detail = if connected, let battery = device.primary { String(localized: "Connected · \(battery)%") }
                     else { connected ? String(localized: "Connected") : String(localized: "Disconnected") }
        let notice = CustomNotice(source: .bluetooth, key: "\(device.id):\(connected)", title: device.name,
                                  detail: detail, icon: device.icon)
        Task { @MainActor [weak self] in
            guard let self, self.lifecycle.accepts(session), CustomFeature.bluetooth.isEnabled else { return }
            self.notify?(notice)
        }
    }

    private func snapshot(_ device: IOBluetoothDevice, id: String) -> CustomAccessory {
        let name = device.name ?? "Bluetooth audio"
        let lowered = name.lowercased()
        let icon = if lowered.contains("airpods max") { "airpodsmax" }
                   else if lowered.contains("airpods pro") { "airpodspro" }
                   else if lowered.contains("airpods") { "airpods" }
                   else { "headphones" }

        func level(_ key: String) -> Int? {
            // shortcut: these selectors are optional OS-provided readings, use a documented API if macOS exposes one.
            guard device.responds(to: NSSelectorFromString(key)),
                  let value = (device.value(forKey: key) as? NSNumber)?.intValue,
                  (1...100).contains(value) else { return nil }
            return value
        }
        return .init(id: id, name: name, icon: icon, left: level("batteryPercentLeft"),
                     right: level("batteryPercentRight"), caseLevel: level("batteryPercentCase"),
                     single: level("batteryPercentSingle"))
    }
}
