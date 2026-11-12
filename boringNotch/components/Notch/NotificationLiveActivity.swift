//
//  NotificationLiveActivity.swift
//  boringNotch
//

import SwiftUI
import Defaults

private struct NotificationSourceIcon: View {
    let bundleID: String?
    let size: CGFloat

    var body: some View {
        if let bundleID {
            appIcon(for: bundleID)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            Image(systemName: "bell")
                .font(.system(size: size * 0.55))
                .frame(width: size, height: size)
        }
    }
}

struct NotificationLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    let notification: SystemNotification

    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity = 0.0

    private var itemSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    var body: some View {
        HStack {
            NotificationSourceIcon(bundleID: notification.bundleID, size: itemSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            ZStack {
                Circle()
                    .stroke(Color.effectiveAccent, lineWidth: 1.5)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                Circle()
                    .fill(Color.effectiveAccent)
                    .frame(width: 7, height: 7)
            }
            .frame(width: itemSize, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .onAppear { pulse() }
        .onChange(of: notification.id) { _, _ in pulse() }
    }

    private func pulse() {
        ringScale = 1
        ringOpacity = 0.8
        withAnimation(.easeOut(duration: 0.6)) {
            ringScale = 1.8
            ringOpacity = 0
        }
    }
}

struct NotificationExpandedView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = SystemNotificationManager.shared
    @Default(.telegramNotificationReplies) private var telegramReplies
    @Default(.notificationCardLayout) private var cardLayout
    @State private var replySession: UUID?
    @State private var draft = ""
    @State private var isOpeningReply = false
    @State private var isSending = false
    @State private var canSend = false
    @State private var replyUnavailable = false
    @State private var replyError: LocalizedStringKey?
    let notification: SystemNotification
    let showsMore: Bool

    private var isExpanded: Bool { showsMore || replySession != nil }
    private var showsExpandedMessage: Bool { showsMore && replySession == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NotificationCardContent(
                notification: notification, layout: cardLayout, showsMore: showsExpandedMessage,
                isReplying: replySession != nil, openSource: openSourceApp,
                onScrollHover: { vm.isHoveringNotificationScroll = $0 }
            ) {
                cardActions
            }
            if replySession != nil {
                replyComposer
            } else if let replyError {
                Text(replyError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .frame(width: isExpanded ? 505 : 400, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: telegramReplies) { _, enabled in
            if !enabled { endReply() }
        }
        .onDisappear { endReply() }
    }

    private var cardActions: some View {
        HStack(spacing: 4) {
            if telegramReplies, notification.bundleID == "ru.keepcoder.Telegram", notification.nativeActionID != nil {
                Button(action: beginReply) {
                    Text("Reply")
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .opacity(showsExpandedMessage ? 1 : 0)
                .allowsHitTesting(showsExpandedMessage)
                .accessibilityHidden(!showsExpandedMessage)
                .disabled(!showsExpandedMessage || isOpeningReply)
            }

            if replySession == nil, !manager.queuedNotifications.isEmpty {
                Button {
                    manager.showNextQueued()
                } label: {
                    Text("+\(manager.queuedNotifications.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show next queued notification")
            }

            Button {
                endReply()
                manager.dismissActive(token: notification.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
            .disabled(isSending)
        }
    }

    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                NotificationReplyInput(
                    text: $draft, isPreparing: isOpeningReply, isEditable: !isSending,
                    submit: sendReply, cancel: cancelReply
                )
                .frame(height: 36)
                .frame(maxWidth: 360)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Reply")
                Button("Send", action: sendReply)
                    .disabled(!canSend || isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", action: cancelReply)
                    .disabled(isSending)
            }
            if let replyError {
                Text(replyError)
                    .foregroundStyle(.secondary)
            }
            if replyUnavailable {
                Button("Copy reply and open Telegram", action: continueInTelegram)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(.caption)
    }

    private func beginReply() {
        guard showsMore, !isOpeningReply, let actionID = notification.nativeActionID,
              manager.beginReply(to: notification) else { return }
        let session = UUID()
        replySession = session
        replyError = nil
        isOpeningReply = true
        vm.isComposingNotificationReply = true
        Task {
            let result = await XPCHelperClient.shared.notificationReply(actionID, operation: .begin)
            guard replySession == session else {
                if result == .accepted { _ = await XPCHelperClient.shared.notificationReply(actionID, operation: .cancel) }
                isOpeningReply = false
                return
            }
            isOpeningReply = false
            canSend = result == .accepted
            if !canSend {
                replyUnavailable = true
            }
        }
    }

    private func sendReply() {
        guard let session = replySession, let actionID = notification.nativeActionID,
              canSend, !isSending, manager.activeNotification == notification,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true
        replyError = nil
        Task {
            let result = await XPCHelperClient.shared.notificationReply(actionID, operation: .submit, text: draft)
            guard replySession == session else { return }
            isSending = false
            canSend = false
            switch result {
            case .accepted:
                endReply()
                manager.dismissActive(token: notification.id)
            case .unavailable:
                replyUnavailable = true
            case .uncertain:
                replyError = "The system did not confirm the reply. Check Telegram."
            }
        }
    }

    private func cancelReply() {
        guard !isSending else { return }
        endReply()
    }

    private func continueInTelegram() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(draft, forType: .string) else { return }
        endReply(openSource: true)
    }

    private func endReply(openSource: Bool = false) {
        guard replySession != nil else { return }
        replySession = nil
        draft = ""
        isSending = false
        canSend = false
        replyUnavailable = false
        replyError = nil
        vm.isComposingNotificationReply = false
        manager.endReply(to: notification)
        if let actionID = notification.nativeActionID {
            Task {
                _ = await XPCHelperClient.shared.notificationReply(actionID, operation: .cancel)
                if openSource { openSourceApp() }
            }
        }
    }

    private func openSourceApp() {
        Task {
            guard await manager.open(notification), manager.activeNotification == notification else { return }
            manager.dismissActive(token: notification.id)
        }
    }
}

struct NotificationCardContent<Actions: View>: View {
    let notification: SystemNotification
    let layout: NotificationCardLayout
    let showsMore: Bool
    let isReplying: Bool
    let openSource: () -> Void
    let onScrollHover: (Bool) -> Void
    @ViewBuilder let actions: () -> Actions

    private let iconSize: CGFloat = 38
    private var textInset: CGFloat { iconSize + 12 }
    private var sender: String? { notification.title == notification.appName ? nil : notification.title }
    private var message: String? {
        guard let body = notification.body, !body.isEmpty else { return nil }
        return body
    }

    var body: some View {
        if layout == .inline, !isReplying, let message, !message.contains(where: \.isNewline),
           notification.subtitle == nil {
            ViewThatFits(in: .horizontal) {
                content(inlineMessage: message)
                content()
            }
        } else {
            content()
        }
    }

    private func content(inlineMessage: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: layout == .inline && inlineMessage == nil ? 8 : 2) {
            HStack(alignment: .top, spacing: 8) {
                header(inlineMessage: inlineMessage)
                    .padding(.leading, textInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions().fixedSize(horizontal: true, vertical: false)
            }
            if inlineMessage == nil, let message {
                Group {
                    if showsMore {
                        NotificationMessageBody(text: message, openSource: openSource, onScrollHover: onScrollHover)
                    } else {
                        sourceButton {
                            notificationMessageText(message)
                                .lineLimit(isReplying ? 1 : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, layout == .column ? textInset : 0)
            }
        }
        .frame(minHeight: iconSize, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            sourceButton {
                NotificationSourceIcon(bundleID: notification.bundleID, size: iconSize)
            }
            .accessibilityHidden(true)
        }
    }

    private func header(inlineMessage: String?) -> some View {
        sourceButton {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(notification.appName ?? "Notification")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(notification.receivedAt, style: .relative)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let sender {
                        Text(sender).font(.system(size: 13, weight: .medium))
                    }
                    if let inlineMessage {
                        if sender != nil { Text(verbatim: " · ").foregroundStyle(.secondary) }
                        notificationMessageText(inlineMessage)
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: inlineMessage != nil, vertical: false)

                if let subtitle = notification.subtitle {
                    notificationMessageText(subtitle).lineLimit(1)
                }
            }
        }
        .accessibilityHint("Opens \(notification.appName ?? "the app")")
    }

    private func sourceButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button(action: openSource, label: label)
            .buttonStyle(.plain)
            .disabled(isReplying)
    }
}

private func notificationMessageText(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.78))
}

struct NotificationMessageBody: View {
    let text: String
    let openSource: () -> Void
    let onScrollHover: (Bool) -> Void

    @State private var hasMoreBelow = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            message
            ScrollView(.vertical) {
                message.onGeometryChange(for: Bool.self) { geometry in
                    guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else { return false }
                    return geometry.size.height - viewport.maxY > 1
                } action: { hasMoreBelow = $0 }
            }
            .overlay(alignment: .bottom) {
                if hasMoreBelow {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                        .overlay(alignment: .bottom) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onHover(perform: onScrollHover)
            .onDisappear { onScrollHover(false) }
        }
        .frame(maxHeight: 106, alignment: .topLeading)
    }

    private var message: some View {
        Button(action: openSource) {
            notificationMessageText(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct NotificationReplyInput: NSViewRepresentable {
    @Binding var text: String
    let isPreparing: Bool
    let isEditable: Bool
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(input: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.delegate = context.coordinator
        editor.font = .systemFont(ofSize: 13)
        editor.isRichText = false
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 4, height: 3)
        editor.string = text
        editor.isEditable = isEditable && !isPreparing
        scroll.drawsBackground = false
        if !isPreparing {
            context.coordinator.focusAfterLayout(editor)
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let justPrepared = context.coordinator.input.isPreparing && !isPreparing
        context.coordinator.input = self
        guard let editor = view.documentView as? NSTextView else { return }
        editor.isEditable = isEditable && !isPreparing
        if justPrepared {
            context.coordinator.focusAfterLayout(editor)
        }
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.releaseFocus()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var input: NotificationReplyInput
        private weak var window: BoringNotchSkyLightWindow?
        private weak var editor: NSTextView?
        private var previousApplication: NSRunningApplication?
        private var isMounted = true

        init(input: NotificationReplyInput) { self.input = input }

        @MainActor
        func focusAfterLayout(_ editor: NSTextView) {
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, self.isMounted, let editor,
                      let window = editor.window as? BoringNotchSkyLightWindow else { return }
                self.window = window
                self.editor = editor
                // The inactive panel can show a caret without receiving keyboard events.
                if !NSApp.isActive {
                    self.previousApplication = NSWorkspace.shared.frontmostApplication
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(self.applicationDidActivate),
                        name: NSApplication.didBecomeActiveNotification, object: NSApp
                    )
                    NSApp.activate(ignoringOtherApps: true)
                }
                self.makeEditorKey()
            }
        }

        @MainActor @objc private func applicationDidActivate() {
            NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: NSApp)
            makeEditorKey()
        }

        @MainActor private func makeEditorKey() {
            guard isMounted, let window, let editor, editor.window === window else { return }
            window.makeFirstResponder(editor)
            window.wantsKeyForTextInput = true
            window.makeKeyAndOrderFront(nil)
        }

        @MainActor func releaseFocus() {
            isMounted = false
            NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: NSApp)
            guard let window else { return }
            let restoreApplication = NSApp.isActive && (NSApp.keyWindow == nil || NSApp.keyWindow === window)
            if window.firstResponder === editor { window.makeFirstResponder(nil) }
            window.wantsKeyForTextInput = false
            if window.isKeyWindow { window.resignKey() }
            if restoreApplication, let previousApplication {
                _ = previousApplication.activate(from: .current, options: [])
            }
        }

        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView {
                input.text = editor.string
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                input.cancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)),
               NSApp.currentEvent?.modifierFlags.contains(.shift) != true {
                input.submit()
                return true
            }
            return false
        }
    }
}
