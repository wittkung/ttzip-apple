// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import Combine
import TTZipCore
import TTZipUI

/// Masterpiece Hi-Fi Audio Player View powered by native libmpv engine.
/// Supports universal lossless & spatial audio decoding (APE, FLAC, DTS, Opus, Ogg, MP3, M4A, WAV, AIFF, ALAC, DSF, etc.)
/// with an expansive vinyl turntable animation, dynamic tone arm, 1600-bin DAW waveform, and real-time audio telemetry.
public struct UnifiedAudioPlayerView: View {
    public let url: URL
    public let fileName: String

    @State private var audioEngine = MPVAudioEngine.shared
    @State private var albumArtImage: NSImage? = nil
    @State private var copySuccessToast = false
    @State private var rotationAngle: Double = 0
    @State private var rotationSpeed: Double = 0
    @State private var isHovering = false
    @State private var sessionId = UUID().uuidString
    @State private var fileSizeFormatted: String = ""
    @State private var defaultCodecName: String = ""
    @State private var defaultBitrate: String = "--"
    @State private var defaultSampleRate: String = "--"
    @State private var defaultChannels: String = "--"
    @State private var audioTitle: String? = nil
    @State private var audioArtist: String? = nil
    @State private var audioAlbum: String? = nil

    private let animationTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    public init(url: URL, fileName: String) {
        self.url = url
        self.fileName = fileName
    }

    public var formatBadge: String {
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "AUDIO" : ext
    }

    public var isLossless: Bool {
        AudioPreviewFormatHelper.isLosslessFormat(extension: url.pathExtension)
    }

    private var displayTitle: String {
        if let audioTitle, !audioTitle.isEmpty {
            return audioTitle
        }
        if let mpvTitle = audioEngine.metadata?.title, !mpvTitle.isEmpty {
            return mpvTitle
        }
        let clean = (fileName as NSString).deletingPathExtension
        return clean.isEmpty ? fileName : clean
    }

    private var displaySubtitle: String? {
        let artist = audioArtist ?? audioEngine.metadata?.artist
        let album = audioAlbum
        if let artist, !artist.isEmpty, let album, !album.isEmpty {
            return "\(artist) · \(album)"
        } else if let artist, !artist.isEmpty {
            return artist
        } else if let album, !album.isEmpty {
            return album
        }
        return nil
    }

    private var displayCodecName: String {
        if !audioEngine.codecFormatted.isEmpty && audioEngine.codecFormatted != "--" {
            return audioEngine.codecFormatted
        }
        return defaultCodecName
    }

    private var displayBitrate: String {
        if !audioEngine.bitrateFormatted.isEmpty && audioEngine.bitrateFormatted != "--" {
            return audioEngine.bitrateFormatted
        }
        return defaultBitrate
    }

    private var displaySampleRate: String {
        if !audioEngine.sampleRateFormatted.isEmpty && audioEngine.sampleRateFormatted != "--" {
            return audioEngine.sampleRateFormatted
        }
        return defaultSampleRate
    }

    private var displayChannels: String {
        if !audioEngine.channelsFormatted.isEmpty && audioEngine.channelsFormatted != "--" {
            return audioEngine.channelsFormatted
        }
        return defaultChannels
    }

    public var body: some View {
        GeometryReader { geo in
            let availableWidth = geo.size.width
            let availableHeight = geo.size.height

            // Calculate adaptive turntable diameter based on vertical and horizontal real estate
            let nonTurntableHeight: CGFloat = audioEngine.hasPlaybackError ? 430 : 360
            let verticalSpaceForTurntable = max(130, availableHeight - nonTurntableHeight)
            let horizontalSpaceForTurntable = max(130, availableWidth - 54)
            let computedDiameter = min(horizontalSpaceForTurntable, verticalSpaceForTurntable, 290)
            let turntableDiameter = max(130, computedDiameter)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: availableHeight > 620 ? 16 : 10) {
                    // 1. Expansive Vinyl Turntable with spinning tonearm & grooves
                    VinylTurntableView(
                        diameter: turntableDiameter,
                        isPlaying: audioEngine.isPlaying,
                        rotationAngle: rotationAngle,
                        albumArt: albumArtImage,
                        onTogglePlayPause: {
                            audioEngine.togglePlayPause()
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, availableHeight > 600 ? 12 : 4)

                    // 2. Track Title, Artist, and High-Res Badges
                    trackHeaderSection

                    // 3. Fail-Fast Diagnostic Card (if playback error occurs)
                    diagnosticErrorCard

                    // 4. Dynamic 1600-point Sound Wave Visualizer with Microsecond Scrubber
                    AudioWaveformVisualizerView(
                        url: url,
                        isPlaying: audioEngine.isPlaying,
                        currentTime: audioEngine.currentTime,
                        duration: audioEngine.duration,
                        sampleCount: 1600,
                        onSeek: { targetSeconds in
                            audioEngine.seek(to: targetSeconds)
                        }
                    )
                    .padding(.horizontal, 16)

                    // 5. Playback Transport Controls Bar (Seeking, Volume, Playback Speed)
                    AudioPlaybackControlsBar(
                        isPlaying: audioEngine.isPlaying,
                        volume: audioEngine.volume,
                        isMuted: audioEngine.isMuted,
                        playbackSpeed: audioEngine.playbackSpeed,
                        onTogglePlayPause: { audioEngine.togglePlayPause() },
                        onSeekBy: { delta in audioEngine.seekBy(delta) },
                        onSetVolume: { v in audioEngine.setVolume(v) },
                        onToggleMute: { audioEngine.toggleMute() },
                        onSetPlaybackSpeed: { spd in audioEngine.setPlaybackSpeed(spd) }
                    )

                    // 6. Audio Specs DAW Inspection Grid
                    AudioSpecsInspectionGrid(
                        formatBadge: formatBadge,
                        displayCodec: displayCodecName,
                        displaySampleRate: displaySampleRate,
                        displayBitrate: displayBitrate,
                        displayChannels: displayChannels,
                        fileSize: fileSizeFormatted,
                        durationFormatted: formatTimePrecise(audioEngine.duration)
                    )
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .frame(minHeight: availableHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(animationTimer) { _ in
            if audioEngine.isPlaying {
                if rotationSpeed < 0.6 {
                    rotationSpeed = min(0.6, rotationSpeed + 0.05)
                }
            } else {
                if rotationSpeed > 0.0 {
                    rotationSpeed = max(0.0, rotationSpeed * 0.92 - 0.005)
                }
            }
            if rotationSpeed > 0.0001 {
                rotationAngle = (rotationAngle + rotationSpeed).truncatingRemainder(dividingBy: 360)
            }
        }
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
            audioEngine.load(url: url)
            MediaPlaybackCoordinator.shared.registerSession(
                id: sessionId,
                isPlaying: audioEngine.isPlaying,
                togglePlayPause: {
                    audioEngine.togglePlayPause()
                },
                seekBy: { delta in
                    audioEngine.seekBy(delta)
                }
            )
        }
        .onChange(of: url) { _, newURL in
            setupTrackMetadata()
            audioEngine.load(url: newURL)
        }
        .onChange(of: audioEngine.isPlaying) { _, playing in
            MediaPlaybackCoordinator.shared.updatePlaybackState(id: sessionId, isPlaying: playing)
        }
        .onDisappear {
            MediaPlaybackCoordinator.shared.unregisterSession(id: sessionId)
            audioEngine.pause()
        }
    }

    // MARK: - Track Header Section

    private var trackHeaderSection: some View {
        VStack(spacing: 5) {
            Text(displayTitle)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if let subtitle = displaySubtitle {
                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 24)
            }

            HStack(spacing: 6) {
                Text(formatBadge)
                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(TTZipTheme.bambooGreen.opacity(0.14))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(TTZipTheme.bambooGreen.opacity(0.35), lineWidth: 0.8))

                if isLossless {
                    Text("LOSSLESS")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(TTZipTheme.kintsugiGold.opacity(0.14))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(TTZipTheme.kintsugiGold.opacity(0.35), lineWidth: 0.8))
                }

                if displayBitrate != "--" && !displayBitrate.isEmpty {
                    Text(displayBitrate)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(TTZipTheme.kintsugiGold.opacity(0.12))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(TTZipTheme.kintsugiGold.opacity(0.30), lineWidth: 0.8))
                }

                if !displayCodecName.isEmpty {
                    Text(displayCodecName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Fail-Fast Diagnostic Card

    @ViewBuilder
    private var diagnosticErrorCard: some View {
        if audioEngine.hasPlaybackError {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                    Text("Playback Failure (libmpv)")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                    Spacer()
                    Text(formatBadge)
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TTZipTheme.cinnabarRed.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(audioEngine.errorMessage ?? "Native microkernel failed to demux or decode audio stream.")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                HStack(spacing: 8) {
                    Button {
                        let diagnostics = """
                        [TTZip Audio Diagnostics]
                        File: \(fileName)
                        Path: \(url.path)
                        Format: \(formatBadge)
                        Engine: libmpv native core
                        Error: \(audioEngine.errorMessage ?? "Unknown decoding error")
                        """
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics, forType: .string)
                        copySuccessToast = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copySuccessToast = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copySuccessToast ? "checkmark" : "doc.on.doc")
                            Text(copySuccessToast ? "Copied" : "Copy Diagnostics")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(TTZipTheme.kintsugiGold)

                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Open with External App")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        audioEngine.load(url: url)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TTZipTheme.bambooGreen)
                }
            }
            .padding(10)
            .background(TTZipTheme.cinnabarRed.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(TTZipTheme.cinnabarRed.opacity(0.35), lineWidth: 1.0)
            )
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Audio Metadata Setup

    private func setupTrackMetadata() {
        let ext = url.pathExtension.lowercased()
        var estimatedBitrate: Int = 320_000
        var defaultSR = "44.1 kHz"
        var defaultCH = "Stereo"
        var codecTitle = "\(ext.uppercased()) Audio Stream"

        switch ext {
        case "ape":
            codecTitle = "Monkey's Audio Lossless"
            defaultSR = "44.1 kHz"
            estimatedBitrate = 850_000
        case "flac":
            codecTitle = "FLAC Lossless Audio"
            defaultSR = "44.1 kHz"
            estimatedBitrate = 900_000
        case "dts":
            codecTitle = "DTS Digital Surround"
            defaultSR = "48.0 kHz"
            defaultCH = "5.1 Surround"
            estimatedBitrate = 1_509_000
        case "opus":
            codecTitle = "Opus Interactive Audio"
            defaultSR = "48.0 kHz"
            estimatedBitrate = 160_000
        case "ogg":
            codecTitle = "Ogg Vorbis Stream"
            defaultSR = "48.0 kHz"
            estimatedBitrate = 256_000
        case "mp3":
            codecTitle = "MPEG-1 Layer III"
            defaultSR = "44.1 kHz"
            estimatedBitrate = 320_000
        case "m4a", "aac":
            codecTitle = "Advanced Audio Coding"
            defaultSR = "44.1 kHz"
            estimatedBitrate = 256_000
        case "wav":
            codecTitle = "Linear PCM Audio"
            defaultSR = "44.1 kHz"
            estimatedBitrate = 1_411_200
        case "aiff", "aifc":
            codecTitle = "Audio Interchange Format"
            defaultSR = "44.1 kHz"
            estimatedBitrate = 1_411_200
        case "alac", "m4b":
            codecTitle = "Apple Lossless (ALAC)"
            defaultSR = "44.1 kHz"
            estimatedBitrate = 950_000
        case "wma":
            codecTitle = "Windows Media Audio"
            defaultSR = "44.1 kHz"
            estimatedBitrate = 192_000
        case "caf":
            codecTitle = "CoreAudio Format"
            defaultSR = "48.0 kHz"
            estimatedBitrate = 1_411_200
        case "dsf", "dff":
            codecTitle = "Direct Stream Digital (DSD)"
            defaultSR = "2.8224 MHz"
            estimatedBitrate = 5_644_800
        case "wv":
            codecTitle = "WavPack Lossless Audio"
            defaultSR = "44.1 kHz"
            estimatedBitrate = 800_000
        case "mid", "midi":
            codecTitle = "MIDI Synthesized Audio"
            defaultSR = "Synthesized"
            defaultCH = "Multi-Track"
            estimatedBitrate = 128_000
        case "mka":
            codecTitle = "Matroska Audio Container"
            defaultSR = "48.0 kHz"
            estimatedBitrate = 320_000
        default:
            codecTitle = "\(ext.uppercased()) Audio Stream"
        }

        self.defaultCodecName = codecTitle
        self.defaultSampleRate = defaultSR
        self.defaultChannels = defaultCH
        self.defaultBitrate = String(format: "%.0f kbps", Double(estimatedBitrate) / 1000.0)

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let s = attrs[.size] as? Int64 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useAll]
            formatter.countStyle = .file
            self.fileSizeFormatted = formatter.string(fromByteCount: s)
        }

        // Asynchronous album cover art & audio tag metadata probe
        let currentURL = self.url
        Task {
            if let meta = try? await TTZipAudioPlaybackService.shared.probeMetadata(url: currentURL) {
                await MainActor.run {
                    if let t = meta.title, !t.isEmpty { self.audioTitle = t }
                    if let a = meta.artist, !a.isEmpty { self.audioArtist = a }
                    if let alb = meta.album, !alb.isEmpty { self.audioAlbum = alb }
                    if let cover = meta.coverArt, let img = NSImage(data: cover.data) {
                        self.albumArtImage = img
                    }
                }
            } else if let cover = try? await TTZipAudioPlaybackService.shared.extractCoverArt(url: currentURL),
                      let img = NSImage(data: cover.data) {
                await MainActor.run {
                    self.albumArtImage = img
                }
            } else {
                await MainActor.run {
                    self.albumArtImage = nil
                }
            }
        }
    }

    private func formatTimePrecise(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00.00" }
        let totalSec = Int(seconds)
        let mins = totalSec / 60
        let secs = totalSec % 60
        let centis = Int((seconds - Double(totalSec)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, centis)
    }
}
