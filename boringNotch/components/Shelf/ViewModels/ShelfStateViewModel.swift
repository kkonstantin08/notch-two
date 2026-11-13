//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit

private final class ShelfFileLease: @unchecked Sendable {
    let url: URL
    init?(url: URL) {
        guard TemporaryFileStorageService.shared.retainExistingFile(at: url) else { return nil }
        self.url = url
    }
    deinit { TemporaryFileStorageService.shared.release([url]) }
}

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel(persistence: .shared, selection: .shared)

    @Published private(set) var items: [ShelfItem] {
        didSet { schedulePersistence() }
    }
    @Published private(set) var isLoading = false

    var isEmpty: Bool { items.isEmpty }

    private let persistence: ShelfPersistenceService
    private let selection: ShelfSelectionModel
    private var persistenceTask: Task<Void, Never>?
    private var pendingDrops = 0
    private var clearGeneration = 0
    private var fileLeases: [UUID: ShelfFileLease] = [:]

    init(persistence: ShelfPersistenceService, selection: ShelfSelectionModel) {
        self.persistence = persistence
        self.selection = selection
        items = persistence.load()
        let snapshot = items
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        Task {
            let loadedLeases = await Bookmark.onWorker {
                let leases = snapshot.reduce(into: [UUID: ShelfFileLease]()) { result, item in
                    guard case .file(let data) = item.kind,
                          let url = Bookmark(data: data).resolvedURL else { return }
                    result[item.id] = ShelfFileLease(url: url)
                }
                if persistence.hasCompleteSnapshot(),
                   let referenced = ShelfPersistenceService.cleanupReferences(in: snapshot) {
                    TemporaryFileStorageService.shared.cleanupStaleFiles(referenced: referenced, olderThan: cutoff)
                }
                return leases
            }
            for item in snapshot where items.contains(item) {
                if fileLeases[item.id] == nil { fileLeases[item.id] = loadedLeases[item.id] }
            }
        }
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            await persistence.saveAsync(items)
        }
    }

    func add(_ newItems: [ShelfItem]) async {
        await add(newItems, generation: clearGeneration)
    }

    private func add(_ newItems: [ShelfItem], generation: Int) async {
        guard !newItems.isEmpty else { return }
        let prepared = await Bookmark.onWorker {
            newItems.compactMap { item -> (ShelfItem, String, ShelfFileLease?)? in
                if case .file(let data) = item.kind {
                    guard let url = Bookmark(data: data).resolvedURL,
                          let lease = ShelfFileLease(url: url) else {
                        Log.shelf.debug("Skipped an unavailable file while adding to Shelf")
                        return nil
                    }
                    return (item, "file://" + url.standardizedFileURL.path, lease)
                }
                return (item, item.identityKey, nil)
            }
        }
        while !Task.isCancelled, generation == clearGeneration {
            let snapshot = items
            let existingKeys = await Bookmark.onWorker { snapshot.map(\.identityKey) }
            guard !Task.isCancelled, generation == clearGeneration else { break }
            guard items == snapshot else { continue }
            var seen = Set(existingKeys)
            let additions = prepared.compactMap { item, key, lease -> ShelfItem? in
                guard seen.insert(key).inserted else { return nil }
                fileLeases[item.id] = lease
                return item
            }
            if !additions.isEmpty { items.append(contentsOf: additions) }
            return
        }
        let snapshot = items
        await Bookmark.onWorker {
            guard let references = ShelfPersistenceService.cleanupReferences(in: snapshot) else { return }
            for (item, _, lease) in prepared where item.isTemporary {
                if let url = lease?.url, !references.contains(url.standardizedFileURL) {
                    TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url)
                }
            }
        }
    }

    func remove(_ item: ShelfItem) {
        remove([item])
    }

    func remove(_ itemsToRemove: [ShelfItem]) {
        remove(itemsToRemove, preservingTemporaryFiles: false)
    }

    func finishExternalDrop(_ draggedItems: [ShelfItem], temporaryURLs: [UUID: URL], removeCards: Bool) async {
        // A destination can read the exported URL after AppKit reports the drop.
        let renewed = temporaryURLs.isEmpty ? [] : await Bookmark.onWorker {
            temporaryURLs.compactMap { id, url in
                TemporaryFileStorageService.shared.renewOwnership(at: url) ? id : nil
            }
        }
        guard removeCards else { return }
        remove(draggedItems.filter { temporaryURLs[$0.id] == nil || renewed.contains($0.id) },
               preservingTemporaryFiles: true)
    }

    private func remove(_ itemsToRemove: [ShelfItem], preservingTemporaryFiles: Bool) {
        let ids = Set(itemsToRemove.map(\.id))
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        selection.remove(ids)
        let temporaryFiles = removed.compactMap { item -> (Data, URL?)? in
            guard !preservingTemporaryFiles, item.isTemporary, case .file(let bookmark) = item.kind else { return nil }
            return (bookmark, fileLeases[item.id]?.url)
        }
        for id in ids { fileLeases[id] = nil }

        let remainingItems = items
        let empty = items.isEmpty
        guard empty || !temporaryFiles.isEmpty else { return }
        Task {
            let paths = await Bookmark.onWorker {
                let referenced = ShelfPersistenceService.cleanupReferences(in: remainingItems)
                return temporaryFiles.compactMap { data, knownURL in
                    let url = knownURL ?? Bookmark(data: data).resolvedURL
                    if let url, let referenced, !referenced.contains(url.standardizedFileURL) {
                        TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url)
                    }
                    return url
                }
            }
            if empty {
                await ThumbnailService.shared.clearCache()
            } else {
                for url in paths { await ThumbnailService.shared.clearCache(for: url) }
            }
        }
    }

    func removeSelected() {
        remove(selection.selectedItems(in: items))
    }

    func removeAll() {
        clearGeneration += 1
        remove(items)
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              case .file(let previous) = items[index].kind, previous != bookmark else { return }
        items[index] = ShelfItem(id: item.id, kind: .file(bookmark: bookmark), isTemporary: items[index].isTemporary)
    }

    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let generation = clearGeneration
        let load = ShelfDropService.startLoading(providers)
        pendingDrops += 1
        if !isLoading { isLoading = true }
        Task { [weak self] in
            let dropped = await load.value
            guard let self else { return }
            await add(dropped, generation: generation)
            pendingDrops -= 1
            if pendingDrops == 0 { isLoading = false }
        }
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) async -> URL? {
        await resolveFiles(for: [item])[item.id]
    }

    // AppKit starts the native drag inside mouseDragged, before returning the event.
    func fileURLForDrag(_ item: ShelfItem) -> URL? {
        guard let current = items.first(where: { $0.id == item.id }),
              case .file(let bookmark) = current.kind else { return nil }
        let result = Bookmark(data: bookmark).resolve()
        guard let url = result.url, url.accessSecurityScopedResource(accessor: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { return nil }
        if let refreshed = result.refreshedData { updateBookmark(for: current, bookmark: refreshed) }
        if fileLeases[item.id]?.url != url { fileLeases[item.id] = ShelfFileLease(url: url) }
        return url
    }

    func resolveFiles(for requestedItems: [ShelfItem]) async -> [UUID: URL] {
        let files = requestedItems.compactMap { item -> (ShelfItem, Data)? in
            guard case .file(let bookmark) = item.kind else { return nil }
            return (item, bookmark)
        }
        guard !files.isEmpty else { return [:] }
        let resolved = await Bookmark.onWorker {
            files.compactMap { item, data -> (ShelfItem, URL, Data?)? in
                let result = Bookmark(data: data).resolve()
                guard let url = result.url, url.accessSecurityScopedResource(accessor: {
                    FileManager.default.fileExists(atPath: $0.path)
                }) else { return nil }
                return (item, url, result.refreshedData)
            }
        }
        guard !Task.isCancelled else { return [:] }
        let current = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var urls: [UUID: URL] = [:]
        var refreshed: [UUID: Data] = [:]
        for (item, url, data) in resolved where current[item.id] == item {
            urls[item.id] = url
            refreshed[item.id] = data
        }
        if !refreshed.isEmpty {
            items = items.map { item in
                guard let data = refreshed[item.id] else { return item }
                return ShelfItem(id: item.id, kind: .file(bookmark: data), isTemporary: item.isTemporary)
            }
        }
        return urls
    }

    func flushSync() {
        persistenceTask?.cancel()
        persistenceTask = nil
        persistence.save(items)
    }
}
