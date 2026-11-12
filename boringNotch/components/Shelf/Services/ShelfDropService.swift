//
//  ShelfDropService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-26.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfDropService {
    static let contentTypes: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText, .data, .item]

    @MainActor
    static func providersForDrop(
        _ providers: [NSItemProvider], pasteboard: NSPasteboard = .init(name: .drag)
    ) -> [NSItemProvider] {
        // SwiftUI can expose file contents while omitting Finder's original URLs.
        guard !providers.isEmpty, let items = pasteboard.pasteboardItems, !items.isEmpty,
              items.allSatisfy({ $0.types.contains(.fileURL) }),
              let files = pasteboard.readObjects(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
              ) as? [NSURL], files.count == items.count else { return providers }
        return files.map { NSItemProvider(object: $0) }
    }

    @MainActor
    static func clipboardProviders(from pasteboard: NSPasteboard = .general) -> [NSItemProvider] {
        if let files = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL], !files.isEmpty {
            return files.map { NSItemProvider(object: $0) }
        }

        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            if let string = item.string(forType: .URL), let url = URL(string: string), url.scheme != nil {
                return NSItemProvider(object: url as NSURL)
            }
            if let type = item.availableType(from: [.png, .tiff]),
               let data = item.data(forType: type) {
                let provider = NSItemProvider()
                provider.suggestedName = type == .png ? "Pasted Image.png" : "Pasted Image.tiff"
                provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
                return provider
            }
            return item.string(forType: .string).map { NSItemProvider(object: $0 as NSString) }
        }
    }

    // Begin reading while SwiftUI still grants access to the dropped pasteboard.
    static func startLoading(_ providers: [NSItemProvider]) -> Task<[ShelfItem], Never> {
        let reads = providers.map { StartedRead(provider: $0, payload: startRead($0)) }
        return Task { await finishLoading(reads) }
    }

    // A fallback reads the same immutable provider only after the first request completes.
    private struct StartedRead: @unchecked Sendable {
        let provider: NSItemProvider
        let payload: AsyncStream<DropPayload>
    }

    private enum DropPayload: Sendable {
        case item(ShelfItemKind, temporary: Bool)
        case data(Data, filename: String)
        case unavailable
    }

    private static func startRead(_ provider: NSItemProvider) -> AsyncStream<DropPayload> {
        let types = dataTypes(for: provider)
        let name = suggestedName(for: provider)
        let hasType: (UTType) -> Bool = { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        let type: UTType
        if hasType(.fileURL) {
            type = .fileURL
        } else if hasType(.url) {
            type = .url
        } else if name == nil, !types.contains(where: { !$0.conforms(to: .text) && $0.preferredFilenameExtension != nil }),
                  let text = [UTType.utf8PlainText, .plainText].first(where: hasType) {
            type = text
        } else {
            type = types.first(where: { filename(for: $0, suggested: name) != nil }) ?? .item
        }

        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { object, error in
                defer { continuation.finish() }
                guard error == nil else {
                    continuation.yield(.unavailable)
                    return
                }
                if type == .fileURL || type == .url {
                    if let url = NSItemProvider.fileURL(from: object),
                       let bookmark = createBookmark(for: url) {
                        continuation.yield(.item(.file(bookmark: bookmark),
                                                 temporary: TemporaryFileStorageService.shared.ownsFile(at: url)))
                    } else if type == .url,
                              let url = (object as? URL) ?? textValue(object).flatMap(URL.init(string:)),
                              url.scheme != nil, !url.isFileURL {
                        continuation.yield(.item(.link(url: url), temporary: false))
                    } else {
                        continuation.yield(.unavailable)
                    }
                } else if let file = object as? URL, file.isFileURL,
                          let payload = retainPromisedFile(file, suggestedName: name) {
                    continuation.yield(payload)
                } else if type.conforms(to: .text), name == nil, let text = textValue(object) {
                    continuation.yield(.item(.text(string: text), temporary: false))
                } else if let filename = filename(for: type, suggested: name),
                          let data = (object as? Data) ?? (type.conforms(to: .text) ? textValue(object).map { Data($0.utf8) } : nil) {
                    continuation.yield(.data(data, filename: filename))
                } else {
                    continuation.yield(.unavailable)
                }
            }
        }
    }

    private static func textValue(_ object: NSSecureCoding?) -> String? {
        (object as? String) ?? (object as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func finishLoading(_ reads: [StartedRead]) async -> [ShelfItem] {
        await withTaskGroup(of: (Int, ShelfItem?).self) { group in
            var next = 0
            var results = [ShelfItem?](repeating: nil, count: reads.count)
            func enqueue() {
                let index = next
                next += 1
                let started = reads[index]
                group.addTask {
                    var read = started.payload.makeAsyncIterator()
                    let item: ShelfItem?
                    switch await read.next() {
                    case .item(let kind, let temporary):
                        item = await ShelfItem(kind: kind, isTemporary: temporary)
                    case .data(let data, let filename):
                        item = await storeData(data, filename: filename)
                    case .unavailable:
                        item = await processProvider(started.provider)
                    case nil:
                        item = nil
                    }
                    return (index, item)
                }
            }
            for _ in 0..<min(reads.count, 8) { enqueue() }
            for await (index, item) in group {
                results[index] = item
                if next < reads.count { enqueue() }
            }
            return results.compactMap { $0 }
        }
    }

    private static func processProvider(_ provider: NSItemProvider) async -> ShelfItem? {
        if let file = await provider.extractFileURL(),
           let item = await originalFile(at: file) {
            return item
        }

        if let url = await provider.extractURL() {
            if url.isFileURL {
                if let item = await originalFile(at: url) { return item }
            } else {
                return await ShelfItem(kind: .link(url: url), isTemporary: false)
            }
        }

        if case .item(let kind, let temporary)? = await promisedFile(from: provider) {
            return await ShelfItem(kind: kind, isTemporary: temporary)
        }

        // A failed file-URL load may leave serialized URL or promise metadata behind.
        guard !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        let hasFilename = provider.suggestedName.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let hasFileContent = provider.registeredTypeIdentifiers.contains { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .text) && type.preferredFilenameExtension != nil
        }
        if !hasFilename, !hasFileContent, let text = await provider.extractText() {
            return await ShelfItem(kind: .text(string: text), isTemporary: false)
        }

        guard let payload = await loadNamedData(from: provider) else { return nil }
        return await storeData(payload.data, filename: payload.name)
    }

    private static func storeData(_ data: Data, filename: String) async -> ShelfItem? {
        guard let temp = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(data, suggestedName: filename)
        ) else { return nil }
        guard let bookmark = createBookmark(for: temp) else {
            TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: temp)
            return nil
        }
        return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
    }

    private static func promisedFile(from provider: NSItemProvider) async -> DropPayload? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) else { return nil }
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { item, error in
                guard error == nil, let file = item as? URL, file.isFileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: retainPromisedFile(file, suggestedName: suggestedName))
            }
        }
    }

    private static func retainPromisedFile(_ file: URL, suggestedName: String?) -> DropPayload? {
        if file.accessSecurityScopedResource(accessor: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }) {
            return createBookmark(for: file).map { .item(.file(bookmark: $0), temporary: false) }
        }
        // A provider may remove its file as soon as this callback returns.
        guard let owned = TemporaryFileStorageService.shared.copyProviderFile(
            at: file, suggestedName: suggestedName
        ) else { return nil }
        guard let bookmark = createBookmark(for: owned) else {
            TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: owned)
            return nil
        }
        return .item(.file(bookmark: bookmark), temporary: true)
    }

    private static func originalFile(at url: URL) async -> ShelfItem? {
        guard url.isFileURL, let bookmark = createBookmark(for: url) else { return nil }
        return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: TemporaryFileStorageService.shared.ownsFile(at: url))
    }

    private static func createBookmark(for url: URL) -> Data? {
        url.accessSecurityScopedResource { (try? Bookmark(url: $0))?.data }
    }

    private static func suggestedName(for provider: NSItemProvider) -> String? {
        provider.suggestedName
            .map { ($0 as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { ["", ".", "..", "/"].contains($0) ? nil : $0 }
    }

    private static func dataTypes(for provider: NSItemProvider) -> [UTType] {
        let dataTypes = provider.registeredTypeIdentifiers.compactMap { UTType($0) }.filter {
            $0.conforms(to: .data) && !$0.conforms(to: .url)
        }
        let concrete = dataTypes.filter { $0.preferredFilenameExtension != nil }
        let generic = dataTypes.filter { $0.preferredFilenameExtension == nil }
        let files = concrete.filter { !$0.conforms(to: .text) }
        let text = concrete.filter { $0.conforms(to: .text) }
        return files + text + generic
    }

    private static func filename(for type: UTType, suggested: String?) -> String? {
        guard let name = suggested ?? type.preferredFilenameExtension.map({ "Dropped File.\($0)" }) else { return nil }
        let suppliedExtension = (name as NSString).pathExtension.lowercased()
        guard let ext = type.preferredFilenameExtension, suppliedExtension != ext else { return name }
        if ["", "dat", "bin"].contains(suppliedExtension) {
            return "\((name as NSString).deletingPathExtension).\(ext)"
        }
        return name
    }

    private static func loadNamedData(from provider: NSItemProvider) async -> (data: Data, name: String)? {
        let name = suggestedName(for: provider)
        for type in dataTypes(for: provider) {
            guard let filename = filename(for: type, suggested: name) else { continue }
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data { return (data, filename) }
        }
        return nil
    }
}
