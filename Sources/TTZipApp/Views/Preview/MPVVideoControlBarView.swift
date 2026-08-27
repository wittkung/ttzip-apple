// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore

/// Zen minimalist floating control bar with glassmorphic styling, precision scrubbing, track selectors, subtitle delay stepper, and HDR status.
public struct MPVVideoControlBarView: View {
    @ObservedObject public var store: MPVMetalPlayerStore
    public let onToggleFullScreen: () -> Void
    public let onOpenExternal: () -> Void
    
    @State private var isVolumeHovered: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    public init(
        store: MPVMetalPlayerStore,
        onToggleFullScreen: @escaping () -> Void = {},
        onOpenExternal: @escaping () -> Void = {}
    ) {
        self.store = store
        self.onToggleFullScreen = onToggleFullScreen
        self.onOpenExternal = onOpenExternal
    }
    
    private var isChinese: Bool {
        l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
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
            .help(store.isPlaying ? (isChinese ? "暂停 (空格)" : "Pause (Space)") : (isChinese ? "播放 (空格)" : "Play (Space)"))
            
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
            
            // MARK: - HDR / EDR Status Indicator Pill
            hdrStatusBadge
            
            // MARK: - Audio Track Selector Menu
            if !store.audioTracks.isEmpty {
                Menu {
                    Text(isChinese ? "音轨选择" : "Audio Tracks")
                    Divider()
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
                .help(isChinese ? "选择音频轨道" : "Select Audio Track")
            }
            
            // MARK: - Universal Dual Subtitle & Delay Selector Menu
            subtitleMenu
            
            // MARK: - Volume / Mute Toggle
            Button(action: { store.toggleMute() }) {
                Image(systemName: volumeIconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(store.isMuted ? .white.opacity(0.5) : .white.opacity(0.85))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(store.isMuted ? (isChinese ? "取消静音" : "Unmute") : (isChinese ? "静音" : "Mute"))
            
            // MARK: - Fullscreen Toggle
            Button(action: { onToggleFullScreen() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(isChinese ? "进入/退出全屏 (F)" : "Toggle Full Screen (F)")
            
            // MARK: - Open in External Player
            Button(action: { onOpenExternal() }) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(isChinese ? "在系统播放器中打开 (IINA/QuickTime)" : "Open in Default Player (IINA/QuickTime)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial.opacity(0.85))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 2)
    }
    
    // MARK: - Subviews & Controls
    
    @ViewBuilder
    private var hdrStatusBadge: some View {
        let metrics = store.edrMetrics
        if metrics.isHDRActive || metrics.hdrFormat.isHDR {
            HStack(spacing: 3) {
                Circle()
                    .fill(TTZipTheme.kintsugiGold)
                    .frame(width: 5, height: 5)
                Text(metrics.hdrFormat.rawValue)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(TTZipTheme.kintsugiGold.opacity(0.15))
            .clipShape(Capsule())
            .help(isChinese ? "4K/8K XDR 渲染模式 (峰值 \(Int(metrics.peakNits)) nits)" : "XDR HDR Video (Peak \(Int(metrics.peakNits)) nits)")
        } else {
            Text("SDR")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
    }
    
    @ViewBuilder
    private var subtitleMenu: some View {
        Menu {
            // Section 1: Primary Subtitle
            Section(isChinese ? "主字幕轨道" : "Primary Subtitles") {
                Button(action: { store.selectSubtitleTrack(nil) }) {
                    HStack {
                        if store.selectedSubtitleTrackId == nil {
                            Image(systemName: "checkmark")
                        }
                        Text(isChinese ? "关闭主字幕" : "Subtitles Off")
                    }
                }
                
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
            }
            
            // Section 2: Secondary / Bilingual Subtitle
            if !store.subtitleTracks.isEmpty {
                Section(isChinese ? "次级双语字幕" : "Secondary Subtitles") {
                    Button(action: { store.selectSecondarySubtitleTrack(nil) }) {
                        HStack {
                            if store.selectedSecondarySubtitleTrackId == nil {
                                Image(systemName: "checkmark")
                            }
                            Text(isChinese ? "关闭次级字幕" : "Secondary Off")
                        }
                    }
                    
                    ForEach(store.subtitleTracks) { sub in
                        Button(action: { store.selectSecondarySubtitleTrack(sub) }) {
                            HStack {
                                if store.selectedSecondarySubtitleTrackId == sub.id {
                                    Image(systemName: "checkmark")
                                }
                                Text("[\(sub.format)] \(sub.title) (\(sub.language))")
                            }
                        }
                    }
                }
            }
            
            // Section 3: Subtitle Delay Adjustment
            Section(isChinese ? "字幕同步微调" : "Subtitle Sync") {
                Text(String(format: isChinese ? "当前延迟: %.1fs" : "Delay: %.1fs", store.subtitleDelay))
                
                Button(action: { store.setSubtitleDelay(seconds: store.subtitleDelay - 0.1) }) {
                    Label(isChinese ? "提前 0.1 秒 (-0.1s)" : "Advance 0.1s (-0.1s)", systemImage: "gobackward.minus")
                }
                
                Button(action: { store.setSubtitleDelay(seconds: store.subtitleDelay + 0.1) }) {
                    Label(isChinese ? "延迟 0.1 秒 (+0.1s)" : "Delay 0.1s (+0.1s)", systemImage: "goforward.plus")
                }
                
                if abs(store.subtitleDelay) > 0.001 {
                    Button(action: { store.setSubtitleDelay(seconds: 0.0) }) {
                        Label(isChinese ? "重置延迟 (0.0s)" : "Reset Delay (0.0s)", systemImage: "arrow.counterclockwise")
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
        .help(isChinese ? "字幕选择与同步调节" : "Subtitle & Sync Controls")
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

