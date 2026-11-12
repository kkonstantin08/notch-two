//
//  PlaybackState.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import ImageIO

enum RepeatMode: Int, Codable {
    case off = 1
    case one = 2
    case all = 3
}

enum MediaArtwork {
    static func thumbnail(for data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct PlaybackState {
    var bundleIdentifier: String
    var audioCaptureBundleIdentifiers: [String] = []
    var isPlaying: Bool = false
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Double = 1
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off
    var lastUpdated: Date = Date.distantPast
    var artwork: Data?
    var volume: Double = 0.5
    var isFavorite: Bool = false

    var supportsNowPlayingFavorite: Bool {
        bundleIdentifier == MediaAppBundleID.appleMusic
    }
    var supportsNowPlayingPlaybackModes: Bool { bundleIdentifier != MediaAppBundleID.yandexMusic }

    func isSameTrack(as other: PlaybackState) -> Bool {
        bundleIdentifier == other.bundleIdentifier && title == other.title && artist == other.artist && album == other.album
    }

    var effectiveAudioCaptureBundleIdentifiers: [String] {
        let raw = audioCaptureBundleIdentifiers.isEmpty ? [bundleIdentifier] : audioCaptureBundleIdentifiers
        return raw.normalizedBundleIdentifiers
    }
}

extension Sequence where Element == String {
    var normalizedBundleIdentifiers: [String] {
        var seen = Set<String>()
        return filter { value in
            guard !value.isEmpty, !seen.contains(value) else { return false }
            seen.insert(value)
            return true
        }
    }
}

extension PlaybackState: Equatable {
    static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        return lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.effectiveAudioCaptureBundleIdentifiers == rhs.effectiveAudioCaptureBundleIdentifiers
            && lhs.isPlaying == rhs.isPlaying
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.currentTime == rhs.currentTime
            && lhs.duration == rhs.duration
            && lhs.isShuffled == rhs.isShuffled
            && lhs.repeatMode == rhs.repeatMode
            && lhs.artwork == rhs.artwork
            && lhs.isFavorite == rhs.isFavorite
    }
}

struct PlaybackPauseConfirmation {
    let requested: PlaybackState
    private var observedPlaying = false

    init(requested: PlaybackState) { self.requested = requested }

    mutating func observe(_ state: PlaybackState) -> Bool? {
        guard state.isSameTrack(as: requested) else { return false }
        if state.isPlaying { observedPlaying = true; return nil }
        return observedPlaying
    }
}
