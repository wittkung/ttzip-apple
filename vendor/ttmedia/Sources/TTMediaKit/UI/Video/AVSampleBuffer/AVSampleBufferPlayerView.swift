// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
@preconcurrency import AVFoundation
import CoreMedia
import QuartzCore
import os

/// Native AppKit host view encapsulating `AVSampleBufferDisplayLayer` video presentation
/// and `AVSampleBufferAudioRenderer` audio output, unified under `AVSampleBufferRenderSynchronizer`.
///
/// Features hardware-locked ProMotion display link synchronization (up to 120Hz), automatic
/// window occlusion suspension for zero idle GPU draw, and distortion-free aspect ratio scaling.
@MainActor
public final class AVSampleBufferPlayerNSView: NSView {
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "AVSampleBufferPlayerNSView")

    // MARK: - Core Presentation Pipeline Components

    public let displayLayer: AVSampleBufferDisplayLayer
    public let audioRenderer: AVSampleBufferAudioRenderer
    public let synchronizer: AVSampleBufferRenderSynchronizer
    public let renderer: AVSampleBufferRenderer

    // MARK: - State & Metrics

    public private(set) var isPresenting: Bool = true
    public private(set) var sessionID: UUID?
    public private(set) var viewportID: UUID?
    public private(set) var isOccluded: Bool = false
    public private(set) var isMinimized: Bool = false
    public var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying {
                synchronizer.setRate(playbackRate, time: synchronizer.currentTime())
            }
        }
    }

    public var isPlaying: Bool {
        synchronizer.rate > 0.0
    }

    public var currentTime: CMTime {
        synchronizer.currentTime()
    }

    // MARK: - Callbacks & Delegation

    public var onTimeUpdate: ((CMTime) -> Void)?
    public var onTogglePlayPause: (() -> Void)?
    public var onToggleFullScreen: (() -> Void)?
    public var onSeek: ((CMTime) -> Void)?
    public var onHoverChanged: ((Bool) -> Void)?
    public var onMouseMovedAtPoint: ((CGPoint) -> Void)?
    public var onWindowFocusLost: (() -> Void)?
    public var onDropFiles: (([URL]) -> Void)?
    public var onVolumeChange: ((Float) -> Void)?
    public var onMuteToggle: (() -> Void)?
    public var onCanvasSingleClick: (() -> Void)?
    public var onCanvasDoubleClick: (() -> Void)?
    public var bottomControlBarExclusionHeight: CGFloat = 76.0
    public weak var controlsVisibility: MediaControlsVisibility?
    private var explicitControlBarVisible: Bool = true
    public var isControlBarVisible: Bool {
        get { controlsVisibility?.isVisible ?? explicitControlBarVisible }
        set { explicitControlBarVisible = newValue }
    }

    // MARK: - Video Geometry & Display Rotation

    public var videoContentRect: CGRect? {
        didSet {
            if oldValue != videoContentRect {
                needsLayout = true
            }
        }
    }

    public var userRotationDegrees: Int = 0 {
        didSet {
            let normalized = VideoContentGeometry.normalizedRotationDegrees(userRotationDegrees)
            if normalized != oldValue {
                needsLayout = true
            }
        }
    }

    public var onRotateClockwise: (() -> Void)?
    public var onRotateCounterClockwise: (() -> Void)?
    public var onRotate180: (() -> Void)?
    public var onResetRotation: (() -> Void)?
    public var formatDetailsSummary: String?
    public var onHostScreenObservationChanged: ((VideoHostScreenObservation, UUID?) -> Void)?

    // MARK: - DisplayLink & Occlusion State

    private var displayLink: CADisplayLink?
    private var trackingAreaRef: NSTrackingArea?
    private weak var observedHostWindow: NSWindow?
    private var singleClickTask: Task<Void, Never>?
    private var mouseDownLocationInView: NSPoint?
    private var didDragSinceMouseDown: Bool = false

    // DisplayLink Target Trampoline
    @MainActor
    private final class Trampoline: NSObject {
        weak var owner: AVSampleBufferPlayerNSView?

        init(owner: AVSampleBufferPlayerNSView) {
            self.owner = owner
            super.init()
        }

        @objc func onDisplayLinkPulse(_ link: CADisplayLink) {
            owner?.handleDisplayLinkPulse(link)
        }
    }

    private lazy var trampoline = Trampoline(owner: self)

    // MARK: - Lifecycle & Initialization

    public init(
        frame frameRect: NSRect = .zero,
        renderer: AVSampleBufferRenderer? = nil,
        synchronizer: AVSampleBufferRenderSynchronizer? = nil,
        audioRenderer: AVSampleBufferAudioRenderer? = nil,
        attachesDisplayLayerImmediately: Bool = true
    ) {
        let layer = renderer?.displayLayer ?? AVSampleBufferDisplayLayer()
        self.displayLayer = layer
        self.audioRenderer = audioRenderer ?? AVSampleBufferAudioRenderer()
        let synch = synchronizer ?? AVSampleBufferRenderSynchronizer()
        self.synchronizer = synch
        self.renderer = renderer ?? AVSampleBufferRenderer(displayLayer: layer)
        self.isPresenting = attachesDisplayLayerImmediately

        super.init(frame: frameRect)
        setupLayer(attachDisplayLayer: attachesDisplayLayerImmediately)
        registerForDraggedTypes([.fileURL])
    }

    public required init?(coder: NSCoder) {
        let layer = AVSampleBufferDisplayLayer()
        self.displayLayer = layer
        self.audioRenderer = AVSampleBufferAudioRenderer()
        self.synchronizer = AVSampleBufferRenderSynchronizer()
        self.renderer = AVSampleBufferRenderer(displayLayer: layer)
        self.isPresenting = true

        super.init(coder: coder)
        setupLayer(attachDisplayLayer: true)
        registerForDraggedTypes([.fileURL])
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupLayer(attachDisplayLayer: Bool) {
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        self.layerContentsRedrawPolicy = .duringViewResize
        self.layer?.masksToBounds = true

        // Configure video aspect ratio preserving gravity (zero distortion invariant)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        if attachDisplayLayer {
            self.layer?.addSublayer(displayLayer)
        }
    }

    /// Updates whether this viewport is the sole presenter permitted to host `displayLayer`.
    /// Inactive viewports never steal `displayLayer` back in `updateNSView` or `layout()`.
    public func updatePresentationOwnership(
        sessionID: UUID,
        viewportID: UUID,
        isPresenting: Bool,
        reason: String
    ) {
        let wasPresenting = self.isPresenting
        self.sessionID = sessionID
        self.viewportID = viewportID
        self.isPresenting = isPresenting

        guard isPresenting else {
            if wasPresenting {
                let superlayerDesc = displayLayer.superlayer.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
                logger.info(
                    "[PlaybackLifecycle] PRESENTER_RELINQUISHED session=\(sessionID.uuidString, privacy: .public) viewport=\(viewportID.uuidString, privacy: .public) reason=\(reason, privacy: .public) currentSuperlayer=\(superlayerDesc, privacy: .public)"
                )
            }
            return
        }

        if self.layer == nil {
            self.wantsLayer = true
        }
        guard let hostLayer = self.layer else { return }
        if displayLayer.superlayer !== hostLayer {
            let prevSuperlayer = displayLayer.superlayer.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            let newSuperlayer = String(describing: Unmanaged.passUnretained(hostLayer).toOpaque())
            hostLayer.addSublayer(displayLayer)
            applyDisplayLayerGeometry()
            if let window = self.window {
                displayLayer.contentsScale = window.backingScaleFactor
            }
            logger.info(
                "[PlaybackLifecycle] LAYER_ATTACH session=\(sessionID.uuidString, privacy: .public) viewport=\(viewportID.uuidString, privacy: .public) reason=\(reason, privacy: .public) prevSuperlayer=\(prevSuperlayer, privacy: .public) newSuperlayer=\(newSuperlayer, privacy: .public)"
            )
        } else {
            applyDisplayLayerGeometry()
        }
        notifyHostScreenObservationChanged()
    }

    // MARK: - Layout & Aspect Ratio Invariant

    public override func layout() {
        super.layout()
        guard isPresenting, displayLayer.superlayer === layer else { return }
        applyDisplayLayerGeometry()
    }

    /// Aligns displayLayer bounds, center position, and rotation transform with aspect-fitted video content rectangle.
    public func applyDisplayLayerGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rot = VideoContentGeometry.normalizedRotationDegrees(userRotationDegrees)
        if rot == 0 {
            displayLayer.setAffineTransform(.identity)
            displayLayer.frame = bounds
        } else {
            let targetRect = videoContentRect ?? bounds
            let isQuarterTurn = (rot == 90 || rot == 270)
            let layerBounds = isQuarterTurn
                ? CGRect(x: 0, y: 0, width: targetRect.height, height: targetRect.width)
                : CGRect(x: 0, y: 0, width: targetRect.width, height: targetRect.height)
            displayLayer.bounds = layerBounds
            displayLayer.position = CGPoint(x: targetRect.midX, y: targetRect.midY)
            let radians = CGFloat(rot) * .pi / 180.0
            displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: radians))
        }
        CATransaction.commit()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingAreaRef = area
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window = self.window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        notifyHostScreenObservationChanged()
    }

    // MARK: - Window Attachment & Occlusion Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if observedHostWindow !== self.window {
            if let oldWindow = observedHostWindow {
                CodeReadingToolsInteractionCoordinator.invalidateOwnedMenus(for: oldWindow)
            }
            observedHostWindow = self.window
        }
        if let window = self.window {
            setupWindowObservers(for: window)
            updateOcclusionState(for: window)
            setupDisplayLink()
            notifyHostScreenObservationChanged()
        } else {
            teardownWindowObservers()
            teardownDisplayLink()
            cancelPendingCanvasSingleClick()
            onWindowFocusLost?()
        }
    }

    private func setupWindowObservers(for window: NSWindow) {
        teardownWindowObservers()
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(handleWindowOcclusionChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        nc.addObserver(
            self,
            selector: #selector(handleWindowMiniaturize(_:)),
            name: NSWindow.didMiniaturizeNotification,
            object: window
        )
        nc.addObserver(
            self,
            selector: #selector(handleWindowDeminiaturize(_:)),
            name: NSWindow.didDeminiaturizeNotification,
            object: window
        )
        nc.addObserver(
            self,
            selector: #selector(handleWindowResignKeyOrActive(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        nc.addObserver(
            self,
            selector: #selector(handleWindowResignKeyOrActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleMenuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleMenuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleWindowScreenOrParametersChange(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        nc.addObserver(
            self,
            selector: #selector(handleWindowScreenOrParametersChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func teardownWindowObservers() {
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        nc.removeObserver(self, name: NSWindow.didMiniaturizeNotification, object: nil)
        nc.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: nil)
        nc.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        nc.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        nc.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        nc.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        nc.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        nc.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func handleMenuDidBeginTracking(_ notification: Notification) {
        let menuID = (notification.object as? NSMenu).map { ObjectIdentifier($0) }
        _ = CodeReadingToolsInteractionCoordinator.beginTrackedMenu(menuID: menuID, for: self.window)
    }

    @objc private func handleMenuDidEndTracking(_ notification: Notification) {
        let menuID = (notification.object as? NSMenu).map { ObjectIdentifier($0) }
        _ = CodeReadingToolsInteractionCoordinator.endTrackedMenu(menuID: menuID, for: self.window)
    }

    @objc private func handleWindowScreenOrParametersChange(_ notification: Notification) {
        notifyHostScreenObservationChanged()
    }

    private func notifyHostScreenObservationChanged() {
        guard isPresenting else { return }
        let snapshot = VideoRendererOutputEvaluator.snapshotHostScreen(from: self.window)
        onHostScreenObservationChanged?(snapshot, sessionID)
    }

    @objc private func handleWindowResignKeyOrActive(_ notification: Notification) {
        onWindowFocusLost?()
    }

    @objc private func handleWindowOcclusionChange(_ notification: Notification) {
        if let window = self.window {
            updateOcclusionState(for: window)
        }
    }

    @objc private func handleWindowMiniaturize(_ notification: Notification) {
        self.isMinimized = true
        suspendDisplayLink()
        onWindowFocusLost?()
    }

    @objc private func handleWindowDeminiaturize(_ notification: Notification) {
        self.isMinimized = false
        if let window = self.window {
            updateOcclusionState(for: window)
        }
    }

    private func updateOcclusionState(for window: NSWindow) {
        let isVisible = window.occlusionState.contains(.visible) && !isMinimized
        self.isOccluded = !isVisible

        if isVisible {
            resumeDisplayLink()
        } else {
            suspendDisplayLink()
            onWindowFocusLost?()
        }
    }

    // MARK: - ProMotion DisplayLink Refresh Synchronization

    private func setupDisplayLink() {
        teardownDisplayLink()
        let link = self.displayLink(target: trampoline, selector: #selector(Trampoline.onDisplayLinkPulse(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24.0, maximum: 120.0, preferred: 120.0)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    private func teardownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func suspendDisplayLink() {
        displayLink?.isPaused = true
    }

    private func resumeDisplayLink() {
        if !isOccluded && !isMinimized {
            displayLink?.isPaused = false
        }
    }

    private func handleDisplayLinkPulse(_ link: CADisplayLink) {
        guard isPlaying, !isOccluded else { return }
        let time = synchronizer.currentTime()
        onTimeUpdate?(time)
    }

    // MARK: - Master Clock Playback Controls

    /// Starts playback synchronized to the master clock at current playback rate.
    public func play() {
        synchronizer.setRate(playbackRate, time: synchronizer.currentTime())
        resumeDisplayLink()
    }

    /// Pauses playback on the master clock.
    public func pause() {
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
    }

    /// Toggles between play and pause states.
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
        onTogglePlayPause?()
    }

    /// Seeks to a specific presentation timestamp, flushing queued buffers across video and audio renderers.
    public func seek(to time: CMTime) {
        let wasPlaying = isPlaying
        displayLayer.flush()
        audioRenderer.flush()
        renderer.flush()

        let targetRate: Float = wasPlaying ? playbackRate : 0.0
        synchronizer.setRate(targetRate, time: time)
        onSeek?(time)
    }

    /// Adjusts audio output volume [0.0 ... 1.0].
    public func setVolume(_ volume: Float) {
        audioRenderer.volume = max(0.0, min(1.0, volume))
    }

    /// Sets video display gravity (default: `.resizeAspect` to prevent distortion).
    public func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        displayLayer.videoGravity = gravity
    }

    // MARK: - Keyboard and Mouse Gesture Handling

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Cancels any pending single-click canvas toggle task (e.g., when scrubbing or interacting with controls).
    public func cancelPendingCanvasSingleClick() {
        singleClickTask?.cancel()
        singleClickTask = nil
    }

    /// Evaluates whether a click at `locationInView` falls inside the bottom control bar exclusion zone.
    public func shouldIgnoreCanvasClick(at locationInView: NSPoint) -> Bool {
        guard isControlBarVisible, bottomControlBarExclusionHeight > 0 else { return false }
        return locationInView.y >= 0 && locationInView.y <= bottomControlBarExclusionHeight
    }

    public override func mouseDown(with event: NSEvent) {
        if self.window?.firstResponder !== self {
            self.window?.makeFirstResponder(self)
        }
        let loc = convert(event.locationInWindow, from: nil)
        mouseDownLocationInView = loc
        didDragSinceMouseDown = false
        if shouldIgnoreCanvasClick(at: loc) {
            cancelPendingCanvasSingleClick()
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        let loc = convert(event.locationInWindow, from: nil)
        if let start = mouseDownLocationInView,
           hypot(loc.x - start.x, loc.y - start.y) > 3.0 {
            didDragSinceMouseDown = true
            cancelPendingCanvasSingleClick()
        }
        onMouseMovedAtPoint?(loc)
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let loc = convert(event.locationInWindow, from: nil)
        onMouseMovedAtPoint?(loc)
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
        let loc = convert(event.locationInWindow, from: nil)
        onMouseMovedAtPoint?(loc)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    public override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let downLoc = mouseDownLocationInView
        let wasDragged = didDragSinceMouseDown
        mouseDownLocationInView = nil
        didDragSinceMouseDown = false

        if wasDragged || shouldIgnoreCanvasClick(at: loc) || (downLoc.map { shouldIgnoreCanvasClick(at: $0) } ?? false) {
            cancelPendingCanvasSingleClick()
            return
        }

        if event.clickCount == 2 {
            cancelPendingCanvasSingleClick()
            if let onCanvasDoubleClick {
                onCanvasDoubleClick()
            } else {
                onToggleFullScreen?()
            }
        } else if event.clickCount == 1 {
            cancelPendingCanvasSingleClick()
            let debounce = min(NSEvent.doubleClickInterval, 0.18)
            singleClickTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(debounce))
                guard !Task.isCancelled, let self else { return }
                if let onCanvasSingleClick = self.onCanvasSingleClick {
                    onCanvasSingleClick()
                } else {
                    self.togglePlayPause()
                }
            }
        } else {
            super.mouseUp(with: event)
        }
    }

    public override func keyDown(with event: NSEvent) {
        let isShift = event.modifierFlags.contains(.shift)
        // Space bar: Play/Pause
        if event.keyCode == 49 {
            if let onCanvasSingleClick {
                onCanvasSingleClick()
            } else {
                togglePlayPause()
            }
            return
        }
        // F key: Fullscreen / Media Focus
        if event.keyCode == 3 || event.charactersIgnoringModifiers?.lowercased() == "f" {
            if let onCanvasDoubleClick {
                onCanvasDoubleClick()
            } else {
                onToggleFullScreen?()
            }
            return
        }
        // M key: Mute toggle
        if event.keyCode == 46 || event.charactersIgnoringModifiers?.lowercased() == "m" {
            onMuteToggle?()
            return
        }
        // Left arrow: Seek backward (Shift: 1s, Normal: 10s)
        if event.keyCode == 123 {
            let delta = isShift ? -1.0 : -10.0
            let current = synchronizer.currentTime()
            let newSeconds = max(0.0, CMTimeGetSeconds(current) + delta)
            seek(to: CMTime(seconds: newSeconds, preferredTimescale: current.timescale))
            return
        }
        // Right arrow: Seek forward (Shift: 1s, Normal: 10s)
        if event.keyCode == 124 {
            let delta = isShift ? 1.0 : 10.0
            let current = synchronizer.currentTime()
            let newSeconds = max(0.0, CMTimeGetSeconds(current) + delta)
            seek(to: CMTime(seconds: newSeconds, preferredTimescale: current.timescale))
            return
        }
        // Up arrow: Volume +10%
        if event.keyCode == 126 {
            onVolumeChange?(0.1)
            return
        }
        // Down arrow: Volume -10%
        if event.keyCode == 125 {
            onVolumeChange?(-0.1)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Drag and Drop Handling

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types, types.contains(.fileURL) else {
            return []
        }
        return .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return false
        }
        onDropFiles?(urls)
        return true
    }

    // MARK: - Video Context Menu (Rotation, Fullscreen & Format)

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "VideoContextMenu")

        // 1. Play / Pause
        let playPauseItem = NSMenuItem(
            title: isPlaying ? MediaLocalization.text(.pause) : MediaLocalization.text(.play),
            action: #selector(handleMenuTogglePlayPause(_:)),
            keyEquivalent: " "
        )
        playPauseItem.target = self
        menu.addItem(playPauseItem)
        menu.addItem(NSMenuItem.separator())

        // 2. Rotation Submenu
        let rotationParentItem = NSMenuItem(
            title: VideoInteractionLocalization.text(.rotationMenu),
            action: nil,
            keyEquivalent: ""
        )
        menu.setSubmenu(makeRotationSubmenu(), for: rotationParentItem)
        menu.addItem(rotationParentItem)

        // 3. Fullscreen
        menu.addItem(NSMenuItem.separator())
        let fullScreenItem = NSMenuItem(
            title: MediaLocalization.text(.fullscreen),
            action: #selector(handleMenuToggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.target = self
        menu.addItem(fullScreenItem)

        // 4. Format Details Summary
        if let summary = formatDetailsSummary, !summary.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let formatItem = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
            formatItem.isEnabled = false
            menu.addItem(formatItem)
        }
        CodeReadingToolsInteractionCoordinator.registerOwnedMenu(
            menu,
            for: self.window,
            controlsVisibility: self.controlsVisibility
        )
        return menu
    }

    private func makeRotationSubmenu() -> NSMenu {
        let rotSubmenu = NSMenu(title: "Rotation")

        let rotCW = NSMenuItem(
            title: VideoInteractionLocalization.text(.rotateClockwise),
            action: #selector(handleMenuRotateCW(_:)),
            keyEquivalent: ""
        )
        rotCW.target = self
        rotSubmenu.addItem(rotCW)

        let rotCCW = NSMenuItem(
            title: VideoInteractionLocalization.text(.rotateCounterClockwise),
            action: #selector(handleMenuRotateCCW(_:)),
            keyEquivalent: ""
        )
        rotCCW.target = self
        rotSubmenu.addItem(rotCCW)

        let rot180 = NSMenuItem(
            title: VideoInteractionLocalization.text(.rotate180),
            action: #selector(handleMenuRotate180(_:)),
            keyEquivalent: ""
        )
        rot180.target = self
        rotSubmenu.addItem(rot180)

        rotSubmenu.addItem(NSMenuItem.separator())
        let resetRot = NSMenuItem(
            title: VideoInteractionLocalization.text(.resetOrientation),
            action: #selector(handleMenuResetRotation(_:)),
            keyEquivalent: ""
        )
        resetRot.target = self
        resetRot.isEnabled = (userRotationDegrees != 0)
        rotSubmenu.addItem(resetRot)

        return rotSubmenu
    }

    @objc private func handleMenuTogglePlayPause(_ sender: Any?) {
        if let onCanvasSingleClick {
            onCanvasSingleClick()
        } else {
            togglePlayPause()
        }
    }

    @objc private func handleMenuRotateCW(_ sender: Any?) {
        onRotateClockwise?()
    }

    @objc private func handleMenuRotateCCW(_ sender: Any?) {
        onRotateCounterClockwise?()
    }

    @objc private func handleMenuRotate180(_ sender: Any?) {
        onRotate180?()
    }

    @objc private func handleMenuResetRotation(_ sender: Any?) {
        onResetRotation?()
    }

    @objc private func handleMenuToggleFullScreen(_ sender: Any?) {
        if let onCanvasDoubleClick {
            onCanvasDoubleClick()
        } else {
            onToggleFullScreen?()
        }
    }
}


