// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Observation
import SwiftUI
import TTMediaKit
import TTZipUI

/// Shared bottom-trailing floating corner button overlay with a passive proximity hover sensor
/// and a native focusable `NSButton` that blocks zero content hit-testing while hidden.
/// Backed by `PreviewCornerActionRevealCoordinator` in `TTMediaKit`.
@MainActor
public struct PreviewCornerActionOverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var envReduceTransparency
    @Environment(\.colorSchemeContrast) private var envColorSchemeContrast
    @Environment(\.textFloatingToolsStateOverride) private var envFloatingToolsStateOverride
    @Environment(\.mediaControlsVisibility) private var envControlsVisibility

    public let id: String
    public let symbolName: String
    public let accessibilityLabel: String
    public let helpText: String
    public let explicitStateOverride: TTTextFloatingToolsPresentationState?
    public let externalControlsVisibility: MediaControlsVisibility?
    public let coordinator: PreviewCornerActionRevealCoordinator?
    public let action: @MainActor () -> Void

    @State private var ownedCoordinator = PreviewCornerActionRevealCoordinator()
    @State private var sensorAnchor = PreviewCornerSensorAnchorBox()

    public init(
        id: String,
        symbolName: String,
        accessibilityLabel: String,
        helpText: String,
        explicitStateOverride: TTTextFloatingToolsPresentationState? = nil,
        externalControlsVisibility: MediaControlsVisibility? = nil,
        coordinator: PreviewCornerActionRevealCoordinator? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.symbolName = symbolName
        self.accessibilityLabel = accessibilityLabel
        self.helpText = helpText
        self.explicitStateOverride = explicitStateOverride
        self.externalControlsVisibility = externalControlsVisibility
        self.coordinator = coordinator
        self.action = action
    }

    private var activeCoordinator: PreviewCornerActionRevealCoordinator {
        coordinator ?? ownedCoordinator
    }

    private var resolvedExplicitState: TTTextFloatingToolsPresentationState? {
        explicitStateOverride ?? envFloatingToolsStateOverride
    }

    private var resolvedControlsVisibility: MediaControlsVisibility? {
        externalControlsVisibility ?? envControlsVisibility
    }

    private var isExternallyLocked: Bool {
        let hasControlLock = resolvedControlsVisibility?.hasActiveInteractionLock ?? false
        let targetWindow = sensorAnchor.resolvedWindow
        let hasChildPopoverOrPanel = (targetWindow?.childWindows ?? []).contains { $0.isVisible }
            || sensorAnchor.hasActiveInWindowPopover
        let hasActiveMenu = CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(
            for: targetWindow
        )
        return hasControlLock || hasChildPopoverOrPanel || hasActiveMenu
    }

    private var usesReducedMotion: Bool {
        envReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var usesHighContrastOrReducedTransparency: Bool {
        envReduceTransparency
            || envColorSchemeContrast == .increased
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    public var isButtonVisible: Bool {
        activeCoordinator.isPresented(explicitState: resolvedExplicitState)
    }

    public var body: some View {
        let isVisible = isButtonVisible
        let isHighlighted = activeCoordinator.isButtonHovered || activeCoordinator.isButtonFocused
        let shape = RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)

        ZStack(alignment: .bottomTrailing) {
            PreviewCornerHoverSensorRepresentable(
                sensorID: "\(id).HoverSensor",
                anchor: sensorAnchor,
                onHoverChange: { hovering in
                    let locked = isExternallyLocked
                    updateCoordinator {
                        $0.setExternallyLocked(locked)
                        $0.setZoneHovered(hovering)
                    }
                }
            )
            .frame(
                width: PreviewCornerActionRevealCoordinator.defaultSensorSize.width,
                height: PreviewCornerActionRevealCoordinator.defaultSensorSize.height
            )

            PreviewCornerNativeButtonRepresentable(
                id: id,
                symbolName: symbolName,
                accessibilityLabel: accessibilityLabel,
                helpText: helpText,
                isVisible: isVisible,
                isHighlighted: isHighlighted,
                onHoverChange: { hovering in
                    let locked = isExternallyLocked
                    updateCoordinator {
                        $0.setExternallyLocked(locked)
                        $0.setButtonHovered(hovering)
                    }
                },
                onFocusChange: { focused in
                    let locked = isExternallyLocked
                    updateCoordinator {
                        $0.setExternallyLocked(locked)
                        $0.setButtonFocused(focused)
                    }
                },
                action: action
            )
            .frame(width: 28, height: 28)
            .background {
                if isVisible {
                    buttonGlassPlate(in: shape, isHighlighted: isHighlighted)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isVisible {
                    shape.strokeBorder(
                        Color.white.opacity(isHighlighted ? 0.42 : 0.22),
                        lineWidth: TTZipTheme.Layout.hairlineBorderWidth
                    )
                    .allowsHitTesting(false)
                }
            }
            .scaleEffect(isVisible ? 1.0 : (usesReducedMotion ? 1.0 : 0.96), anchor: .bottomTrailing)
            .environment(\.ttButtonHelpEnabled, isVisible)
            .ttButtonHelp(helpText)
            .padding(.trailing, TTZipTheme.Spacing.sm)
            .padding(.bottom, TTZipTheme.Spacing.sm)
        }
        .onChange(of: isExternallyLocked, initial: true) { _, locked in
            updateCoordinator { $0.setExternallyLocked(locked) }
        }
        .onChange(of: resolvedControlsVisibility?.lifecycleGeneration) { _, _ in
            activeCoordinator.tearDown()
        }
        .onDisappear {
            activeCoordinator.tearDown()
        }
    }

    @ViewBuilder
    private func buttonGlassPlate(in shape: RoundedRectangle, isHighlighted: Bool) -> some View {
        if usesHighContrastOrReducedTransparency {
            shape.fill(TTZipUniversalTokens.Mineral.obsidianBlack.opacity(isHighlighted ? 0.94 : 0.88))
        } else {
            shape
                .fill(TTZipUniversalTokens.Mineral.obsidianBlack.opacity(isHighlighted ? 0.64 : 0.36))
                .background(.ultraThinMaterial, in: shape)
        }
    }

    private func updateCoordinator(_ mutation: (PreviewCornerActionRevealCoordinator) -> Void) {
        if usesReducedMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                mutation(activeCoordinator)
            }
        } else {
            withAnimation(TTZipTheme.Motion.micro) {
                mutation(activeCoordinator)
            }
        }
    }
}

@MainActor
private final class PreviewCornerSensorAnchorBox {
    weak var sensorView: NSView?
    weak var hostWindow: NSWindow?
    var resolvedWindow: NSWindow? {
        sensorView?.window ?? hostWindow
    }
    var hasActiveInWindowPopover: Bool {
        guard let root = resolvedWindow?.contentView else { return false }
        return Self.containsActivePopoverControl(in: root)
    }

    private static func containsActivePopoverControl(in view: NSView) -> Bool {
        if let button = view as? NSButton,
           button.accessibilityIdentifier() == "CodeFloatingFontIncreaseButton",
           !button.isHidden,
           button.alphaValue > 0.01 {
            return true
        }
        for child in view.subviews where containsActivePopoverControl(in: child) {
            return true
        }
        return false
    }
}

private struct PreviewCornerHoverSensorRepresentable: NSViewRepresentable {
    let sensorID: String
    let anchor: PreviewCornerSensorAnchorBox
    let onHoverChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> PreviewCornerHoverSensorNSView {
        let view = PreviewCornerHoverSensorNSView(frame: .zero)
        view.setAccessibilityIdentifier(sensorID)
        view.anchor = anchor
        view.onHoverChange = onHoverChange
        anchor.sensorView = view
        anchor.hostWindow = view.window
        return view
    }

    func updateNSView(_ nsView: PreviewCornerHoverSensorNSView, context: Context) {
        nsView.setAccessibilityIdentifier(sensorID)
        nsView.anchor = anchor
        nsView.onHoverChange = onHoverChange
        anchor.sensorView = nsView
        if let win = nsView.window {
            anchor.hostWindow = win
        }
    }

    static func dismantleNSView(_ nsView: PreviewCornerHoverSensorNSView, coordinator: ()) {
        nsView.tearDown()
    }
}

/// Passive AppKit tracking view that senses pointer entry/exit in the bottom-trailing corner
/// while returning `nil` from `hitTest(_:)` so underlying preview content receives 100% of clicks, drags, and scrolls.
@MainActor
public final class PreviewCornerHoverSensorNSView: NSView {
    fileprivate weak var anchor: PreviewCornerSensorAnchorBox?
    var onHoverChange: (@MainActor (Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    public private(set) var isPointerInside = false {
        didSet {
            if oldValue != isPointerInside {
                onHoverChange?(isPointerInside)
            }
        }
    }

    override public var isFlipped: Bool { true }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        anchor?.hostWindow = window
        if window == nil {
            isPointerInside = false
        }
    }

    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        let localPoint = convert(event.locationInWindow, from: nil)
        isPointerInside = bounds.insetBy(dx: -1.0, dy: -1.0).contains(localPoint)
    }

    override public func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let localPoint = convert(event.locationInWindow, from: nil)
        isPointerInside = bounds.contains(localPoint)
    }

    override public func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerInside = false
    }

    func tearDown() {
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
            trackingAreaRef = nil
        }
        isPointerInside = false
    }
}

private struct PreviewCornerNativeButtonRepresentable: NSViewRepresentable {
    let id: String
    let symbolName: String
    let accessibilityLabel: String
    let helpText: String
    let isVisible: Bool
    let isHighlighted: Bool
    let onHoverChange: @MainActor (Bool) -> Void
    let onFocusChange: @MainActor (Bool) -> Void
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> PreviewCornerActionNSButton {
        let button = PreviewCornerActionNSButton(frame: .zero)
        configure(button)
        return button
    }

    func updateNSView(_ nsView: PreviewCornerActionNSButton, context: Context) {
        configure(nsView)
    }

    private func configure(_ button: PreviewCornerActionNSButton) {
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityLabel(accessibilityLabel)
        button.symbolName = symbolName
        button.isChromeVisible = isVisible
        button.isChromeHighlighted = isHighlighted
        button.onHoverChange = onHoverChange
        button.onFocusChange = onFocusChange
        button.onAction = action
        button.needsDisplay = true
    }
}

/// Native `NSButton` for the preview corner action (`28 × 28 pt`).
/// Remains in the key-view loop for keyboard Tab focus and accessibility press even while visually hidden,
/// while yielding `hitTest(_:) -> nil` when `isChromeVisible == false` so hidden controls never swallow pointer events.
@MainActor
public final class PreviewCornerActionNSButton: NSButton {
    public var symbolName: String = "" {
        didSet {
            if oldValue != symbolName { needsDisplay = true }
        }
    }
    public var isChromeVisible: Bool = false {
        didSet {
            if oldValue != isChromeVisible { needsDisplay = true }
        }
    }
    public var isChromeHighlighted: Bool = false {
        didSet {
            if oldValue != isChromeHighlighted { needsDisplay = true }
        }
    }
    var onAction: (@MainActor () -> Void)?
    var onHoverChange: (@MainActor (Bool) -> Void)?
    var onFocusChange: (@MainActor (Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    public private(set) var isPointerHovered = false {
        didSet {
            if oldValue != isPointerHovered {
                onHoverChange?(isPointerHovered)
                needsDisplay = true
            }
        }
    }

    override public var isFlipped: Bool { true }

    override public var acceptsFirstResponder: Bool { isEnabled }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: 28.0, height: 28.0)
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isTransparent = false
        bezelStyle = .regularSquare
        title = ""
        target = self
        action = #selector(handleTriggered(_:))
        setButtonType(.momentaryPushIn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard isChromeVisible, isEnabled, !isHidden else { return nil }
        return super.hitTest(point)
    }

    @objc
    private func handleTriggered(_ sender: Any?) {
        guard isEnabled, !isHidden, isChromeVisible else { return }
        onAction?()
    }

    override public func mouseDown(with event: NSEvent) {
        guard isEnabled, !isHidden, isChromeVisible else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint), hitTest(convert(localPoint, to: superview)) === self else {
            return
        }
        super.mouseDown(with: event)
        needsDisplay = true
    }

    override public func performClick(_ sender: Any?) {
        guard isEnabled, !isHidden else { return }
        if !isChromeVisible {
            onFocusChange?(true)
        }
        onAction?()
    }

    override public func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isHidden else { return false }
        onAction?()
        return true
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        let localPoint = convert(event.locationInWindow, from: nil)
        isPointerHovered = bounds.insetBy(dx: -1.0, dy: -1.0).contains(localPoint)
    }

    override public func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let localPoint = convert(event.locationInWindow, from: nil)
        isPointerHovered = bounds.contains(localPoint)
    }

    override public func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerHovered = false
    }

    override public func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?(true)
            needsDisplay = true
        }
        return accepted
    }

    override public func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
            needsDisplay = true
        }
        return resigned
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard isChromeVisible, bounds.width > 0, bounds.height > 0, !symbolName.isEmpty else {
            return
        }
        let config = NSImage.SymbolConfiguration(pointSize: 11.0, weight: .semibold)
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config),
              let tinted = baseImage.copy() as? NSImage else {
            return
        }
        let alpha: CGFloat = (isChromeHighlighted || isHighlighted || isPointerHovered) ? 0.98 : 0.86
        let tint = NSColor.white.withAlphaComponent(alpha)
        tinted.lockFocus()
        tint.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let imgSize = tinted.size
        let imgRect = NSRect(
            x: bounds.midX - imgSize.width / 2.0,
            y: bounds.midY - imgSize.height / 2.0,
            width: imgSize.width,
            height: imgSize.height
        )
        tinted.draw(in: imgRect)
    }
}
