// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit

struct TTZipCodeWindowAccessor: NSViewRepresentable {
    let coordinator: CodeReadingToolsInteractionCoordinator
    let isPopoverPresented: Bool
    let controlsVisibility: MediaControlsVisibility?
    let onDismissPopover: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TTZipCodeWindowAnchor()
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
        if let anchor = nsView as? TTZipCodeWindowAnchor {
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

private final class TTZipCodeWindowAnchor: NSView {
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

struct TTZipCodeToolButtonStyle: Equatable {
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

@MainActor
final class TTZipCodeToolsFocusCoordinator {
    weak var triggerButton: TTZipCodeToolNSButton?
    private weak var activePopoverResponder: TTZipCodeToolNSButton?

    func updatePopoverFocus(_ button: TTZipCodeToolNSButton, isFocused: Bool) {
        if isFocused {
            activePopoverResponder = button
        } else if activePopoverResponder === button {
            activePopoverResponder = nil
        }
    }

    func restoreTriggerFocusIfNeeded() {
        guard let responder = activePopoverResponder,
              let triggerButton,
              let window = triggerButton.window,
              window.firstResponder === responder,
              triggerButton.acceptsFirstResponder else {
            return
        }
        _ = window.makeFirstResponder(triggerButton)
    }
}

struct TTZipCodeToolButton: NSViewRepresentable {
    let id: String
    let accessibilityLabel: String
    let accessibilityValue: String?
    let helpText: String
    let isEnabled: Bool
    let isChromeVisible: Bool
    let keyEquivalent: String
    let keyEquivalentModifierMask: NSEvent.ModifierFlags
    let style: TTZipCodeToolButtonStyle
    let onMount: ((TTZipCodeToolNSButton) -> Void)?
    let onHoverChange: ((Bool) -> Void)?
    let onFocusChange: ((TTZipCodeToolNSButton, Bool) -> Void)?
    let action: () -> Void

    init(
        id: String,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        helpText: String,
        isEnabled: Bool = true,
        isChromeVisible: Bool = true,
        keyEquivalent: String = "",
        keyEquivalentModifierMask: NSEvent.ModifierFlags = [],
        style: TTZipCodeToolButtonStyle,
        onMount: ((TTZipCodeToolNSButton) -> Void)? = nil,
        onHoverChange: ((Bool) -> Void)? = nil,
        onFocusChange: ((TTZipCodeToolNSButton, Bool) -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.helpText = helpText
        self.isEnabled = isEnabled
        self.isChromeVisible = isChromeVisible
        self.keyEquivalent = keyEquivalent
        self.keyEquivalentModifierMask = keyEquivalentModifierMask
        self.style = style
        self.onMount = onMount
        self.onHoverChange = onHoverChange
        self.onFocusChange = onFocusChange
        self.action = action
    }

    func makeNSView(context: Context) -> TTZipCodeToolNSButton {
        let button = TTZipCodeToolNSButton(frame: .zero)
        configure(button)
        return button
    }

    func updateNSView(_ nsView: TTZipCodeToolNSButton, context: Context) {
        configure(nsView)
    }

    private func configure(_ button: TTZipCodeToolNSButton) {
        onMount?(button)
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(accessibilityValue)
        button.isChromeVisible = isChromeVisible
        button.toolTip = isChromeVisible ? helpText : nil
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

final class TTZipCodeToolNSButton: NSButton {
    var visualStyle = TTZipCodeToolButtonStyle() {
        didSet {
            if oldValue != visualStyle {
                invalidateIntrinsicContentSize()
                needsDisplay = true
            }
        }
    }
    var isChromeVisible = true {
        didSet {
            if oldValue != isChromeVisible {
                if !isChromeVisible { isPointerHovered = false }
                needsDisplay = true
            }
        }
    }
    var onAction: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onFocusChange: ((TTZipCodeToolNSButton, Bool) -> Void)?
    private var isPointerHovered = false {
        didSet {
            if oldValue != isPointerHovered {
                onHoverChange?(isPointerHovered)
                needsDisplay = true
            }
        }
    }
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        isEnabled
    }

    override var canBecomeKeyView: Bool {
        isEnabled && !isHiddenOrHasHiddenAncestor && alphaValue > 0.01
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: visualStyle.minWidth, height: visualStyle.minHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isTransparent = false
        bezelStyle = .regularSquare
        title = ""
        target = self
        action = #selector(handleButtonTriggered(_:))
        setButtonType(.momentaryPushIn)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isChromeVisible, !isHidden, alphaValue > 0.01 else { return nil }
        return super.hitTest(point)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 49, flags.isEmpty, !NSApplication.shared.isFullKeyboardAccessEnabled {
            if !event.isARepeat { performClick(self) }
            return
        }
        super.keyDown(with: event)
    }

    private var canTriggerProgrammatically: Bool {
        guard isEnabled, !isHidden, alphaValue > 0.01 else { return false }
        guard isChromeVisible else { return true }
        let centerInSuperview = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: superview)
        return hitTest(centerInSuperview) === self
    }

    @objc
    private func handleButtonTriggered(_ sender: Any?) {
        guard isEnabled, !isHidden, alphaValue > 0.01 else { return }
        onAction?()
    }

    override func mouseDown(with event: NSEvent) {
        guard isChromeVisible, isEnabled, !isHidden, alphaValue > 0.01 else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint), hitTest(convert(localPoint, to: superview)) === self else {
            return
        }
        super.mouseDown(with: event)
        needsDisplay = true
    }

    override func performClick(_ sender: Any?) {
        guard canTriggerProgrammatically else { return }
        _ = sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        guard canTriggerProgrammatically else { return false }
        return sendAction(action, to: target)
    }

    override func updateTrackingAreas() {
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

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isChromeVisible else {
            isPointerHovered = false
            return
        }
        isPointerHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerHovered = false
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?(self, true)
            needsDisplay = true
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(self, false)
            needsDisplay = true
        }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        guard isChromeVisible, rect.width > 0, rect.height > 0 else { return }

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
