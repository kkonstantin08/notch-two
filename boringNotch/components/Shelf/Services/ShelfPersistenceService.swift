//
//  ShelfPersistenceService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation

// Access model types
@_exported import struct Foundation.URL

final class ShelfPersistenceService: Sendable {
    static let shared: ShelfPersistenceService = {
        let manager = FileManager.default
        let support = try? manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = (support ?? manager.temporaryDirectory)
            .appendingPathComponent("boringNotch/Shelf", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return ShelfPersistenceService(fileURL: directory.appendingPathComponent("items.json"))
    }()

    private let fileURL: URL
    private let writes = DispatchQueue(label: "notch.shelf.persistence", qos: .utility)

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [ShelfItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Try to decode as array first (normal case)
        if let items = try? decoder.decode([ShelfItem].self, from: data) {
            return items
        }

        // If array decoding fails, try to decode individual items
        do {
            // Parse as JSON array to get individual item data
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                Log.shelf.error("⚠️ Shelf persistence file is not a valid JSON array")
                return []
            }

            var validItems: [ShelfItem] = []
            var failedCount = 0

            for (index, jsonItem) in jsonArray.enumerated() {
                do {
                    let itemData = try JSONSerialization.data(withJSONObject: jsonItem)
                    let item = try decoder.decode(ShelfItem.self, from: itemData)
                    validItems.append(item)
                } catch {
                    failedCount += 1
                    Log.shelf.error("⚠️ Failed to decode shelf item at index \(index): \(error.localizedDescription)")
                }
            }

            if failedCount > 0 {
                Log.shelf.error("📦 Successfully loaded \(validItems.count) shelf items, discarded \(failedCount) corrupted items")
            }

            return validItems
        } catch {
            Log.shelf.error("❌ Failed to parse shelf persistence file: \(error.localizedDescription)")
            return []
        }
    }

    func hasCompleteSnapshot() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ShelfItem].self, from: data)) != nil
    }

    static func cleanupReferences(in items: [ShelfItem]) -> Set<URL>? {
        var references = Set<URL>()
        for item in items {
            guard case .file(let data) = item.kind else { continue }
            // An unresolved bookmark cannot prove that an owned copy is unused.
            guard let url = Bookmark(data: data).resolvedURL else { return nil }
            references.insert(url.standardizedFileURL)
        }
        return references
    }

    func save(_ items: [ShelfItem]) {
        writes.sync { write(items) }
    }

    @MainActor
    func saveAsync(_ items: [ShelfItem]) async {
        await withCheckedContinuation { continuation in
            writes.async {
                self.write(items)
                continuation.resume()
            }
        }
    }

    private func write(_ items: [ShelfItem]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)
        } catch {
            Log.shelf.error("Failed to save shelf items: \(error.localizedDescription)")
        }
    }
}
