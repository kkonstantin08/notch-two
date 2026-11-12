import Foundation

enum TimedProcessRunner {
    static func exitsSuccessfully(
        _ process: Process,
        timeout: Duration
    ) async throws -> Bool {
        try Task.checkCancellation()

        let terminations = AsyncStream<Bool> { continuation in
            process.terminationHandler = { process in
                continuation.yield(
                    process.terminationReason == .exit && process.terminationStatus == 0
                )
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }

        defer { process.terminationHandler = nil }

        return try await withTaskCancellationHandler {
            let succeeded = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await succeeded in terminations {
                        return succeeded
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return false
                }

                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }

            try Task.checkCancellation()
            stop(process)
            return succeeded
        } onCancel: {
            stop(process)
        }
    }

    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        _ = kill(process.processIdentifier, SIGKILL)
    }
}

enum NowPlayingError: Error, Sendable { case unavailable }

struct NowPlayingResources: Sendable {
    let adapterScriptURL: URL
    let adapterFrameworkPath: String
    let testClientURL: URL

    static func load(from bundle: Bundle = .main) throws -> Self {
        let fileManager = FileManager.default

        guard let scriptURL = bundle.url(
            forResource: "mediaremote-adapter",
            withExtension: "pl"
        ), fileManager.isReadableFile(atPath: scriptURL.path) else {
            throw NowPlayingError.unavailable
        }

        guard let privateFrameworksPath = bundle.privateFrameworksPath else {
            throw NowPlayingError.unavailable
        }
        let frameworkPath = privateFrameworksPath.appending("/MediaRemoteAdapter.framework")
        let frameworkExecutable = frameworkPath.appending("/MediaRemoteAdapter")
        guard fileManager.isExecutableFile(atPath: frameworkExecutable) else {
            throw NowPlayingError.unavailable
        }

        guard let testClientURL = bundle.url(
            forResource: "MediaRemoteAdapterTestClient",
            withExtension: nil
        ), fileManager.isExecutableFile(atPath: testClientURL.path) else {
            throw NowPlayingError.unavailable
        }

        return Self(
            adapterScriptURL: scriptURL,
            adapterFrameworkPath: frameworkPath,
            testClientURL: testClientURL
        )
    }
}

enum NowPlayingFailure: Equatable, Sendable {
    case setup
    case probe
    case runtime
    case runtimeExhausted
}

struct NowPlayingRetrySchedule {
    private(set) var attempts = 0

    mutating func nextDelay(streamUptime: Duration) -> Duration? {
        // A single initial metadata update can precede another immediate exit.
        // Reset only after a stream has stayed alive for a meaningful interval.
        if streamUptime >= .seconds(30) { attempts = 0 }
        guard attempts < 6 else { return nil }
        let delay: Duration = .seconds(1 << attempts)
        attempts += 1
        return delay
    }
}

enum NowPlayingAvailability: Equatable, Sendable {
    case unchecked
    case checking
    case available
    case unavailable(NowPlayingFailure)

    var isSelectable: Bool { self == .available }

    var failure: NowPlayingFailure? {
        guard case let .unavailable(failure) = self else { return nil }
        return failure
    }

    var offersManualRetry: Bool { failure == .probe || failure == .runtimeExhausted }

    var usesTemporaryFallback: Bool {
        guard let failure else { return false }
        return failure != .setup
    }

    var settingsMessage: LocalizedStringResource? {
        switch self {
        case .unchecked, .checking, .available:
            nil
        case .unavailable(.setup):
            LocalizedStringResource(
                "Boring Notch's Now Playing components are unavailable. Reopen or reinstall the app.",
                comment: "Now Playing setup failure message shown when required bundled components cannot be used."
            )
        case .unavailable(.probe):
            LocalizedStringResource(
                "Boring Notch could not verify Now Playing. Try again, or reopen the app if it keeps happening.",
                comment: "Recoverable Now Playing probe failure message."
            )
        case .unavailable(.runtime):
            LocalizedStringResource(
                "Boring Notch lost its Now Playing connection. Reconnecting automatically...",
                comment: "Now Playing runtime failure message shown before an automatic recovery attempt."
            )
        case .unavailable(.runtimeExhausted):
            LocalizedStringResource(
                "Now Playing disconnected repeatedly. Use Check Again to reconnect.",
                comment: "Now Playing runtime failure message shown after automatic retries stop."
            )
        }
    }
}

@MainActor
final class NowPlayingStreamSession {
    // A blocked thread in the adapter observes EOF even after SIGKILL of the app.
    // No PID matching, periodic wakeups, or extra watchdog process.
    static func parentBoundArguments(script: URL, arguments: [String]) -> [String] {
        let wrapper = #"""
        die "Missing parent lifetime pipe" unless -p STDIN;
        threads->create(sub {
            my $buffer;
            while (1) {
                my $read = sysread(STDIN, $buffer, 1);
                next if !defined($read) && $!{EINTR};
                POSIX::_exit(0) if !defined($read) || $read == 0;
            }
        })->detach();
        my $script = shift @ARGV;
        $0 = $script;
        do $script;
        die $@ if $@;
        """#
        return ["-Mthreads", "-MPOSIX", "-e", wrapper, script.path] + arguments
    }

    private let lifetimePipe = Pipe()
    private let process: Process
    private let reader: JSONLinesPipeHandler
    private let onUpdate: @MainActor (NowPlayingUpdate) async -> Void
    private let onFailure: @MainActor () -> Void

    private var readTask: Task<Void, Never>?
    private var isStopped = false

    init(
        process: Process,
        reader: JSONLinesPipeHandler = JSONLinesPipeHandler(),
        onUpdate: @escaping @MainActor (NowPlayingUpdate) async -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        self.process = process
        self.reader = reader
        self.onUpdate = onUpdate
        self.onFailure = onFailure
    }

    func start() {
        guard readTask == nil, !isStopped else { return }

        process.standardInput = lifetimePipe
        process.standardOutput = reader.outputPipe
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finish()
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            finish()
            return
        }

        let session = self
        readTask = Task { @MainActor [reader, session] in
            await reader.readJSONLines(as: NowPlayingUpdate.self) { update in
                await session.receive(update)
            }
            session.finish()
        }
    }

    func stop() {
        guard !isStopped else { return }
        cleanup()
    }

    private func receive(_ update: NowPlayingUpdate) async {
        guard !isStopped else { return }
        await onUpdate(update)
    }

    private func finish() {
        guard !isStopped else { return }
        cleanup()
        onFailure()
    }

    private func cleanup() {
        isStopped = true
        process.terminationHandler = nil
        readTask?.cancel()
        readTask = nil
        reader.close()
        try? lifetimePipe.fileHandleForWriting.close()
        TimedProcessRunner.stop(process)
    }

    deinit {
        process.terminationHandler = nil
        reader.close()
        try? lifetimePipe.fileHandleForWriting.close()
        TimedProcessRunner.stop(process)
    }
}

struct NowPlayingUpdate: Decodable, Sendable {
    let payload: NowPlayingPayload
    let diff: Bool?

    @MainActor private static let timestampFormatter = ISO8601DateFormatter()

    @MainActor
    func applying(to previous: PlaybackState, now: Date = .now) -> PlaybackState {
        let bundle = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier
            ?? (diff == true ? previous.bundleIdentifier : "")
        let isContinuation = diff == true && bundle == previous.bundleIdentifier
        let fallback = isContinuation ? previous : PlaybackState(bundleIdentifier: bundle)
        var state = fallback
        state.audioCaptureBundleIdentifiers = (
            payload.bundleIdentifier.map { [$0] } ?? fallback.effectiveAudioCaptureBundleIdentifiers
        ).normalizedBundleIdentifiers
        state.title = payload.title ?? fallback.title
        state.artist = payload.artist ?? fallback.artist
        state.album = payload.album ?? fallback.album
        state.duration = payload.duration ?? fallback.duration
        state.playbackRate = payload.playbackRate ?? fallback.playbackRate
        state.isPlaying = payload.playing ?? fallback.isPlaying
        state.volume = payload.volume ?? fallback.volume
        state.isShuffled = payload.shuffleMode.map { $0 != 1 } ?? fallback.isShuffled
        state.repeatMode = payload.repeatMode.map { RepeatMode(rawValue: $0) ?? .off } ?? fallback.repeatMode

        let sameTrack = state.isSameTrack(as: previous)
        let playbackChanged = state.isPlaying != previous.isPlaying || state.playbackRate != previous.playbackRate
        let sampleDate = payload.timestamp.flatMap { Self.timestampFormatter.date(from: $0) }
        if let elapsedTime = payload.elapsedTime {
            state.currentTime = elapsedTime
        } else if !sameTrack {
            state.currentTime = 0
        } else if isContinuation, previous.isPlaying, playbackChanged {
            state.currentTime += previous.playbackRate * (sampleDate ?? now).timeIntervalSince(previous.lastUpdated)
        }
        let rebased = !isContinuation || !sameTrack || playbackChanged || payload.elapsedTime != nil
        state.lastUpdated = sampleDate ?? (rebased ? now : fallback.lastUpdated)

        if let artwork = payload.artworkData {
            state.artwork = artwork.bytes
        } else if state.album != fallback.album || state.artist != fallback.artist {
            state.artwork = nil
        }
        state.isFavorite = state.supportsNowPlayingFavorite && sameTrack && previous.isFavorite
        return state
    }
}

struct NowPlayingPayload: Decodable, Sendable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: ArtworkData?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?

    struct ArtworkData: Decodable, Sendable {
        let bytes: Data?

        init(from decoder: Decoder) throws {
            let base64 = try? decoder.singleValueContainer().decode(String.self)
            bytes = base64.flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}
