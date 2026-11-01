// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

private struct TTButtonHelpEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    var ttButtonHelpEnabled: Bool {
        get { self[TTButtonHelpEnabledKey.self] }
        set { self[TTButtonHelpEnabledKey.self] = newValue }
    }
}

public extension View {
    /// Displays local, non-activating help after a continuous one-second hover.
    func ttButtonHelp(_ text: String) -> some View {
        modifier(TTDelayedButtonHelpModifier(text: text))
    }
}

private struct TTDelayedButtonHelpModifier: ViewModifier {
    let text: String
    @Environment(\.ttButtonHelpEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content.accessibilityLabel(text)
            .accessibilityHint(text)
            .onHover { isHovered = $0 }
            .background {
                if isHovered && isEnabled && !text.isEmpty {
                    TTDelayedButtonHelpAnchor(text: text, isEnabled: isEnabled).allowsHitTesting(false)
                }
            }
            .onDisappear { isHovered = false }
    }
}

@MainActor
final class TTButtonHelpDelay {
    typealias Wait = @Sendable (Duration) async throws -> Void
    nonisolated static let defaultDelay: Duration = .seconds(1)
    private let delay: Duration
    private let wait: Wait
    private var generation: UInt64 = 0
    private(set) var isEnabled = true
    var onDisabled: (@MainActor () -> Void)?
    private(set) var pendingTask: Task<Void, Never>?

    init(delay: Duration = defaultDelay, wait: @escaping Wait = { try await Task.sleep(for: $0) }) {
        self.delay = delay
        self.wait = wait
    }

    func begin(onReady: @escaping @MainActor () -> Void) {
        guard isEnabled else { return }
        cancel()
        let token = generation
        let delay = delay
        let wait = wait
        pendingTask = Task { [weak self] in
            do { try await wait(delay) } catch { return }
            guard !Task.isCancelled, let self, self.isEnabled, self.generation == token else { return }
            onReady()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if !enabled {
            cancel()
            onDisabled?()
        }
    }

    func cancel() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }
}

private struct TTDelayedButtonHelpAnchor: NSViewRepresentable {
    var text: String
    var isEnabled: Bool

    func makeNSView(context: Context) -> TTButtonHelpTrackingView {
        let view = TTButtonHelpTrackingView(text: text)
        view.updateEnabled(isEnabled)
        return view
    }

    func updateNSView(_ view: TTButtonHelpTrackingView, context: Context) {
        view.updateText(text)
        view.updateEnabled(isEnabled)
    }

    static func dismantleNSView(_ view: TTButtonHelpTrackingView, coordinator: ()) {
        view.tearDown()
    }
}

@MainActor
private final class TTButtonHelpTrackingView: NSView {
    private static weak var visibleOwner: TTButtonHelpTrackingView?
    private var text: String
    private var eventMonitor: Any?
    private var area: NSTrackingArea?
    private var helpPanel: TTButtonHelpPanel?
    private let delay = TTButtonHelpDelay()

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        delay.onDisabled = { [weak self] in self?.hideHelp() }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(applicationDeactivated), name: NSApplication.willResignActiveNotification, object: nil)
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            center.addObserver(self, selector: #selector(hostChanged(_:)), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { return nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(next)
        area = next
        bootstrapHoverIfNeeded()
    }

    override func layout() {
        super.layout()
        bootstrapHoverIfNeeded()
    }

    override func mouseEntered(with event: NSEvent) { bootstrapHoverIfNeeded() }

    private func beginHover() {
        guard delay.isEnabled, !text.isEmpty, delay.pendingTask == nil, helpPanel == nil else { return }
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
            ) { [weak self] event in
                self?.hideHelp()
                return event
            }
        }
        delay.begin { [weak self] in self?.presentIfStillHovered() }
    }

    override func mouseExited(with event: NSEvent) { hideHelp() }

    override func mouseMoved(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { hideHelp(); return }
        bootstrapHoverIfNeeded()
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { hideHelp() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideHelp()
        bootstrapHoverIfNeeded()
    }

    func updateEnabled(_ enabled: Bool) {
        delay.setEnabled(enabled)
        if enabled { bootstrapHoverIfNeeded() }
    }

    func updateText(_ next: String) {
        guard text != next else { return }
        text = next
        hideHelp()
        bootstrapHoverIfNeeded()
    }

    func tearDown() {
        hideHelp()
        NotificationCenter.default.removeObserver(self)
        if let area { removeTrackingArea(area) }
        area = nil
    }

    @objc private func applicationDeactivated() { hideHelp() }

    @objc private func hostChanged(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        hideHelp()
    }

    private func hideHelp() {
        delay.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if Self.visibleOwner === self { Self.visibleOwner = nil }
        if let helpPanel {
            helpPanel.parent?.removeChildWindow(helpPanel)
            helpPanel.orderOut(nil)
        }
        helpPanel = nil
    }

    private var hoveredScreenAnchor: NSRect? {
        guard delay.isEnabled, let window, window.isVisible, window.isKeyWindow, NSApp.isActive,
              !text.isEmpty, !isHiddenOrHasHiddenAncestor else { return nil }
        let visibleBounds = bounds.intersection(visibleRect)
        guard !visibleBounds.isEmpty else { return nil }
        let anchor = window.convertToScreen(convert(visibleBounds, to: nil))
        return anchor.contains(NSEvent.mouseLocation) ? anchor : nil
    }

    private func bootstrapHoverIfNeeded() {
        guard hoveredScreenAnchor != nil else { return }
        beginHover()
    }

    private func presentIfStillHovered() {
        guard let window, let anchor = hoveredScreenAnchor else { return }
        if let other = Self.visibleOwner, other !== self {
            if other.bounds.width * other.bounds.height <= bounds.width * bounds.height { return }
            other.hideHelp()
        }
        Self.visibleOwner = self
        let panel = TTButtonHelpPanel(text: text, anchor: anchor, screen: window.screen)
        helpPanel = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }
}

@MainActor
private final class TTButtonHelpPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(text: String, anchor: NSRect, screen: NSScreen?) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 4
        let size = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 320, height: 120)) ?? NSSize(width: 160, height: 20)
        let contentSize = NSSize(width: min(320, max(30, size.width)) + 20, height: min(120, max(16, size.height)) + 12)
        super.init(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = true
        level = .floating
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
        material.material = .toolTip
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 8
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        label.frame = NSRect(x: 10, y: 6, width: contentSize.width - 20, height: contentSize.height - 12)
        material.addSubview(label)
        contentView = material
        position(anchor: anchor, screen: screen)
    }

    required init?(coder: NSCoder) { return nil }

    private func position(anchor: NSRect, screen: NSScreen?) {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor.insetBy(dx: -200, dy: -100)
        let x = min(max(anchor.midX - frame.width / 2, visible.minX + 4), visible.maxX - frame.width - 4)
        var y = anchor.minY - frame.height - 6
        if y < visible.minY + 4 { y = min(anchor.maxY + 6, visible.maxY - frame.height - 4) }
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
