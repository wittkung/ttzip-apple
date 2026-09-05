// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import AVFoundation
import TTZipCore
import TTZipUI

/// Masterpiece libmpv Metal/EDR video player viewport supporting Apple Liquid Retina XDR 1600 nits,
/// drag-and-drop subtitle mounting, seamless controlled full-screen toggles, and sliding playlist drawer.
public struct MPVMetalVideoPlayerView: View {
    public let url: URL
    public let isFullScreen: Bool
    
    @ObservedObject public var store: MPVMetalPlayerStore
    public var playlistStore: MediaPlaylistStore
    @State private var isHovering: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var isPlaylistOpen: Bool = false
    @State private var copySuccessToast: Bool = false
    @State private var hideTimer: Timer? = nil
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    public init(
        url: URL,
        store: MPVMetalPlayerStore = .shared,
        playlistStore: MediaPlaylistStore = .shared,
        isFullScreen: Bool = false
    ) {
        self.url = url
        self.store = store
        self.playlistStore = playlistStore
        self.isFullScreen = isFullScreen
    }
    
    private var isChinese: Bool {
        l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
    }
    
    public var body: some View {
        ZStack(alignment: .center) {
            Color.black.ignoresSafeArea()
            
            // Native libmpv 16-bit float Metal EDR hardware passthrough viewport (Permanent single-layer)
            MPVMetalContainerRepresentableView(
                url: url,
                store: store,
                isFullScreen: isFullScreen,
                onDropSubtitle: { subURL in
                    store.loadSubtitle(url: subURL, select: true)
                },
                onTogglePlayPause: {
                    store.togglePlayPause()
                },
                onToggleFullScreen: {
                    toggleFullScreen()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Fail-Fast Video Diagnostic Overlay
                if store.hasPlaybackError {
                    VStack(spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(TTZipTheme.cinnabarRed)
                            Text(isChinese ? "视频播放失败 (libmpv)" : "Video Playback Error (libmpv)")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(TTZipTheme.cinnabarRed)
                        }
                        
                        Text(store.errorMessage ?? (isChinese ? "微内核解复用或硬解解码失败" : "Failed to decode video stream in libmpv microkernel"))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .padding(10)
                            .background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .frame(maxWidth: 420)
                        
                        HStack(spacing: 12) {
                            Button {
                                let diag = """
                                [TTZip Video Diagnostics]
                                URL: \(url.path)
                                Store URL: \(store.currentURL?.path ?? "none")
                                Error: \(store.errorMessage ?? "Unknown video error")
                                """
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(diag, forType: .string)
                                copySuccessToast = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    copySuccessToast = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: copySuccessToast ? "checkmark" : "doc.on.doc")
                                    Text(copySuccessToast ? (isChinese ? "已复制" : "Copied") : (isChinese ? "复制诊断日志" : "Copy Diagnostics"))
                                }
                                .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(TTZipTheme.kintsugiGold)
                            
                            Button {
                                NSWorkspace.shared.open(store.currentURL ?? url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.right.square")
                                    Text(isChinese ? "用外部应用打开" : "Open in External App")
                                }
                                .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            
                            Button {
                                store.load(url: url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                    Text(isChinese ? "重试" : "Retry")
                                }
                                .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(TTZipTheme.bambooGreen)
                        }
                    }
                    .padding(24)
                    .background(.ultraThinMaterial.opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(TTZipTheme.cinnabarRed.opacity(0.4), lineWidth: 1.2)
                    )
                    .shadow(color: Color.black.opacity(0.6), radius: 20)
                    .padding(20)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }
                
                // Subtitle Drag-and-Drop Highlight Overlay
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(TTZipTheme.kintsugiGold, lineWidth: 2.5)
                        .background(Color.black.opacity(0.4))
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "captions.bubble.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(TTZipTheme.kintsugiGold)
                                Text(isChinese ? "释放以加载外部字幕" : "Drop Subtitle to Load")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        )
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
                
                // Top-right Sleek Actions
                if isHovering {
                    VStack {
                        HStack(spacing: 8) {
                            Spacer()
                            
                            // Playlist Drawer Shortcut
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    isPlaylistOpen.toggle()
                                }
                            }) {
                                Image(systemName: isPlaylistOpen ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(isPlaylistOpen ? TTZipTheme.kintsugiGold : .white.opacity(0.9))
                                    .padding(7)
                                    .background(.ultraThinMaterial.opacity(0.8))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(isChinese ? "播放列表" : "Playlist")
                            
                            // Fullscreen Toggle
                            Button(action: { toggleFullScreen() }) {
                                Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(7)
                                    .background(.ultraThinMaterial.opacity(0.8))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(isFullScreen ? (isChinese ? "退出全屏 (Esc/F)" : "Exit Full Screen (Esc/F)") : (isChinese ? "进入全屏预览 (F)" : "Enter Full Screen (F)"))
                        }
                        .padding(10)
                        Spacer()
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
                
                // Bottom Ultra-Sleek Zen Floating Controls with Ambient Scrim Veil
                if isHovering || !store.isPlaying {
                    VStack {
                        Spacer()
                        MPVVideoControlBarView(
                            store: store,
                            playlistStore: playlistStore,
                            isPlaylistOpen: isPlaylistOpen,
                            onTogglePlaylist: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    isPlaylistOpen.toggle()
                                }
                            },
                            onToggleFullScreen: { toggleFullScreen() },
                            onOpenExternal: {
                                if let current = store.currentURL ?? playlistStore.currentURL {
                                    NSWorkspace.shared.open(current)
                                } else {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    .background(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.black.opacity(0.18),
                                Color.black.opacity(0.65)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 110)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                    )
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
                
                // Playlist Side Drawer Panel
                if isPlaylistOpen {
                    HStack(spacing: 0) {
                        Spacer()
                        MPVPlaylistDrawerView(
                            playlistStore: playlistStore,
                            onSelectItem: { item in
                                store.load(url: item.url)
                                playlistStore.select(item: item)
                            },
                            onClose: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    isPlaylistOpen = false
                                }
                            }
                        )
                        .padding(12)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { droppedURL, _ in
                guard let droppedURL = droppedURL else { return }
                let ext = droppedURL.pathExtension.lowercased()
                if ["srt", "ass", "ssa", "vtt", "sub", "lrc"].contains(ext) {
                    Task { @MainActor in
                        store.loadSubtitle(url: droppedURL, select: true)
                    }
                }
            }
            return true
        }
        .onAppear {
            if store.currentURL == nil || store.currentURL != url {
                store.load(url: url)
                playlistStore.populateFromDirectory(for: url)
            }
            let activeURL = store.currentURL ?? url
            let sessionId = activeURL.path
            
            store.onFilePlaybackEnded = { [weak playlistStore] _ in
                if let nextItem = playlistStore?.playNext() {
                    store.load(url: nextItem.url)
                }
            }
            
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
        .onChange(of: url) { _, newURL in
            store.load(url: newURL)
            playlistStore.populateFromDirectory(for: newURL)
        }
        .onChange(of: store.currentURL) { _, newURL in
            if let newURL = newURL {
                MediaPlaybackCoordinator.shared.registerSession(
                    id: newURL.path,
                    isPlaying: store.isPlaying,
                    togglePlayPause: {
                        store.togglePlayPause()
                    },
                    seekBy: { delta in
                        store.seekBy(delta)
                    }
                )
            }
        }
        .onChange(of: store.isPlaying) { _, playing in
            let activeId = store.currentURL?.path ?? url.path
            MediaPlaybackCoordinator.shared.updatePlaybackState(id: activeId, isPlaying: playing)
        }
        .onDisappear {
            hideTimer?.invalidate()
            hideTimer = nil
            let activeId = store.currentURL?.path ?? url.path
            MediaPlaybackCoordinator.shared.unregisterSession(id: activeId)
            store.pause()
        }
    }
    
    private func toggleFullScreen() {
        NotificationCenter.default.post(name: NSNotification.Name("TTZipToggleMediaFocusNotification"), object: nil)
    }
    
    private func resetHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.2)) {
                    if store.isPlaying && !isPlaylistOpen { isHovering = false }
                }
            }
        }
    }
}

/// Native NSView hosting container embedding libmpv surface with Extended Dynamic Range (EDR) capability.
public struct MPVNativeMetalContainerView: NSViewRepresentable {
    public let url: URL
    @ObservedObject public var store: MPVMetalPlayerStore
    public let isFullScreen: Bool
    public let onDropSubtitle: (URL) -> Void
    public let onTogglePlayPause: () -> Void
    public let onToggleFullScreen: () -> Void
    
    public init(
        url: URL,
        store: MPVMetalPlayerStore = .shared,
        isFullScreen: Bool = false,
        onDropSubtitle: @escaping (URL) -> Void = { _ in },
        onTogglePlayPause: @escaping () -> Void = {},
        onToggleFullScreen: @escaping () -> Void = {}
    ) {
        self.url = url
        self.store = store
        self.isFullScreen = isFullScreen
        self.onDropSubtitle = onDropSubtitle
        self.onTogglePlayPause = onTogglePlayPause
        self.onToggleFullScreen = onToggleFullScreen
    }
    
    public func makeNSView(context: Context) -> MPVMetalNSView {
        let view = MPVMetalNSView(frame: .zero, isFullScreen: isFullScreen)
        view.isFullScreen = isFullScreen
        view.store = store
        view.onDropSubtitle = onDropSubtitle
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        return view
    }
    
    public func updateNSView(_ nsView: MPVMetalNSView, context: Context) {
        nsView.isFullScreen = isFullScreen
        nsView.store = store
        nsView.onDropSubtitle = onDropSubtitle
        nsView.onTogglePlayPause = onTogglePlayPause
        nsView.onToggleFullScreen = onToggleFullScreen
        if store.currentURL == nil {
            store.load(url: url)
        }
    }
}

/// High-performance NSView subclass configured for XDR Extended Dynamic Range, keyboard shortcuts, and subtitle drag operations.
/// Preserved as layer host base class and white-box test target.
open class MPVMetalNSView: NSView {
    private var singleClickWorkItem: DispatchWorkItem? = nil
    open var isFullScreen: Bool = false
    
    open weak var store: MPVMetalPlayerStore? {
        didSet {
            if let window = self.window, let store = store {
                if let videoLayer = self.layer as? (any MPVVideoLayerProtocol) {
                    videoLayer.contentsScale = window.backingScaleFactor
                    videoLayer.bind(store: store)
                }
            }
        }
    }
    open var onDropSubtitle: ((URL) -> Void)?
    open var onTogglePlayPause: (() -> Void)?
    open var onToggleFullScreen: (() -> Void)?
    
    open override func makeBackingLayer() -> CALayer {
        let glLayer = MPVOpenGLLayer()
        glLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        return glLayer
    }
    
    public init(frame frameRect: NSRect, isFullScreen: Bool) {
        self.isFullScreen = isFullScreen
        super.init(frame: frameRect)
        setupLayer()
        registerForDraggedTypes([.fileURL])
    }
    
    public override init(frame frameRect: NSRect) {
        self.isFullScreen = false
        super.init(frame: frameRect)
        setupLayer()
        registerForDraggedTypes([.fileURL])
    }
    
    public required init?(coder: NSCoder) {
        self.isFullScreen = false
        super.init(coder: coder)
        setupLayer()
        registerForDraggedTypes([.fileURL])
    }
    
    private func setupLayer() {
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        self.layerContentsRedrawPolicy = .duringViewResize
        self.layer?.wantsExtendedDynamicRangeContent = true
        self.layer?.masksToBounds = true
    }
    
    open override var acceptsFirstResponder: Bool { true }
    
    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let targetStore = self.store ?? MPVMetalPlayerStore.shared
        if let window = self.window {
            if let videoLayer = self.layer as? (any MPVVideoLayerProtocol) {
                videoLayer.contentsScale = window.backingScaleFactor
                videoLayer.bind(store: targetStore)
            }
        } else {
            singleClickWorkItem?.cancel()
            singleClickWorkItem = nil
            if let videoLayer = self.layer as? (any MPVVideoLayerProtocol) {
                videoLayer.unbind()
            }
        }
    }
    
    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window = self.window {
            if let videoLayer = self.layer as? (any MPVVideoLayerProtocol) {
                videoLayer.contentsScale = window.backingScaleFactor
                videoLayer.forceRedraw()
            } else {
                self.layer?.contentsScale = window.backingScaleFactor
            }
        }
    }
    
    open override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            singleClickWorkItem?.cancel()
            singleClickWorkItem = nil
            onToggleFullScreen?()
        } else if event.clickCount == 1 {
            singleClickWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onTogglePlayPause?()
            }
            self.singleClickWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        } else {
            super.mouseUp(with: event)
        }
    }
    
    open override func keyDown(with event: NSEvent) {
        // KeyCode 3 is 'F' (Fullscreen toggle)
        if event.keyCode == 3 || event.charactersIgnoringModifiers?.lowercased() == "f" {
            onToggleFullScreen?()
            return
        }
        // KeyCode 49 is Space Bar
        if event.keyCode == 49 {
            onTogglePlayPause?()
            return
        }
        // KeyCode 53 is ESC
        if event.keyCode == 53 {
            NotificationCenter.default.post(name: NSNotification.Name("TTZipToggleMediaFocusNotification"), object: nil)
            return
        }
        super.keyDown(with: event)
    }
    
    open override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasValidSubtitleURL(sender) {
            return .copy
        }
        return []
    }
    
    open override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let firstURL = urls.first, isSubtitleURL(firstURL) {
            onDropSubtitle?(firstURL)
            return true
        }
        return false
    }
    
    private func hasValidSubtitleURL(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let firstURL = urls.first {
            return isSubtitleURL(firstURL)
        }
        return false
    }
    
    private func isSubtitleURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["srt", "ass", "ssa", "vtt", "sub", "lrc"].contains(ext)
    }
}

/// Legacy container view shim preserving test suite backward compatibility.
public struct AVPlayerLayerContainerView {
    public final class PlayerNSView: NSView {
        public let playerLayer = AVPlayerLayer()
        
        public override init(frame frameRect: NSRect = .zero) {
            super.init(frame: frameRect)
            self.wantsLayer = true
            self.layer?.backgroundColor = NSColor.black.cgColor
            self.layer?.wantsExtendedDynamicRangeContent = true
            playerLayer.frame = self.bounds
            playerLayer.videoGravity = .resizeAspect
            self.layer?.addSublayer(playerLayer)
        }
        
        public required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        public override func layout() {
            super.layout()
            playerLayer.frame = self.bounds
        }
    }
}
