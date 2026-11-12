//
//  Bookmark.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-08.
//

import Foundation
import AppKit

struct Bookmark: Sendable, Equatable, Codable {
    let data: Data

    private static let worker = DispatchQueue(label: "notch.shelf.files", qos: .userInitiated)

    static func onWorker<Result: Sendable>(_ operation: @escaping @Sendable () -> Result) async -> Result {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume(returning: operation()) }
        }
    }

    init(data: Data) {
        self.data = data
    }

    init(url: URL) throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "Bookmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a valid file URL or file does not exist at \(url.path)"])
        }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            self.data = bookmark
        } catch {
            Log.shelf.debug("Could not create Shelf bookmark: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    func resolve() -> (url: URL?, refreshedData: Data?) {
        guard !data.isEmpty else { return (nil, nil) }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale, let newData = try? url.bookmarkData(options: [.withSecurityScope]) {
                return (url, newData)
            }
            return (url, nil)
        } catch {
            Log.shelf.debug("Could not resolve Shelf bookmark: \(error.localizedDescription, privacy: .private)")
            return (nil, nil)
        }
    }

    /// Simple URL resolution without refresh tracking. Use for read-only access.
    var resolvedURL: URL? {
        resolve().url
    }

    func validate() async -> Bool {
        let (url, _) = resolve()
        guard let url = url else { return false }
        return url.accessSecurityScopedResource { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    func withAccess<T: Sendable>(_ block: @Sendable (URL) async throws -> T) async rethrows -> T? {
        guard let url = resolvedURL else { return nil }
        return try await url.accessSecurityScopedResource { url in
            try await block(url)
        }
    }

    func withAccess<T>(_ block: (URL) throws -> T) rethrows -> T? {
        guard let url = resolvedURL else { return nil }
        return try url.accessSecurityScopedResource { url in
            try block(url)
        }
    }
}
