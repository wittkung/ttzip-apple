// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import AVFoundation
import Metal
import QuartzCore
import TTZipCore

/// Masterpiece video player viewport supporting native AVKit hardware playback and Rust-demuxed Zen Cinema Deck.
public struct MPVMetalVideoPlayerView: View {
    public let url: URL
    
    @StateObject private var store = MPVMetalPlayerStore()
    @State private var isHovering: Bool = false
    @State private var hideTimer: Timer? = nil
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    public init(url: URL) {
        self.url = url
    }
    
    private var isChinese: Bool {
        l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
    }
    
    public var body: some View {
        ZStack(alignment: .center) {
            Color.black.ignoresSafeArea()
            
            if store.hasDecoderLimitation {
                // Non-native Matroska/WebM/AVI container: Elegant Zen Cinema Deck
                ZenCinemaDeckView(url: url, store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let player = store.player {
                // Native Apple Silicon AVPlayer hardware viewport
                AVPlayerLayerContainerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(count: 2) {
                        toggleFullScreen()
                    }
                    .onTapGesture(count: 1) {
                        store.togglePlayPause()
                    }
                
                // Top-right Sleek Actions
                if isHovering {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: { toggleFullScreen() }) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(7)
                                    .background(.ultraThinMaterial.opacity(0.8))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(isChinese ? "进入全屏预览 (F)" : "Enter Full Screen")
                        }
                        .padding(10)
                        Spacer()
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
                
                // Bottom Ultra-Sleek Zen Floating Controls
                if isHovering || !store.isPlaying {
                    VStack {
                        Spacer()
                        MPVVideoControlBarView(
                            store: store,
                            onToggleFullScreen: { toggleFullScreen() },
                            onOpenExternal: { NSWorkspace.shared.open(url) }
                        )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovering = true
                resetHideTimer()
            case .ended:
                isHovering = false
            }
        }
        .onAppear {
            store.setup(url: url)
        }
        .onChange(of: url) { _, newURL in
            store.setup(url: newURL)
        }
        .onDisappear {
            hideTimer?.invalidate()
            hideTimer = nil
            store.cleanUp()
        }
    }
    
    private func toggleFullScreen() {
        if FullScreenMediaWindowController.shared.isPresenting {
            FullScreenMediaWindowController.shared.dismiss()
        } else {
            FullScreenMediaWindowController.shared.present(view: AnyView(self))
        }
    }
    
    private func resetHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.2)) {
                    if store.isPlaying { isHovering = false }
                }
            }
        }
    }
}

/// High-aesthetic WSJ Editorial grade Zen media preview deck for extended containers (MKV, WebM, AVI, FLV, TS).
public struct ZenCinemaDeckView: View {
    public let url: URL
    @ObservedObject public var store: MPVMetalPlayerStore
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    public init(url: URL, store: MPVMetalPlayerStore) {
        self.url = url
        self.store = store
    }
    
    private var isChinese: Bool {
        l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
    }
    
    private var fileSizeString: String {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attr[.size] as? Int64 else {
            return "--"
        }
        return l10n.formatBytes(size)
    }
    
    private var containerPill: String {
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "VIDEO" : ext
    }
    
    private var videoSpecString: String {
        if let videoTrack = store.demuxSummary?.tracks.first(where: { $0.trackType == .video }) {
            var parts: [String] = []
            if let w = videoTrack.width, let h = videoTrack.height {
                if w >= 3800 || h >= 2100 { parts.append("4K UHD (\(w)×\(h))") }
                else if w >= 1900 || h >= 1000 { parts.append("1080p FHD (\(w)×\(h))") }
                else { parts.append("\(w)×\(h)") }
            }
            if !videoTrack.codec.isEmpty { parts.append(videoTrack.codec.uppercased()) }
            return parts.joined(separator: " · ")
        }
        let upper = url.lastPathComponent.uppercased()
        if upper.contains("2160P") || upper.contains("4K") { return "4K UHD · HEVC / H.265" }
        if upper.contains("1080P") { return "1080p FHD · AVC / H.264" }
        return "\(containerPill) Video Stream"
    }
    
    private var audioSpecString: String {
        if let audioTrack = store.demuxSummary?.tracks.first(where: { $0.trackType == .audio }) {
            var parts: [String] = []
            if let title = audioTrack.title, !title.isEmpty { parts.append(title) }
            if !audioTrack.codec.isEmpty { parts.append(audioTrack.codec.uppercased()) }
            if let ch = audioTrack.channels {
                parts.append(ch >= 6 ? "5.1 Surround" : "\(ch) Channels")
            }
            return parts.joined(separator: " · ")
        }
        let upper = url.lastPathComponent.uppercased()
        if upper.contains("DDP5.1") || upper.contains("5.1") { return "Dolby Digital Plus 5.1" }
        return isChinese ? "标准音频流" : "Standard Audio Stream"
    }
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                // Top Hero Badge & Filename
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(containerPill)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(TTZipTheme.kintsugiGold.opacity(0.15))
                            .clipShape(Capsule())
                        
                        Text(fileSizeString)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(TTZipTheme.bambooGreen.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 14)
                }
                .padding(.top, 16)
                
                // Primary Action Button (Instant One-Click Playback)
                Button(action: { NSWorkspace.shared.open(url) }) {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(isChinese ? "在默认播放器中播放 (IINA/VLC/QuickTime)" : "Play in Default Player")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(TTZipTheme.bambooGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                
                // Secondary Quick Actions
                HStack(spacing: 8) {
                    Button(action: { QuickLookPreviewCoordinator.shared.previewDiskFile(url: url) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 10))
                            Text(isChinese ? "快速查看 (Space)" : "Quick Look")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "") }) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                            Text(isChinese ? "在访达中显示" : "Reveal")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                
                // Rust Demuxed Media Specifications Card
                VStack(alignment: .leading, spacing: 6) {
                    Text(isChinese ? "媒体规格与流信息" : "Stream Specifications")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .textCase(.uppercase)
                    
                    VStack(spacing: 3) {
                        specRow(icon: "video.fill", title: isChinese ? "视频流" : "Video", value: videoSpecString)
                        specRow(icon: "waveform", title: isChinese ? "音频流" : "Audio", value: audioSpecString)
                        if !store.subtitleTracks.isEmpty {
                            specRow(icon: "captions.bubble.fill", title: isChinese ? "字幕" : "Subtitles", value: "\(store.subtitleTracks.count) \(isChinese ? "条内嵌/伴随字幕" : "Tracks")")
                        }
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity)
        }
    }
    
    private func specRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(TTZipTheme.kintsugiGold)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

