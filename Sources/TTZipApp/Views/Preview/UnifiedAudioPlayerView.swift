// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AVFoundation
import TTZipCore

public struct UnifiedAudioPlayerView: View {
    public let url: URL
    public let fileName: String
    
    @State var player: AVPlayer? = nil
    @State var isPlaying = false
    @State var currentTime: Double = 0
    @State var duration: Double = 0
    @State var isEditingSlider = false
    @State var timeObserverToken: Any? = nil
    @State var statusObservation: NSKeyValueObservation? = nil
    @State var failureObserverToken: Any? = nil
    @State var metadataTask: Task<Void, Never>? = nil
    @State var rotationAngle: Double = 0
    @State var volume: Double = 1.0
    @State var isMuted: Bool = false
    
    @State var audioBitrate: String = "Analyzing..."
    @State var audioSampleRate: String = "--"
    @State var audioChannels: String = "--"
    @State var audioCodecName: String = ""
    @State var fileSizeFormatted: String = ""
    @State var sessionId = UUID().uuidString
    @State var isHovering = false
    @State var isDecoderSimulated = false
    
    private let animationTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    
    public init(url: URL, fileName: String) {
        self.url = url
        self.fileName = fileName
    }
    
    var formatBadge: String {
        url.pathExtension.uppercased()
    }
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 18) {
                // 1. Vinyl Record Disc with dynamic rotation and ambient glow
                vinylDiscSection
                
                // 2. Track Title & Format Badge
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
                        
                        if !audioBitrate.contains("Analyzing") && !audioBitrate.isEmpty {
                            Text(audioBitrate)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(TTZipTheme.kintsugiGold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(TTZipTheme.kintsugiGold.opacity(0.14))
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(TTZipTheme.kintsugiGold.opacity(0.35), lineWidth: 0.8))
                        }
                        
                        if !audioCodecName.isEmpty {
                            Text(audioCodecName)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(Capsule())
                        }
                    }
                }
                
                // 3. Dynamic 1600-point Sound Wave Visualizer with Microsecond Scrubber
                AudioWaveformVisualizerView(
                    url: url,
                    isPlaying: isPlaying,
                    currentTime: currentTime,
                    duration: duration,
                    sampleCount: 1600,
                    onSeek: { targetSeconds in
                        currentTime = targetSeconds
                        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 60000)
                        player?.seek(to: targetTime)
                    }
                )
                .padding(.horizontal, 16)
                
                // 4. Playback Controls Bar
                VStack(spacing: 14) {
                    HStack(spacing: 32) {
                        Button {
                            seekBy(-15)
                        } label: {
                            Image(systemName: "gobackward.15")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .help("Rewind 15 seconds")
                        
                        Button {
                            togglePlayPause()
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
                                    .shadow(color: TTZipTheme.bambooGreen.opacity(0.4), radius: isPlaying ? 10 : 4)
                                
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: isPlaying ? 0 : 2)
                            }
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            seekBy(15)
                        } label: {
                            Image(systemName: "goforward.15")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .help("Forward 15 seconds")
                    }
                    
                    // Volume Control
                    HStack(spacing: 10) {
                        Button {
                            isMuted.toggle()
                            player?.isMuted = isMuted
                        } label: {
                            Image(systemName: isMuted ? "speaker.slash.fill" : (volume > 0.5 ? "speaker.wave.3.fill" : "speaker.wave.1.fill"))
                                .font(.system(size: 11))
                                .foregroundStyle(isMuted ? TTZipTheme.cinnabarRed : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        
                        Slider(value: $volume, in: 0...1) { _ in
                            player?.volume = Float(volume)
                            if volume > 0 && isMuted {
                                isMuted = false
                                player?.isMuted = false
                            }
                        }
                        .tint(TTZipTheme.bambooGreen.opacity(0.7))
                        .frame(width: 100)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.025))
                    .clipShape(Capsule())
                }
                
                // 5. Audio Specs DAW Inspection Grid
                VStack(alignment: .leading, spacing: 10) {
                    Label("Audio Specs", systemImage: "waveform.circle.fill")
                        .font(.system(size: 11.5, weight: .bold, design: .serif))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                    
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            audioMetaTag(title: "Format", value: formatBadge)
                            audioMetaTag(title: "Sample Rate", value: audioSampleRate)
                        }
                        GridRow {
                            audioMetaTag(title: "Bitrate", value: audioBitrate)
                            audioMetaTag(title: "Channels", value: audioChannels)
                        }
                        GridRow {
                            audioMetaTag(title: "File Size", value: fileSizeFormatted.isEmpty ? "--" : fileSizeFormatted)
                            audioMetaTag(title: "Duration", value: formatTimePrecise(duration))
                        }
                        GridRow {
                            audioMetaTag(title: "Audio Engine", value: isDecoderSimulated ? "Embedded Bitstream" : "CoreAudio Native")
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
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .onReceive(animationTimer) { _ in
            if isPlaying {
                rotationAngle = (rotationAngle + 0.6).truncatingRemainder(dividingBy: 360)
                
                if isDecoderSimulated && duration > 0 {
                    if !isEditingSlider {
                        let nextTime = currentTime + (1.0 / 60.0)
                        if nextTime >= duration {
                            currentTime = 0
                            isPlaying = false
                        } else {
                            currentTime = nextTime
                        }
                    }
                }
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
                isPlaying: isPlaying,
                togglePlayPause: {
                    togglePlayPause()
                },
                seekBy: { delta in
                    seekBy(delta)
                }
            )
        }
        .onChange(of: url) { _, _ in
            setupPlayer()
        }
        .onChange(of: isPlaying) { _, playing in
            MediaPlaybackCoordinator.shared.updatePlaybackState(id: sessionId, isPlaying: playing)
        }
        .onDisappear {
            MediaPlaybackCoordinator.shared.unregisterSession(id: sessionId)
            cleanUpPlayer()
        }
    }
    
    // MARK: - Vinyl Record View
    
    private var vinylDiscSection: some View {
        ZStack {
            // 1. Ambient Glow Halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            isPlaying ? TTZipTheme.bambooGreen.opacity(0.38) : TTZipTheme.kintsugiGold.opacity(0.18),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 105
                    )
                )
                .frame(width: 200, height: 200)
                .blur(radius: isPlaying ? 14 : 7)
            
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
                    
                    Image(systemName: isPlaying ? "wave.3.forward" : "music.note")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: Color.black.opacity(0.3), radius: 2)
                }
            }
            .rotationEffect(.degrees(rotationAngle))
        }
        .padding(.top, 10)
    }
}
