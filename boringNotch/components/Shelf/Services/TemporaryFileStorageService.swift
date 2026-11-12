//
//  TemporaryFileStorageService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import Darwin
import Foundation

enum TempFileType: Sendable {
    case data(Data, suggestedName: String?)
    case text(String)
    case url(URL)
}

final class TemporaryFileStorageService: @unchecked Sendable {
    static let shared = TemporaryFileStorageService()
    private let root: URL
    private let lock = NSLock()
    private var leases: [String: Int] = [:]
    private var pendingRemoval: Set<URL> = []
    private let markerName = ".notchtwo-owner-v1.json"

    private struct Ownership: Codable {
        let filename: String
        let pid: Int32
        let created: Date
    }

    init(root: URL? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.root = (root ?? caches.resolvingSymlinksInPath().appendingPathComponent("NotchTwoShelf-v1", isDirectory: true)).standardizedFileURL
    }

    func createTempFile(for type: TempFileType) async -> URL? {
        await Bookmark.onWorker { self.writeTempFile(for: type) }
    }

    func copyProviderFile(at source: URL, suggestedName: String?) -> URL? {
        guard source.isFileURL,
              (try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({
                  $0.isRegularFile == true && $0.isSymbolicLink != true
              }) == true,
              let directory = createDirectory() else { return nil }
        let destination = directory.appendingPathComponent(safeFilename(suggestedName, fallback: source.lastPathComponent))
        do {
            try source.accessSecurityScopedResource { try FileManager.default.copyItem(at: $0, to: destination) }
            try mark(destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            Log.shelf.error("Could not retain a dropped file: \(error.localizedDescription)")
            return nil
        }
    }

    func retain(_ urls: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        for url in urls { leases[url.standardizedFileURL.path, default: 0] += 1 }
    }

    func retainExistingFile(at url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard url.accessSecurityScopedResource(accessor: { FileManager.default.fileExists(atPath: $0.path) }) else { return false }
        leases[url.standardizedFileURL.path, default: 0] += 1
        return true
    }

    @discardableResult
    func release(_ urls: [URL]) -> Task<Void, Never> {
        lock.lock()
        for url in urls {
            let path = url.standardizedFileURL.path
            if let count = leases[path], count > 1 { leases[path] = count - 1 } else { leases[path] = nil }
        }
        let retry = pendingRemoval.filter { leases[$0.standardizedFileURL.path] == nil }
        lock.unlock()
        return Task { await Bookmark.onWorker { retry.forEach(self.removePendingTemporaryFileIfNeeded) } }
    }

    func ownsFile(at url: URL) -> Bool {
        guard let (rootFD, directoryFD) = descriptors(for: url) else { return false }
        defer { close(rootFD); close(directoryFD) }
        return ownership(in: directoryFD)?.filename == url.lastPathComponent
    }

    func renewOwnership(at url: URL) -> Bool {
        guard let (rootFD, directoryFD) = descriptors(for: url) else { return false }
        defer { close(rootFD); close(directoryFD) }
        guard ownership(in: directoryFD)?.filename == url.lastPathComponent,
              let data = try? JSONEncoder().encode(Ownership(filename: url.lastPathComponent, pid: getpid(), created: Date())) else { return false }
        let temporaryMarker = ".\(UUID().uuidString).owner"
        let marker = openat(directoryFD, temporaryMarker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard marker >= 0 else { return false }
        defer { close(marker); _ = unlinkat(directoryFD, temporaryMarker, 0) }
        let written = data.withUnsafeBytes { bytes in write(marker, bytes.baseAddress, bytes.count) }
        guard written == data.count, fsync(marker) == 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard ownership(in: directoryFD)?.filename == url.lastPathComponent,
              renameat(directoryFD, temporaryMarker, directoryFD, markerName) == 0 else { return false }
        pendingRemoval.remove(url.standardizedFileURL)
        return true
    }

    func removeTemporaryFileIfNeeded(at url: URL) {
        guard let (rootFD, directoryFD) = descriptors(for: url) else { return }
        defer { close(rootFD); close(directoryFD) }
        guard ownership(in: directoryFD)?.filename == url.lastPathComponent else { return }
        lock.lock()
        defer { lock.unlock() }
        if leases[url.standardizedFileURL.path] != nil { pendingRemoval.insert(url.standardizedFileURL); return }
        unlinkOwnedFile(at: url, rootFD: rootFD, directoryFD: directoryFD)
    }

    private func removePendingTemporaryFileIfNeeded(at url: URL) {
        guard let (rootFD, directoryFD) = descriptors(for: url) else { return }
        defer { close(rootFD); close(directoryFD) }
        guard ownership(in: directoryFD)?.filename == url.lastPathComponent else { return }
        lock.lock()
        defer { lock.unlock() }
        guard pendingRemoval.contains(url.standardizedFileURL), leases[url.standardizedFileURL.path] == nil else { return }
        unlinkOwnedFile(at: url, rootFD: rootFD, directoryFD: directoryFD)
    }

    private func unlinkOwnedFile(at url: URL, rootFD: Int32, directoryFD: Int32) {
        var info = stat()
        let status = fstatat(directoryFD, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW)
        if status == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                  unlinkat(directoryFD, url.lastPathComponent, 0) == 0 else { return }
        } else if errno != ENOENT { return }
        pendingRemoval.remove(url.standardizedFileURL)
        _ = unlinkat(directoryFD, markerName, 0)
        _ = unlinkat(rootFD, url.deletingLastPathComponent().lastPathComponent, AT_REMOVEDIR)
    }

    // Only marked, old operations from a dead process are candidates. Legacy UUIDs are not proof of ownership.
    func cleanupStaleFiles(referenced: Set<URL>, olderThan cutoff: Date) {
        let rootFD = openRoot(create: false)
        guard rootFD >= 0 else { return }
        defer { close(rootFD) }
        let referenced = Set(referenced.map { $0.standardizedFileURL.path })
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in entries where UUID(uuidString: directory.lastPathComponent) != nil {
            let fd = openat(rootFD, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let owner = ownership(in: fd)
            close(fd)
            guard let owner, owner.created < cutoff, owner.pid != getpid(),
                  kill(owner.pid, 0) == -1, errno == ESRCH else { continue }
            let file = directory.appendingPathComponent(owner.filename)
            guard !referenced.contains(file.standardizedFileURL.path) else { continue }
            removeTemporaryFileIfNeeded(at: file)
        }
    }

    private func openRoot(create: Bool) -> Int32 {
        if create { _ = mkdir(root.path, S_IRWXU) }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { close(fd); return -1 }
        return fd
    }

    private func createDirectory() -> URL? {
        let fd = openRoot(create: true)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let name = UUID().uuidString
        guard mkdirat(fd, name, S_IRWXU) == 0 else { return nil }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    private func descriptors(for url: URL) -> (Int32, Int32)? {
        guard url.isFileURL, !url.pathComponents.contains(".."),
              url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == root.path,
              UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil else { return nil }
        let fd = openRoot(create: false)
        guard fd >= 0 else { return nil }
        let child = openat(fd, url.deletingLastPathComponent().lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { close(fd); return nil }
        return (fd, child)
    }

    private func ownership(in fd: Int32) -> Ownership? {
        let marker = openat(fd, markerName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard marker >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: marker, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(marker, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size <= 4096,
              let data = try? handle.readToEnd(),
              let owner = try? JSONDecoder().decode(Ownership.self, from: data),
              owner.pid > 1, owner.filename != markerName,
              owner.filename == (owner.filename as NSString).lastPathComponent,
              !["", ".", ".."].contains(owner.filename) else { return nil }
        return owner
    }

    private func mark(_ file: URL) throws {
        let owner = Ownership(filename: file.lastPathComponent, pid: getpid(), created: Date())
        try JSONEncoder().encode(owner).write(to: file.deletingLastPathComponent().appendingPathComponent(markerName), options: .withoutOverwriting)
    }

    private func writeTempFile(for type: TempFileType) -> URL? {
        guard let directory = createDirectory() else { return nil }
        let data: Data
        let name: String
        switch type {
        case .data(let contents, let suggestedName):
            data = contents
            name = safeFilename(suggestedName, fallback: "Untitled.dat")
        case .text(let string):
            data = Data(string.utf8)
            name = "Text.txt"
        case .url(let url):
            guard let contents = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0) else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            data = contents
            name = safeFilename(url.host.map { "\($0).webloc" }, fallback: "Link.webloc")
        }
        let file = directory.appendingPathComponent(name)
        do {
            try data.write(to: file, options: .withoutOverwriting)
            try mark(file)
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            Log.shelf.error("Could not write Shelf temporary file: \(error.localizedDescription)")
            return nil
        }
    }

    private func safeFilename(_ suggestedName: String?, fallback: String) -> String {
        guard let suggestedName else { return fallback }
        let name = (suggestedName as NSString).lastPathComponent
        return ["", ".", "..", "/", markerName].contains(name) ? fallback : name
    }

    func createZip(from urls: [URL], suggestedName: String? = nil) async -> URL? {
        retain(urls)
        defer { release(urls) }
        return await Bookmark.onWorker { self.zipFiles(urls, suggestedName: suggestedName) }
    }

    private func zipFiles(_ urls: [URL], suggestedName: String?) -> URL? {
        guard !urls.isEmpty, let workingDir = createDirectory() else { return nil }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: workingDir) } }

        // Helper to run zip process
        func runZip(arguments: [String], currentDirectory: URL) -> Bool {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            proc.arguments = arguments
            proc.currentDirectoryURL = currentDirectory
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                Log.shelf.error("❌ Failed to run zip: \(error)")
                return false
            }
        }

        // Single-item optimization: do not copy contents into the working dir.
        if urls.count == 1, let src = urls.first {
            let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let baseName = src.lastPathComponent
            let archiveName: String
            if isDir {
                // Folder: name as FolderName.zip and include the folder itself in the archive
                archiveName = "\(baseName).zip"
                let archiveURL = workingDir.appendingPathComponent(archiveName)
                // Run zip from the parent directory so the folder is stored as top-level entry
                let parent = src.deletingLastPathComponent()
                let args = ["-r", "-q", archiveURL.path, "--", baseName]
                let ok = runZip(arguments: args, currentDirectory: parent)
                if ok {
                    do { try mark(archiveURL); completed = true; return archiveURL } catch { return nil }
                } else {
                    return nil
                }
            } else {
                // File: include the file only (no parent folders). Name should include original extension.
                archiveName = "\(baseName).zip"
                let archiveURL = workingDir.appendingPathComponent(archiveName)
                let parent = src.deletingLastPathComponent()
                // -j to junk paths and store only the file
                let args = ["-j", "-q", archiveURL.path, "--", baseName]
                let ok = runZip(arguments: args, currentDirectory: parent)
                if ok {
                    do { try mark(archiveURL); completed = true; return archiveURL } catch { return nil }
                } else {
                    return nil
                }
            }
        }

        // Keep input copies separate so an input named Archive.zip cannot become the output.
        let inputDirectory = workingDir.appendingPathComponent("input", isDirectory: true)
        do { try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: false) }
        catch { return nil }
        for src in urls {
            let dest = inputDirectory.appendingPathComponent(src.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    // Avoid collision by appending a suffix
                    let unique = "\(UUID().uuidString)_\(src.lastPathComponent)"
                    try FileManager.default.copyItem(at: src, to: inputDirectory.appendingPathComponent(unique))
                } else {
                    try FileManager.default.copyItem(at: src, to: dest)
                }
            } catch {
                Log.shelf.error("Could not prepare complete Shelf archive: \(error.localizedDescription)")
                return nil
            }
        }

        let archiveName = safeFilename(suggestedName, fallback: "Archive.zip")
        let archiveURL = workingDir.appendingPathComponent(archiveName)
        let args = ["-r", "-q", archiveURL.path, "."]
        let ok = runZip(arguments: args, currentDirectory: inputDirectory)
        if ok {
            // Remove the copied (uncompressed) items so the temp folder contains only the archive
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: workingDir, includingPropertiesForKeys: nil)
                for file in contents {
                    if file.standardizedFileURL != archiveURL.standardizedFileURL {
                        try FileManager.default.removeItem(at: file)
                    }
                }
            } catch {
                Log.shelf.error("⚠️ Failed to cleanup working directory after zip: \(error)")
            }
            do { try mark(archiveURL); completed = true; return archiveURL } catch { return nil }
        } else {
            return nil
        }
    }
}
