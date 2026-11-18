// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit

struct TTZipEmbeddedAudioPlayerView: View {
    let url: URL
    let fileName: String
    let onDetachMiniPlayer: (MPVAudioEngine, String, String?, NSImage?) -> Void

    @State var audioEngine = MPVAudioEngine.shared
    @State var albumArtImage: NSImage? = nil
    @State var copySuccessToast = false
    @State private var sessionID = UUID().uuidString
    @State private var ownedLoadGeneration: UInt64 = 0
    @State var fileSizeFormatted: String = ""
    @State var defaultCodecName: String = ""
    @State var defaultBitrate: String = "--"
    @State var defaultSampleRate: String = "--"
    @State var defaultChannels: String = "--"
    @State var audioTitle: String? = nil
    @State var audioArtist: String? = nil
    @State var audioAlbum: String? = nil
    @State var experienceState = AudioPlaybackCheckpointState()
    @State var metadataTask: Task<Void, Never>? = nil

    init(
        url: URL,
        fileName: String,
        onDetachMiniPlayer: @escaping (MPVAudioEngine, String, String?, NSImage?) -> Void
    ) {
        self.url = url
        self.fileName = fileName
        self.onDetachMiniPlayer = onDetachMiniPlayer
    }

    var formatBadge: String {
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "AUDIO" : ext
    }

    var isLossless: Bool {
        AudioPreviewFormatHelper.isLosslessFormat(extension: url.pathExtension)
    }

    var isWaveformOnlyPreview: Bool {
        if AudioPreviewFormatHelper.isWaveformOnlyExtension(url.pathExtension) {
            return true
        }
        return !MPVAudioEngine.formatSupport(forExtension: url.pathExtension).isPlayableNatively
    }

    var isPlaybackAvailable: Bool {
        !isWaveformOnlyPreview && !audioEngine.hasPlaybackError
    }

    var shouldShowFatalDiagnosticCard: Bool {
        guard audioEngine.hasPlaybackError else { return false }
        if isWaveformOnlyPreview {
            return !audioEngine.isExtractingWaveform && audioEngine.waveformSamples.isEmpty
        }
        return true
    }

    func layoutMetrics(forWidth width: CGFloat, height: CGFloat) -> AudioInspectorLayoutMetrics {
        AudioInspectorLayoutMetrics(availableWidth: width, availableHeight: height)
    }

    var body: some View {
        GeometryReader { geo in
            let availableWidth = geo.size.width
            let availableHeight = geo.size.height
            let metrics = layoutMetrics(forWidth: availableWidth, height: availableHeight)

            if metrics.isCompact {
                compactPlayerBody(
                    availableWidth: availableWidth,
                    availableHeight: availableHeight
                )
            } else {
                standardDawPlayerBody(
                    availableWidth: availableWidth,
                    availableHeight: availableHeight
                )
            }
        }
        .background(AudioShortcutWindowAnchor(sessionID: sessionID))
        .onContinuousHover { phase in
            switch phase {
            case .active:
                MediaPlaybackCoordinator.shared.setHovered(id: sessionID, isHovered: true)
            case .ended:
                MediaPlaybackCoordinator.shared.setHovered(id: sessionID, isHovered: false)
            }
        }
        .onAppear(perform: beginSession)
        .onChange(of: url) { _, newURL in
            setupTrackMetadata()
            loadAudio(from: newURL)
        }
        .onChange(of: audioEngine.duration) { _, _ in restoreAudioExperienceIfNeeded() }
        .onChange(of: audioEngine.currentTime) { _, _ in saveAudioExperience() }
        .onChange(of: audioEngine.isPlaying) { _, playing in
            MediaPlaybackCoordinator.shared.updatePlaybackState(id: sessionID, isPlaying: playing)
        }
        .onDisappear(perform: endSession)
    }

    func loadAudio(from targetURL: URL) {
        ownedLoadGeneration = audioEngine.load(url: targetURL, ownerSessionID: sessionID)
    }

    private func beginSession() {
        setupTrackMetadata()
        if let activeURL = audioEngine.currentURL,
           activeURL.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath(),
           audioEngine.activeOwnerSessionID == sessionID,
           audioEngine.activeLoadGeneration > 0 {
            ownedLoadGeneration = audioEngine.activeLoadGeneration
        } else {
            loadAudio(from: url)
        }
        restoreAudioExperienceIfNeeded()

        MediaPlaybackCoordinator.shared.registerSession(
            id: sessionID,
            isPlaying: audioEngine.isPlaying,
            togglePlayPause: {
                guard isPlaybackAvailable else { return }
                audioEngine.togglePlayPause()
            },
            seekBy: { delta in
                audioEngine.seekBy(delta)
            },
            stop: { [generation = ownedLoadGeneration] in
                audioEngine.stopIfCurrent(url: url, generation: generation, sessionID: sessionID)
            }
        )
    }

    private func endSession() {
        saveAudioExperience(force: true)
        metadataTask?.cancel()
        metadataTask = nil
        MediaPlaybackCoordinator.shared.unregisterSession(id: sessionID)
        audioEngine.stopIfCurrent(url: url, generation: ownedLoadGeneration, sessionID: sessionID)
    }
}

@MainActor
private struct AudioShortcutWindowAnchor: NSViewRepresentable {
    let sessionID: String

    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.sessionID = sessionID
        view.bindWindow()
    }

    final class AnchorView: NSView {
        var sessionID: String?
        override var acceptsFirstResponder: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bindWindow()
        }

        func bindWindow() {
            guard let sessionID, let window else { return }
            MediaPlaybackCoordinator.shared.bindWindow(id: sessionID, window: window)
        }
    }
}
