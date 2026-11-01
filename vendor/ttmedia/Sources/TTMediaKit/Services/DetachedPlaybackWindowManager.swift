// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import QuartzCore

/// Dedicated macOS floating panel hosting the detached video playback viewport.
///
/// Configured with `.floating` window level, `.nonactivatingPanel` to avoid stealing
/// focus from other workspace applications, and background drag mobility.
@MainActor
internal final class DetachedPlaybackPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isFloatingPanel = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.animationBehavior = .utilityWindow
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Floating overlay container featuring delicate frosted glass (HUD material) and shimmer border.
@MainActor
internal final class DetachedRootContainerView: NSVisualEffectView {
    private let videoHostView = NSView()
    private var overlayView: DetachedControlsOverlayView?
    
    init(onDockBack: @escaping () -> Void) {
        super.init(frame: .zero)
        self.material = .hudWindow
        self.state = .active
        self.blendingMode = .behindWindow
        self.wantsLayer = true
        self.layer?.cornerRadius = 14.0
        self.layer?.masksToBounds = true
        self.layer?.borderWidth = 1.0
        self.layer?.borderColor = NSColor(white: 1.0, alpha: 0.18).cgColor
        
        videoHostView.frame = bounds
        videoHostView.autoresizingMask = [.width, .height]
        videoHostView.wantsLayer = true
        videoHostView.layer?.cornerRadius = 14.0
        videoHostView.layer?.masksToBounds = true
        addSubview(videoHostView)
        
        let overlay = DetachedControlsOverlayView(onDockBack: onDockBack)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        self.overlayView = overlay
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func embed(videoView: NSView) {
        videoView.frame = videoHostView.bounds
        videoView.autoresizingMask = [.width, .height]
        videoHostView.addSubview(videoView)
    }
}

/// Hover-activated controls overlay presenting the floating Dock Back action button.
@MainActor
internal final class DetachedControlsOverlayView: NSView {
    private let dockButton = NSButton()
    private var trackingAreaRef: NSTrackingArea?
    private let onDockBack: () -> Void
    
    init(onDockBack: @escaping () -> Void) {
        self.onDockBack = onDockBack
        super.init(frame: .zero)
        self.wantsLayer = true
        setupButton()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupButton() {
        dockButton.bezelStyle = .regularSquare
        dockButton.isBordered = false
        dockButton.title = ""
        dockButton.wantsLayer = true
        dockButton.layer?.cornerRadius = 14.0
        dockButton.layer?.masksToBounds = true
        dockButton.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.82).cgColor
        dockButton.layer?.borderWidth = 0.5
        dockButton.layer?.borderColor = NSColor(white: 1.0, alpha: 0.28).cgColor
        
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        dockButton.image = NSImage(
            systemSymbolName: "arrow.down.right.and.arrow.up.left",
            accessibilityDescription: "Dock Back"
        )?.withSymbolConfiguration(config)
        dockButton.imagePosition = .imageOnly
        dockButton.contentTintColor = .white
        
        dockButton.target = self
        dockButton.action = #selector(handleDockClicked)
        dockButton.alphaValue = 0.0
        addSubview(dockButton)
    }
    
    @objc private func handleDockClicked() {
        onDockBack()
    }
    
    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 28.0
        let margin: CGFloat = 12.0
        dockButton.frame = NSRect(
            x: bounds.width - buttonSize - margin,
            y: bounds.height - buttonSize - margin,
            width: buttonSize,
            height: buttonSize
        )
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            dockButton.animator().alphaValue = 1.0
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            dockButton.animator().alphaValue = 0.0
        }
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        let pointInButton = dockButton.convert(point, from: self)
        if dockButton.bounds.contains(pointInButton) && dockButton.alphaValue > 0.01 {
            return dockButton
        }
        // Pass through transparent areas so window background drag is unobstructed
        return nil
    }
}

/// Placeholder view mounted in the parent container while video playback is detached to floating window.
@MainActor
internal final class DetachedPlaceholderView: NSView {
    private let onRestore: () -> Void
    
    init(frame: NSRect, onRestore: @escaping () -> Void) {
        self.onRestore = onRestore
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor(white: 0.06, alpha: 1.0).cgColor
        
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 10
        container.alignment = .centerX
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        
        let imgView = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .light)
        imgView.image = NSImage(systemSymbolName: "pip.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        imgView.contentTintColor = NSColor(white: 0.6, alpha: 1.0)
        container.addArrangedSubview(imgView)
        
        let label = NSTextField(labelWithString: "Playing in Floating Window")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0.75, alpha: 1.0)
        container.addArrangedSubview(label)
        
        let restoreBtn = NSButton(title: "Restore to Window", target: self, action: #selector(handleRestoreClicked))
        restoreBtn.bezelStyle = .rounded
        container.addArrangedSubview(restoreBtn)
        
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func handleRestoreClicked() {
        onRestore()
    }
}

/// Operating mode of the detached floating playback window.
public enum DetachedWindowMode: Sendable {
    case videoPiP           // Dedicated floating video Picture-in-Picture viewport
    case compactAudioBar    // 72pt compact desktop floating mini audio player bar
}

/// Industrial detached floating window manager governing Picture-in-Picture and Mini Audio Bar playback sessions.
///
/// Seamlessly migrates the active playback viewport between the main application
/// window tree and an always-on-top, non-activating floating `NSPanel` without pipeline interruption.
@MainActor
public final class DetachedPlaybackWindowManager: NSObject, NSWindowDelegate {
    public static let shared = DetachedPlaybackWindowManager()
    
    public private(set) var isDetached: Bool = false
    public private(set) var currentMode: DetachedWindowMode? = nil
    
    private var panel: DetachedPlaybackPanel?
    private weak var detachedContainerView: NSView?
    private weak var originalSuperview: NSView?
    private weak var originalWindow: NSWindow?
    private var originalFrame: NSRect = .zero
    private var originalAutoresizingMask: NSView.AutoresizingMask = []
    private var placeholderView: NSView?
    private var windowCloseObserver: (any NSObjectProtocol)?
    private var miniAudioHostingView: NSView?
    private var onDockBackCustomHandler: (() -> Void)?
    private var isSnapping: Bool = false
    
    public override init() {
        super.init()
    }
    
    deinit {
        MainActor.assumeIsolated {
            if let obs = windowCloseObserver {
                NotificationCenter.default.removeObserver(obs)
                windowCloseObserver = nil
            }
        }
    }
    
    private func ensureRawPanel() -> DetachedPlaybackPanel {
        if let existing = self.panel {
            return existing
        }
        let newPanel = DetachedPlaybackPanel()
        newPanel.delegate = self
        self.panel = newPanel
        return newPanel
    }
    
    private func configurePanelForVideoPiP() -> DetachedPlaybackPanel {
        let p = ensureRawPanel()
        if !(p.contentView is DetachedRootContainerView) {
            let root = DetachedRootContainerView { [weak self] in
                self?.dockBack()
            }
            p.contentView = root
        }
        p.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView]
        return p
    }
    
    private func configurePanelForAudioMiniBar() -> DetachedPlaybackPanel {
        let p = ensureRawPanel()
        p.styleMask = [.titled, .closable, .nonactivatingPanel, .fullSizeContentView]
        return p
    }
    
    /// Detaches the current playback viewport into an always-on-top floating desktop panel.
    public func detach(from containerView: NSView, videoSize: CGSize) {
        guard !isDetached else { return }
        guard let superview = containerView.superview, let originalWin = containerView.window else { return }
        
        self.currentMode = .videoPiP
        self.detachedContainerView = containerView
        self.originalSuperview = superview
        self.originalWindow = originalWin
        self.originalFrame = containerView.frame
        self.originalAutoresizingMask = containerView.autoresizingMask
        
        // 1. Resolve video native aspect ratio
        var aspect = CGSize(width: 16, height: 9)
        if videoSize.width > 0 && videoSize.height > 0 {
            aspect = videoSize
        }
        
        // 2. Configure dedicated floating panel
        let detachedPanel = configurePanelForVideoPiP()
        detachedPanel.contentAspectRatio = aspect
        
        let screen = originalWin.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultWidth: CGFloat = 480
        let defaultHeight: CGFloat = ceil(defaultWidth * (aspect.height / aspect.width))
        let originX = visibleFrame.maxX - defaultWidth - 24
        let originY = visibleFrame.minY + 24
        let panelFrame = NSRect(x: originX, y: originY, width: defaultWidth, height: defaultHeight)
        
        detachedPanel.minSize = CGSize(width: 240, height: ceil(240 * (aspect.height / aspect.width)))
        detachedPanel.maxSize = CGSize(width: visibleFrame.width * 0.85, height: visibleFrame.height * 0.85)
        detachedPanel.setFrame(panelFrame, display: true)
        
        // 3. Mount placeholder in parent hierarchy
        let placeholder = DetachedPlaceholderView(frame: containerView.frame) { [weak self] in
            self?.dockBack()
        }
        placeholder.autoresizingMask = containerView.autoresizingMask
        superview.addSubview(placeholder, positioned: .below, relativeTo: containerView)
        self.placeholderView = placeholder
        
        containerView.removeFromSuperview()
        
        if let root = detachedPanel.contentView as? DetachedRootContainerView {
            root.embed(videoView: containerView)
        }
        
        // 5. Observe parent window lifecycle to auto-dock on close
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: originalWin,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dockBack()
            }
        }
        
        detachedPanel.orderFront(nil)
        self.isDetached = true
    }
    
    /// Detaches playback into an always-on-top 72pt compact desktop floating mini audio player bar.
    ///
    /// - Parameters:
    ///   - store: Shared MPVMetalPlayerStore controlling playback and pipeline state.
    ///   - title: Track title displayed in the primary marquee lane.
    ///   - artist: Optional artist/creator information displayed in the secondary lane.
    ///   - artwork: Optional album artwork thumbnail rendered on the rotating vinyl disc.
    ///   - parentWindow: Optional parent window whose closure triggers automatic docking.
    ///   - onPrevious: Optional custom previous-track callback.
    ///   - onNext: Optional custom next-track callback.
    ///   - onRestore: Optional custom docking restoration callback.
    public func detachAsMiniAudioBar(
        store: MPVAudioEngine,
        title: String,
        artist: String? = nil,
        artwork: NSImage? = nil,
        parentWindow: NSWindow? = nil,
        onPrevious: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        onRestore: (() -> Void)? = nil
    ) {
        if isDetached {
            dockBack()
        }
        
        self.currentMode = .compactAudioBar
        self.originalWindow = parentWindow
        self.onDockBackCustomHandler = onRestore
        
        let targetPanel = configurePanelForAudioMiniBar()
        targetPanel.contentAspectRatio = .zero
        
        let miniWidth: CGFloat = 380
        let miniHeight: CGFloat = 72
        targetPanel.minSize = CGSize(width: miniWidth, height: miniHeight)
        targetPanel.maxSize = CGSize(width: miniWidth, height: miniHeight)
        
        let screen = parentWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = visibleFrame.maxX - miniWidth - 24
        let originY = visibleFrame.minY + 24
        let initialFrame = NSRect(x: originX, y: originY, width: miniWidth, height: miniHeight)
        targetPanel.setFrame(initialFrame, display: true)
        
        let miniView = CompactMiniAudioPlayerView(
            store: store,
            title: title,
            artist: artist,
            artwork: artwork,
            onPrevious: onPrevious,
            onNext: onNext,
            onRestore: { [weak self] in
                self?.dockBack()
            }
        )
        let hostingView = NSHostingView(rootView: miniView)
        hostingView.frame = NSRect(x: 0, y: 0, width: miniWidth, height: miniHeight)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 14.0
        hostingView.layer?.masksToBounds = true
        
        targetPanel.contentView = hostingView
        self.miniAudioHostingView = hostingView
        
        if let parentWin = parentWindow {
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: parentWin,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dockBack()
                }
            }
        }
        
        targetPanel.orderFront(nil)
        self.isDetached = true
    }
    
    /// Docks the detached viewport back into the original parent view hierarchy.
    public func dockBack() {
        guard isDetached else { return }
        
        if let obs = windowCloseObserver {
            NotificationCenter.default.removeObserver(obs)
            windowCloseObserver = nil
        }
        
        if currentMode == .compactAudioBar {
            onDockBackCustomHandler?()
            onDockBackCustomHandler = nil
            panel?.orderOut(nil)
            panel?.contentView = nil
            miniAudioHostingView = nil
            self.originalWindow = nil
            self.isDetached = false
            self.currentMode = nil
            return
        }
        
        guard let containerView = detachedContainerView else {
            isDetached = false
            currentMode = nil
            panel?.orderOut(nil)
            return
        }
        
        containerView.removeFromSuperview()
        
        if let placeholder = placeholderView, let superview = placeholder.superview {
            superview.addSubview(containerView, positioned: .below, relativeTo: placeholder)
            containerView.frame = placeholder.frame
            containerView.autoresizingMask = originalAutoresizingMask
            placeholder.removeFromSuperview()
            self.placeholderView = nil
        } else if let superview = originalSuperview {
            superview.addSubview(containerView)
            containerView.frame = originalFrame
            containerView.autoresizingMask = originalAutoresizingMask
        }
        
        panel?.orderOut(nil)
        self.detachedContainerView = nil
        self.originalSuperview = nil
        self.originalWindow = nil
        self.isDetached = false
        self.currentMode = nil
    }
    
    // MARK: - NSWindowDelegate
    
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        dockBack()
        return false
    }
    
    public func windowDidMove(_ notification: Notification) {
        guard !isSnapping, let p = self.panel, currentMode == .compactAudioBar else { return }
        guard let screen = p.screen else { return }
        
        let snapThreshold: CGFloat = 20.0
        let visibleFrame = screen.visibleFrame
        var frame = p.frame
        var didSnap = false
        
        // Magnetic snap to left screen edge
        if abs(frame.minX - visibleFrame.minX) < snapThreshold {
            frame.origin.x = visibleFrame.minX + 8
            didSnap = true
        }
        // Magnetic snap to right screen edge
        else if abs(frame.maxX - visibleFrame.maxX) < snapThreshold {
            frame.origin.x = visibleFrame.maxX - frame.width - 8
            didSnap = true
        }
        // Magnetic snap to bottom screen edge
        else if abs(frame.minY - visibleFrame.minY) < snapThreshold {
            frame.origin.y = visibleFrame.minY + 8
            didSnap = true
        }
        // Magnetic snap to top screen edge
        else if abs(frame.maxY - visibleFrame.maxY) < snapThreshold {
            frame.origin.y = visibleFrame.maxY - frame.height - 8
            didSnap = true
        }
        
        if didSnap {
            isSnapping = true
            p.setFrame(frame, display: true, animate: true)
            DispatchQueue.main.async { [weak self] in
                self?.isSnapping = false
            }
        }
    }
}
