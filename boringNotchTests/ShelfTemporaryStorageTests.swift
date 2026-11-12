import Foundation
import XCTest
@testable import boringNotch

final class ShelfTemporaryStorageTests: XCTestCase {
    func testCleanupPreservesUnownedFileUnderSystemTemp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unowned-Shelf-Fixture-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = directory.appendingPathComponent("original.txt")
        let contents = Data("original".utf8)
        try contents.write(to: original)

        TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: original)

        XCTAssertEqual(try? Data(contentsOf: original), contents)
    }

    func testCleanupDoesNotFollowDirectorySymlinkIntoOriginals() throws {
        let root = FileManager.default.temporaryDirectory
        let originals = root.appendingPathComponent("Shelf-Originals-\(UUID())", isDirectory: true)
        let link = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: originals)
        }
        let original = originals.appendingPathComponent("original.txt")
        let contents = Data("original".utf8)
        try contents.write(to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: originals)

        TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(
            at: link.appendingPathComponent("original.txt")
        )

        XCTAssertEqual(try? Data(contentsOf: original), contents)
    }

    func testCleanupRemovesAnOwnedCopyAndItsEmptyDirectory() async throws {
        let storage = TemporaryFileStorageService.shared
        let created = await storage.createTempFile(for: .data(Data("copy".utf8), suggestedName: "copy.txt"))
        let copy = try XCTUnwrap(created)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        storage.removeTemporaryFileIfNeeded(at: copy)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
    }
}
