// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore

/// Zen minimalist floating control bar with glassmorphic styling, precision scrubbing, track selectors, and volume control.
public struct MPVVideoControlBarView: View {
    @ObservedObject public var store: MPVMetalPlayerStore
    public let onToggleFullScreen: () -> Void
    public let onOpenExternal: () -> Void
    
    @State private var isVolumeHovered: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0
    
    public init(
        store: MPVMetalPlayerStore,
        onToggleFullScreen: @escaping () -> Void = {},
        onOpenExternal: @escaping () -> Void = {}
    ) {
        self.store = store
        self.onToggleFullScreen = onToggleFullScreen
        self.onOpenExternal = onOpenExternal
    }
    
    private var displayTime: Double {
        isScrubbing ? scrubTime : store.currentTime
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            // MARK: - Play / Pause Toggle
            Button(action: { store.togglePlayPause() }) {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.isPlaying ? "Pause (Space)" : "Play (Space)")
            
            // MARK: - Precise Time Indicator
            Text("\(formatTime(displayTime)) / \(formatTime(store.duration))")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
            
            // MARK: - Microsecond/Fractional Precision Timeline Slider
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track Background
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)
                    
                    // Progress Fill
                    Capsule()
                        .fill(TTZipTheme.bambooGreen)
                        .frame(width: progressWidth(totalWidth: geo.size.width), height: 4)
                    
                    // Scrubbing Thumb Knob
                    Circle()
                        .fill(Color.white)
                        .frame(width: isScrubbing ? 12 : 8, height: isScrubbing ? 12 : 8)
                        .shadow(color: Color.black.opacity(0.4), radius: 3, x: 0, y: 1)
                        .offset(x: max(0, min(progressWidth(totalWidth: geo.size.width) - (isScrubbing ? 6 : 4), geo.size.width - 8)))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            let progress = max(0.0, min(1.0, value.location.x / max(geo.size.width, 1.0)))
                            scrubTime = progress * max(store.duration, 0.1)
                        }
                        .onEnded { value in
                            let progress = max(0.0, min(1.0, value.location.x / max(geo.size.width, 1.0)))
                            let targetTime = progress * max(store.duration, 0.1)
                            store.seek(to: targetTime)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 16)
            
            // MARK: - Audio Track Selector Menu
            Menu {
                if store.audioTracks.isEmpty {
                    Text("Default Track (Direct Output)")
                } else {
                    ForEach(store.audioTracks) { track in
                        Button(action: { store.selectAudioTrack(track) }) {
                            HStack {
                                if store.selectedAudioTrackId == track.id {
                                    Image(systemName: "checkmark")
                                }
                                Text("\(track.title) (\(track.codec.uppercased()) [\(track.language.uppercased())])")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.audioTracks.isEmpty ? Color.white.opacity(0.6) : TTZipTheme.kintsugiGold)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Audio Track Selector")
            
            // MARK: - ASS / SRT Subtitle Track Selector Menu
            Menu {
                Button(action: { store.selectSubtitleTrack(nil) }) {
                    HStack {
                        if store.selectedSubtitleTrackId == nil {
                            Image(systemName: "checkmark")
                        }
                        Text("Subtitles Off")
                    }
                }
                Divider()
                ForEach(store.subtitleTracks) { sub in
                    Button(action: { store.selectSubtitleTrack(sub) }) {
                        HStack {
                            if store.selectedSubtitleTrackId == sub.id {
                                Image(systemName: "checkmark")
                            }
                            Text("[\(sub.format)] \(sub.title) (\(sub.language))")
                        }
                    }
                }
            } label: {
                Image(systemName: store.selectedSubtitleTrackId != nil ? "captions.bubble.fill" : "captions.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.selectedSubtitleTrackId != nil ? TTZipTheme.bambooGreen : Color.white.opacity(0.8))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("ASS/SRT Subtitle Selector")
            
            // MARK: - Volume & Mute Controls
            HStack(spacing: 4) {
                Button(action: { store.toggleMute() }) {
                    Image(systemName: volumeIconName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(store.isMuted ? Color.red.opacity(0.9) : .white)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(store.isMuted ? "Unmute" : "Mute")
                
                Slider(
                    value: Binding(
                        get: { store.isMuted ? 0.0 : store.volume },
                        set: { newVal in store.setVolume(newVal) }
                    ),
                    in: 0.0...1.0
                )
                .frame(width: 54)
                .tint(TTZipTheme.bambooGreen)
                .controlSize(.mini)
            }
            
            // MARK: - Fullscreen Toggle
            Button(action: { onToggleFullScreen() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Toggle Full Screen (F / Double Click)")
            
            // MARK: - Open in External Player
            Button(action: { onOpenExternal() }) {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Open in External Player (IINA/VLC/QuickTime)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.85))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 4)
    }
    
    private var volumeIconName: String {
        if store.isMuted || store.volume == 0 {
            return "speaker.slash.fill"
        } else if store.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if store.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
    
    private func progressWidth(totalWidth: CGFloat) -> CGFloat {
        guard store.duration > 0 else { return 0 }
        let progress = displayTime / store.duration
        return max(0, min(CGFloat(progress) * totalWidth, totalWidth))
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let totalSecs = Int(seconds)
        let hours = totalSecs / 3600
        let minutes = (totalSecs % 3600) / 60
        let secs = totalSecs % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}
