//
//  ShelfItemInteractionView.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

protocol ShelfItemInteractionSurface: AnyObject {}

/// A narrow AppKit bridge for Shelf pointer and native drag interactions.
struct ShelfItemInteractionView<DragPreview: View>: NSViewRepresentable {
    let item: ShelfItem
    let viewModel: ShelfItemViewModel
    @ViewBuilder let dragPreview: () -> DragPreview
    let onPrimaryClick: (NSEvent, NSView) -> Void
    let onContextClick: (NSEvent, NSView) -> Void

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        update(nsView)
    }

    private func update(_ view: InteractionView) {
        view.item = item
        view.dragPreviewProvider = renderDragPreview
        view.onPrimaryClick = onPrimaryClick
        view.onContextClick = onContextClick
    }

    private func renderDragPreview() -> NSImage {
        let renderer = ImageRenderer(content: dragPreview())
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? viewModel.presentationIcon
    }

    final class InteractionView: NSView, NSDraggingSource, ShelfItemInteractionSurface {
        var item: ShelfItem?
        var dragPreviewProvider: (() -> NSImage)?
        var onPrimaryClick: ((NSEvent, NSView) -> Void)?
        var onContextClick: ((NSEvent, NSView) -> Void)?

        private let dragThreshold: CGFloat = 3
        private var mouseDownEvent: NSEvent?
        private var draggedItems: [ShelfItem] = []
        private var draggedTemporaryURLs: [UUID: URL] = [:]
        private var scopedURLs: [URL] = []

        override func rightMouseDown(with event: NSEvent) {
            onContextClick?(event, self)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            onPrimaryClick?(event, self)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownEvent else {
                super.mouseDragged(with: event)
                return
            }

            let dragDistance = hypot(
                event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
                event.locationInWindow.y - mouseDownEvent.locationInWindow.y
            )

            guard dragDistance > dragThreshold else {
                super.mouseDragged(with: event)
                return
            }

            self.mouseDownEvent = nil
            startDragSession(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownEvent = nil
            super.mouseUp(with: event)
        }

        private func startDragSession(with event: NSEvent) {
            guard let item else { return }
            let shelf = ShelfStateViewModel.shared
            let clickedID = item.id
            let selectedItems = ShelfSelectionModel.shared.selectedItems(
                in: shelf.items
            )
            let itemsToDrag = selectedItems.count > 1
                && selectedItems.contains(where: { $0.id == clickedID })
                ? selectedItems
                : [item]

            let image = dragPreviewProvider?() ?? NSImage()
            let origin = NSPoint(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2)
            let frame = NSRect(origin: origin, size: image.size)
            let draggingItems = itemsToDrag.compactMap { item -> NSDraggingItem? in
                guard let writer = pasteboardWriter(for: item, shelf: shelf) else { return nil }
                draggedItems.append(item)
                let draggingItem = NSDraggingItem(pasteboardWriter: writer)
                draggingItem.setDraggingFrame(frame, contents: image)
                return draggingItem
            }
            guard !draggingItems.isEmpty else { return }
            beginDraggingSession(with: draggingItems, event: event, source: self)
        }

        private func pasteboardWriter(for item: ShelfItem, shelf: ShelfStateViewModel) -> (any NSPasteboardWriting)? {
            switch item.kind {
            case .file:
                guard let url = shelf.fileURLForDrag(item) else { return nil }
                if item.isTemporary {
                    guard TemporaryFileStorageService.shared.retainExistingFile(at: url) else { return nil }
                    draggedTemporaryURLs[item.id] = url
                }
                if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                return url as NSURL

            case .text(let string):
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(string, forType: .string)
                return pasteboardItem

            case .link(let url):
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(url.absoluteString, forType: .URL)
                pasteboardItem.setString(url.absoluteString, forType: .string)
                return pasteboardItem
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            ShelfSelectionModel.shared.beginDrag()
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            ShelfSelectionModel.shared.endDrag()
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            scopedURLs.removeAll()

            let completedItems = draggedItems
            let completedTemporaryURLs = draggedTemporaryURLs
            let leasedURLs = Array(completedTemporaryURLs.values)
            if !operation.isEmpty {
                let removeCards = Defaults[.autoRemoveShelfItems]
                Task { @MainActor in
                    defer { TemporaryFileStorageService.shared.release(leasedURLs) }
                    await ShelfStateViewModel.shared.finishExternalDrop(
                        completedItems, temporaryURLs: completedTemporaryURLs, removeCards: removeCards
                    )
                }
            } else {
                TemporaryFileStorageService.shared.release(leasedURLs)
            }
            draggedItems.removeAll()
            draggedTemporaryURLs.removeAll()
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            true
        }
    }
}
