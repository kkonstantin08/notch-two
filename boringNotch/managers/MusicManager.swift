//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

struct NowPlayingFallbackNotice: Identifiable, Equatable {
    let id = UUID()
    let fallbackSource: MediaControllerType
    let failure: NowPlayingFailure

    var title: LocalizedStringResource {
        switch failure {
        case .setup:
            LocalizedStringResource(
                "Now Playing components unavailable",
                comment: "Title of the passive notice shown when required Now Playing components cannot be used."
            )
        case .probe:
            LocalizedStringResource(
                "Could not verify Now Playing",
                comment: "Title of the passive notice shown when the Now Playing availability probe fails."
            )
        case .runtime, .runtimeExhausted:
            LocalizedStringResource(
                "Now Playing connection lost",
                comment: "Title of the passive notice shown when an active Now Playing stream fails."
            )
        }
    }

    var subtitle: LocalizedStringResource {
        if failure == .setup {
            LocalizedStringResource(
                "Using \(fallbackSource.localizedString) instead",
                comment: "Now Playing setup failure notice. The placeholder is the fallback music source name."
            )
        } else {
            LocalizedStringResource(
                "Using \(fallbackSource.localizedString) temporarily",
                comment: "Temporary Now Playing fallback notice. The placeholder is the fallback music source name."
            )
        }
    }
}

@MainActor
final class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private static let noticeDuration: Duration = .seconds(6)
    private static let artworkQueue = DispatchQueue(label: "BoringNotch.MediaArtwork", qos: .userInitiated)

    private var controllerCancellables = Set<AnyCancellable>()
    private var averageColorTask: Task<Void, Never>?
    private var debounceIdleTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var runtimeFailureTask: Task<Void, Never>?
    private var runtimeRecoveryTask: Task<Void, Never>?
    private var runtimeRetry = NowPlayingRetrySchedule()
    private var runtimeStartedAt: ContinuousClock.Instant?
    private var noticeDismissalTask: Task<Void, Never>?
    private var isDestroyed = false
    private var lastNoticedFailure: NowPlayingFailure?

    // Helper to check if macOS can use NowPlayingController
    @Published private(set) var preferredMediaController: MediaControllerType
    @Published private(set) var nowPlayingAvailability: NowPlayingAvailability = .unchecked
    @Published private(set) var effectiveMediaController: MediaControllerType?
    @Published private(set) var nowPlayingNotice: NowPlayingFallbackNotice?

    // Active controller
    private var playbackCommandVersion = UUID()
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = ""
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String?
    @Published var audioCaptureBundleIdentifiers: [String] = []
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @Published var usingAppIconForArtwork: Bool = false
    @Published var canFavoriteTrack: Bool = false
    var supportsPlaybackModes: Bool { bundleIdentifier != MediaAppBundleID.yandexMusic }

    // Lyrics are now managed by LyricsService
    var lyricsService: LyricsService { LyricsService.shared }
    var currentLyrics: String { lyricsService.currentLyrics }
    var isFetchingLyrics: Bool { lyricsService.isFetchingLyrics }
    var syncedLyrics: [(time: Double, text: String)] { lyricsService.syncedLyrics }
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data?
    private var artworkWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        Self.migrateMediaControllerPreferenceIfNeeded()
        preferredMediaController = Defaults[.mediaController]

        if preferredMediaController == .nowPlaying {
            activateFallback()
            ensureNowPlayingAvailabilityChecked()
        } else {
            activateControllerIfNeeded(preferredMediaController)
        }
    }

    private static func migrateMediaControllerPreferenceIfNeeded() {
        guard !Defaults[.didMigrateMediaControllerChoice] else { return }

        let firstLaunch = UserDefaults.standard.object(forKey: "firstLaunch") as? Bool ?? true
        let hasStoredController = UserDefaults.standard.object(forKey: "mediaController") != nil
        Defaults[.didChooseMediaController] = Defaults[.didChooseMediaController]
            || hasStoredController
            || !firstLaunch
        Defaults[.didMigrateMediaControllerChoice] = true
    }

    deinit {
        debounceIdleTask?.cancel()
        availabilityTask?.cancel()
        runtimeFailureTask?.cancel()
        runtimeRecoveryTask?.cancel()
        noticeDismissalTask?.cancel()
        controllerCancellables.removeAll()
        artworkWorkItem?.cancel()
        averageColorTask?.cancel()
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true

        debounceIdleTask?.cancel()
        availabilityTask?.cancel()
        runtimeFailureTask?.cancel()
        runtimeRecoveryTask?.cancel()
        noticeDismissalTask?.cancel()
        availabilityTask = nil
        runtimeFailureTask = nil
        runtimeRecoveryTask = nil
        noticeDismissalTask = nil
        controllerCancellables.removeAll()
        artworkWorkItem?.cancel()
        artworkWorkItem = nil
        averageColorTask?.cancel()
        averageColorTask = nil
        (activeController as? any NowPlayingRuntimeControlling)?.stopRuntimeStream()

        activeController = nil
        effectiveMediaController = nil
        nowPlayingNotice = nil
    }

    func selectMediaController(_ type: MediaControllerType) {
        guard !isDestroyed else { return }

        Defaults[.mediaController] = type
        Defaults[.didChooseMediaController] = true
        preferredMediaController = type
        cancelRuntimeRecovery()
        clearNotice()

        if type == .nowPlaying {
            if nowPlayingAvailability == .available {
                activateControllerIfNeeded(.nowPlaying)
            } else {
                activateFallback()
                refreshNowPlayingAvailability()
            }
        } else {
            activateControllerIfNeeded(type)
        }
    }

    private func resolvedNowPlayingFallback() -> MediaControllerType {
        guard let bundleIdentifier = Defaults[.lastSupportedNowPlayingBundleIdentifier],
              let controller = MediaControllerType(nowPlayingBundleIdentifier: bundleIdentifier)
        else {
            return .appleMusic
        }

        return controller
    }

    func ensureNowPlayingAvailabilityChecked() {
        guard nowPlayingAvailability == .unchecked else { return }
        startAvailabilityCheck()
    }

    func refreshNowPlayingAvailability() {
        cancelRuntimeRecovery()
        startAvailabilityCheck()
    }

    private func startAvailabilityCheck() {
        guard !isDestroyed, availabilityTask == nil else { return }

        nowPlayingAvailability = .checking
        availabilityTask = Task { @MainActor [weak self] in
            let availability: NowPlayingAvailability
            do {
                availability = try await MediaChecker().checkAvailability(maxAttempts: 3)
            } catch is CancellationError {
                return
            } catch {
                availability = .unavailable(.probe)
            }

            guard let self, !self.isDestroyed else { return }
            self.availabilityTask = nil
            self.nowPlayingAvailability = availability

            if availability == .available {
                if self.runtimeRetry.attempts == 0 { self.clearNotice() }
                if self.preferredMediaController == .nowPlaying {
                    self.activateControllerIfNeeded(.nowPlaying)
                }
            } else if self.preferredMediaController == .nowPlaying,
                      let failure = availability.failure {
                let noticeFailure = Defaults[.didChooseMediaController] ? failure : nil
                self.activateFallback(noticeFailure: noticeFailure)
            }
        }
    }

    private func activateFallback(noticeFailure: NowPlayingFailure? = nil) {
        let fallbackController = resolvedNowPlayingFallback()

        if let noticeFailure {
            requestNotice(fallbackController: fallbackController, failure: noticeFailure)
        }

        activateControllerIfNeeded(fallbackController)
    }

    private func requestNotice(
        fallbackController: MediaControllerType,
        failure: NowPlayingFailure
    ) {
        guard lastNoticedFailure != failure else { return }
        lastNoticedFailure = failure

        noticeDismissalTask?.cancel()
        noticeDismissalTask = nil
        nowPlayingNotice = NowPlayingFallbackNotice(
            fallbackSource: fallbackController,
            failure: failure
        )
    }

    @discardableResult
    func markNowPlayingNoticePresented(_ noticeID: UUID) -> Bool {
        guard nowPlayingNotice?.id == noticeID,
              noticeDismissalTask == nil
        else {
            return false
        }

        noticeDismissalTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: Self.noticeDuration)
            } catch {
                return
            }
            guard self.nowPlayingNotice?.id == noticeID else { return }
            self.nowPlayingNotice = nil
            self.noticeDismissalTask = nil
        }
        return true
    }

    private func clearNotice() {
        noticeDismissalTask?.cancel()
        noticeDismissalTask = nil
        nowPlayingNotice = nil
        lastNoticedFailure = nil
    }

    private func activateControllerIfNeeded(_ type: MediaControllerType) {
        guard !isDestroyed,
              activeController == nil || effectiveMediaController != type
        else {
            return
        }

        do {
            let controller = try makeController(for: type)
            activateController(controller, type: type)
        } catch {
            if type == .nowPlaying {
                let failure = NowPlayingFailure.setup
                nowPlayingAvailability = .unavailable(failure)
                let noticeFailure = Defaults[.didChooseMediaController] ? failure : nil
                activateFallback(noticeFailure: noticeFailure)
                return
            }

            guard type != .appleMusic else { return }
            activateController(AppleMusicController(), type: .appleMusic)
        }
    }

    private func makeController(
        for type: MediaControllerType
    ) throws -> any MediaControllerProtocol {
        switch type {
        case .nowPlaying:
            try NowPlayingController()
        case .appleMusic:
            AppleMusicController()
        case .spotify:
            SpotifyController()
        case .youtubeMusic:
            YouTubeMusicController()
        }
    }

    private func activateController(
        _ controller: any MediaControllerProtocol,
        type: MediaControllerType
    ) {
        let isReplacingController = activeController != nil

        runtimeFailureTask?.cancel()
        runtimeFailureTask = nil
        (activeController as? any NowPlayingRuntimeControlling)?.stopRuntimeStream()
        controllerCancellables.removeAll()

        if isReplacingController {
            resetPublishedPlaybackState()
        }
        activeController = controller
        effectiveMediaController = type
        canFavoriteTrack = controller.supportsFavorite
        volumeControlSupported = controller.supportsVolumeControl

        controller.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, controller] state in
                guard let self,
                      self.activeController === controller,
                      state.lastUpdated != .distantPast
                else {
                    return
                }
                self.updateFromPlaybackState(state)
            }
            .store(in: &controllerCancellables)

        if let runtimeController = controller as? any NowPlayingRuntimeControlling {
            runtimeFailureTask = Task { @MainActor [weak self, runtimeController] in
                for await _ in runtimeController.runtimeFailures {
                    guard let self else { return }
                    self.handleRuntimeFailure(from: runtimeController)
                }
            }
        }

        forceUpdate()
        if let runtimeController = controller as? any NowPlayingRuntimeControlling {
            runtimeStartedAt = .now
            runtimeController.startRuntimeStream()
        } else {
            runtimeStartedAt = nil
        }
    }

    private func resetPublishedPlaybackState() {
        debounceIdleTask?.cancel()
        debounceIdleTask = nil
        artworkWorkItem?.cancel()
        artworkWorkItem = nil
        averageColorTask?.cancel()
        averageColorTask = nil

        songTitle = ""
        artistName = ""
        album = ""
        albumArt = defaultImage
        isPlaying = false
        isPlayerIdle = true
        avgColor = .white
        bundleIdentifier = nil
        audioCaptureBundleIdentifiers = []
        songDuration = 0
        elapsedTime = 0
        timestampDate = Date()
        playbackRate = 1
        isShuffled = false
        repeatMode = .off
        volume = 0.5
        usingAppIconForArtwork = false
        isFavoriteTrack = false

        artworkData = nil
        lyricsService.clearLyrics()
    }

    private func handleRuntimeFailure(from controller: any NowPlayingRuntimeControlling) {
        guard activeController === controller,
              effectiveMediaController == .nowPlaying,
              preferredMediaController == .nowPlaying
        else {
            return
        }

        NSLog("Now Playing runtime stream failed; switching to fallback")
        let uptime = runtimeStartedAt?.duration(to: .now) ?? .zero
        let delay = runtimeRetry.nextDelay(streamUptime: uptime)
        let failure: NowPlayingFailure = delay == nil ? .runtimeExhausted : .runtime
        if runtimeRetry.attempts == 1 { lastNoticedFailure = nil }
        nowPlayingAvailability = .unavailable(failure)
        let noticeFailure = Defaults[.didChooseMediaController] ? failure : nil
        activateFallback(noticeFailure: noticeFailure)
        if let delay { scheduleRuntimeRecovery(after: delay) }
    }

    private func scheduleRuntimeRecovery(after delay: Duration) {
        runtimeRecoveryTask?.cancel()
        runtimeRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard let self,
                  !self.isDestroyed,
                  self.preferredMediaController == .nowPlaying
            else {
                return
            }

            self.runtimeRecoveryTask = nil
            self.startAvailabilityCheck()
        }
    }

    private func cancelRuntimeRecovery() {
        runtimeRecoveryTask?.cancel()
        runtimeRecoveryTask = nil
        runtimeRetry = .init()
    }

    // MARK: - Update Methods
    private func updateFromPlaybackState(_ state: PlaybackState) {
        guard state.lastUpdated != .distantPast else { return }

        if effectiveMediaController == .nowPlaying,
           MediaControllerType(nowPlayingBundleIdentifier: state.bundleIdentifier) != nil,
           Defaults[.lastSupportedNowPlayingBundleIdentifier] != state.bundleIdentifier {
            Defaults[.lastSupportedNowPlayingBundleIdentifier] = state.bundleIdentifier
        }

        // Check for playback state changes (playing/paused)
        let playingStateChanged = state.isPlaying != self.isPlaying
        if playingStateChanged {
            if state.isPlaying { playbackCommandVersion = UUID() }
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        let bundleChanged = state.bundleIdentifier != bundleIdentifier
        let trackChanged = state.title != songTitle || state.artist != artistName || state.album != album || bundleChanged
        let artworkChanged = state.artwork != artworkData
        if artworkChanged {
            artworkData = state.artwork
            artworkWorkItem?.cancel()
            if let artwork = state.artwork {
                updateArtwork(artwork, bundleIdentifier: state.bundleIdentifier)
            }
        }
        if state.artwork == nil && (artworkChanged || bundleChanged) {
            showArtworkFallback(for: state.bundleIdentifier)
        }
        if trackChanged {
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                updateSneakPeek()
            }
            fetchLyricsIfAvailable(bundleIdentifier: state.bundleIdentifier, title: state.title, artist: state.artist)
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume

        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }

        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        let captureBundleIDs = state.effectiveAudioCaptureBundleIdentifiers
        if captureBundleIDs != self.audioCaptureBundleIdentifiers {
            self.audioCaptureBundleIdentifiers = captureBundleIDs
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        let supportsFavorite = effectiveMediaController == .nowPlaying
            ? state.supportsNowPlayingFavorite : activeController?.supportsFavorite == true
        if canFavoriteTrack != supportsFavorite { canFavoriteTrack = supportsFavorite }
        let isFavorite = supportsFavorite && state.isFavorite
        if isFavoriteTrack != isFavorite { isFavoriteTrack = isFavorite }

        if volumeChanged {
            self.volume = state.volume
        }

        // The slider extrapolates from (elapsedTime, timestampDate); only
        // republish when an extrapolation input actually changed — otherwise
        // every no-op stream event invalidates the whole view tree. A pause/
        // resume must rebase it too, or the estimate overshoots by the pause
        // duration.
        if timeChanged || playbackRateChanged || playingStateChanged || trackChanged {
            self.timestampDate = state.lastUpdated
        }
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor [weak self] in
            guard self?.activeController === controller, controller.supportsFavorite else { return }
            await controller.setFavorite(favorite)
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    private func fetchLyricsIfAvailable(bundleIdentifier: String?, title: String, artist: String) {
        guard Defaults[.enableLyrics], !title.isEmpty else {
            Task { @MainActor in
                lyricsService.clearLyrics()
            }
            return
        }

        Task { @MainActor in
            await lyricsService.fetchLyrics(bundleIdentifier: bundleIdentifier, title: title, artist: artist)
        }
    }

    private func updateArtwork(_ artworkData: Data, bundleIdentifier: String) {
        let workItem = DispatchWorkItem { [weak self] in
            let thumbnail = MediaArtwork.thumbnail(for: artworkData)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDestroyed, self.artworkData == artworkData else { return }
                if let thumbnail {
                    if self.usingAppIconForArtwork { self.usingAppIconForArtwork = false }
                    self.updateAlbumArt(newAlbumArt: NSImage(cgImage: thumbnail, size: .zero))
                } else {
                    self.showArtworkFallback(for: self.bundleIdentifier ?? bundleIdentifier)
                }
            }
        }
        artworkWorkItem = workItem
        Self.artworkQueue.async(execute: workItem)
    }

    private func showArtworkFallback(for bundleIdentifier: String) {
        let icon = appIconAsNSImage(for: bundleIdentifier)
        if usingAppIconForArtwork != (icon != nil) { usingAppIconForArtwork = icon != nil }
        updateAlbumArt(newAlbumArt: icon ?? defaultImage)
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                guard !Task.isCancelled, let self, !self.isPlaying, !self.isPlayerIdle else { return }
                withAnimation {
                    self.isPlayerIdle = true
                }
            }
        }
    }

    private func updateAlbumArt(newAlbumArt: NSImage) {
        guard albumArt !== newAlbumArt else { return }
        averageColorTask?.cancel()
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        let artwork = albumArt
        averageColorTask = Task { [weak self, artwork] in
            let color = await artwork.averageColor()
            guard !Task.isCancelled,
                  let self,
                  self.albumArt === artwork else {
                return
            }

            withAnimation(.smooth) {
                self.avgColor = color ?? .white
            }
        }
    }

    private func updateSneakPeek() {
        guard isPlaying && Defaults[.enableSneakPeek] && !Defaults[.alwaysShowSneakPeek] else { return }
        if Defaults[.sneakPeekStyles] == .standard {
            NotchUIEventBus.events.send(.sneakPeek(type: .music, value: 0, duration: max(1, min(15, Defaults[.sneakPeekDuration]))))
        } else {
            NotchUIEventBus.events.send(.expandingView(type: .music))
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        playbackCommandVersion = UUID()
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        playbackCommandVersion = UUID()
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        playbackCommandVersion = UUID()
        Task {
            await activeController?.pause()
        }
    }

    func pauseForEyeBreak() async -> (@MainActor () async -> Void)? {
        guard let controller = activeController, isPlaying else { return nil }
        playbackCommandVersion = UUID()
        let track = (bundleIdentifier, songTitle, artistName, album)
        let version = playbackCommandVersion
        var requested = PlaybackState(bundleIdentifier: bundleIdentifier ?? "")
        requested.title = songTitle
        requested.artist = artistName
        requested.album = album
        var confirmation = PlaybackPauseConfirmation(requested: requested)
        let changes = AsyncStream.makeStream(of: Bool.self)
        let observation = controller.playbackStatePublisher.sink { state in
            if let confirmed = confirmation.observe(state) { changes.continuation.yield(confirmed) }
        }
        defer { observation.cancel(); changes.continuation.finish() }
        await controller.pause()
        let confirmed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await result in changes.stream { return result }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard confirmed, playbackCommandVersion == version else { return nil }
        return { [weak self, weak controller] in
            guard let self, let controller, self.activeController === controller,
                  self.playbackCommandVersion == version, !self.isPlaying,
                  (self.bundleIdentifier, self.songTitle, self.artistName, self.album) == track else { return }
            await controller.play()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }

    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        playbackCommandVersion = UUID()
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        playbackCommandVersion = UUID()
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, elapsedTime + seconds), songDuration)
        seek(to: newPos)
    }

    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            Log.music.error("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (_, error) in
                if let error = error {
                    Log.music.error("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    Log.music.debug("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            Log.music.error("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
            }
        }
    }

    func syncVolumeFromActiveApp() async {
        // Check if bundle identifier is valid and if the app is actually running
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }

        var script: String?
        if bundleID == MediaAppBundleID.appleMusic {
            script = """
            tell application "Music"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else if bundleID == MediaAppBundleID.spotify {
            script = """
            tell application "Spotify"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else {
            // For unsupported apps, don't sync volume
            return
        }

        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0

            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}
