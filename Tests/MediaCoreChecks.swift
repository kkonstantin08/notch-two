import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct MediaCoreChecks {
    private struct Message: Codable, Sendable, Equatable {
        let id: Int
        var artwork: String? = nil
    }

    private actor Received {
        var messages: [Message] = []

        func append(_ message: Message) {
            messages.append(message)
        }
    }

    private static func read(_ data: Data) async -> [Message] {
        let reader = JSONLinesPipeHandler()
        defer { reader.close() }
        let writer = reader.outputPipe.fileHandleForWriting
        let writing = Task.detached {
            defer { try? writer.close() }
            try? writer.write(contentsOf: data)
        }
        let received = Received()
        await reader.readJSONLines(as: Message.self) { await received.append($0) }
        await writing.value
        return await received.messages
    }

    private static func require(_ condition: Bool, _ failure: String) {
        guard condition else {
            print("FAIL: \(failure)")
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--lifetime-parent") {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            child.arguments = NowPlayingStreamSession.parentBoundArguments(script: URL(fileURLWithPath: CommandLine.arguments.last!), arguments: [])
            child.standardInput = Pipe()
            child.standardOutput = FileHandle.nullDevice
            try child.run()
            print(child.processIdentifier)
            fflush(stdout)
            try await Task.sleep(for: .seconds(60))
            return
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("adapter-\(UUID()).pl")
        try Data("sleep 60;".utf8).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for signal in [SIGTERM, SIGKILL, SIGABRT] {
            let parent = Process()
            parent.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            parent.arguments = ["--lifetime-parent", fixture.path]
            let output = Pipe()
            parent.standardOutput = output
            try parent.run()
            let bytes = output.fileHandleForReading.availableData
            let pid = Int32(String(data: bytes, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))!
            require(kill(pid, 0) == 0, "adapter did not start")
            kill(parent.processIdentifier, signal)
            var exited = false
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(10))
                if kill(pid, 0) == -1 && errno == ESRCH { exited = true; break }
            }
            require(exited, "adapter survived parent signal \(signal)")
        }
        print("PASS: adapter exits on parent TERM, KILL and ABRT without a watchdog process")
        let artwork = String(repeating: "a", count: 400_000)
        if CommandLine.arguments.contains("--benchmark") {
            let started = ContinuousClock.now
            let input = Data((0..<30).map { "{\"id\":\($0),\"artwork\":\"\(artwork)\"}\n" }.joined().utf8)
            let ids = await read(input).map(\.id)
            require(ids == Array(0..<30), "benchmark lost or reordered updates")
            print("30 × 400 KB JSON lines: \(started.duration(to: .now))")
            return
        }

        let fragmented = Data(("{\"id\":1,\"artwork\":\"\(artwork)\"}\r\n{\"id\":2}\n{\"id\":3}").utf8)
        let values = await read(fragmented)
        require(values == [Message(id: 1, artwork: artwork), Message(id: 2)], "fragmented line, CRLF or EOF framing failed")

        let oversized = String(repeating: "a", count: 8 * 1024 * 1024)
        let remaining = await read(Data(("{\"id\":1,\"artwork\":\"\(oversized)\"}\n{\"id\":2}\n").utf8))
        require(remaining == [Message(id: 2)], "oversized line must be skipped without losing the next update")

        let malformed = await read(Data("bad\nbad\n{\"id\":1}\nbad\nbad\nbad\n{\"id\":2}\n".utf8))
        require(malformed == [Message(id: 1)], "valid updates should reset malformed count and the third failure should stop reading")

        for _ in 0..<20 {
            let reader = JSONLinesPipeHandler()
            let received = DispatchSemaphore(value: 0)
            let reading = Task {
                await reader.readJSONLines(as: Message.self) { message in
                    if message == Message(id: 1) { received.signal() }
                }
            }
            try reader.outputPipe.fileHandleForWriting.write(contentsOf: Data("{\"id\":1}\n".utf8))
            let delivered = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: received.wait(timeout: .now() + 1) == .success)
                }
            }
            reader.close()
            await reading.value
            require(delivered, "small line was delayed until the writer closed")
        }

        var recovery = NowPlayingRetrySchedule()
        let delays: [Duration?] = (0..<7).map { _ in recovery.nextDelay(streamUptime: .seconds(1)) }
        require(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), nil],
                "stream crashes must eventually stop triggering subprocesses")
        require(recovery.nextDelay(streamUptime: .seconds(45)) == .seconds(1), "healthy stream must reset the retry budget")
        require(NowPlayingAvailability.unavailable(.runtimeExhausted).offersManualRetry, "retry must remain available to the user")

        var playingTrack = PlaybackState(bundleIdentifier: "fixture.player")
        playingTrack.title = "Track"
        playingTrack.isPlaying = true
        var confirmation = PlaybackPauseConfirmation(requested: playingTrack)
        require(confirmation.observe(playingTrack) == nil, "a playing track is not a pause acknowledgement")
        var pausedTrack = playingTrack
        pausedTrack.isPlaying = false
        require(confirmation.observe(pausedTrack) == true, "pause transition was not confirmed")
        var alreadyPaused = PlaybackPauseConfirmation(requested: playingTrack)
        require(alreadyPaused.observe(pausedTrack) == false, "an existing pause must not be claimed")
        var differentTrack = pausedTrack
        differentTrack.title = "Another track"
        require(confirmation.observe(differentTrack) == false, "pause ownership crossed a track change")
        let decoder = JSONDecoder()
        let yandex = try decoder.decode(NowPlayingUpdate.self, from: Data(#"{"diff":true,"payload":{"bundleIdentifier":"ru.yandex.desktop.music","title":"Track","artist":"Artist","artworkData":" YWJj\n ","supportsIsLiked":true,"isLiked":true}}"#.utf8))
        var apple = PlaybackState(bundleIdentifier: MediaAppBundleID.appleMusic)
        apple.album = "Previous album"
        apple.isFavorite = true
        let track = yandex.applying(to: apple)
        require(track.title == "Track" && track.artist == "Artist" && track.artwork == Data("abc".utf8),
                "Yandex metadata and artwork should survive a player change")
        require(track.album.isEmpty && !track.isFavorite && !track.supportsNowPlayingFavorite && !track.supportsNowPlayingPlaybackModes,
                "another player's favorite and raw legacy flags cannot confirm a Yandex like")

        var staleFavorite = track
        staleFavorite.isFavorite = true
        let positionOnly = try decoder.decode(NowPlayingUpdate.self, from: Data(#"{"diff":true,"payload":{"elapsedTime":17}}"#.utf8))
        require(!positionOnly.applying(to: staleFavorite).isFavorite, "Yandex must not retain a favorite")
        require(!staleFavorite.supportsNowPlayingFavorite, "Yandex favorites are removed")

        let corruptArtwork = try decoder.decode(NowPlayingUpdate.self, from: Data(#"{"diff":true,"payload":{"title":"Next","artworkData":"%%%invalid"}}"#.utf8))
        let next = corruptArtwork.applying(to: track)
        require(next.title == "Next" && next.artwork == nil, "invalid artwork must not discard valid track metadata")
        let seek = try decoder.decode(NowPlayingUpdate.self, from: Data(#"{"diff":true,"payload":{"elapsedTime":60}}"#.utf8))
        let seekDate = Date(timeIntervalSince1970: 100)
        let seekedTrack = seek.applying(to: next, now: seekDate)
        require(seekedTrack.currentTime == 60 && seekedTrack.lastUpdated == seekDate, "confirmed seek must rebase the playback clock")
        require(MediaArtwork.thumbnail(for: Data("invalid image".utf8)) == nil, "invalid image bytes must not produce a thumbnail")
        let context = CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        require(CGImageDestinationFinalize(destination), "could not encode the test cover")
        let thumbnail = MediaArtwork.thumbnail(for: png as Data)
        require(thumbnail?.width == 512 && thumbnail?.height == 256, "artwork should be decoded with bounded dimensions")

        print("PASS: framing, 20 stream lifecycles, retry budget, Yandex metadata and favorite capability")
    }
}
