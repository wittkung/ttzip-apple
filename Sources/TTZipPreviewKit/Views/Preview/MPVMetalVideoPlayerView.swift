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
    
    @ObservedObject public var store: MPVMetalPlayerStore
    public var playlistStore: MediaPlaylistStore
    @State private var isHovering: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var isPlaylistOpen: Bool = false
    @State private var hideTimer: Timer? = nil
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    public init(
        url: URL,
        store: MPVMetalPlayerStore = .shared,
        playlistStore: MediaPlaylistStore = .shared
    ) {
        self.url = url
        self.store = store
        self.playlistStore = playlistStore
    }
    
    private var isChinese: Bool {
        l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
    }
    
    public var body: some View {
        ZStack(alignment: .center) {
            Color.black.ignoresSafeArea()
            
            // Native libmpv 16-bit float Metal EDR hardware passthrough viewport
            MPVMetalContainerRepresentableView(
                url: url,
                store: store,
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
            
            // Subtitle Overlay (if dialogue active and not rendered into video surface)
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
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(7)
                                .background(.ultraThinMaterial.opacity(0.8))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(isChinese ? "进入全屏预览 (F)" : "Enter Full Screen (F)")
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
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
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
            let sessionId = url.path
            store.load(url: url)
            playlistStore.populateFromDirectory(for: url)
            
            MediaPlaybackCoordinator.shared.registerSession(
                id: sessionId,
                isPlaying: store.isPlaying,
                togglePlayPause: {
                    store.togglePlayPause()
                },
                seekBy: { delta in
                    store.seek(to: store.currentTime + delta)
                }
            )
        }
        .onChange(of: url) { _, newURL in
            store.load(url: newURL)
            playlistStore.populateFromDirectory(for: newURL)
        }
        .onChange(of: store.isPlaying) { _, playing in
            MediaPlaybackCoordinator.shared.updatePlaybackState(id: url.path, isPlaying: playing)
        }
        .onDisappear {
            hideTimer?.invalidate()
            hideTimer = nil
            MediaPlaybackCoordinator.shared.unregisterSession(id: url.path)
            store.pause()
        }
    }
    
    private func toggleFullScreen() {
        if FullScreenMediaWindowController.shared.isPresenting {
            FullScreenMediaWindowController.shared.dismiss()
        } else {
            FullScreenMediaWindowController.shared.present(
                view: AnyView(
                    MPVMetalVideoPlayerView(
                        url: store.currentURL ?? url,
                        store: store,
                        playlistStore: playlistStore
                    )
                )
            )
        }
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
    public let onDropSubtitle: (URL) -> Void
    public let onTogglePlayPause: () -> Void
    public let onToggleFullScreen: () -> Void
    
    public init(
        url: URL,
        store: MPVMetalPlayerStore = .shared,
        onDropSubtitle: @escaping (URL) -> Void = { _ in },
        onTogglePlayPause: @escaping () -> Void = {},
        onToggleFullScreen: @escaping () -> Void = {}
    ) {
        self.url = url
        self.store = store
        self.onDropSubtitle = onDropSubtitle
        self.onTogglePlayPause = onTogglePlayPause
        self.onToggleFullScreen = onToggleFullScreen
    }
    
    public func makeNSView(context: Context) -> MPVMetalNSView {
        let view = MPVMetalNSView()
        view.store = store
        view.onDropSubtitle = onDropSubtitle
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        return view
    }
    
    public func updateNSView(_ nsView: MPVMetalNSView, context: Context) {
        nsView.store = store
        nsView.onDropSubtitle = onDropSubtitle
        nsView.onTogglePlayPause = onTogglePlayPause
        nsView.onToggleFullScreen = onToggleFullScreen
        if store.currentURL != url {
            store.load(url: url)
        }
    }
}

/// High-performance NSView subclass configured for XDR Extended Dynamic Range, keyboard shortcuts, and subtitle drag operations.
/// Preserved as layer host base class and white-box test target.
open class MPVMetalNSView: NSView {
    open weak var store: MPVMetalPlayerStore? {
        didSet {
            if let window = self.window, let store = store {
                if let glLayer = self.layer as? MPVOpenGLLayer {
                    glLayer.contentsScale = window.backingScaleFactor
                    glLayer.bind(store: store)
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
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
        registerForDraggedTypes([.fileURL])
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
            if let glLayer = self.layer as? MPVOpenGLLayer {
                glLayer.contentsScale = window.backingScaleFactor
                glLayer.bind(store: targetStore)
            }
        } else {
            if let glLayer = self.layer as? MPVOpenGLLayer {
                glLayer.unbind()
            }
        }
    }
    
    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window = self.window {
            self.layer?.contentsScale = window.backingScaleFactor
        }
    }
    
    open override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            onToggleFullScreen?()
        } else if event.clickCount == 1 {
            onTogglePlayPause?()
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
            if FullScreenMediaWindowController.shared.isPresenting {
                FullScreenMediaWindowController.shared.dismiss()
                return
            }
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
