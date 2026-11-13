import AppKit
import Foundation
import UniformTypeIdentifiers

@main
struct ShelfChecks {
    private struct Failure: Error {
        let reason: String
    }

    @MainActor
    static func main() async {
        do {
            try await checkStorageOwnership()
            try await checkBatchOperations()
            try await checkUnresolvedRemainingBookmark()
            try await checkReaddition()
            try await checkPaste()
            try await checkDropRepresentations()
            try await checkNativeFileDropPrefersFinderURLs()
            try await checkTextFiles()
            try await checkSuccessfulExternalDrop()
            try await checkClearDuringDrop()
        } catch let failure as Failure {
            FileHandle.standardError.write(Data("Shelf check failed: \(failure.reason)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("Shelf fixture failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func checkDropRepresentations() async throws {
        let unnamed = dataProvider(.data, data: Data("opaque drag metadata".utf8))
        let unknownItems = await ShelfDropService.startLoading([unnamed]).value
        defer {
            for item in unknownItems {
                if let url = item.fileURL { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url) }
            }
        }
        try require(unknownItems.isEmpty, "unnamed generic drag bytes were saved as a file")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Real File.pdf")
        let bytes = Data("%PDF-test".utf8)
        try bytes.write(to: original)
        let provider = NSItemProvider(object: original as NSURL)
        registerData(.data, data: Data("opaque drag metadata".utf8), on: provider)
        let originalItems = await ShelfDropService.startLoading([provider]).value
        try require(originalItems.first?.fileURL?.standardizedFileURL == original.standardizedFileURL,
                    "drag did not retain the original filename and URL")
        try require((try? Data(contentsOf: original)) == bytes, "drag modified the source file")

        let drop = DropFileProvider()
        registerData(.fileURL, data: Data(original.absoluteString.utf8), on: drop)
        let loading = ShelfDropService.startLoading([drop])
        guard let deliver = drop.deliver else {
            throw Failure(reason: "file drop did not start reading inside the drop callback")
        }
        deliver(Data(original.absoluteString.utf8) as NSData, nil)
        let loaded = await loading.value
        try require(loaded.first?.fileURL?.standardizedFileURL == original.standardizedFileURL,
                    "deferred file-URL bytes did not resolve to the original")

        let folder = root.appendingPathComponent("Real Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let folderItems = await ShelfDropService.startLoading([NSItemProvider(object: folder as NSURL)]).value
        try require(folderItems.first?.fileURL?.lastPathComponent == folder.lastPathComponent,
                    "drop did not retain the folder name")

        let typed = dataProvider(.data, data: Data("opaque drag metadata".utf8))
        typed.suggestedName = "Untitled.dat"
        registerData(.pdf, data: bytes, on: typed)
        let typedItems = await ShelfDropService.startLoading([typed]).value
        guard let url = typedItems.first?.fileURL else { throw Failure(reason: "typed PDF drop disappeared") }
        defer { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url) }
        try require(url.pathExtension == "pdf" && (try? Data(contentsOf: url)) == bytes,
                    "typed drop did not retain its extension and content")
        print("Shelf drop kept real filenames and rejected unnamed generic drag metadata")
    }

    @MainActor
    private static func checkNativeFileDropPrefersFinderURLs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original from Finder.txt")
        let bytes = Data("Finder drop fixture".utf8)
        try bytes.write(to: original)

        let fallback = dataProvider(.utf8PlainText, data: bytes)
        fallback.suggestedName = original.lastPathComponent
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try require(pasteboard.writeObjects([original as NSURL]), "could not publish Finder's file URL")

        let providers = ShelfDropService.providersForDrop([fallback], pasteboard: pasteboard)
        let items = await ShelfDropService.startLoading(providers).value
        try require(items.count == 1 && items[0].isTemporary == false, "Finder drop made a temporary copy")
        try require(items[0].fileURL?.standardizedFileURL == original.standardizedFileURL,
                    "Finder drop lost the original path")

        pasteboard.clearContents()
        try require(pasteboard.writeObjects([original as NSURL, "Mixed drag text" as NSString]),
                    "could not publish mixed drag representations")
        let mixed = ShelfDropService.providersForDrop([fallback], pasteboard: pasteboard)
        try require(mixed.first === fallback, "native file URL replaced a mixed drag")
        print("Shelf preserves Finder URLs when SwiftUI supplies file content instead")
    }

    @MainActor
    private static func checkTextFiles() async throws {
        let contents = Data("sample text contents".utf8)
        let provider = dataProvider(.utf8PlainText, data: contents)
        provider.suggestedName = "Notes.txt"
        let results = await ShelfDropService.startLoading([provider]).value
        guard let item = results.first, case .file = item.kind, let url = item.fileURL else {
            throw Failure(reason: "a named text file became a text card")
        }
        defer { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url) }
        try require(url.lastPathComponent == "Notes.txt", "text-file drop lost its name")
        try require((try? Data(contentsOf: url)) == contents, "text-file drop changed the contents")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Promised.txt")
        try contents.write(to: original)
        let promised = NSItemProvider()
        promised.registerFileRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier,
                                           fileOptions: [], visibility: .all) { completion in
            completion(original, false, nil)
            return nil
        }
        let promisedItems = await ShelfDropService.startLoading([promised]).value
        guard let promisedItem = promisedItems.first, case .file = promisedItem.kind,
              let promisedURL = promisedItem.fileURL else {
            throw Failure(reason: "a promised text file was lost")
        }
        defer {
            if promisedItem.isTemporary { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: promisedURL) }
        }
        try require(promisedItem.isTemporary, "promised file is not an owned copy")
        try require(promisedURL != original, "promised source was retained instead of copied")
        try require(promisedURL.lastPathComponent == original.lastPathComponent, "promised file lost its name")
        try require((try? Data(contentsOf: original)) == contents, "promised source was changed")
        try FileManager.default.removeItem(at: original)
        try require((try? Data(contentsOf: promisedURL)) == contents, "copy disappeared with the provider's temporary file")

        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let folderProvider = NSItemProvider()
        folderProvider.registerFileRepresentation(forTypeIdentifier: UTType.folder.identifier,
                                                  fileOptions: [.openInPlace], visibility: .all) { completion in
            completion(folder, true, nil)
            return nil
        }
        let folders = await ShelfDropService.startLoading([folderProvider]).value
        try require(folders.first?.fileURL?.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
                    "directory representation no longer resolves")
        try require(folders.first?.isTemporary == false, "original folder became disposable")

        let pdf = dataProvider(.utf8PlainText, data: Data("auxiliary text".utf8))
        registerData(.pdf, data: Data("%PDF-fixture".utf8), on: pdf)
        let pdfItems = await ShelfDropService.startLoading([pdf]).value
        guard let pdfItem = pdfItems.first, case .file = pdfItem.kind, let pdfURL = pdfItem.fileURL else {
            throw Failure(reason: "a PDF with auxiliary text became a text card")
        }
        defer { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: pdfURL) }
        try require(pdfURL.pathExtension == "pdf", "PDF drop used its auxiliary text representation")
        try require((try? Data(contentsOf: pdfURL)) == Data("%PDF-fixture".utf8), "PDF content changed")

        let plainText = NSItemProvider(object: "ordinary text" as NSString)
        let textItems = await ShelfDropService.startLoading([plainText]).value
        try require(textItems.map(\.kind) == [.text(string: "ordinary text")], "ordinary text became a file")
        print("Shelf preserves named and promised text files while keeping plain text cards")
    }

    private static func dataProvider(_ type: UTType, data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        registerData(type, data: data, on: provider)
        return provider
    }

    private final class DropFileProvider: NSItemProvider, @unchecked Sendable {
        var deliver: NSItemProvider.CompletionHandler?

        override func loadItem(forTypeIdentifier typeIdentifier: String, options: [AnyHashable: Any]? = nil,
                               completionHandler: NSItemProvider.CompletionHandler? = nil) {
            if typeIdentifier == UTType.fileURL.identifier { deliver = completionHandler }
        }
    }

    private static func registerData(_ type: UTType, data: Data, on provider: NSItemProvider) {
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
    }

    @MainActor
    private static func checkSuccessfulExternalDrop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ShelfPersistenceService(fileURL: root.appendingPathComponent("items.json"))
        let shelf = ShelfStateViewModel(persistence: persistence, selection: ShelfSelectionModel())
        let storage = TemporaryFileStorageService.shared
        let bytes = Data("Drag destination fixture".utf8)
        let original = root.appendingPathComponent("Finder original.txt")
        try bytes.write(to: original)
        guard let copy = await storage.createTempFile(for: .data(bytes, suggestedName: "Shelf copy.txt")) else {
            throw Failure(reason: "could not make a temporary drag fixture")
        }
        defer { storage.removeTemporaryFileIfNeeded(at: copy) }
        let originalItem = ShelfItem(kind: .file(bookmark: try Bookmark(url: original).data))
        let copyItem = ShelfItem(kind: .file(bookmark: try Bookmark(url: copy).data), isTemporary: true)
        await shelf.add([originalItem, copyItem])
        try require(shelf.items.count == 2, "could not put both drag fixtures on Shelf")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let urls = [originalItem, copyItem].compactMap { shelf.fileURLForDrag($0) as NSURL? }
        try require(urls.count == 2 && pasteboard.writeObjects(urls), "could not export both files as native URLs")
        let paths = [original, copy].map { $0.resolvingSymlinksInPath().path }
        let exported = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
        try require(exported?.map { ($0 as URL).resolvingSymlinksInPath().path } == paths, "drag lost native file URLs")
        let filenames = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String]
        try require(filenames?.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == paths,
                    "drag lost the native filename list")
        try require(NSFilePromiseReceiver.readableDraggedTypes.allSatisfy { pasteboard.types?.contains(.init($0)) != true },
                    "drag advertised a promise instead of only native file URLs")

        await shelf.finishExternalDrop([originalItem, copyItem], temporaryURLs: [copyItem.id: copy], removeCards: false)
        try require(shelf.items.count == 2, "accepted drop removed cards with auto-removal off")
        storage.retain([copy])
        storage.removeTemporaryFileIfNeeded(at: copy)
        await shelf.finishExternalDrop([originalItem, copyItem], temporaryURLs: [copyItem.id: copy], removeCards: true)
        await storage.release([copy]).value
        shelf.flushSync()
        try require(shelf.isEmpty && persistence.load().isEmpty, "a successful external drop left its card on Shelf")
        try require((try? Data(contentsOf: original)) == bytes, "auto-removal changed the Finder original")
        try require((try? Data(contentsOf: copy)) == bytes, "URL-only drop lost the file needed by preview")

        let readded = ShelfItem(kind: copyItem.kind, isTemporary: true)
        await shelf.add([readded])
        shelf.removeAll()
        for _ in 0..<200 where FileManager.default.fileExists(atPath: copy.path) { try await Task.sleep(for: .milliseconds(5)) }
        try require(!FileManager.default.fileExists(atPath: copy.path), "Clear All left an owned file on disk")
        print("Shelf exports native file URLs, preserves previews and originals, and clears owned files")
    }

    @MainActor
    private static func checkClearDuringDrop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = ShelfStateViewModel(persistence: ShelfPersistenceService(fileURL: root.appendingPathComponent("items.json")), selection: ShelfSelectionModel())
        let storage = TemporaryFileStorageService.shared
        guard let url = await storage.createTempFile(for: .text("in-flight file")) else {
            throw Failure(reason: "could not create in-flight fixture")
        }
        defer { storage.removeTemporaryFileIfNeeded(at: url) }
        let provider = DropFileProvider()
        registerData(.fileURL, data: Data(url.absoluteString.utf8), on: provider)
        shelf.load([provider])
        guard let deliver = provider.deliver else { throw Failure(reason: "drop read did not start") }
        shelf.removeAll()
        deliver(url as NSURL, nil)
        for _ in 0..<200 where shelf.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        try require(!shelf.isLoading && shelf.isEmpty, "Clear All let an in-flight drop repopulate the Shelf")
        for _ in 0..<200 where FileManager.default.fileExists(atPath: url.path) { try await Task.sleep(for: .milliseconds(5)) }
        try require(!FileManager.default.fileExists(atPath: url.path), "Clear All left an in-flight owned file behind")
        print("Shelf Clear All discarded an in-flight drop and reclaimed its owned file")
    }

    private static func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw Failure(reason: reason) }
    }

    private static func checkStorageOwnership() async throws {
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
        let storage = TemporaryFileStorageService.shared
        try contents.write(to: original)
        storage.removeTemporaryFileIfNeeded(at: original)
        try require((try? Data(contentsOf: original)) == contents, "cleanup deleted an unowned file")

        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: originals)
        storage.removeTemporaryFileIfNeeded(at: link.appendingPathComponent("original.txt"))
        try require((try? Data(contentsOf: original)) == contents, "cleanup followed a directory symlink")

        let unrelatedDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: unrelatedDirectory) }
        let unrelated = unrelatedDirectory.appendingPathComponent("not-ours.txt")
        try contents.write(to: unrelated)
        storage.removeTemporaryFileIfNeeded(at: unrelated)
        try require((try? Data(contentsOf: unrelated)) == contents, "a UUID name was mistaken for ownership")

        let knownBookmark = try Bookmark(url: original)
        let knownItem = await ShelfItem(kind: .file(bookmark: knownBookmark.data))
        let unknownItem = await ShelfItem(kind: .file(bookmark: Data("unresolvable fixture".utf8)))
        try require(ShelfPersistenceService.cleanupReferences(in: [knownItem]) == [original.standardizedFileURL],
                    "cleanup did not preserve a resolved reference")
        try require(ShelfPersistenceService.cleanupReferences(in: [knownItem, unknownItem]) == nil,
                    "an unresolved bookmark was mistaken for proof that old files are unused")

        guard let owned = await storage.createTempFile(
            for: .data(Data("copy".utf8), suggestedName: "../copy.txt")
        ) else { throw Failure(reason: "could not create a Shelf-owned copy") }
        let ownedDirectory = owned.deletingLastPathComponent()
        try require(UUID(uuidString: ownedDirectory.lastPathComponent) != nil, "copy escaped its managed directory")
        defer { storage.removeTemporaryFileIfNeeded(at: owned) }
        storage.removeTemporaryFileIfNeeded(at: owned)
        try require(!FileManager.default.fileExists(atPath: owned.path), "owned copy still exists")
        try require(!FileManager.default.fileExists(atPath: ownedDirectory.path), "empty managed directory still exists")
        let testRoot = originals.appendingPathComponent("OwnedCache")
        let isolated = TemporaryFileStorageService(root: testRoot)
        for size in [1, 1_048_576, 16_777_216] {
            for _ in 0..<3 {
                guard let file = await isolated.createTempFile(for: .data(Data(repeating: 7, count: size), suggestedName: "fixture.bin")) else {
                    throw Failure(reason: "could not create synthetic cache file")
                }
                isolated.retain([file])
                isolated.removeTemporaryFileIfNeeded(at: file)
                try require(FileManager.default.fileExists(atPath: file.path), "deleted an active share/drag file")
                await isolated.release([file]).value
                try require(!FileManager.default.fileExists(atPath: file.path), "released file was not removed")
            }
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: testRoot.path)
        try require(entries.isEmpty, "repeated operations grew the cache")
        guard let stale = await isolated.createTempFile(for: .text("stale fixture")) else { throw Failure(reason: "stale fixture failed") }
        let marker = stale.deletingLastPathComponent().appendingPathComponent(".notchtwo-owner-v1.json")
        var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
        metadata["pid"] = Int32.max
        metadata["created"] = -1_000_000.0
        try JSONSerialization.data(withJSONObject: metadata).write(to: marker)
        try require(isolated.ownsFile(at: stale), "ownership marker unreadable after simulated crash")
        isolated.cleanupStaleFiles(referenced: [stale], olderThan: Date())
        try require(FileManager.default.fileExists(atPath: stale.path), "deleted a persisted Shelf reference")
        isolated.cleanupStaleFiles(referenced: [], olderThan: Date())
        try require(!FileManager.default.fileExists(atPath: stale.path), "did not reclaim an owned stale file")
        let archiveInput = originals.appendingPathComponent("Archive.zip")
        let otherInput = originals.appendingPathComponent("Other.txt")
        try contents.write(to: archiveInput)
        try contents.write(to: otherInput)
        guard let archive = await isolated.createZip(from: [archiveInput, otherInput], suggestedName: "Archive.zip") else {
            throw Failure(reason: "could not create an archive with a colliding input name")
        }
        defer { isolated.removeTemporaryFileIfNeeded(at: archive) }
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extract.arguments = ["-p", archive.path, "Archive.zip"]
        let output = Pipe()
        extract.standardOutput = output
        try extract.run()
        let extracted = output.fileHandleForReading.readDataToEndOfFile()
        extract.waitUntilExit()
        try require(extract.terminationStatus == 0 && extracted == contents, "archive overwrote an input named Archive.zip")
        print("Shelf cache: nine 1 B / 1 MiB / 16 MiB cycles returned to 0 payload bytes; leases and restart references preserved")
        print("Shelf cleanup preserved originals and removed its owned copy")
    }

    @MainActor
    private static func checkUnresolvedRemainingBookmark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ShelfPersistenceService(fileURL: root.appendingPathComponent("items.json"))
        let storage = TemporaryFileStorageService.shared
        guard let url = await storage.createTempFile(for: .text("bookmark fixture")) else {
            throw Failure(reason: "could not create bookmark fixture")
        }
        defer { storage.removeTemporaryFileIfNeeded(at: url) }
        let owned = ShelfItem(kind: .file(bookmark: try Bookmark(url: url).data), isTemporary: true)
        let unresolved = ShelfItem(kind: .file(bookmark: Data([1, 2, 3])))
        persistence.save([owned, unresolved])
        let reopened = ShelfStateViewModel(persistence: persistence, selection: ShelfSelectionModel())
        reopened.remove(owned)
        try await Task.sleep(for: .milliseconds(25))
        await Bookmark.onWorker {}
        try require(reopened.items == [unresolved], "unresolved card was removed")
        try require(FileManager.default.fileExists(atPath: url.path),
                    "deletion treated an unresolved remaining bookmark as proof that a file was unused")
        print("Shelf preserves owned files while a remaining bookmark cannot be resolved")
    }

    @MainActor
    private static func checkReaddition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = ShelfStateViewModel(persistence: ShelfPersistenceService(fileURL: root.appendingPathComponent("items.json")), selection: ShelfSelectionModel())
        let storage = TemporaryFileStorageService.shared
        for _ in 0..<50 {
            guard let url = await storage.createTempFile(for: .text("re-add fixture")) else {
                throw Failure(reason: "could not create re-add fixture")
            }
            let data = try Bookmark(url: url).data
            let first = ShelfItem(kind: .file(bookmark: data), isTemporary: true)
            await shelf.add([first])
            storage.retain([url]) // An in-flight drag keeps the source available during re-add.
            shelf.removeAll()
            await shelf.add([ShelfItem(kind: .file(bookmark: data), isTemporary: true)])
            try require(shelf.items.count == 1, "re-add did not commit its still-available file")
            await storage.release([url]).value
            // Drain deferred cleanup before inspecting the committed card.
            try await Task.sleep(for: .milliseconds(5))
            await Bookmark.onWorker {}
            try require(FileManager.default.fileExists(atPath: url.path), "cleanup deleted a re-added Shelf file")
            shelf.removeAll()
            try await Task.sleep(for: .milliseconds(5))
            await Bookmark.onWorker {}
            try require(!FileManager.default.fileExists(atPath: url.path), "final Clear All left its unleased file")
            await shelf.add([ShelfItem(kind: .file(bookmark: data), isTemporary: true)])
            try require(shelf.isEmpty, "a missing file was committed after cleanup won")
        }
        print("Shelf remove/re-add preserved every committed file across 50 races and final Clear All")
    }

    @MainActor
    private static func checkBatchOperations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ShelfPersistenceService(fileURL: root.appendingPathComponent("items.json"))
        let selection = ShelfSelectionModel()
        let shelf = ShelfStateViewModel(persistence: persistence, selection: selection)
        let contents = Data("fixture contents".utf8)
        let originals = try (0..<100).map { index in
            let url = root.appendingPathComponent("original-\(index).txt")
            try contents.write(to: url)
            return url
        }
        let items = try originals.map { ShelfItem(kind: .file(bookmark: try Bookmark(url: $0).data)) }

        for count in [10, 50, 100] {
            let started = ContinuousClock.now
            let batch = Array(items.prefix(count))
            await shelf.add(batch)
            let files = await shelf.resolveFiles(for: batch)
            try require(files.count == count, "resolved \(files.count) of \(count) files")
            selection.selectAll(in: shelf.items)
            try require(selection.selectedIDs == Set(batch.map(\.id)), "Select All missed items")
            var updates = 0
            let observation = shelf.$items.dropFirst().sink { _ in updates += 1 }
            shelf.removeSelected()
            observation.cancel()
            try require(updates == 1, "batch removal published \(updates) times")
            try require(shelf.isEmpty && !selection.hasSelection, "batch removal left items or stale selection")
            shelf.flushSync()
            try require(persistence.load().isEmpty, "removed items remained in persisted Shelf")
            print("Shelf add, resolve, select, remove and persist \(count) files: \(ContinuousClock.now - started)")
        }
        for original in originals {
            try require((try? Data(contentsOf: original)) == contents, "Shelf removed or modified a Finder file")
        }

        await shelf.add(Array(items.prefix(3)))
        selection.toggle(items[0])
        selection.shiftSelect(to: items[1], in: shelf.items)
        try require(selection.selectedIDs == Set([items[0].id, items[1].id]), "Cmd and Shift selection range changed")
        shelf.removeAll()
        shelf.flushSync()
        try require(shelf.isEmpty && !selection.hasSelection && persistence.load().isEmpty, "Clear All left items")
    }

    @MainActor
    private static func checkPaste() async throws {
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.clearContents()
        try require(clipboard.setString("Shelf paste fixture", forType: .string), "could not write test clipboard")
        let pasted = await ShelfDropService.startLoading(ShelfDropService.clipboardProviders(from: clipboard)).value
        try require(pasted.map(\.kind) == [.text(string: "Shelf paste fixture")], "clipboard text did not reach Shelf")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try (0..<10).map { index in
            let url = root.appendingPathComponent("pasted-\(index).txt")
            try Data("fixture".utf8).write(to: url)
            return url
        }
        clipboard.clearContents()
        try require(clipboard.writeObjects(files.map { $0 as NSURL }), "could not write test clipboard file URLs")
        let fileItems = await ShelfDropService.startLoading(ShelfDropService.clipboardProviders(from: clipboard)).value
        let fileNames = fileItems.compactMap { $0.fileURL?.lastPathComponent }
        try require(fileNames == files.map(\.lastPathComponent), "paste lost files or reordered the selection")
        try require(fileItems.allSatisfy { !$0.isTemporary }, "pasted Finder files were marked as disposable")
        print("Shelf private pasteboard round trip passed for text and 10 files")
    }
}
