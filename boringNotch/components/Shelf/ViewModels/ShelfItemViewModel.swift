//
//  ShelfItemViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoreServices
import ObjectiveC

@MainActor
final class ShelfItemViewModel: ObservableObject {
    @Published private(set) var item: ShelfItem

    @Published var thumbnail: NSImage?
    @Published var isRenaming: Bool = false
    @Published var draftTitle: String = ""
    @Published private(set) var displayName: String
    private let fallbackIcon: NSImage
    var presentationIcon: NSImage { thumbnail ?? fallbackIcon }
    private var sharingLifecycle: SharingLifecycleDelegate?
    private var quickShareLifecycle: SharingLifecycleDelegate?
    private var sharingAccessingURLs: [URL] = []

    private let selection = ShelfSelectionModel.shared

    init(item: ShelfItem) {
        self.item = item
        if case .file = item.kind {
            displayName = String(localized: "File")
            fallbackIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
        } else {
            displayName = item.displayName
            fallbackIcon = item.icon
        }
    }

    func loadPresentation(for currentItem: ShelfItem) async {
        if currentItem != item { item = currentItem }
        guard case .file = item.kind else { return }
        guard let url = await ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: currentItem) else {
            guard !Task.isCancelled else { return }
            displayName = String(localized: "Unavailable File")
            thumbnail = nil
            return
        }
        let title = await Bookmark.onWorker { ShelfItem.fileDisplayName(at: url) }
        guard !Task.isCancelled else { return }
        if displayName != title { displayName = title }
        let size = CGSize(width: 56, height: 56)
        if let image = await ThumbnailService.shared.thumbnail(for: url, size: size),
           !Task.isCancelled {
            thumbnail = NSImage(cgImage: image, size: size)
        }
    }

    // MARK: - Actions
    func handleClick(event: NSEvent, view: NSView) {
        let flags = event.modifierFlags
        if flags.contains(.shift) {
            selection.shiftSelect(to: item, in: ShelfStateViewModel.shared.items)
        } else if flags.contains(.command) {
            selection.toggle(item)
        } else if flags.contains(.control) {
            handleRightClick(event: event, view: view)
        } else {
            if !selection.isSelected(item.id) { selection.selectSingle(item) }
        }
        if event.clickCount == 2 { handleDoubleClick() }
    }

    func handleRightClick(event: NSEvent, view: NSView) {
        if !selection.isSelected(item.id) { selection.selectSingle(item) }
        ShelfContextMenuBuilder.present(
            item: item, event: event, in: view,
            onShare: { [weak self] v in self?.shareItem(from: v) },
            onQuickLook: { [weak self] urls in self?.onQuickLookRequest?(urls) }
        )
    }

    func handleDoubleClick() {
    let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
        for it in selected { ShelfActionService.open(it) }
    }

    func shareItem(from view: NSView?) {
        Task {
            var itemsToShare: [Any] = []
            var fileURLs: [URL] = []
            if case .text(let text) = item.kind {
                itemsToShare.append(text)
            } else {
                let shelf = ShelfStateViewModel.shared
                let selected = selection.selectedItems(in: shelf.items)
                let resolved = await shelf.resolveFiles(for: selected)
                for item in selected {
                    switch item.kind {
                    case .file:
                        if let url = resolved[item.id] {
                            itemsToShare.append(url)
                            fileURLs.append(url)
                        }
                    case .text(let string):
                        itemsToShare.append(string)
                    case .link(let url):
                        itemsToShare.append(url)
                    }
                }
            }

            guard !itemsToShare.isEmpty else { return }

            stopSharingAccessingURLs()
            // Start security-scoped access for all file URLs and keep it active during sharing
            sharingAccessingURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }

            // Create and retain lifecycle delegate for the entire share operation
            TemporaryFileStorageService.shared.retain(fileURLs)
            let accessing = sharingAccessingURLs
            sharingAccessingURLs = []
            let lifecycle = SharingStateManager.shared.makeDelegate {
                accessing.forEach { $0.stopAccessingSecurityScopedResource() }
                TemporaryFileStorageService.shared.release(fileURLs)
            }
            self.sharingLifecycle = lifecycle

            let picker = NSSharingServicePicker(items: itemsToShare)
            picker.delegate = lifecycle
            lifecycle.markPickerBegan()
            if let view {
                picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
            } else {
                lifecycle.sharingServicePicker(picker, didChoose: nil)
            }
        }
    }

    private func stopSharingAccessingURLs() {
        for url in sharingAccessingURLs {
            url.stopAccessingSecurityScopedResource()
        }
        sharingAccessingURLs.removeAll()
    }

    /// Call this closure to request a QuickLook preview for the given URLs.
    var onQuickLookRequest: (([URL]) -> Void)?
}
