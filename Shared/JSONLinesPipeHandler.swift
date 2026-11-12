//
//  JSONLinesPipeHandler.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Shared source compiled into BOTH targets (via the Shared synchronized
//  group). There is intentionally one copy — edit once, both sides build it.
//

import Foundation
import os

/// Streams newline-delimited JSON from a pipe, decoding each line.
/// Used by the app (mediaremote-adapter now-playing stream) and the XPC
/// helper (Lunar daemon event stream).
actor JSONLinesPipeHandler {
    nonisolated let outputPipe: Pipe
    private nonisolated let fileHandle: FileHandle
    private let chunks: AsyncStream<Data>
    private nonisolated let continuation: AsyncStream<Data>.Continuation
    private nonisolated let chunkConsumed = DispatchSemaphore(value: 0)
    private nonisolated let isClosed = OSAllocatedUnfairLock(initialState: false)
    private var hasReader = false

    private static let maximumLineBytes = 8 * 1024 * 1024

    init(pipe: Pipe = Pipe()) {
        outputPipe = pipe
        fileHandle = pipe.fileHandleForReading
        (chunks, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
        let flags = fcntl(fileHandle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(fileHandle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            continuation.finish()
            return
        }
        let continuation = self.continuation
        let chunkConsumed = self.chunkConsumed
        let isClosed = self.isClosed
        fileHandle.readabilityHandler = { handle in
            let chunk = isClosed.withLock { closed -> Data? in
                guard !closed else { return nil }
                var chunk = Data(count: 16 * 1024)
                // A single read returns available bytes. FileHandle's
                // read(upToCount:) waits to fill the buffer or reach EOF.
                let count = chunk.withUnsafeMutableBytes { bytes in
                    var result: Int
                    repeat {
                        result = Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
                    } while result == -1 && errno == EINTR
                    return result
                }
                if count == -1 && errno == EAGAIN { return Data() }
                guard count > 0 else { return nil }
                chunk.count = count
                return chunk
            }
            guard let chunk else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            // Dispatch may deliver a coalesced readiness event after draining.
            guard !chunk.isEmpty else { return }
            // Keep the pipe's backpressure while decoding or delivering
            // a record. Never drop part of a JSON update.
            switch continuation.yield(chunk) {
            case .enqueued:
                chunkConsumed.wait()
            case .dropped:
                handle.readabilityHandler = nil
                continuation.finish()
            case .terminated:
                break
            @unknown default:
                continuation.finish()
            }
        }
    }

    func readJSONLines<Value: Decodable & Sendable>(
        as type: Value.Type,
        onValue: @escaping @Sendable (Value) async -> Void
    ) async {
        guard !hasReader else { return }
        hasReader = true
        defer { close() }

        let decoder = JSONDecoder()
        var line = Data()
        var discardingOversizedLine = false
        var consecutiveMalformedLines = 0

        for await chunk in chunks {
            defer { chunkConsumed.signal() }
            var remaining = chunk[...]
            while !remaining.isEmpty, !Task.isCancelled, !isClosed.withLock({ $0 }) {
                let newline = remaining.firstIndex(of: UInt8(ascii: "\n"))
                let fragment = remaining[..<(newline ?? remaining.endIndex)]
                if !discardingOversizedLine {
                    if line.count + fragment.count <= Self.maximumLineBytes {
                        line.append(fragment)
                    } else {
                        discardingOversizedLine = true
                        line.removeAll(keepingCapacity: false)
                    }
                }
                guard let newline else { break }
                remaining = remaining[remaining.index(after: newline)...]
                if line.last == UInt8(ascii: "\r") { line.removeLast() }

                if !discardingOversizedLine,
                   let decoded = try? decoder.decode(Value.self, from: line) {
                    consecutiveMalformedLines = 0
                    await onValue(decoded)
                } else {
                    consecutiveMalformedLines += 1
                    if consecutiveMalformedLines >= 3 { return }
                }
                discardingOversizedLine = false
                line.removeAll(keepingCapacity: true)
            }
        }
    }

    nonisolated func close() {
        let shouldClose = isClosed.withLock { closed in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        continuation.finish()
        chunkConsumed.signal()
        fileHandle.readabilityHandler = nil
        try? fileHandle.close()
        try? outputPipe.fileHandleForWriting.close()
    }

    deinit {
        close()
    }
}
