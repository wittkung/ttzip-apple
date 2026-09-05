// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import SwiftUI
import QuartzCore
import os.log
import TTZipUI

/// High-performance native NSView host container anchoring the `MPVMetalRenderLayer` and `MPVMetalDisplayLink`.
///
/// Features dynamic HiDPI Retina scale factor tracking, automatic occlusion-aware GPU suspension
/// for zero idle power consumption, gesture handling, subtitle drag-and-drop, and SwiftUI bridging.
public final class MPVMetalContainerView: MPVMetalNSView {
    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MPVMetalContainerView")
    
    public override weak var store: MPVMetalPlayerStore? {
        didSet {
            bindStore()
        }
    }
    
    private let displayLink = MPVMetalDisplayLink()
    private final class ObserverTokenHolder: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
        func removeAll() {
            let center = NotificationCenter.default
            for token in tokens {
                center.removeObserver(token)
            }
            tokens.removeAll()
        }
    }
    
    private let observerHolder = ObserverTokenHolder()
    private var singleClickWorkItem: DispatchWorkItem? = nil
    private var warmupFrameCount: Int = 5
    
    public override func makeBackingLayer() -> CALayer {
        let glLayer = MPVOpenGLLayer()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        glLayer.contentsScale = scale
        return glLayer
    }
    
    public override init(frame frameRect: NSRect, isFullScreen: Bool) {
        super.init(frame: frameRect, isFullScreen: isFullScreen)
        setupContainer()
    }
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect, isFullScreen: false)
        setupContainer()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupContainer()
    }
    
    deinit {
        observerHolder.removeAll()
        displayLink.stop()
    }
    
    private func setupContainer() {
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .duringViewResize
        self.layer?.backgroundColor = NSColor.black.cgColor
        self.layer?.wantsExtendedDynamicRangeContent = true
        self.layer?.masksToBounds = true
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        self.layer?.contentsScale = scale
        
        registerForDraggedTypes([.fileURL])
        
        displayLink.setFrameCallback { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self = self, let glLayer = self.layer as? MPVOpenGLLayer else { return }
                guard let store = self.store ?? MPVMetalPlayerStore.shared as MPVMetalPlayerStore? else { return }
                if self.warmupFrameCount > 0 {
                    self.warmupFrameCount -= 1
                    glLayer.forceRedraw()
                    return
                }
                guard store.isPlaying else { return }
                glLayer.forceRedraw()
            }
        }
    }
    
    public override var acceptsFirstResponder: Bool { true }
    
    // MARK: - Lifecycle & Hierarchy Management
    
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observerHolder.removeAll()
        
        if let window = self.window {
            warmupFrameCount = 5
            setupWindowObservers(for: window)
            updateScaleAndBounds()
            displayLink.attach(to: self)
            displayLink.start()
            bindStore()
        } else {
            singleClickWorkItem?.cancel()
            singleClickWorkItem = nil
            displayLink.suspend()
            (layer as? MPVOpenGLLayer)?.unbind()
        }
    }
    
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScaleAndBounds()
    }
    
    public override func layout() {
        super.layout()
        updateScaleAndBounds()
    }
    
    private func updateScaleAndBounds() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if let glLayer = layer as? MPVOpenGLLayer {
            glLayer.contentsScale = scale
            glLayer.forceRedraw()
        }
    }
    
    private func bindStore() {
        guard let targetStore = store ?? MPVMetalPlayerStore.shared as MPVMetalPlayerStore? else { return }
        if let glLayer = layer as? MPVOpenGLLayer {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            glLayer.contentsScale = scale
            glLayer.bind(store: targetStore)
            warmupFrameCount = 5
        }
    }
    
    // MARK: - Occlusion & Power Management
    
    private func setupWindowObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        
        let miniObs = center.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logger.debug("Window minimized: suspending Metal display link")
                self?.displayLink.suspend()
            }
        }
        
        let deminiObs = center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logger.debug("Window un-minimized: resuming Metal display link")
                self?.displayLink.resume()
                (self?.layer as? MPVOpenGLLayer)?.forceRedraw()
            }
        }
        
        let occludeObs = center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let win = self.window else { return }
                if win.occlusionState.contains(.visible) {
                    self.displayLink.resume()
                    (self.layer as? MPVOpenGLLayer)?.forceRedraw()
                } else {
                    self.displayLink.suspend()
                }
            }
        }
        
        observerHolder.tokens.append(contentsOf: [miniObs, deminiObs, occludeObs])
    }
    
    // MARK: - User Interaction & Keyboard Handling
    
    public override func mouseUp(with event: NSEvent) {
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
    
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 3 || event.charactersIgnoringModifiers?.lowercased() == "f" {
            onToggleFullScreen?()
            return
        }
        if event.keyCode == 49 {
            onTogglePlayPause?()
            return
        }
        if event.keyCode == 53 {
            NotificationCenter.default.post(name: NSNotification.Name("TTZipToggleMediaFocusNotification"), object: nil)
            return
        }
        super.keyDown(with: event)
    }
    
    // MARK: - Drag and Drop Handling
    
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

/// SwiftUI View Representable bridging `MPVMetalContainerView` into the declarative presentation tree.
public struct MPVMetalContainerRepresentableView: NSViewRepresentable {
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
    
    public func makeNSView(context: Context) -> MPVMetalContainerView {
        let view = MPVMetalContainerView(frame: .zero, isFullScreen: isFullScreen)
        view.isFullScreen = isFullScreen
        view.store = store
        view.onDropSubtitle = onDropSubtitle
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        return view
    }
    
    public func updateNSView(_ nsView: MPVMetalContainerView, context: Context) {
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
