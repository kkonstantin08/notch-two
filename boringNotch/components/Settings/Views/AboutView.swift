//
//  AboutView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

struct AboutView: View {
    @State private var showBuildNumber: Bool = false
    @Environment(\.openWindow) var openWindow

    /// The exact version this build reports in the issue form.
    private var reportVersion: String {
        let version = Bundle.main.releaseVersionNumber ?? "unknown"
        let build = Bundle.main.buildVersionNumber ?? "unknown"
        let channel = UpdateChannel.bundled
        let channelSuffix = channel == .stable ? "" : ", \(channel.rawValue) channel"
        return "\(version) (build \(build)\(channelSuffix))"
    }

    /// Opens the Notch Two bug report form with its version and macOS fields prefilled.
    private var bugReportURL: URL? {
        var components = URLComponents(string: "https://github.com/kkonstantin08/notch-two/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "template", value: "1-bug-report-form.yml"),
            URLQueryItem(name: "version", value: reportVersion),
            URLQueryItem(
                name: "operating-system",
                value: ProcessInfo.processInfo.operatingSystemVersionString
            ),
        ]
        return components?.url
    }

    var body: some View {
        VStack {
            Form {
                Section {
                    HStack {
                        Text("Release name")
                        Spacer()
                        Text(Defaults[.releaseName])
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        if showBuildNumber {
                            Text("(\(Bundle.main.buildVersionNumber ?? ""))")
                                .foregroundStyle(.secondary)
                        }
                        Text(Bundle.main.releaseVersionNumber ?? String(localized: "Unknown"))
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        withAnimation {
                            showBuildNumber.toggle()
                        }
                    }
                } header: {
                    Text("Version info")
                }

                Text("Notch Two updates are installed from the local Git project.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 30) {
                    Spacer(minLength: 0)
                    Button {
                        if let url = bugReportURL {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "exclamationmark.bubble")
                                .font(.system(size: 15, weight: .medium))
                                .frame(height: 18)
                            Text("Report a Bug")
                        }
                        .contentShape(Rectangle())
                    }
                    .help("Open a bug report with your version filled in automatically")
                    Button {
                        if let url = URL(string: "https://github.com/kkonstantin08/notch-two") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image("Github")
                                .resizable().scaledToFit()
                                .frame(width: 18, height: 18)
                                .foregroundStyle(.primary)
                            Text("GitHub")
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(PlainButtonStyle())
            }
            VStack(spacing: 0) {
                Divider()
                Text("Made with 🫶🏻 by not so boring not.people")
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .padding(.bottom, 7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("About")
    }
}
