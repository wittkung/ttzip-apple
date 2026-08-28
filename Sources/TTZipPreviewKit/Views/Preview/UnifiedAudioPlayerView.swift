// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// Masterpiece Hi-Fi Audio Player View powered by native libmpv engine.
/// Supports universal lossless & spatial audio decoding (APE, FLAC, DTS, Opus, Ogg, MP3, M4A, WAV, AIFF, ALAC, etc.)
/// with vinyl record physics animation, 1600-bin DAW waveform scrubbing, and real-time audio spec telemetry.
public struct UnifiedAudioPlayerView: View {
    public let url: URL
    public let fileName: String
    
    @StateObject private var store = MPVMetalPlayerStore()
    @State private var rotationAngle: Double = 0
    @State private var isHovering = false
    @State private var sessionId = UUID().uuidString
    @State private var fileSizeFormatted: String = ""
    @State private var defaultCodecName: String = ""
    @State private var defaultBitrate: String = "--"
    @State private var defaultSampleRate: String = "--"
    @State private var defaultChannels: String = "--"
    
    private let animationTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    
    public init(url: URL, fileName: String) {
        self.url = url
        self.fileName = fileName
    }
    
    public var formatBadge: String {
        url.pathExtension.uppercased()
    }
    
    private var displayCodecName: String {
        if !store.audioCodecFormatted.isEmpty {
            return store.audioCodecFormatted
        }
        return defaultCodecName
    }
    
    private var displayBitrate: String {
        if !store.audioBitrateFormatted.isEmpty {
            return store.audioBitrateFormatted
        }
        return defaultBitrate
    }
    
    private var displaySampleRate: String {
        if store.audioSampleRate != "--" && !store.audioSampleRate.isEmpty {
            return store.audioSampleRate
        }
        return defaultSampleRate
    }
    
    private var displayChannels: String {
        if store.audioChannels != "--" && !store.audioChannels.isEmpty {
            return store.audioChannels
        }
        return defaultChannels
    }
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 18) {
                // 1. Vinyl Record Disc with dynamic rotation and ambient glow
                vinylDiscSection
                
                // 2. Track Title & Format Badge
                trackHeaderSection
                
                // 3. Dynamic 1600-point Sound Wave Visualizer with Microsecond Scrubber
                AudioWaveformVisualizerView(
                    url: url,
                    isPlaying: store.isPlaying,
                    currentTime: store.currentTime,
                    duration: store.duration,
                    sampleCount: 1600,
                    onSeek: { targetSeconds in
                        store.seek(to: targetSeconds)
                    }
                )
                .padding(.horizontal, 16)
                
                // 4. Playback Controls Bar
                playbackControlsSection
                
                // 5. Audio Specs DAW Inspection Grid
                audioSpecsSection
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .onReceive(animationTimer) { _ in
            if store.isPlaying {
                rotationAngle = (rotationAngle + 0.6).truncatingRemainder(dividingBy: 360)
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
            setupPlayer()
            MediaPlaybackCoordinator.shared.registerSession(
                id: sessionId,
                isPlaying: store.isPlaying,
                togglePlayPause: {
                    store.togglePlayPause()
                },
                seekBy: { delta in
                    store.seekBy(delta)
                }
            )
        }
        .onChange(of: url) { _, _ in
            setupPlayer()
        }
        .onChange(of: store.isPlaying) { _, playing in
            MediaPlaybackCoordinator.shared.updatePlaybackState(id: sessionId, isPlaying: playing)
        }
        .onDisappear {
            MediaPlaybackCoordinator.shared.unregisterSession(id: sessionId)
            cleanUpPlayer()
        }
    }
    
    // MARK: - Vinyl Record Disc View
    
    private var vinylDiscSection: some View {
        ZStack {
            // 1. Ambient Glow Halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            store.isPlaying ? TTZipTheme.bambooGreen.opacity(0.38) : TTZipTheme.kintsugiGold.opacity(0.18),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 105
                    )
                )
                .frame(width: 200, height: 200)
                .blur(radius: store.isPlaying ? 14 : 7)
            
            // 2. Vinyl Record Disc (152x152)
            ZStack {
                // Disc body
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.07, green: 0.08, blue: 0.09),
                                Color(red: 0.16, green: 0.17, blue: 0.19),
                                Color(red: 0.05, green: 0.06, blue: 0.07)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 152, height: 152)
                    .shadow(color: Color.black.opacity(0.5), radius: 12, x: 0, y: 6)
                
                // Realistic groove tracks
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 1.2).frame(width: 138, height: 138)
                Circle().stroke(Color.white.opacity(0.06), lineWidth: 1.0).frame(width: 124, height: 124)
                Circle().stroke(Color.white.opacity(0.05), lineWidth: 1.0).frame(width: 110, height: 110)
                Circle().stroke(Color.white.opacity(0.06), lineWidth: 1.0).frame(width: 96, height: 96)
                Circle().stroke(TTZipTheme.kintsugiGold.opacity(0.25), lineWidth: 1.0).frame(width: 82, height: 82)
                Circle().stroke(Color.white.opacity(0.05), lineWidth: 0.8).frame(width: 68, height: 68)
                
                // Luster reflection cross
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                Color.white.opacity(0.06),
                                Color.clear,
                                Color.white.opacity(0.06),
                                Color.clear,
                                Color.white.opacity(0.06),
                                Color.clear,
                                Color.white.opacity(0.06),
                                Color.clear
                            ],
                            center: .center
                        )
                    )
                    .frame(width: 148, height: 148)
                
                // 3. Center Vinyl Label (48x48)
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    TTZipTheme.bambooGreen,
                                    TTZipTheme.kintsugiGold
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1.0)
                        )
                        .shadow(color: TTZipTheme.bambooGreen.opacity(0.4), radius: 6)
                    
                    // Spindle Hole
                    Circle()
                        .fill(Color(red: 0.05, green: 0.06, blue: 0.07))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .strokeBorder(TTZipTheme.kintsugiGold.opacity(0.6), lineWidth: 1.0)
                        )
                    
                    Image(systemName: store.isPlaying ? "wave.3.forward" : "music.note")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: Color.black.opacity(0.3), radius: 2)
                }
            }
            .rotationEffect(.degrees(rotationAngle))
        }
        .padding(.top, 10)
    }
    
    // MARK: - Track Header Section
    
    private var trackHeaderSection: some View {
        VStack(spacing: 6) {
            Text(fileName)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            HStack(spacing: 6) {
                Text(formatBadge)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(TTZipTheme.bambooGreen.opacity(0.14))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(TTZipTheme.bambooGreen.opacity(0.35), lineWidth: 0.8))
                
                if displayBitrate != "--" && !displayBitrate.isEmpty {
                    Text(displayBitrate)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(TTZipTheme.kintsugiGold.opacity(0.14))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(TTZipTheme.kintsugiGold.opacity(0.35), lineWidth: 0.8))
                }
                
                if !displayCodecName.isEmpty {
                    Text(displayCodecName)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Capsule())
                }
            }
        }
    }
    
    // MARK: - Playback Controls Section
    
    private var playbackControlsSection: some View {
        VStack(spacing: 14) {
            HStack(spacing: 32) {
                Button {
                    store.seekBy(-15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help("Rewind 15 seconds")
                
                Button {
                    store.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        TTZipTheme.bambooGreen,
                                        Color(red: 0.15, green: 0.65, blue: 0.45)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 52, height: 52)
                            .shadow(color: TTZipTheme.bambooGreen.opacity(0.4), radius: store.isPlaying ? 10 : 4)
                        
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: store.isPlaying ? 0 : 2)
                    }
                }
                .buttonStyle(.plain)
                
                Button {
                    store.seekBy(15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help("Forward 15 seconds")
            }
            
            // Volume & Mute Control
            HStack(spacing: 10) {
                Button {
                    store.toggleMute()
                } label: {
                    Image(systemName: store.isMuted ? "speaker.slash.fill" : (store.volume > 0.5 ? "speaker.wave.3.fill" : "speaker.wave.1.fill"))
                        .font(.system(size: 11))
                        .foregroundStyle(store.isMuted ? TTZipTheme.cinnabarRed : Color.secondary)
                }
                .buttonStyle(.plain)
                
                Slider(
                    value: Binding(
                        get: { store.volume },
                        set: { store.setVolume($0) }
                    ),
                    in: 0...1
                )
                .tint(TTZipTheme.bambooGreen.opacity(0.7))
                .frame(width: 100)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.025))
            .clipShape(Capsule())
        }
    }
    
    // MARK: - Audio Specs DAW Inspection Grid
    
    private var audioSpecsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Audio Specs", systemImage: "waveform.circle.fill")
                .font(.system(size: 11.5, weight: .bold, design: .serif))
                .foregroundStyle(TTZipTheme.kintsugiGold)
            
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    audioMetaTag(title: "Format", value: formatBadge)
                    audioMetaTag(title: "Sample Rate", value: displaySampleRate)
                }
                GridRow {
                    audioMetaTag(title: "Bitrate", value: displayBitrate)
                    audioMetaTag(title: "Channels", value: displayChannels)
                }
                GridRow {
                    audioMetaTag(title: "File Size", value: fileSizeFormatted.isEmpty ? "--" : fileSizeFormatted)
                    audioMetaTag(title: "Duration", value: formatTimePrecise(store.duration))
                }
                GridRow {
                    audioMetaTag(title: "Audio Engine", value: "libmpv Hi-Fi Core")
                    audioMetaTag(title: "Waveform Bins", value: "1600 Samples")
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
        .padding(.horizontal, 16)
    }
    
    private func audioMetaTag(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    // MARK: - Audio Player Engine Setup & Teardown
    
    private func setupPlayer() {
        cleanUpPlayer()
        
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
        
        // Launch native libmpv engine in pure audio mode
        store.setup(url: url, isAudioOnly: true)
    }
    
    private func cleanUpPlayer() {
        store.cleanUp()
    }
    
    private func formatTimePrecise(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00.00" }
        let totalSec = Int(seconds)
        let mins = totalSec / 60
        let secs = totalSec % 60
        let centis = Int((seconds - Double(totalSec)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, centis)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let secs = Int(seconds)
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }
}

