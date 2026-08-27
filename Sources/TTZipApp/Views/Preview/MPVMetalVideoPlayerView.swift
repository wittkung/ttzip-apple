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

/// Native Metal EDR video player viewport supporting 16-bit Float HDR and Zen floating controls.
public struct MPVMetalVideoPlayerView: View {
    public let url: URL
    
    @StateObject private var store = MPVMetalPlayerStore()
    @State private var isHovering: Bool = false
    @State private var hideTimer: Timer? = nil
    @State private var sessionId: String = UUID().uuidString
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
                if w >= 3800 || h >= 2100 { badges.append("4K UHD") }
                else if w >= 1900 || h >= 1000 { badges.append("1080p FHD") }
                else if w >= 1200 || h >= 700 { badges.append("720p HD") }
            }
            if !videoTrack.codec.isEmpty { badges.append(videoTrack.codec.uppercased()) }
        } else {
            if upper.contains("2160P") || upper.contains("4K") || upper.contains("UHD") { badges.append("4K UHD") }
            else if upper.contains("1080P") || upper.contains("FHD") { badges.append("1080p") }
            if upper.contains("H.265") || upper.contains("HEVC") || upper.contains("X265") { badges.append("HEVC") }
            else if upper.contains("H.264") || upper.contains("AVC") || upper.contains("X264") { badges.append("AVC") }
        }
        
        if store.edrMetrics.isHDRActive || upper.contains("HDR") || upper.contains("DV") {
            badges.append("EDR 1600nits")
        }
        return badges
    }
    
    public var body: some View {
        ZStack(alignment: .center) {
            Color.black.ignoresSafeArea()
            
            if store.hasDecoderLimitation {
                QuickLookDirectVideoHostingView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let player = store.player {
                MetalEDRVideoContainerView(player: player)
                    .onTapGesture(count: 2) {
                        toggleFullScreen()
                    }
                    .onTapGesture(count: 1) {
                        store.togglePlayPause()
                    }
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            
            // MARK: - Center HUD Play/Pause Pulse
            if !store.hasDecoderLimitation && (isHovering || !store.isPlaying) {
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
            
            // MARK: - Bottom Zen Floating Controls
            if isHovering || !store.isPlaying {
                VStack {
                    Spacer()
                    MPVVideoControlBarView(
                        store: store,
                        onToggleFullScreen: { toggleFullScreen() },
                        onOpenExternal: { NSWorkspace.shared.open(url) }
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
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
                    .foregroundStyle(.white.opacity(0.85))
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
            .help("Open in External Player")
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
                withAnimation {
                    if store.isPlaying { isHovering = false }
                }
            }
        }
    }
}

/// AppKit NSView wrapper hosting CAMetalLayer (16-bit Float HDR / 1600 nits EDR) and AVPlayerLayer.
public struct MetalEDRVideoContainerView: NSViewRepresentable {
    public let player: AVPlayer
    
    public init(player: AVPlayer) {
        self.player = player
    }
    
    public func makeNSView(context: Context) -> MetalEDRNSView {
        let view = MetalEDRNSView()
        view.attach(player: player)
        return view
    }
    
    public func updateNSView(_ nsView: MetalEDRNSView, context: Context) {
        nsView.attach(player: player)
    }
    
    public final class MetalEDRNSView: NSView {
        public let metalLayer = CAMetalLayer()
        public let playerLayer = AVPlayerLayer()
        private var metalDevice: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        
        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setupMetalLayers()
        }
        
        public required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupMetalLayers()
        }
        
        private func setupMetalLayers() {
            self.wantsLayer = true
            let device = MTLCreateSystemDefaultDevice()
            self.metalDevice = device
            self.commandQueue = device?.makeCommandQueue()
            
            metalLayer.device = device
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpace(name: CGColorSpace.sRGB)
            metalLayer.framebufferOnly = false
            metalLayer.allowsNextDrawableTimeout = false
            metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            
            playerLayer.videoGravity = .resizeAspect
            playerLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            
            self.layer?.backgroundColor = NSColor.black.cgColor
            self.layer?.addSublayer(metalLayer)
            self.layer?.addSublayer(playerLayer)
        }
        
        public func attach(player: AVPlayer) {
            if playerLayer.player !== player {
                playerLayer.player = player
            }
            renderEDRFrame()
        }
        
        public func renderEDRFrame() {
            guard let queue = commandQueue,
                  let drawable = metalLayer.nextDrawable() else { return }
            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = drawable.texture
            passDesc.colorAttachments[0].loadAction = .clear
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            passDesc.colorAttachments[0].storeAction = .store
            
            if let cmdBuffer = queue.makeCommandBuffer(),
               let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) {
                encoder.endEncoding()
                cmdBuffer.present(drawable)
                cmdBuffer.commit()
            }
        }
        
        public override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.frame = bounds
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
