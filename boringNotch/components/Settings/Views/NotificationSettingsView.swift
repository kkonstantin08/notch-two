//
//  NotificationSettingsView.swift
//  boringNotch
//
import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

private struct NotificationApp: Identifiable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

struct NotificationSettingsView: View {
    @Default(.notificationLiveActivity) private var notificationLiveActivity
    @Default(.notificationsFromAllApps) private var notificationsFromAllApps
    @Default(.notificationAllowedApps) private var allowedApps
    @Default(.notificationExcludedApps) private var excludedApps
    @Default(.notificationDisplayDuration) private var displayDuration
    @Default(.notificationCardLayout) private var cardLayout
    @State private var isAccessibilityAuthorized = true
    @State private var isCheckingAccessibility = false

    private var selectedApps: [NotificationApp] {
        (notificationsFromAllApps ? excludedApps : allowedApps)
            .map { NotificationApp(bundleID: $0, name: displayName(for: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .notificationLiveActivity) {
                    Text("Show notifications in the notch")
                }
            } footer: {
                Text("Requires \(AccessibilityPermission.displayName). Only visible banners are mirrored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isAccessibilityAuthorized {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: AccessibilityPermission.systemImageName)
                            .font(.title)
                            .foregroundStyle(Color.effectiveAccent)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(AccessibilityPermission.displayName) Required")
                                .font(.headline)
                            Text("Grant \(AccessibilityPermission.displayName) to mirror notification banners.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("If Notch Two is already enabled, remove its entry with −. Then use + to add and enable \(Bundle.main.bundlePath).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack {
                                Button("Open System Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                Button("Check Again") {
                                    Task { await checkAccessibility() }
                                }
                                .disabled(isCheckingAccessibility)
                            }
                            .padding(.top, 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section("Display") {
                Defaults.Toggle(key: .notificationAutoExpand) {
                    Text("Expand notch on new notification")
                }
                Picker("Notification layout", selection: $cardLayout) {
                    Text("Single column").tag(NotificationCardLayout.column)
                    Text("On one line").tag(NotificationCardLayout.inline)
                }
                Picker("Display duration", selection: $displayDuration) {
                    ForEach([2.0, 3, 5, 8, 10, 15, 30], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    Text("Until dismissed").tag(0.0)
                }
                Text("Hovering pauses the countdown. Turning this feature off restores native macOS banners.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!notificationLiveActivity)

            Section {
                Defaults.Toggle(key: .telegramNotificationReplies) {
                    Text("Reply to Telegram notifications")
                }
            }
            .disabled(!notificationLiveActivity)

            Section {
                Defaults.Toggle(key: .notificationsFromAllApps) {
                    Text("From all apps")
                }
                .disabled(!notificationLiveActivity)

                if notificationsFromAllApps {
                    Text("Excluded Apps").font(.headline)
                }

                if selectedApps.isEmpty {
                    Text(notificationsFromAllApps ? LocalizedStringKey("No apps excluded") : "No apps selected")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(selectedApps) { app in
                        HStack {
                            appIcon(for: app.bundleID)
                                .resizable().scaledToFit()
                                .frame(width: 20, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 5))

                            Text(app.name)
                            Spacer()
                            Button(notificationsFromAllApps ? LocalizedStringKey("Allow Again") : "Remove") {
                                if notificationsFromAllApps {
                                    excludedApps.remove(app.bundleID)
                                } else {
                                    allowedApps.remove(app.bundleID)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Button {
                    chooseApplication(excluding: notificationsFromAllApps)
                } label: {
                    Label(notificationsFromAllApps ? LocalizedStringKey("Exclude Applications…") : "Add Application…", systemImage: "plus")
                }
            } header: {
                Text("Apps")
            } footer: {
                Text(notificationsFromAllApps
                     ? LocalizedStringKey("Excluded apps keep their normal macOS banners.")
                     : "Only selected apps are mirrored. Add applications from your Mac; no preset app list is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!notificationLiveActivity)
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .task {
            await checkAccessibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { notification in
            if let granted = notification.userInfo?["granted"] as? Bool {
                isAccessibilityAuthorized = granted
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkAccessibility() }
        }
        .onChange(of: allowedApps) { _, _ in
            SystemNotificationManager.shared.updateFilter()
        }
        .onChange(of: excludedApps) { _, _ in
            SystemNotificationManager.shared.updateFilter()
        }
        .onChange(of: notificationsFromAllApps) { _, _ in
            SystemNotificationManager.shared.updateFilter()
        }
    }

    private func checkAccessibility() async {
        guard !isCheckingAccessibility else { return }
        isCheckingAccessibility = true
        defer { isCheckingAccessibility = false }
        isAccessibilityAuthorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
    }

    private func chooseApplication(excluding: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            let bundleIDs = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            guard !bundleIDs.isEmpty else { return }
            DispatchQueue.main.async {
                if excluding {
                    excludedApps.formUnion(bundleIDs)
                } else {
                    allowedApps.formUnion(bundleIDs)
                }
            }
        }
    }

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let bundle = Bundle(url: url)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}
