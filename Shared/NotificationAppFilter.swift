import Foundation

struct NotificationAppFilter: Equatable {
    private let bundleIDs: Set<String>
    private let fallbackNames: Set<String>
    private let allApps: Bool

    init(bundleIDs: Set<String>, allApps: Bool) {
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        fallbackNames = Set(self.bundleIDs.compactMap { $0.split(separator: ".").last.map(String.init) })
        self.allApps = allApps
    }

    func allows(bundleID: String?, appName: String?) -> Bool {
        let matches: Bool
        if let bundleID, !bundleID.isEmpty {
            matches = bundleIDs.contains(bundleID.lowercased())
        } else if let appName {
            matches = fallbackNames.contains(appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        } else {
            matches = false
        }
        return allApps ? !matches : matches
    }
}
