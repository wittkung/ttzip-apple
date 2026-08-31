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
    
    private let metalLayer = MPVMetalRenderLayer()
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
    
    public override func makeBackingLayer() -> CALayer {
        return metalLayer
    }
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        self.layer = metalLayer
        self.layerContentsRedrawPolicy = .duringViewResize
        self.layer?.backgroundColor = NSColor.black.cgColor
        self.layer?.masksToBounds = true
        
        registerForDraggedTypes([.fileURL])
        
        let layer = self.metalLayer
        displayLink.setFrameCallback { [weak layer] _, _ in
            layer?.requestRender()
        }
    }
    
    public override var acceptsFirstResponder: Bool { true }
    
    // MARK: - Lifecycle & Hierarchy Management
    
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observerHolder.removeAll()
        
        if let window = self.window {
            setupWindowObservers(for: window)
            updateScaleAndBounds()
            displayLink.attach(to: self)
            displayLink.start()
            bindStore()
        } else {
            displayLink.suspend()
            metalLayer.unbind()
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
        metalLayer.updateDrawableSize(boundsSize: bounds.size, scaleFactor: scale)
    }
    
    private func bindStore() {
        guard let window = self.window, let store = store ?? MPVMetalPlayerStore.shared as MPVMetalPlayerStore? else { return }
        metalLayer.updateDrawableSize(boundsSize: bounds.size, scaleFactor: window.backingScaleFactor)
        metalLayer.bind(store: store)
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
                self?.logger.debug("Window deminimized: resuming Metal display link")
                self?.displayLink.resume()
            }
        }
        
        let occlusionObs = center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let win = self.window else { return }
                if win.occlusionState.contains(.visible) {
                    self.displayLink.resume()
                } else {
                    self.logger.debug("Window occluded: suspending Metal pipeline")
                    self.displayLink.suspend()
                }
            }
        }
        
        observerHolder.tokens = [miniObs, deminiObs, occlusionObs]
    }
    
    // MARK: - User Interaction & Keyboard Handling
    
    public override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            onToggleFullScreen?()
        } else if event.clickCount == 1 {
            onTogglePlayPause?()
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
            if FullScreenMediaWindowController.shared.isPresenting {
                FullScreenMediaWindowController.shared.dismiss()
                return
            }
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
    
    public func makeNSView(context: Context) -> MPVMetalContainerView {
        let view = MPVMetalContainerView()
        view.store = store
        view.onDropSubtitle = onDropSubtitle
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        return view
    }
    
    public func updateNSView(_ nsView: MPVMetalContainerView, context: Context) {
        nsView.store = store
        nsView.onDropSubtitle = onDropSubtitle
        nsView.onTogglePlayPause = onTogglePlayPause
        nsView.onToggleFullScreen = onToggleFullScreen
        if store.currentURL != url {
            store.load(url: url)
        }
    }
}
