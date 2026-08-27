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
        HStack(spacing: 8) {
            // MARK: - Play / Pause Toggle
            Button(action: { store.togglePlayPause() }) {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.isPlaying ? "Pause (Space)" : "Play (Space)")
            
            // MARK: - Precise Time Indicator
            Text("\(formatTime(displayTime)) / \(formatTime(store.duration))")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            
            // MARK: - Microsecond/Fractional Precision Timeline Slider
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track Background
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 3)
                    
                    // Progress Fill
                    Capsule()
                        .fill(TTZipTheme.bambooGreen)
                        .frame(width: progressWidth(totalWidth: geo.size.width), height: 3)
                    
                    // Scrubbing Thumb Knob
                    Circle()
                        .fill(Color.white)
                        .frame(width: isScrubbing ? 8 : 6, height: isScrubbing ? 8 : 6)
                        .shadow(color: Color.black.opacity(0.4), radius: 2, x: 0, y: 1)
                        .offset(x: max(0, min(progressWidth(totalWidth: geo.size.width) - (isScrubbing ? 4 : 3), geo.size.width - 6)))
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
            .frame(height: 12)
            
            // MARK: - Audio Track Selector Menu
            if !store.audioTracks.isEmpty {
                Menu {
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
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Audio Track Selector")
            }
            
            // MARK: - ASS / SRT Subtitle Track Selector Menu
            if !store.subtitleTracks.isEmpty {
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
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(store.selectedSubtitleTrackId != nil ? TTZipTheme.bambooGreen : Color.white.opacity(0.8))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Subtitle Selector")
            }
            
            // MARK: - Fullscreen Toggle
            Button(action: { onToggleFullScreen() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Toggle Full Screen")
            
            // MARK: - Open in External Player
            Button(action: { onOpenExternal() }) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Open in Default Player (IINA/VLC/QuickTime)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial.opacity(0.8))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 2)

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
