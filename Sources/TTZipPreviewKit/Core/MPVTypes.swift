// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

/// Output rendering and audio routing configuration mode for libmpv.
public enum MPVOutputMode: Sendable, Equatable, Hashable {
    case audioOnly
    case video(renderBackend: String)

    public var isAudioOnly: Bool {
        switch self {
        case .audioOnly:
            return true
        case .video:
            return false
        }
    }

    public var renderBackend: String? {
        switch self {
        case .audioOnly:
            return nil
        case .video(let backend):
            return backend
        }
    }
}

/// Generic property value wrapper supporting libmpv formats.
public enum MPVPropertyValue: Sendable, Equatable, Hashable {
    case string(String)
    case double(Double)
    case flag(Bool)
    case int64(Int64)
    case none
}

/// High-level event stream representation emitted by the libmpv core.
public enum MPVEvent: Sendable, Equatable {
    case fileLoaded
    case playbackRestart
    case seek(position: Double)
    case pause(isPaused: Bool)
    case eof
    case error(String)
    case propertyChange(name: String, value: MPVPropertyValue)
    case logMessage(level: String, text: String)
}

/// Media track representation for audio and video streams.
public struct MPVTrackSnapshot: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let trackId: Int64
    public let title: String
    public let language: String
    public let codec: String
    public let isDefault: Bool
    public let isSelected: Bool

    public init(
        id: String,
        trackId: Int64,
        title: String,
        language: String = "",
        codec: String = "",
        isDefault: Bool = false,
        isSelected: Bool = false
    ) {
        self.id = id
        self.trackId = trackId
        self.title = title
        self.language = language
        self.codec = codec
        self.isDefault = isDefault
        self.isSelected = isSelected
    }
}

/// Subtitle track representation for embedded and external subtitles.
public struct MPVSubtitleSnapshot: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let subtitleId: Int64
    public let title: String
    public let language: String
    public let format: String
    public let isExternal: Bool
    public let isDefault: Bool
    public let isSelected: Bool

    public init(
        id: String,
        subtitleId: Int64,
        title: String,
        language: String = "",
        format: String = "SRT",
        isExternal: Bool = false,
        isDefault: Bool = false,
        isSelected: Bool = false
    ) {
        self.id = id
        self.subtitleId = subtitleId
        self.title = title
        self.language = language
        self.format = format
        self.isExternal = isExternal
        self.isDefault = isDefault
        self.isSelected = isSelected
    }
}

/// Comprehensive media stream and format metadata snapshot.
public struct MPVMediaMetadataSnapshot: Sendable, Equatable, Hashable {
    public let videoCodec: String
    public let audioCodec: String
    public let videoWidth: Int
    public let videoHeight: Int
    public let aspectRatio: Double
    public let colorSpace: String
    public let audioSampleRate: Int
    public let audioChannels: Int
    public let audioBitDepth: Int
    public let audioTracks: [MPVTrackSnapshot]
    public let subtitleTracks: [MPVSubtitleSnapshot]
    public let title: String?
    public let artist: String?

    public init(
        videoCodec: String = "",
        audioCodec: String = "",
        videoWidth: Int = 0,
        videoHeight: Int = 0,
        aspectRatio: Double = 0.0,
        colorSpace: String = "",
        audioSampleRate: Int = 0,
        audioChannels: Int = 0,
        audioBitDepth: Int = 0,
        audioTracks: [MPVTrackSnapshot] = [],
        subtitleTracks: [MPVSubtitleSnapshot] = [],
        title: String? = nil,
        artist: String? = nil
    ) {
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.aspectRatio = aspectRatio
        self.colorSpace = colorSpace
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.audioBitDepth = audioBitDepth
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.title = title
        self.artist = artist
    }
}

/// Immutable, thread-safe snapshot of the current playback engine state.
public struct MPVPlaybackStateSnapshot: Sendable, Equatable, Hashable {
    public let currentTime: Double
    public let duration: Double
    public let isPaused: Bool
    public let volume: Double
    public let isMuted: Bool
    public let cacheProgress: Double
    public let isEOF: Bool
    public let isBuffering: Bool

    public init(
        currentTime: Double = 0.0,
        duration: Double = 0.0,
        isPaused: Bool = true,
        volume: Double = 1.0,
        isMuted: Bool = false,
        cacheProgress: Double = 0.0,
        isEOF: Bool = false,
        isBuffering: Bool = false
    ) {
        self.currentTime = currentTime
        self.duration = duration
        self.isPaused = isPaused
        self.volume = volume
        self.isMuted = isMuted
        self.cacheProgress = cacheProgress
        self.isEOF = isEOF
        self.isBuffering = isBuffering
    }

    /// Normalized playback progress in the range 0.0 to 1.0.
    public var progressFraction: Double {
        guard duration > 0.0 else { return 0.0 }
        return max(0.0, min(1.0, currentTime / duration))
    }
}

/// Domain error hierarchy for libmpv operations.
public enum MPVError: Error, Sendable, LocalizedError, Equatable {
    case initializationFailed(String)
    case commandFailed(command: String, status: Int32, reason: String)
    case setPropertyFailed(property: String, status: Int32, reason: String)
    case handleDeallocated
    case invalidArgument(String)
    case fileNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .initializationFailed(let msg):
            return "MPV Engine initialization failed: \(msg)"
        case .commandFailed(let cmd, let status, let reason):
            return "MPV Command '\(cmd)' failed (code \(status)): \(reason)"
        case .setPropertyFailed(let prop, let status, let reason):
            return "MPV SetProperty '\(prop)' failed (code \(status)): \(reason)"
        case .handleDeallocated:
            return "MPV Handle has been released or is not initialized"
        case .invalidArgument(let msg):
            return "Invalid argument: \(msg)"
        case .fileNotFound(let url):
            return "Media file not found at url: \(url.path)"
        }
    }
}
