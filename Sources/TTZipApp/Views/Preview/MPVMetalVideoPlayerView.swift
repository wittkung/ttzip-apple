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

/// Masterpiece libmpv Metal/EDR video player viewport supporting Apple Liquid Retina XDR 1600 nits and drag-and-drop subtitle mounting.
public struct MPVMetalVideoPlayerView: View {
    public let url: URL
    
    @StateObject private var store = MPVMetalPlayerStore()
    @State private var isHovering: Bool = false
    @State private var isDropTargeted: Bool = false
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
            
            // Native libmpv EDR/Metal Viewport
            MPVNativeMetalContainerView(
                url: url,
                store: store,
                onDropSubtitle: { subURL in
                    store.addExternalSubtitle(url: subURL)
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { droppedURL, _ in
                guard let droppedURL = droppedURL else { return }
                let ext = droppedURL.pathExtension.lowercased()
                if ["srt", "ass", "ssa", "vtt", "sub", "lrc"].contains(ext) {
                    Task { @MainActor in
                        store.addExternalSubtitle(url: droppedURL)
                    }
                }
            }
            return true
        }
        .onAppear {
            let sessionId = url.path
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
        .onChange(of: store.isPlaying) { _, playing in
            MediaPlaybackCoordinator.shared.updatePlaybackState(id: url.path, isPlaying: playing)
        }
        .onDisappear {
            hideTimer?.invalidate()
            hideTimer = nil
            MediaPlaybackCoordinator.shared.unregisterSession(id: url.path)
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

/// Native NSView hosting container embedding libmpv surface with Extended Dynamic Range (EDR) capability.
public struct MPVNativeMetalContainerView: NSViewRepresentable {
    public let url: URL
    @ObservedObject public var store: MPVMetalPlayerStore
    public let onDropSubtitle: (URL) -> Void
    public let onTogglePlayPause: () -> Void
    public let onToggleFullScreen: () -> Void
    
    public init(
        url: URL,
        store: MPVMetalPlayerStore,
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
        view.onDropSubtitle = onDropSubtitle
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        store.setup(url: url, view: view)
        return view
    }
    
    public func updateNSView(_ nsView: MPVMetalNSView, context: Context) {
        nsView.onDropSubtitle = onDropSubtitle
        nsView.onTogglePlayPause = onTogglePlayPause
        nsView.onToggleFullScreen = onToggleFullScreen
        if store.currentURL != url {
            store.setup(url: url, view: nsView)
        }
    }
}

/// High-performance NSView subclass configured for XDR Extended Dynamic Range and subtitle drag operations.
public final class MPVMetalNSView: NSView {
    public var onDropSubtitle: ((URL) -> Void)?
    public var onTogglePlayPause: (() -> Void)?
    public var onToggleFullScreen: (() -> Void)?
    
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
    }
    
    public override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            onToggleFullScreen?()
        } else if event.clickCount == 1 {
            onTogglePlayPause?()
        } else {
            super.mouseUp(with: event)
        }
    }
    
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasValidSubtitleURL(sender) {
            return .copy
        }
        return []
    }
    
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
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
