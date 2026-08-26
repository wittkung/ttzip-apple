// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AVFoundation
import AVKit
import TTZipCore

/// Unified zero-kickout in-app video player view with hardware acceleration and Rust demuxing.
public struct UnifiedVideoPlayerView: View {
    public let url: URL
    
    @StateObject private var store = SharedVideoPlayerStore()
    @State private var isHovering = false
    @State private var hideTimer: Timer? = nil
    @State private var sessionId = UUID().uuidString
    @State private var showSpecsPopover = false
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    public init(url: URL) {
        self.url = url
    }
    
    private var isChinese: Bool {
        l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
    }
    
    private var containerBadge: String {
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "VIDEO" : ext
    }
    
    private var qualityBadges: [String] {
        var badges: [String] = []
        let upper = url.lastPathComponent.uppercased()
        
        if let videoTrack = store.demuxSummary?.tracks.first(where: { $0.trackType == .video }) {
            if let w = videoTrack.width, let h = videoTrack.height {
                if w >= 3800 || h >= 2100 {
                    badges.append("4K UHD")
                } else if w >= 1900 || h >= 1000 {
                    badges.append("1080p FHD")
                } else if w >= 1200 || h >= 700 {
                    badges.append("720p HD")
                }
            }
            if !videoTrack.codec.isEmpty {
                badges.append(videoTrack.codec.uppercased())
            }
        } else {
            if upper.contains("2160P") || upper.contains("4K") || upper.contains("UHD") {
                badges.append("4K UHD")
            } else if upper.contains("1080P") || upper.contains("FHD") {
                badges.append("1080p")
            }
            if upper.contains("H.265") || upper.contains("HEVC") || upper.contains("X265") {
                badges.append("HEVC")
            } else if upper.contains("H.264") || upper.contains("AVC") || upper.contains("X264") {
                badges.append("AVC")
            }
        }
        
        if upper.contains("DV") || upper.contains("DOLBY VISION") {
            badges.append("Dolby Vision")
        } else if upper.contains("HDR") {
            badges.append("HDR")
        }
        
        return badges
    }
    
    public var body: some View {
        ZStack(alignment: .center) {
            Color.black.ignoresSafeArea()
            
            if let player = store.player {
                AVPlayerLayerContainerView(player: player)
                    .onTapGesture {
                        store.togglePlayPause()
                    }
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            
            // MARK: - Center HUD / Play Pulse
            if store.hasDecoderLimitation {
                decoderNoticeOverlay
            } else if isHovering || !store.isPlaying {
                Button(action: { store.togglePlayPause() }) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial.opacity(0.85))
                            .frame(width: 64, height: 64)
                            .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                        
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: store.isPlaying ? 0 : 2)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.85).combined(with: .opacity).animation(.spring(response: 0.2, dampingFraction: 0.8)))
            }
            
            // MARK: - Top Header Info Bar
            if isHovering || !store.isPlaying {
                VStack {
                    topInfoBar
                    Spacer()
                }
            }
            
            // MARK: - Bottom Playback Controls
            if isHovering || !store.isPlaying {
                VStack {
                    Spacer()
                    bottomControlBar
                }
            }
        }
        .contextMenu {
            Button(action: { NSWorkspace.shared.open(url) }) {
                Label(isChinese ? "在默认播放器中打开 (IINA/VLC/QuickTime)" : "Open in Default Player", systemImage: "arrow.up.forward.app")
            }
            Button(action: { NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "") }) {
                Label(isChinese ? "在访达中显示" : "Reveal in Finder", systemImage: "folder")
            }
            Button(action: { QuickLookPreviewCoordinator.shared.previewDiskFile(url: url) }) {
                Label(isChinese ? "快速查看" : "Quick Look", systemImage: "eye")
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovering = true
                MediaPlaybackCoordinator.shared.setHovered(id: sessionId, isHovered: true)
                resetHideTimer()
            case .ended:
                isHovering = false
                MediaPlaybackCoordinator.shared.setHovered(id: sessionId, isHovered: false)
            }
        }
        .onAppear {
            store.setup(url: url)
            MediaPlaybackCoordinator.shared.registerSession(
                id: sessionId,
                isPlaying: store.isPlaying,
                togglePlayPause: { [weak store] in store?.togglePlayPause() },
                seekBy: { [weak store] delta in store?.seekBy(delta) }
            )
        }
        .onChange(of: url) { _, newURL in
            store.setup(url: newURL)
        }
        .onChange(of: store.isPlaying) { _, playing in
            MediaPlaybackCoordinator.shared.updatePlaybackState(id: sessionId, isPlaying: playing)
        }
        .onDisappear {
            hideTimer?.invalidate()
            hideTimer = nil
            MediaPlaybackCoordinator.shared.unregisterSession(id: sessionId)
            store.cleanUp()
        }
    }
    
    private var topInfoBar: some View {
        HStack(spacing: 8) {
            Text(containerBadge)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(TTZipTheme.kintsugiGold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(TTZipTheme.kintsugiGold.opacity(0.2))
                .clipShape(Capsule())
            
            Text(url.lastPathComponent)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            
            ForEach(qualityBadges, id: \.self) { badge in
                Text(badge)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
            }
            
            Spacer()
            
            Button(action: { NSWorkspace.shared.open(url) }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .bold))
                    Text(isChinese ? "外部打开" : "Open In App")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(isChinese ? "在系统关联播放器中打开 (IINA/VLC/QuickTime)" : "Open in External Player (IINA/VLC/QuickTime)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.85))
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 2)
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
    }
    
    private var bottomControlBar: some View {
        HStack(spacing: 12) {
            Button(action: { store.togglePlayPause() }) {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            
            Text("\(formatTime(store.currentTime)) / \(formatTime(store.duration))")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
            
            Slider(
                value: Binding(
                    get: { store.currentTime },
                    set: { newValue in store.seek(to: newValue) }
                ),
                in: 0...max(store.duration, 0.1)
            )
            .tint(TTZipTheme.bambooGreen)
            
            Button(action: {
                store.isMuted.toggle()
                store.player?.isMuted = store.isMuted
            }) {
                Image(systemName: store.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            
            Button(action: { NSWorkspace.shared.open(url) }) {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
            }
            .buttonStyle(.plain)
            .help(isChinese ? "调起外部独立播放器" : "Launch External Player")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.85))
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
    }
    
    private var decoderNoticeOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 28))
                .foregroundStyle(TTZipTheme.kintsugiGold)
            
            Text(isChinese ? "\(containerBadge) 媒体预览就绪" : "\(containerBadge) In-App Media Ready")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            
            Text(isChinese ? "已提取音视频轨与章节。可直接在内嵌视图浏览或调起外部播放器硬解：" : "Metadata extracted via Rust microkernel. Open externally for complete hardware decoding:")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            
            Button(action: { NSWorkspace.shared.open(url) }) {
                HStack(spacing: 6) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(isChinese ? "在默认播放器中打开 (IINA/VLC)" : "Open in Default Player")
                        .font(.system(size: 11.5, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(TTZipTheme.bambooGreen)
                .clipShape(Capsule())
                .shadow(color: TTZipTheme.bambooGreen.opacity(0.4), radius: 6, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8))
        .shadow(color: Color.black.opacity(0.5), radius: 12, x: 0, y: 6)
    }
    
    private func resetHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            Task { @MainActor in
                withAnimation {
                    if store.isPlaying {
                        isHovering = false
                    }
                }
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let secs = Int(seconds)
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }
}

public struct AVPlayerLayerContainerView: NSViewRepresentable {
    public let player: AVPlayer
    
    public init(player: AVPlayer) {
        self.player = player
    }
    
    public func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }
    
    public func updateNSView(_ nsView: PlayerNSView, context: Context) {
        nsView.playerLayer.player = player
        nsView.playerLayer.videoGravity = .resizeAspect
    }
    
    public final class PlayerNSView: NSView {
        public let playerLayer = AVPlayerLayer()
        
        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            self.wantsLayer = true
            self.layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.frame = self.bounds
            playerLayer.videoGravity = .resizeAspect
            self.layer?.addSublayer(playerLayer)
        }
        
        public required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        public override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = self.bounds
            CATransaction.commit()
        }
    }
}
