//
//  QuickLookService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-07.
//

import Foundation
import Combine
import UniformTypeIdentifiers
import SwiftUI
import QuickLook
import QuickLookUI
import AppKit

@MainActor
final class QuickLookService: ObservableObject {
    @Published var urls: [URL] = []
    @Published var selectedURL: URL?

    @Published var isQuickLookOpen: Bool = false

    private var previewGeneration = UUID()
    private var previewPanel: QLPreviewPanel?
    private var leasedURLs: [URL] = []
    private var accessingURLs: [URL] = []
    private var previewPanelObserver: Any?
    private var selectionCancellable: AnyCancellable?

    init() {
        selectionCancellable = ShelfSelectionModel.shared.$selectedIDs
            .dropFirst()
            .sink { [weak self] selectedIDs in
                self?.updateFromShelfSelection(selectedIDs: selectedIDs)
            }
    }

    func show(urls: [URL], selectFirst: Bool = true, slideshow: Bool = false) {
        guard !urls.isEmpty else { return }
        let existing = Set(leasedURLs.map(\.standardizedFileURL))
        let additions = urls.filter { $0.isFileURL && !existing.contains($0.standardizedFileURL) }
        TemporaryFileStorageService.shared.retain(additions)
        leasedURLs.append(contentsOf: additions)
        // Keep files and scopes until close: Quick Look may read the previous selection during transition.
        previewGeneration = UUID()
        let generation = previewGeneration
        for url in urls where url.isFileURL && !accessingURLs.contains(url) {
            if url.startAccessingSecurityScopedResource() { accessingURLs.append(url) }
        }
        self.urls = urls
        self.isQuickLookOpen = true

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard self.isQuickLookOpen, self.previewGeneration == generation else { return }
            if selectFirst {
                self.selectedURL = self.urls.first
            }
        }

        // Observe the shared Quick Look preview panel closing so we can relinquish security scope
        let panel = QLPreviewPanel.shared()
        // Remove any existing observer for previous panel
        if let prev = previewPanel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: prev)
        }
        previewPanel = panel
        NotificationCenter.default.addObserver(self, selector: #selector(previewPanelWillClose(_:)), name: NSWindow.willCloseNotification, object: panel)
    }

    func hide() {
        previewGeneration = UUID()
        selectedURL = nil
        urls.removeAll()
        isQuickLookOpen = false
        if let panel = previewPanel, panel.isVisible {
            panel.orderOut(nil)
        }
        stopAccessingCurrentURLs()
        if let panel = previewPanel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
            previewPanel = nil
        }
    }

    private func stopAccessingCurrentURLs() {
        NSLog("Stopping access to \(accessingURLs.count) URLs")
        for url in accessingURLs where url.isFileURL {
            url.stopAccessingSecurityScopedResource()
        }
        accessingURLs.removeAll()
        TemporaryFileStorageService.shared.release(leasedURLs)
        leasedURLs.removeAll()
        // If Quick Look panel was closed externally, also remove observer and clear reference
        if let panel = previewPanel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
            previewPanel = nil
        }
    }

    func updateSelection(urls: [URL]) {
        guard isQuickLookOpen else { return }
        show(urls: urls, selectFirst: true)
    }

    private func updateFromShelfSelection(selectedIDs: Set<UUID>) {
        guard isQuickLookOpen else { return }
        guard !selectedIDs.isEmpty else {
            hide()
            return
        }

        let urls: [URL] = ShelfStateViewModel.shared.items.compactMap { item in
            guard selectedIDs.contains(item.id) else { return nil }
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }

        if !urls.isEmpty {
            updateSelection(urls: urls)
        }
    }
}

extension QuickLookService {
    @objc private func previewPanelWillClose(_ notification: Notification) {
        guard let panel = notification.object as? QLPreviewPanel, panel === previewPanel else { return }
        let generation = previewGeneration
        Task { @MainActor in
            guard self.previewGeneration == generation, panel === self.previewPanel else { return }
            previewGeneration = UUID()
            stopAccessingCurrentURLs()
            selectedURL = nil
            urls.removeAll()
            isQuickLookOpen = false
            // Remove observer and clear reference
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
            previewPanel = nil
        }
    }
}

struct QuickLookPresenter: ViewModifier {
    @ObservedObject var service: QuickLookService

    func body(content: Content) -> some View {
        content
            .quickLookPreview($service.selectedURL, in: service.urls)
    }
}

extension View {
    func quickLookPresenter(using service: QuickLookService) -> some View {
        self.modifier(QuickLookPresenter(service: service))
    }
}
