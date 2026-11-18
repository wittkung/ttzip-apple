// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreMedia
import SwiftUI

/// A per-viewport playback snapshot and its controls for the current video session.
@MainActor
public struct VideoPlaybackControlsContext {
    public struct Transport {
        public let currentTime: CMTime
        public let duration: CMTime
        public let isPlaying: Bool
        public let isFullScreen: Bool
        public let volume: Float
        public let isMuted: Bool
        public let playbackRate: Float
        public let pipSupported: Bool
        public let pipActive: Bool
    }

    public struct Subtitles {
        public let name: String?
        public let options: [SubtitleMenuOption]
        public let selectedID: String?
        public let selectedSecondaryID: String
        public let style: SubtitleStyleConfiguration
        public let geometry: SubtitleVideoContentGeometry?
        public let activeCodec: String?
    }

    public enum Action {
        case togglePlayPause
        case seekBy(Double)
        case seekTo(CMTime)
        case setVolume(Float)
        case toggleMute
        case setPlaybackRate(Float)
        case togglePictureInPicture
        case toggleFullScreen
        case interaction(Interaction)
        case subtitle(SubtitleAction)
    }

    public enum Interaction {
        case activity
        case scrubbing(Bool)
        case popoverPresented(Bool)
    }

    public enum SubtitleAction {
        case load
        case remove
        case select(String)
        case selectSecondary(String)
        case updateStyle(SubtitleStyleConfiguration)
    }

    public let videoURL: URL
    public let viewportSize: CGSize
    public let rotationDegrees: Int
    public let transport: Transport
    public let subtitles: Subtitles
    public let format: VideoFormatPresentationState

    let cachedThumbnail: @MainActor (CMTime) -> CGImage?
    let dispatch: @MainActor (Action) -> Void

    /// Reads a cached frame without starting a decode or seeking the player.
    public func thumbnail(at time: CMTime) -> CGImage? {
        cachedThumbnail(time)
    }

    public func send(_ action: Action) {
        dispatch(action)
    }
}

private struct VideoPlaybackControlsKey: EnvironmentKey {
    static let defaultValue: (@MainActor (VideoPlaybackControlsContext) -> AnyView)? = nil
}

public extension EnvironmentValues {
    var videoPlaybackControls: (@MainActor (VideoPlaybackControlsContext) -> AnyView)? {
        get { self[VideoPlaybackControlsKey.self] }
        set { self[VideoPlaybackControlsKey.self] = newValue }
    }
}
