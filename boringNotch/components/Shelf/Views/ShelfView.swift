//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit
import Defaults

extension View {
    func shelfDropTarget(isTargeted: Binding<Bool>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        onDrop(of: ShelfDropService.contentTypes, delegate: ShelfDropTarget(isTargeted: isTargeted, perform: perform))
    }
}

private struct ShelfDropTarget: DropDelegate {
    @Binding var isTargeted: Bool
    let perform: ([NSItemProvider]) -> Bool

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        defer { isTargeted = false }
        return perform(ShelfDropService.providersForDrop(
            info.itemProviders(for: ShelfDropService.contentTypes)
        ))
    }
}

struct ShelfView: View {
    let dropInteraction: DropInteractionState
    @StateObject var shelfState = ShelfStateViewModel.shared
    @ObservedObject private var selection = ShelfSelectionModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let spacing: CGFloat = 8

    private var displayedItems: [ShelfItem] {
        Defaults[.reverseShelfOrdering] ? Array(shelfState.items.reversed()) : shelfState.items
    }

    var body: some View {
        @Bindable var interaction = dropInteraction

        ShelfQuickLookHost { quickLookService in
            HStack(spacing: 12) {
                FileShareView(dropInteraction: dropInteraction)
                    .aspectRatio(1, contentMode: .fit)
                panel(quickLookService: quickLookService)
                    .contentShape(.interaction, Rectangle())
                    .shelfDropTarget(isTargeted: Binding(
                        get: { interaction.shelfTargeting && !selection.isDragging },
                        set: { interaction.shelfTargeting = $0 && !selection.isDragging }
                    )) { providers in
                        handleDrop(providers: providers)
                    }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, !ShelfSelectionModel.shared.isDragging else { return false }
        dropInteraction.dropEvent = true
        shelfState.load(providers)
        return true
    }

    private func panel(quickLookService: QuickLookService) -> some View {
        let highlighted = (!selection.isDragging && !dropInteraction.dropZoneTargeting
            && (dropInteraction.notchTargeting || dropInteraction.shelfTargeting)) || shelfState.isLoading
        return RoundedRectangle(cornerRadius: 16)
            .fill(highlighted ? Color.accentColor.opacity(0.2) : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        highlighted ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.1),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                    )
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: highlighted)
            .overlay {
                VStack(spacing: 2) {
                    HStack {
                        Spacer()
                        ShelfActionsView(shelf: shelfState, items: displayedItems)
                    }
                    .zIndex(1)
                    ZStack {
                        ShelfBackgroundInteractionView()
                        content(quickLookService: quickLookService)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .contextMenu {
                Button("Paste") { shelfState.load(ShelfDropService.clipboardProviders()) }
            }
    }

    private func content(quickLookService: QuickLookService) -> some View {
        let items = displayedItems
        let transition: AnyTransition = reduceMotion ? .identity : .asymmetric(
            insertion: .offset(y: 2).combined(with: .opacity),
            removal: .opacity
        )
        return ScrollView(.horizontal) {
            LazyHStack(spacing: spacing) {
                ForEach(items) { item in
                    ShelfItemView(item: item, quickLookService: quickLookService)
                        .transition(transition)
                }
            }
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if shelfState.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)

                    Text("Drop files here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
                .allowsHitTesting(false)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: items.map(\.id))
    }
}

private struct ShelfActionsView: NSViewRepresentable {
    @ObservedObject var shelf: ShelfStateViewModel
    let items: [ShelfItem]
    @ObservedObject private var selection = ShelfSelectionModel.shared
    @EnvironmentObject private var vm: BoringViewModel
    private static let buttonSize = CGSize(width: 36, height: 30)

    func makeCoordinator() -> Coordinator { Coordinator(view: self) }

    func makeNSView(context: Context) -> NSButton {
        let button = MenuButton(frame: CGRect(origin: .zero, size: Self.buttonSize))
        let label = String(localized: "Shelf Actions")
        button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityRole(.menuButton)
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        Self.buttonSize
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.view = self
        button.isEnabled = !selection.isDragging
    }

    private final class MenuButton: NSButton {
        override var intrinsicContentSize: NSSize { ShelfActionsView.buttonSize }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    @MainActor
    final class Coordinator: NSObject {
        var view: ShelfActionsView

        init(view: ShelfActionsView) { self.view = view }

        @objc func openMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            addItem(String(localized: "Select All"), action: #selector(selectAll), enabled: !view.items.isEmpty, to: menu)
            addItem(String(localized: "Paste All"), action: #selector(pasteAll), enabled: true, to: menu)
            menu.addItem(.separator())
            addItem(String(localized: "Clear All"), action: #selector(clearAll),
                    enabled: !view.items.isEmpty || view.shelf.isLoading, to: menu)

            let vm = view.vm
            let wasActive = vm.isPopoverActive
            vm.isPopoverActive = true
            defer { vm.isPopoverActive = wasActive }
            menu.popUp(positioning: nil, at: .zero, in: sender)
        }

        private func addItem(_ title: String, action: Selector, enabled: Bool, to menu: NSMenu) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }

        @objc private func selectAll() { view.selection.selectAll(in: view.items) }
        @objc private func pasteAll() { view.shelf.load(ShelfDropService.clipboardProviders()) }
        @objc private func clearAll() { view.shelf.removeAll() }
    }
}

private struct ShelfBackgroundInteractionView: NSViewRepresentable {
    func makeNSView(context: Context) -> BackgroundView {
        BackgroundView()
    }

    func updateNSView(_ nsView: BackgroundView, context: Context) {}

    static func dismantleNSView(_ nsView: BackgroundView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class BackgroundView: NSView {
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()

            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window,
                  event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let contentView = window.contentView
            else { return }

            let hitPoint = contentView.convert(event.locationInWindow, from: nil)
            guard !isShelfItemInteraction(contentView.hitTest(hitPoint)) else { return }

            ShelfSelectionModel.shared.clear()
        }

        private func isShelfItemInteraction(_ hitView: NSView?) -> Bool {
            var view = hitView
            while let currentView = view {
                if currentView is any ShelfItemInteractionSurface {
                    return true
                }
                view = currentView.superview
            }
            return false
        }
    }
}

private struct ShelfQuickLookHost<Content: View>: View {
    @State private var service = QuickLookService()
    @ViewBuilder let content: (QuickLookService) -> Content

    var body: some View {
        content(service)
            .quickLookPresenter(using: service)
    }
}
