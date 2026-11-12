import Foundation

@main
struct NotificationFilterChecks {
    static func main() {
        let all = NotificationAppFilter(bundleIDs: ["com.example.Mail"], allApps: true)
        check(!all.allows(bundleID: "com.example.mail", appName: "Mail"))
        check(!all.allows(bundleID: nil, appName: " MAIL "))
        check(all.allows(bundleID: "com.example.other", appName: "Mail"))
        check(all.allows(bundleID: "com.example.calendar", appName: "Calendar"))
        check(all.allows(bundleID: nil, appName: nil))

        let selected = NotificationAppFilter(bundleIDs: ["com.example.mail"], allApps: false)
        check(selected.allows(bundleID: "com.example.Mail", appName: nil))
        check(selected.allows(bundleID: "", appName: "Mail"))
        check(!selected.allows(bundleID: "com.example.calendar", appName: "Calendar"))
        check(!selected.allows(bundleID: nil, appName: nil))

        check(NotificationAppFilter(bundleIDs: [], allApps: true).allows(bundleID: nil, appName: nil))
        check(!NotificationAppFilter(bundleIDs: [], allApps: false).allows(bundleID: "com.example.mail", appName: nil))
        print("PASS: notification exclusions and allow-list modes")
    }

    private static func check(_ value: Bool, line: UInt = #line) {
        guard value else {
            FileHandle.standardError.write(Data("Notification filter check failed at line \(line)\n".utf8))
            exit(1)
        }
    }
}
