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
            guard store !== oldValue else { return }
            bindStore()
        }
    }
    
    private let displayLink = MPVMetalDisplayLink()
    @MainActor
    private final class ObserverTokenHolder {
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
    private var lastBoundsSize: CGSize = .zero
    private var lastBackingScale: CGFloat = 1.0
    
    public override func makeBackingLayer() -> CALayer {
        let metalLayer = MPVMetalRenderLayer()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        return metalLayer
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
        MainActor.assumeIsolated {
            observerHolder.removeAll()
        }
        displayLink.stop()
    }
    
    private func setupContainer() {
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .duringViewResize
        self.layer?.backgroundColor = NSColor.black.cgColor
        self.layer?.wantsExtendedDynamicRangeContent = true
        self.layer?.cornerRadius = 8
        self.layer?.masksToBounds = true
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        self.layer?.contentsScale = scale
        
        registerForDraggedTypes([.fileURL])
        
        displayLink.setFrameCallback { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let strongSelf = self else { return }
                let rawLayer = strongSelf.layer
                guard let videoLayer = rawLayer as? (any MPVVideoLayerProtocol) else { return }
                if strongSelf.warmupFrameCount > 0 {
                    strongSelf.warmupFrameCount -= 1
                    videoLayer.forceRedraw()
                    return
                }
                if let store = strongSelf.store, store.isPlaying {
                    videoLayer.requestRender()
                }
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
            bindStore()
            updateScaleAndBounds(force: true)
            displayLink.attach(to: self)
            displayLink.start()
        } else {
            singleClickWorkItem?.cancel()
            singleClickWorkItem = nil
            lastBoundsSize = .zero
            displayLink.suspend()
            (layer as? (any MPVVideoLayerProtocol))?.unbind()
        }
    }
    
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScaleAndBounds(force: true)
    }
    
    public override func layout() {
        super.layout()
        updateScaleAndBounds()
    }
    
    public override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = abs(newSize.width - frame.size.width) >= 0.5 || abs(newSize.height - frame.size.height) >= 0.5
        super.setFrameSize(newSize)
        if sizeChanged {
            updateScaleAndBounds()
        }
    }
    
    /// Synchronizes backing scale and drawable dimensions to match the view's current bounds and Retina scale factor.
    ///
    /// When bounds size experiences a material change and is greater than zero, forces an immediate frame redraw
    /// regardless of playback state (`store.isPlaying`). This guarantees that the paused or initial video frame
    /// strictly aligns 1:1 in pixels with the actual view dimensions, eliminating any snapping or jump when playback starts.
    private func updateScaleAndBounds(force: Bool = false) {
        let currentSize = bounds.size
        guard currentSize.width > 0, currentSize.height > 0 else { return }
        
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let sizeChanged = abs(currentSize.width - lastBoundsSize.width) > 0.001 || abs(currentSize.height - lastBoundsSize.height) > 0.001
        let scaleChanged = abs(scale - lastBackingScale) > 0.001
        
        guard sizeChanged || scaleChanged || force else { return }
        
        lastBoundsSize = currentSize
        lastBackingScale = scale
        
        if let videoLayer = layer as? (any MPVVideoLayerProtocol) {
            videoLayer.contentsScale = scale
            if let metalLayer = videoLayer as? MPVMetalRenderLayer {
                metalLayer.updateDrawableSize(boundsSize: currentSize, scaleFactor: scale)
            }
            // Force redraw regardless of whether store.isPlaying is true.
            // This guarantees that initial paused frames immediately scale to match
            // the new viewport dimensions with zero 1:1 pixel snapping artifacts.
            videoLayer.forceRedraw()
            videoLayer.requestRender()
        }
    }
    
    private func bindStore() {
        guard let targetStore = store ?? MPVMetalPlayerStore.shared as MPVMetalPlayerStore? else { return }
        if let videoLayer = layer as? (any MPVVideoLayerProtocol) {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            videoLayer.contentsScale = scale
            if let metalLayer = videoLayer as? MPVMetalRenderLayer {
                metalLayer.updateDrawableSize(boundsSize: bounds.size, scaleFactor: scale)
            }
            videoLayer.bind(store: targetStore)
            warmupFrameCount = 5
            if bounds.width > 0 && bounds.height > 0 {
                videoLayer.forceRedraw()
            }
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
                (self?.layer as? (any MPVVideoLayerProtocol))?.forceRedraw()
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
                    (self.layer as? (any MPVVideoLayerProtocol))?.forceRedraw()
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
            let debounceInterval = min(NSEvent.doubleClickInterval, 0.22)
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
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
            if let onToggleFullScreen = onToggleFullScreen {
                onToggleFullScreen()
            } else {
                NotificationCenter.default.post(name: NSNotification.Name("TTZipToggleMediaFocusNotification"), object: nil)
            }
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
    public var store: MPVMetalPlayerStore
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
        if nsView.store !== store {
            nsView.store = store
        }
        nsView.onDropSubtitle = onDropSubtitle
        nsView.onTogglePlayPause = onTogglePlayPause
        nsView.onToggleFullScreen = onToggleFullScreen
        if store.currentURL == nil {
            store.load(url: url)
        }
    }
}
