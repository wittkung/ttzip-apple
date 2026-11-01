// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import Combine

/// Masterpiece Hi-Fi Audio Player View powered by native audio engine.
/// Supports universal lossless & spatial audio decoding (APE, FLAC, DTS, Opus, Ogg, MP3, M4A, WAV, AIFF, ALAC, DSF, etc.)
/// with restrained acoustic artwork header, Voice Memos symmetric thin-tick waveform, and real-time audio telemetry.
public struct UnifiedAudioPlayerView: View {
    public let url: URL
    public let fileName: String
    public var hostDisplaysFileName: Bool
    public var windowedTileProvider: (any AudioWaveformWindowedTileProviding)?
    public var onDetachMiniPlayer: ((MPVAudioEngine, String, String?, NSImage?) -> Void)?

    @State var audioEngine: MPVAudioEngine
    @State var albumArtImage: NSImage? = nil
    @State var copySuccessToast = false
    @State var isHovering = false
    @State var sessionId = UUID().uuidString
    @State var ownedLoadGeneration: UInt64 = 0
    @State var fileSizeFormatted: String = ""
    @State var defaultCodecName: String = ""
    @State var defaultBitrate: String = "--"
    @State var defaultSampleRate: String = "--"
    @State var defaultChannels: String = "--"
    @State var audioTitle: String? = nil
    @State var audioArtist: String? = nil
    @State var audioAlbum: String? = nil
    @State var isSpinning: Bool = false
    @State var experienceState = AudioPlaybackCheckpointState()
    @State var metadataTask: Task<Void, Never>? = nil

    public init(
        url: URL,
        fileName: String,
        hostDisplaysFileName: Bool = false,
        windowedTileProvider: (any AudioWaveformWindowedTileProviding)? = AudioWaveformWindowExtractor.shared,
        onDetachMiniPlayer: ((MPVAudioEngine, String, String?, NSImage?) -> Void)? = nil
    ) {
        self.url = url
        self.fileName = fileName
        self.hostDisplaysFileName = hostDisplaysFileName
        self.windowedTileProvider = windowedTileProvider
        self.onDetachMiniPlayer = onDetachMiniPlayer
        self._audioEngine = State(initialValue: MPVAudioEngine.shared)
    }

    public init(
        url: URL,
        fileName: String,
        audioEngine: MPVAudioEngine,
        hostDisplaysFileName: Bool = false,
        windowedTileProvider: (any AudioWaveformWindowedTileProviding)? = AudioWaveformWindowExtractor.shared,
        onDetachMiniPlayer: ((MPVAudioEngine, String, String?, NSImage?) -> Void)? = nil
    ) {
        self.url = url
        self.fileName = fileName
        self.hostDisplaysFileName = hostDisplaysFileName
        self.windowedTileProvider = windowedTileProvider
        self.onDetachMiniPlayer = onDetachMiniPlayer
        self._audioEngine = State(initialValue: audioEngine)
        if let activeURL = audioEngine.currentURL,
           activeURL.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath(),
           let existingOwner = audioEngine.activeOwnerSessionID,
           audioEngine.activeLoadGeneration > 0 {
            self._sessionId = State(initialValue: existingOwner)
            self._ownedLoadGeneration = State(initialValue: audioEngine.activeLoadGeneration)
        }
    }

    public var formatBadge: String {
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "AUDIO" : ext
    }

    public var isLossless: Bool {
        AudioPreviewFormatHelper.isLosslessFormat(extension: url.pathExtension)
    }

    /// True when the audio format supports waveform extraction (`waveformSupported: true`)
    /// while native `AVAudioEngine` playback is not verified (`playbackVerified: false`, e.g. `.ogg`/`.oga`/`.opus`).
    public var isWaveformOnlyPreview: Bool {
        if AudioPreviewFormatHelper.isWaveformOnlyExtension(url.pathExtension) {
            return true
        }
        return !MPVAudioEngine.formatSupport(forExtension: url.pathExtension).isPlayableNatively
    }

    public var isPlaybackAvailable: Bool {
        !isWaveformOnlyPreview && !audioEngine.hasPlaybackError
    }

    /// Only show fatal diagnostic error card when a genuinely playable format fails to decode,
    /// OR when a waveform-only format fails waveform extraction as well.
    public var shouldShowFatalDiagnosticCard: Bool {
        guard audioEngine.hasPlaybackError else { return false }
        if isWaveformOnlyPreview {
            return !audioEngine.isExtractingWaveform && audioEngine.waveformSamples.isEmpty
        }
        return true
    }

    public func layoutMetrics(forWidth width: CGFloat, height: CGFloat) -> AudioInspectorLayoutMetrics {
        AudioInspectorLayoutMetrics(availableWidth: width, availableHeight: height)
    }

    public var body: some View {
        GeometryReader { geo in
            let availableWidth = geo.size.width
            let availableHeight = geo.size.height
            let metrics = layoutMetrics(forWidth: availableWidth, height: availableHeight)

            if metrics.isCompact {
                compactPlayerBody(
                    availableWidth: availableWidth,
                    availableHeight: availableHeight,
                    isUltraCompact: metrics.isUltraCompact
                )
            } else {
                standardDawPlayerBody(
                    availableWidth: availableWidth,
                    availableHeight: availableHeight
                )
            }
        }
        .background(MediaKeyboardWindowAnchor(sessionID: sessionId))
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovering = true
                MediaPlaybackCoordinator.shared.setHovered(id: sessionId, isHovered: true)
            case .ended:
                isHovering = false
                MediaPlaybackCoordinator.shared.setHovered(id: sessionId, isHovered: false)
            }
        }
        .onAppear {
            setupTrackMetadata()
            let generation: UInt64
            if let activeURL = audioEngine.currentURL,
               activeURL.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath(),
               audioEngine.activeOwnerSessionID == sessionId,
               audioEngine.activeLoadGeneration > 0 {
                generation = audioEngine.activeLoadGeneration
            } else {
                generation = audioEngine.load(url: url, ownerSessionID: sessionId)
            }
            ownedLoadGeneration = generation
            isSpinning = audioEngine.isPlaying
            restoreAudioExperienceIfNeeded()

            MediaPlaybackCoordinator.shared.registerSession(
                id: sessionId,
                isPlaying: audioEngine.isPlaying,
                togglePlayPause: {
                    guard isPlaybackAvailable else { return }
                    audioEngine.togglePlayPause()
                },
                seekBy: { delta in
                    audioEngine.seekBy(delta)
                },
                stop: {
                    Self.stopAudioEngineIfOwned(
                        engine: audioEngine,
                        ownerURL: url,
                        ownerSessionID: sessionId,
                        ownerGeneration: generation
                    )
                }
            )
        }
        .onChange(of: url) { _, newURL in
            setupTrackMetadata()
            ownedLoadGeneration = audioEngine.load(url: newURL, ownerSessionID: sessionId)
        }
        .onChange(of: audioEngine.duration) { _, _ in restoreAudioExperienceIfNeeded() }
        .onChange(of: audioEngine.currentTime) { _, _ in saveAudioExperience() }
        .onChange(of: audioEngine.isPlaying) { _, playing in
            isSpinning = playing
            MediaPlaybackCoordinator.shared.updatePlaybackState(id: sessionId, isPlaying: playing)
        }
        .onDisappear {
            saveAudioExperience(force: true)
            metadataTask?.cancel()
            metadataTask = nil
            isSpinning = false
            MediaPlaybackCoordinator.shared.unregisterSession(id: sessionId)
            Self.stopAudioEngineIfOwned(
                engine: audioEngine,
                ownerURL: url,
                ownerSessionID: sessionId,
                ownerGeneration: ownedLoadGeneration
            )
        }
    }

    @MainActor
    public static func stopAudioEngineIfOwned(
        engine: MPVAudioEngine,
        ownerURL: URL,
        ownerSessionID: String? = nil,
        ownerGeneration: UInt64? = nil
    ) {
        engine.stopIfCurrent(
            url: ownerURL,
            generation: ownerGeneration,
            sessionID: ownerSessionID
        )
    }
}
