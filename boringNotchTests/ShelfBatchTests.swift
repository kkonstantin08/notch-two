import AppKit
import Combine
import Foundation
import XCTest
@testable import boringNotch

final class ShelfBatchTests: XCTestCase {
    @MainActor
    func testBulkRemovalPublishesOnceAndPreservesFinderFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ShelfPersistenceService(fileURL: root.appendingPathComponent("items.json"))
        let selection = ShelfSelectionModel()
        let shelf = ShelfStateViewModel(persistence: persistence, selection: selection)
        let contents = Data("Fixture contents".utf8)
        let originals = try (0..<100).map { index in
            let url = root.appendingPathComponent("original-\(index).txt")
            try contents.write(to: url)
            return url
        }
        let items = try originals.map { ShelfItem(kind: .file(bookmark: try Bookmark(url: $0).data)) }

        for count in [10, 50, 100] {
            let batch = Array(items.prefix(count))
            await shelf.add(batch)
            selection.selectAll(in: shelf.items)
            XCTAssertEqual(selection.selectedIDs, Set(batch.map(\.id)))

            var updates = 0
            let observation = shelf.$items.dropFirst().sink { _ in updates += 1 }
            shelf.removeSelected()
            observation.cancel()
            XCTAssertEqual(updates, 1)
            XCTAssertTrue(shelf.isEmpty)
            XCTAssertFalse(selection.hasSelection)
            shelf.flushSync()
            XCTAssertTrue(persistence.load().isEmpty)
        }

        for original in originals {
            XCTAssertEqual(try Data(contentsOf: original), contents)
        }
    }

    @MainActor
    func testClearAllIncludesUnselectedItemsAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ShelfPersistenceService(fileURL: root.appendingPathComponent("items.json"))
        let selection = ShelfSelectionModel()
        let shelf = ShelfStateViewModel(persistence: persistence, selection: selection)
        let items = ["first", "second", "third"].map { ShelfItem(kind: .text(string: $0)) }
        await shelf.add(items)
        selection.toggle(items[0])
        selection.shiftSelect(to: items[1], in: items)
        XCTAssertEqual(selection.selectedItems(in: items), Array(items.prefix(2)))

        shelf.removeAll()
        shelf.flushSync()

        XCTAssertFalse(selection.hasSelection)
        XCTAssertTrue(persistence.load().isEmpty)
        XCTAssertTrue(shelf.isEmpty)
    }

    @MainActor
    func testPasteUsesPrivatePasteboardAndRetainsText() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Shelf paste fixture", forType: .string))

        let providers = ShelfDropService.clipboardProviders(from: pasteboard)
        let items = await ShelfDropService.startLoading(providers).value

        XCTAssertEqual(items.map(\.kind), [.text(string: "Shelf paste fixture")])
    }

    @MainActor
    func testSuccessfulExternalDropDetachesShelfItemAndPreservesExportedURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TemporaryFileStorageService.shared
        let staged = await storage.createTempFile(for: .text("Telegram preview"))
        let source = try XCTUnwrap(staged)
        defer { storage.removeTemporaryFileIfNeeded(at: source) }
        let bookmark = try Bookmark(url: source).data
        let item = ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
        let shelf = ShelfStateViewModel(
            persistence: ShelfPersistenceService(fileURL: root.appendingPathComponent("items.json")),
            selection: ShelfSelectionModel()
        )

        await shelf.add([item])
        await shelf.finishExternalDrop([item], temporaryURLs: [item.id: source], removeCards: true)
        XCTAssertTrue(shelf.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let readded = ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
        await shelf.add([readded])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        shelf.remove(readded)
        for _ in 0..<200 where FileManager.default.fileExists(atPath: source.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
}
