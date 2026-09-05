// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TTZipCore
import TTZipUI

/// Zen minimalist two-tier floating control bar with Apple Pro styling:
/// - Tier 1: Dedicated full-width precision timeline scrubber with non-wrapping timestamps.
/// - Tier 2: Ergonomic playback transport, HDR metrics, hover volume slider, speed menu, and media tools.
public struct MPVVideoControlBarView: View {
    @ObservedObject public var store: MPVMetalPlayerStore
    public var playlistStore: MediaPlaylistStore
    public let isPlaylistOpen: Bool
    public let onTogglePlaylist: () -> Void
    public let onToggleFullScreen: () -> Void
    public let onOpenExternal: () -> Void
    
    @State private var isVolumeHovered: Bool = false
    @State private var isTimelineHovered: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0
    @State private var showRemainingTime: Bool = false
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    private let availablePlaybackSpeeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    
    public init(
        store: MPVMetalPlayerStore,
        playlistStore: MediaPlaylistStore = .shared,
        isPlaylistOpen: Bool = false,
        onTogglePlaylist: @escaping () -> Void = {},
        onToggleFullScreen: @escaping () -> Void = {},
        onOpenExternal: @escaping () -> Void = {}
    ) {
        self.store = store
        self.playlistStore = playlistStore
        self.isPlaylistOpen = isPlaylistOpen
        self.onTogglePlaylist = onTogglePlaylist
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
        VStack(spacing: 6) {
            tier1TimelineRow
            tier2ControlsRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial.opacity(0.90))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.24),
                            Color.white.opacity(0.08),
                            TTZipTheme.kintsugiGold.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: Color.black.opacity(0.42), radius: 12, x: 0, y: 3)
    }
    
    // MARK: - Tier 1: Full-Width Precision Timeline Scrubber
    
    private var tier1TimelineRow: some View {
        HStack(spacing: 8) {
            // Elapsed Current Time Label
            Text(formatTime(displayTime))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isScrubbing ? TTZipTheme.kintsugiGold : Color.white.opacity(0.9))
                .frame(minWidth: 38, alignment: .leading)
            
            // Interactive Precision Scrub Bar
            GeometryReader { geo in
                let width = geo.size.width
                let progress = store.duration > 0 ? (displayTime / store.duration) : 0.0
                let clampedProgress = max(0.0, min(1.0, progress))
                let currentTrackWidth = max(0.0, min(CGFloat(clampedProgress) * width, width))
                let trackHeight: CGFloat = (isTimelineHovered || isScrubbing) ? 4.5 : 3.0
                let knobSize: CGFloat = isScrubbing ? 11.0 : ((isTimelineHovered) ? 9.0 : 6.5)
                
                ZStack(alignment: .leading) {
                    // Track Background Trench
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(height: trackHeight)
                    
                    // Active Progress Glow Fill
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [TTZipTheme.bambooGreen.opacity(0.85), TTZipTheme.bambooGreen],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: currentTrackWidth, height: trackHeight)
                    
                    // Precision Thumb Knob
                    Circle()
                        .fill(Color.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: Color.black.opacity(0.45), radius: 2.5, x: 0, y: 1)
                        .offset(x: max(0, min(currentTrackWidth - knobSize / 2, width - knobSize)))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            let progress = max(0.0, min(1.0, value.location.x / max(width, 1.0)))
                            scrubTime = progress * max(store.duration, 0.1)
                        }
                        .onEnded { value in
                            let progress = max(0.0, min(1.0, value.location.x / max(width, 1.0)))
                            let targetTime = progress * max(store.duration, 0.1)
                            store.seek(to: targetTime)
                            isScrubbing = false
                        }
                )
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isTimelineHovered = hovering
                    }
                }
            }
            .frame(height: 12)
            
            // Remaining Time / Total Duration Toggle Button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showRemainingTime.toggle()
                }
            }) {
                Text(formattedRightTime)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .frame(minWidth: 42, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help(showRemainingTime ? (isChinese ? "显示总时长" : "Show Total Duration") : (isChinese ? "显示剩余时间" : "Show Remaining Time"))
        }
    }
    
    // MARK: - Tier 2: Controls, Status & Media Utilities
    
    private var tier2ControlsRow: some View {
        HStack(spacing: 6) {
            // MARK: Left: Core Playback Controls
            HStack(spacing: 5) {
                // Previous Episode
                Button(action: {
                    if let prevItem = playlistStore.playPrevious() {
                        store.load(url: prevItem.url)
                    }
                }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(playlistStore.hasPrevious ? Color.white.opacity(0.9) : Color.white.opacity(0.28))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!playlistStore.hasPrevious)
                .help(isChinese ? "上一集" : "Previous Episode")
                
                // Skip Backward 10 Seconds
                Button(action: { store.seekBy(-10) }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isChinese ? "快退 10 秒 (J / 左箭头)" : "Rewind 10 Seconds (J / Left Arrow)")
                
                // Play / Pause Primary Button (Featured Center-Left Circle)
                Button(action: { store.togglePlayPause() }) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 26, height: 26)
                        
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: store.isPlaying ? 0 : 0.8)
                    }
                }
                .buttonStyle(.plain)
                .help(store.isPlaying ? (isChinese ? "暂停 (空格)" : "Pause (Space)") : (isChinese ? "播放 (空格)" : "Play (Space)"))
                
                // Skip Forward 10 Seconds
                Button(action: { store.seekBy(10) }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isChinese ? "快进 10 秒 (L / 右箭头)" : "Forward 10 Seconds (L / Right Arrow)")
                
                // Next Episode
                Button(action: {
                    if let nextItem = playlistStore.playNext() {
                        store.load(url: nextItem.url)
                    }
                }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(playlistStore.hasNext ? Color.white.opacity(0.9) : Color.white.opacity(0.28))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!playlistStore.hasNext)
                .help(isChinese ? "下一集" : "Next Episode")
            }
            
            Spacer(minLength: 4)
            
            // MARK: Center: HDR / EDR Status Pill
            hdrStatusBadge
            
            Spacer(minLength: 4)
            
            // MARK: Right: Utilities & Menus
            HStack(spacing: 5) {
                // Interactive Volume Slider (Expand on Hover)
                volumeControlView
                
                // Playback Speed Selector Menu
                playbackSpeedMenuView
                
                // Universal Dual Subtitle & Delay Selector Menu
                subtitleMenu
                
                // Audio Track Selector Menu
                audioTrackMenu
                
                // Playlist Drawer Toggle
                Button(action: { onTogglePlaylist() }) {
                    Image(systemName: isPlaylistOpen ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isPlaylistOpen ? TTZipTheme.kintsugiGold : Color.white.opacity(0.82))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(isChinese ? "播放列表" : "Toggle Playlist")
                
                // Open in External Player
                Button(action: { onOpenExternal() }) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(isChinese ? "在外部应用中打开 (IINA/QuickTime)" : "Open in External App (IINA/QuickTime)")
                
                // Native Fullscreen Toggle
                Button(action: { onToggleFullScreen() }) {
                    Image(systemName: store.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(store.isFullScreen ? (isChinese ? "退出全屏 (Esc/F)" : "Exit Full Screen (Esc/F)") : (isChinese ? "全屏播放 (F)" : "Full Screen (F)"))
            }
        }
    }
    
    // MARK: - Subviews: Volume & Speed
    
    private var volumeControlView: some View {
        HStack(spacing: 3) {
            Button(action: { store.toggleMute() }) {
                Image(systemName: volumeIconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(store.isMuted ? Color.white.opacity(0.42) : Color.white.opacity(0.85))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(store.isMuted ? (isChinese ? "取消静音" : "Unmute") : (isChinese ? "静音" : "Mute"))
            
            if isVolumeHovered {
                Slider(
                    value: Binding(
                        get: { store.volume },
                        set: { store.setVolume($0) }
                    ),
                    in: 0.0...1.0
                )
                .frame(width: 50)
                .controlSize(.mini)
                .tint(TTZipTheme.bambooGreen)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.85, anchor: .leading)),
                    removal: .opacity
                ))
            }
        }
        .padding(.horizontal, 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isVolumeHovered = hovering
            }
        }
    }
    
    private var playbackSpeedMenuView: some View {
        Menu {
            Text(isChinese ? "播放速度" : "Playback Speed")
            Divider()
            ForEach(availablePlaybackSpeeds, id: \.self) { speed in
                Button(action: { store.setPlaybackSpeed(speed) }) {
                    HStack {
                        if abs(store.playbackSpeed - speed) < 0.01 {
                            Image(systemName: "checkmark")
                        }
                        Text(speed == 1.0 ? (isChinese ? "1.0× (正常)" : "1.0× (Normal)") : String(format: "%.2g×", speed))
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(store.playbackSpeed == 1.0 ? "1.0×" : String(format: "%.2g×", store.playbackSpeed))
                    .font(.system(size: 9.0, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(store.playbackSpeed != 1.0 ? TTZipTheme.kintsugiGold : Color.white.opacity(0.82))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(store.playbackSpeed != 1.0 ? TTZipTheme.kintsugiGold.opacity(0.18) : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(isChinese ? "倍速播放调节" : "Playback Speed")
    }
    
    // MARK: - Subviews: Badges & Menus
    
    @ViewBuilder
    private var hdrStatusBadge: some View {
        let metrics = store.edrMetrics
        if metrics.isHDRActive || metrics.hdrFormat.isHDR {
            HStack(spacing: 3) {
                Circle()
                    .fill(TTZipTheme.kintsugiGold)
                    .frame(width: 4.5, height: 4.5)
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
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
    }
    
    @ViewBuilder
    private var audioTrackMenu: some View {
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
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(isChinese ? "选择音频轨道" : "Select Audio Track")
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
            
            // Section 4: Add Local Subtitle File via OpenPanel
            Section {
                Button(action: { selectLocalSubtitleFile() }) {
                    Label(isChinese ? "添加本地字幕文件..." : "Add Local Subtitle File...", systemImage: "plus.circle")
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: store.selectedSubtitleTrackId != nil ? "captions.bubble.fill" : "captions.bubble")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(store.selectedSubtitleTrackId != nil ? TTZipTheme.bambooGreen : Color.white.opacity(0.82))
                    .frame(width: 18, height: 18)
                
                if store.selectedSubtitleTrackId != nil {
                    Circle()
                        .fill(TTZipTheme.bambooGreen)
                        .frame(width: 4, height: 4)
                        .offset(x: 1, y: -1)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(isChinese ? "字幕选择与同步调节" : "Subtitle & Sync Controls")
    }
    
    private func selectLocalSubtitleFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let extensions = ["srt", "ass", "ssa", "vtt", "sub", "lrc"]
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.title = isChinese ? "选择本地字幕文件" : "Select Subtitle File"
        panel.prompt = isChinese ? "加载字幕" : "Load Subtitle"
        
        if panel.runModal() == .OK, let url = panel.url {
            store.loadSubtitle(url: url, select: true)
        }
    }
    
    // MARK: - Utilities & Formatters
    
    private var formattedRightTime: String {
        if showRemainingTime {
            let remaining = max(0.0, store.duration - displayTime)
            return "-\(formatTime(remaining))"
        } else {
            return formatTime(store.duration)
        }
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
