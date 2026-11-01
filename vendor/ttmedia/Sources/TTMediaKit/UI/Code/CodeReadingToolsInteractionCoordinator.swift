// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI

/// Three visual states for the content-first floating reading tools overlay.
/// Across all three states, the underlying document viewport frame, origin, height, scroll offset,
/// and first-line glyph position remain 100% invariant.
public enum TTTextFloatingToolsPresentationState: String, Sendable, Equatable, CaseIterable {
    /// Quiet reading state: content fills 100% of the window; reading tools cluster is hidden.
    case quietReading = "quietReading"
    /// Floating buttons visible: compact glass `[ Aa ⎘ ]` cluster appears at bottom-right next to `[ ↙↗ ]`.
    case controlsVisible = "controlsVisible"
    /// Tool popover expanded: compact glass card with theme, font size, line numbers, actions, and document badges opens above `[ Aa ⎘ ]`.
    case popoverExpanded = "popoverExpanded"

    public var showsControlsCluster: Bool {
        self != .quietReading
    }

    public var isPopoverOpen: Bool {
        self == .popoverExpanded
    }
}

/// Instance-scoped coordinator owned by `CodeTextEditorContainerView` that handles local `Escape` dismissal
/// for `isReadingToolsPopoverPresented` and maintains an idempotent 1:1 interaction lock on `MediaControlsVisibility`.
@MainActor
public final class CodeReadingToolsInteractionCoordinator {
    public weak var anchorView: NSView?
    public weak var hostWindow: NSWindow?
    public weak var controlsVisibility: MediaControlsVisibility?
    public private(set) var isPopoverPresented: Bool = false
    public private(set) var hasAcquiredInteractionLock: Bool = false
    public private(set) var isMounted: Bool = false
    public var onRequestDismissPopover: (() -> Void)?
    private var keyMonitor: Any?
    private static var lastPopoverDismissEscapeWindowNumber: Int?
    private static var lastPopoverDismissEscapeTimestampBits: UInt64?

    public init() {}

    public static func wasEscapeConsumedForPopoverDismissal(
        windowNumber: Int?,
        timestamp: TimeInterval?
    ) -> Bool {
        guard let windowNumber,
              let timestamp,
              let lastWin = lastPopoverDismissEscapeWindowNumber,
              let lastBits = lastPopoverDismissEscapeTimestampBits else {
            return false
        }
        return lastWin == windowNumber && lastBits == timestamp.bitPattern
    }

    /// Strict window ownership check for `Escape` events:
    /// - Rejects `targetWindowNumber <= 0`.
    /// - When `event` carries a non-zero `windowNumber` (or `event.window?.windowNumber`), it must equal `targetWindowNumber`.
    /// - When `eventWindowNumber == 0` (`event.window == nil`), it is rejected unless `targetWindow` is demonstrably
    ///   the active `keyWindow` (`targetWindow.isKeyWindow && NSApplication.shared.keyWindow === targetWindow`).
    public static func doesEscapeEventBelongToWindow(
        eventWindow: NSWindow?,
        eventWindowNumber: Int,
        targetWindow: NSWindow
    ) -> Bool {
        let targetNumber = targetWindow.windowNumber
        guard targetNumber > 0 else {
            return false
        }
        if let eventWindow {
            return eventWindow === targetWindow && eventWindow.windowNumber == targetNumber
        }
        if eventWindowNumber != 0 {
            return eventWindowNumber == targetNumber
        }
        return targetWindow.isKeyWindow && NSApplication.shared.keyWindow === targetWindow
    }

    public var resolvedWindow: NSWindow? {
        anchorView?.window ?? hostWindow
    }

    public func syncState(
        isPopoverPresented: Bool,
        controlsVisibility: MediaControlsVisibility?,
        onRequestDismissPopover: @escaping () -> Void
    ) {
        if self.controlsVisibility !== controlsVisibility {
            if hasAcquiredInteractionLock {
                self.controlsVisibility?.endInteraction()
                hasAcquiredInteractionLock = false
            }
            self.controlsVisibility = controlsVisibility
        }
        self.isPopoverPresented = isPopoverPresented
        self.onRequestDismissPopover = onRequestDismissPopover
        reconcileInteractionLock()
    }

    public func handleAppear() {
        isMounted = true
        reconcileInteractionLock()
        installEscapeMonitor()
    }

    public func handleDisappear() {
        isMounted = false
        removeEscapeMonitor()
        if isPopoverPresented {
            isPopoverPresented = false
            onRequestDismissPopover?()
        }
        reconcileInteractionLock()
    }

    public func setPopoverPresented(_ presented: Bool) {
        isPopoverPresented = presented
        if presented,
           let window = resolvedWindow,
           let textView = window.firstResponder as? NSTextView,
           !textView.hasMarkedText() {
            window.makeFirstResponder(nil)
        }
        reconcileInteractionLock()
    }

    public func reconcileInteractionLock() {
        let shouldHoldLock = isMounted && isPopoverPresented
        if shouldHoldLock && !hasAcquiredInteractionLock {
            controlsVisibility?.beginInteraction()
            hasAcquiredInteractionLock = true
        } else if !shouldHoldLock && hasAcquiredInteractionLock {
            controlsVisibility?.endInteraction()
            hasAcquiredInteractionLock = false
        }
    }

    public static func isEditableWindowTextInputActive(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let inputClient = responder as? NSTextInputClient, inputClient.hasMarkedText() {
            return true
        }
        if let textView = responder as? NSTextView {
            return textView.isEditable
        }
        if let textField = responder as? NSTextField {
            return textField.isEditable
        }
        return false
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let shouldConsume = MainActor.assumeIsolated {
                self?.handleEscapeKeyDown(event) ?? false
            }
            return shouldConsume ? nil : event
        }
    }

    private func handleEscapeKeyDown(_ event: NSEvent) -> Bool {
        guard isMounted, isPopoverPresented, Self.isUnmodifiedEscape(event) else {
            return false
        }
        guard let targetWindow = resolvedWindow,
              Self.canDismissPopoverOnEscape(event: event, targetWindow: targetWindow) else {
            return false
        }
        Self.lastPopoverDismissEscapeWindowNumber = targetWindow.windowNumber
        Self.lastPopoverDismissEscapeTimestampBits = event.timestamp.bitPattern
        setPopoverPresented(false)
        onRequestDismissPopover?()
        return true
    }

    private static func isUnmodifiedEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        let cleanMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return cleanMods.intersection([.command, .option, .control, .shift]).isEmpty
    }

    private static func canDismissPopoverOnEscape(event: NSEvent, targetWindow: NSWindow) -> Bool {
        guard doesEscapeEventBelongToWindow(
            eventWindow: event.window,
            eventWindowNumber: event.windowNumber,
            targetWindow: targetWindow
        ) else {
            return false
        }
        if targetWindow.attachedSheet != nil
            || isMenuTrackingActive(for: targetWindow)
            || isEditableWindowTextInputActive(targetWindow) {
            return false
        }
        let query = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(
            windowNumber: targetWindow.windowNumber,
            eventTimestamp: event.timestamp,
            keyCode: event.keyCode
        )
        return !query.isTextInputActive && !query.isEventAlreadyHandled
    }

    private func removeEscapeMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

struct CodeContainerWindowAccessor: NSViewRepresentable {
    let coordinator: CodeReadingToolsInteractionCoordinator
    let isPopoverPresented: Bool
    let controlsVisibility: MediaControlsVisibility?
    let onDismissPopover: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CodeWindowAnchorNSView()
        view.coordinator = coordinator
        coordinator.anchorView = view
        coordinator.syncState(
            isPopoverPresented: isPopoverPresented,
            controlsVisibility: controlsVisibility,
            onRequestDismissPopover: onDismissPopover
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let anchor = nsView as? CodeWindowAnchorNSView {
            anchor.coordinator = coordinator
        }
        coordinator.anchorView = nsView
        if let win = nsView.window {
            coordinator.hostWindow = win
        }
        coordinator.syncState(
            isPopoverPresented: isPopoverPresented,
            controlsVisibility: controlsVisibility,
            onRequestDismissPopover: onDismissPopover
        )
    }
}

private final class CodeWindowAnchorNSView: NSView {
    weak var coordinator: CodeReadingToolsInteractionCoordinator?
    private var hadWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let coordinator else { return }
        if let win = window {
            hadWindow = true
            coordinator.hostWindow = win
            coordinator.handleAppear()
        } else if hadWindow {
            hadWindow = false
            coordinator.hostWindow = nil
            coordinator.handleDisappear()
        }
    }
}

/// Visual configuration for the single visible, hit-testable native `NSButton` used in the floating reading tools overlay.
struct NativeFloatingToolButtonStyle: Equatable {
    var title: String = ""
    var symbolName: String? = nil
    var trailingSymbolName: String? = nil
    var showsLeadingDot: Bool = false
    var leadingDotColor: NSColor = .systemOrange
    var fontSize: CGFloat = 11.0
    var fontWeight: NSFont.Weight = .semibold
    var fontDesign: NSFontDescriptor.SystemDesign = .default
    var foregroundColor: NSColor = .white
    var backgroundColor: NSColor = .clear
    var hoverBackgroundColor: NSColor = NSColor.white.withAlphaComponent(0.14)
    var cornerRadius: CGFloat = 4.5
    var horizontalPadding: CGFloat = 4.0
    var minWidth: CGFloat = 28.0
    var minHeight: CGFloat = 28.0
}

/// Single visible, hit-testable native `NSButton` component that serves as the sole production control
/// for floating reading tools (replacing dual SwiftUI visual `Button` + hidden test bridge).
struct NativeFloatingToolButtonRepresentable: NSViewRepresentable {
    let id: String
    let accessibilityLabel: String
    let accessibilityValue: String?
    let helpText: String
    let isEnabled: Bool
    let keyEquivalent: String
    let keyEquivalentModifierMask: NSEvent.ModifierFlags
    let style: NativeFloatingToolButtonStyle
    let onHoverChange: ((Bool) -> Void)?
    let onFocusChange: ((Bool) -> Void)?
    let action: () -> Void

    init(
        id: String,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        helpText: String,
        isEnabled: Bool = true,
        keyEquivalent: String = "",
        keyEquivalentModifierMask: NSEvent.ModifierFlags = [],
        style: NativeFloatingToolButtonStyle,
        onHoverChange: ((Bool) -> Void)? = nil,
        onFocusChange: ((Bool) -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.helpText = helpText
        self.isEnabled = isEnabled
        self.keyEquivalent = keyEquivalent
        self.keyEquivalentModifierMask = keyEquivalentModifierMask
        self.style = style
        self.onHoverChange = onHoverChange
        self.onFocusChange = onFocusChange
        self.action = action
    }

    func makeNSView(context: Context) -> NativeFloatingToolNSButton {
        let button = NativeFloatingToolNSButton(frame: .zero)
        configure(button)
        return button
    }

    func updateNSView(_ nsView: NativeFloatingToolNSButton, context: Context) {
        configure(nsView)
    }

    private func configure(_ button: NativeFloatingToolNSButton) {
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(accessibilityValue)
        button.toolTip = helpText
        button.isEnabled = isEnabled
        button.keyEquivalent = keyEquivalent
        button.keyEquivalentModifierMask = keyEquivalentModifierMask
        button.visualStyle = style
        button.onHoverChange = onHoverChange
        button.onFocusChange = onFocusChange
        button.onAction = action
        button.needsDisplay = true
    }
}

/// Visible, hit-testable `NSButton` subclass that draws the glass-cell button chrome, icon/label,
/// and dispatches its single production action on mouse click, keyboard activation, or AX press.
public final class NativeFloatingToolNSButton: NSButton {
    var visualStyle = NativeFloatingToolButtonStyle() {
        didSet {
            if oldValue != visualStyle {
                invalidateIntrinsicContentSize()
                needsDisplay = true
            }
        }
    }
    var onAction: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    private var isPointerHovered = false {
        didSet {
            if oldValue != isPointerHovered {
                onHoverChange?(isPointerHovered)
                needsDisplay = true
            }
        }
    }
    private var trackingAreaRef: NSTrackingArea?

    override public var isFlipped: Bool {
        true
    }

    override public var acceptsFirstResponder: Bool {
        isEnabled
    }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: visualStyle.minWidth, height: visualStyle.minHeight)
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isTransparent = false
        bezelStyle = .regularSquare
        title = ""
        target = self
        action = #selector(handleButtonTriggered(_:))
        setButtonType(.momentaryPushIn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc
    private func handleButtonTriggered(_ sender: Any?) {
        guard isEnabled, !isHidden, alphaValue > 0.01 else { return }
        onAction?()
    }

    override public func mouseDown(with event: NSEvent) {
        guard isEnabled, !isHidden, alphaValue > 0.01 else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint), hitTest(convert(localPoint, to: superview)) === self else {
            return
        }
        super.mouseDown(with: event)
        needsDisplay = true
    }

    override public func performClick(_ sender: Any?) {
        guard isEnabled, !isHidden, alphaValue > 0.01 else { return }
        let centerInSuperview = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: superview)
        guard hitTest(centerInSuperview) === self else { return }
        _ = sendAction(action, to: target)
    }

    override public func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isHidden, alphaValue > 0.01 else { return false }
        let centerInSuperview = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: superview)
        guard hitTest(centerInSuperview) === self else { return false }
        return sendAction(action, to: target)
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isPointerHovered = true
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
        let rect = bounds
        guard rect.width > 0, rect.height > 0 else { return }

        let bgPath = NSBezierPath(
            roundedRect: rect,
            xRadius: visualStyle.cornerRadius,
            yRadius: visualStyle.cornerRadius
        )
        let activeBg: NSColor
        if isHighlighted {
            activeBg = visualStyle.hoverBackgroundColor.blended(withFraction: 0.25, of: .white)
                ?? visualStyle.hoverBackgroundColor
        } else if isPointerHovered || window?.firstResponder === self {
            activeBg = visualStyle.backgroundColor == .clear
                ? visualStyle.hoverBackgroundColor
                : visualStyle.backgroundColor
        } else {
            activeBg = visualStyle.backgroundColor
        }
        if activeBg.alphaComponent > 0.001 {
            activeBg.setFill()
            bgPath.fill()
        }

        drawForegroundContent(in: rect)
    }

    private func drawForegroundContent(in rect: NSRect) {
        let fgColor = isEnabled
            ? visualStyle.foregroundColor
            : visualStyle.foregroundColor.withAlphaComponent(0.35)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedButtonFont(),
            .foregroundColor: fgColor
        ]
        let titleSize = visualStyle.title.isEmpty
            ? .zero
            : (visualStyle.title as NSString).size(withAttributes: attrs)
        let leadingImage = resolvedSymbolImage(
            named: visualStyle.symbolName,
            pointSize: visualStyle.fontSize,
            weight: visualStyle.fontWeight
        )
        let trailingImage = resolvedSymbolImage(
            named: visualStyle.trailingSymbolName,
            pointSize: max(8.5, visualStyle.fontSize - 2.5),
            weight: .bold
        )
        let totalWidth = computeTotalForegroundWidth(
            titleWidth: titleSize.width,
            leadingImage: leadingImage,
            trailingImage: trailingImage
        )
        drawSegments(
            in: rect,
            startX: rect.midX - totalWidth / 2.0,
            fgColor: fgColor,
            attrs: attrs,
            titleSize: titleSize,
            leadingImage: leadingImage,
            trailingImage: trailingImage
        )
    }

    private func resolvedButtonFont() -> NSFont {
        let baseFont = NSFont.systemFont(ofSize: visualStyle.fontSize, weight: visualStyle.fontWeight)
        if let descriptor = baseFont.fontDescriptor.withDesign(visualStyle.fontDesign),
           let designed = NSFont(descriptor: descriptor, size: visualStyle.fontSize) {
            return designed
        }
        return baseFont
    }

    private func resolvedSymbolImage(
        named name: String?,
        pointSize: CGFloat,
        weight: NSFont.Weight
    ) -> NSImage? {
        guard let name else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func computeTotalForegroundWidth(
        titleWidth: CGFloat,
        leadingImage: NSImage?,
        trailingImage: NSImage?
    ) -> CGFloat {
        let spacing: CGFloat = 3.0
        var widths: [CGFloat] = []
        if visualStyle.showsLeadingDot { widths.append(5.0) }
        if let leadingImage { widths.append(leadingImage.size.width) }
        if !visualStyle.title.isEmpty { widths.append(titleWidth) }
        if let trailingImage { widths.append(trailingImage.size.width) }
        let contentSum = widths.reduce(0, +)
        let gaps = widths.count > 1 ? CGFloat(widths.count - 1) * spacing : 0.0
        return contentSum + gaps
    }

    private func drawSegments(
        in rect: NSRect,
        startX: CGFloat,
        fgColor: NSColor,
        attrs: [NSAttributedString.Key: Any],
        titleSize: NSSize,
        leadingImage: NSImage?,
        trailingImage: NSImage?
    ) {
        let spacing: CGFloat = 3.0
        var cursorX = startX
        if visualStyle.showsLeadingDot {
            let dotRect = NSRect(x: cursorX, y: rect.midY - 2.5, width: 5.0, height: 5.0)
            visualStyle.leadingDotColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            cursorX += 5.0 + spacing
        }
        if let leadingImage {
            let imgSize = leadingImage.size
            let imgRect = NSRect(
                x: cursorX,
                y: rect.midY - imgSize.height / 2.0,
                width: imgSize.width,
                height: imgSize.height
            )
            drawTintedSymbol(leadingImage, in: imgRect, tint: fgColor)
            cursorX += imgSize.width + spacing
        }
        if !visualStyle.title.isEmpty {
            let textRect = NSRect(
                x: cursorX,
                y: rect.midY - titleSize.height / 2.0,
                width: titleSize.width,
                height: titleSize.height
            )
            (visualStyle.title as NSString).draw(in: textRect, withAttributes: attrs)
            cursorX += titleSize.width + spacing
        }
        if let trailingImage {
            let imgSize = trailingImage.size
            let imgRect = NSRect(
                x: cursorX,
                y: rect.midY - imgSize.height / 2.0,
                width: imgSize.width,
                height: imgSize.height
            )
            drawTintedSymbol(trailingImage, in: imgRect, tint: fgColor.withAlphaComponent(0.82))
        }
    }

    private func drawTintedSymbol(_ image: NSImage, in rect: NSRect, tint: NSColor) {
        guard let copy = image.copy() as? NSImage else { return }
        copy.lockFocus()
        tint.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.draw(in: rect)
    }
}
