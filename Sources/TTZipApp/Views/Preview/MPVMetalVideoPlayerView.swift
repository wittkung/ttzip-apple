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
            
            if !store.hasDecoderLimitation, let player = store.player {
                // Native Apple Silicon AVPlayer hardware viewport
                AVPlayerLayerContainerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(count: 2) {
                        toggleFullScreen()
                    }
                    .onTapGesture(count: 1) {
                        store.togglePlayPause()
                    }
            } else {
                // Universal in-place playback canvas for MKV, WebM, AVI, FLV, TS, etc.
                MPVDirectContainerPlayerView(url: url, store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(count: 2) {
                        toggleFullScreen()
                    }
                    .onTapGesture(count: 1) {
                        store.togglePlayPause()
                    }
            }
            
            // Subtitle Overlay (if active)
            if let subText = store.activeSubtitleDialogue, !subText.isEmpty {
                VStack {
                    Spacer()
                    Text(subText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.bottom, (isHovering || !store.isPlaying) ? 55 : 20)
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
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


/// Universal in-place video playback canvas for MKV, WebM, AVI, FLV, TS, WMV, VOB.
public struct MPVDirectContainerPlayerView: View {
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
    
    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Cinematic background
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.12, green: 0.14, blue: 0.16),
                        Color.black
                    ]),
                    center: .center,
                    startRadius: 20,
                    endRadius: max(geo.size.width, geo.size.height) * 0.8
                )
                
                // Top Watermark Specs
                VStack {
                    HStack(spacing: 6) {
                        Text(containerPill)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(TTZipTheme.kintsugiGold.opacity(0.15))
                            .clipShape(Capsule())
                        
                        Text(videoSpecString)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                        
                        Spacer()
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 14)
                    Spacer()
                }
                
                // Center Play / Active Indicator
                VStack(spacing: 8) {
                    Button(action: { store.togglePlayPause() }) {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial.opacity(0.85))
                                .frame(width: 44, height: 44)
                                .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                            
                            Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: store.isPlaying ? 0 : 1.5)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    if !store.isPlaying {
                        Text(url.lastPathComponent)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .padding(.horizontal, 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}


