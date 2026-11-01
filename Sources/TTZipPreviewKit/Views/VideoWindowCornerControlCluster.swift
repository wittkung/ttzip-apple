// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Observation
import SwiftUI
import TTMediaKit
import TTZipUI

/// Shape style for an individual button in the full-window video corner control cluster.
public enum VideoWindowCornerButtonShapeStyle: Sendable, Equatable {
    case roundedPill
    case circle
}

/// Configuration model for a single control button inside `VideoWindowCornerControlClusterView`.
public struct VideoWindowCornerControlItem: Identifiable {
    public let id: String
    public let symbolName: String
    public let title: String?
    public let accessibilityLabel: String
    public let accessibilityHint: String?
    public let helpText: String
    public let shapeStyle: VideoWindowCornerButtonShapeStyle
    public let isEnabled: Bool
    public let customTint: NSColor?
    public let action: @MainActor () -> Void

    public init(
        id: String,
        symbolName: String,
        title: String? = nil,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        helpText: String,
        shapeStyle: VideoWindowCornerButtonShapeStyle = .roundedPill,
        isEnabled: Bool = true,
        customTint: NSColor? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.symbolName = symbolName
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.helpText = helpText
        self.shapeStyle = shapeStyle
        self.isEnabled = isEnabled
        self.customTint = customTint
        self.action = action
    }

    public var resolvedSize: NSSize {
        switch shapeStyle {
        case .circle:
            return NSSize(width: 32.0, height: 32.0)
        case .roundedPill:
            guard let title, !title.isEmpty else {
                return NSSize(width: 28.0, height: 28.0)
            }
            let font = NSFont.systemFont(ofSize: 11.0, weight: .medium)
            let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            return NSSize(width: max(56.0, 20.0 + 14.0 + 4.0 + textWidth), height: 28.0)
        }
    }
}

/// Reusable passive corner hover sensor view wrapping `PreviewCornerHoverSensorNSView` (`hitTest(_:) -> nil`).
/// Reports pointer entry, movement (with window coordinates), and exit without intercepting video canvas clicks, drags, or scrolls.
@MainActor
public struct VideoWindowCornerHoverSensorView: NSViewRepresentable {
    public let sensorID: String
    public let onHoverChange: @MainActor (Bool) -> Void
    public let onPointerLocationInWindow: (@MainActor (NSPoint?) -> Void)?

    public init(
        sensorID: String,
        onHoverChange: @escaping @MainActor (Bool) -> Void,
        onPointerLocationInWindow: (@MainActor (NSPoint?) -> Void)? = nil
    ) {
        self.sensorID = sensorID
        self.onHoverChange = onHoverChange
        self.onPointerLocationInWindow = onPointerLocationInWindow
    }

    public func makeNSView(context: Context) -> VideoWindowCornerSensorNSView {
        let view = VideoWindowCornerSensorNSView(frame: .zero)
        view.setAccessibilityIdentifier(sensorID)
        view.onHoverChange = onHoverChange
        view.onPointerLocationInWindow = onPointerLocationInWindow
        return view
    }

    public func updateNSView(_ nsView: VideoWindowCornerSensorNSView, context: Context) {
        nsView.setAccessibilityIdentifier(sensorID)
        nsView.onHoverChange = onHoverChange
        nsView.onPointerLocationInWindow = onPointerLocationInWindow
    }

    public static func dismantleNSView(_ nsView: VideoWindowCornerSensorNSView, coordinator: ()) {
        nsView.tearDown()
    }
}

/// Passive AppKit tracking view for top-left and top-right video window corner proximity zones.
/// Always returns `nil` from `hitTest(_:)` so underlying video canvas receives 100% of clicks, double-clicks, drags, and scrolls.
@MainActor
public final class VideoWindowCornerSensorNSView: NSView {
    public var onHoverChange: (@MainActor (Bool) -> Void)?
    public var onPointerLocationInWindow: (@MainActor (NSPoint?) -> Void)?
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
        if window == nil {
            isPointerInside = false
            onPointerLocationInWindow?(nil)
        }
    }

    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        let localPoint = convert(event.locationInWindow, from: nil)
        let inside = bounds.insetBy(dx: -1.0, dy: -1.0).contains(localPoint)
        isPointerInside = inside
        onPointerLocationInWindow?(inside ? event.locationInWindow : nil)
    }

    override public func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let localPoint = convert(event.locationInWindow, from: nil)
        let inside = bounds.contains(localPoint)
        isPointerInside = inside
        onPointerLocationInWindow?(inside ? event.locationInWindow : nil)
    }

    override public func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerInside = false
        onPointerLocationInWindow?(nil)
    }

    public func tearDown() {
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
            trackingAreaRef = nil
        }
        isPointerInside = false
        onPointerLocationInWindow?(nil)
    }
}

/// Top-right window control cluster for full-window video playback (`StandalonePlaybackWindowContentView`
/// and video `.canvasMedia` in `ImmersiveMediaBrowserView`).
///
/// Contract:
/// - Hidden by default (`0` contrasting pixels, `hitTest(_:) -> nil`) during both playing and paused full-window video states.
/// - Reveals only when the pointer enters the top-trailing proximity sensor, hovers any button in the cluster,
///   focuses a button via keyboard Tab, or while a menu/popover lock is active.
/// - Fades out after `260ms` (`PreviewCornerActionRevealCoordinator.defaultHideDelay`) when leaving the corner action zone;
///   re-entering before timeout cancels the pending hide task.
@MainActor
public struct VideoWindowCornerControlClusterView: View {
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var envReduceTransparency
    @Environment(\.colorSchemeContrast) private var envColorSchemeContrast
    @Environment(\.mediaControlsVisibility) private var envControlsVisibility

    public let sensorID: String
    public let items: [VideoWindowCornerControlItem]
    public let coordinator: PreviewCornerActionRevealCoordinator?
    public let isMenuTrackingOverride: Bool
    private let externalLockProvider: (@MainActor () -> Bool)?

    @State private var ownedCoordinator = PreviewCornerActionRevealCoordinator()
    @State private var hoveredButtonIDs: Set<String> = []
    @State private var focusedButtonIDs: Set<String> = []
    @State private var activeTrackingMenuIDs: Set<ObjectIdentifier> = []
    @State private var hostWindowBox = VideoCornerWindowWeakBox()

    public init(
        sensorID: String,
        items: [VideoWindowCornerControlItem],
        coordinator: PreviewCornerActionRevealCoordinator? = nil,
        isMenuTrackingOverride: Bool = false,
        externalLockProvider: (@MainActor () -> Bool)? = nil
    ) {
        self.sensorID = sensorID
        self.items = items
        self.coordinator = coordinator
        self.isMenuTrackingOverride = isMenuTrackingOverride
        self.externalLockProvider = externalLockProvider
    }

    private var activeCoordinator: PreviewCornerActionRevealCoordinator {
        coordinator ?? ownedCoordinator
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

    private var isExternallyLocked: Bool {
        let targetWindow = hostWindowBox.window
        let hasValidTrackedMenu = activeTrackingMenuIDs.contains { menuID in
            CodeReadingToolsInteractionCoordinator.doesMenuBelongToWindow(menuID: menuID, window: targetWindow)
        }
        if isMenuTrackingOverride || hasValidTrackedMenu || (externalLockProvider?() == true) {
            return true
        }
        let hasControlLock = envControlsVisibility?.hasActiveInteractionLock ?? false
        let hasChildMenuOrPopover = (targetWindow?.childWindows ?? []).contains { $0.isVisible }
        let hasActiveMenu = CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(for: targetWindow)
        return hasControlLock || hasChildMenuOrPopover || hasActiveMenu
    }

    public var isClusterVisible: Bool {
        activeCoordinator.isPresented()
    }

    private var sensorSize: CGSize {
        let buttonsWidth = items.reduce(CGFloat(0)) { $0 + $1.resolvedSize.width }
        let spacingWidth = CGFloat(max(0, items.count - 1)) * 10.0
        let width = max(148.0, buttonsWidth + spacingWidth + 44.0)
        return CGSize(width: width, height: 60.0)
    }

    public var body: some View {
        let isVisible = isClusterVisible
        let reduceTransparency = usesHighContrastOrReducedTransparency

        ZStack(alignment: .topTrailing) {
            VideoWindowCornerHoverSensorView(
                sensorID: sensorID,
                onHoverChange: { hovering in
                    let locked = isExternallyLocked
                    updateCoordinator {
                        $0.setExternallyLocked(locked)
                        $0.setZoneHovered(hovering)
                    }
                }
            )
            .frame(width: sensorSize.width, height: sensorSize.height)

            HStack(alignment: .center, spacing: 10) {
                ForEach(items) { item in
                    let isItemHighlighted = hoveredButtonIDs.contains(item.id) || focusedButtonIDs.contains(item.id)
                    let size = item.resolvedSize
                    VideoWindowCornerButtonRepresentable(
                        item: item,
                        isVisible: isVisible,
                        isHighlighted: isItemHighlighted,
                        usesReducedTransparency: reduceTransparency,
                        hostWindowBox: hostWindowBox,
                        onHoverChange: { hovering in
                            if hovering {
                                hoveredButtonIDs.insert(item.id)
                            } else {
                                hoveredButtonIDs.remove(item.id)
                            }
                            let anyHovered = !hoveredButtonIDs.isEmpty
                            let locked = isExternallyLocked
                            updateCoordinator {
                                $0.setExternallyLocked(locked)
                                $0.setButtonHovered(anyHovered)
                            }
                        },
                        onFocusChange: { focused in
                            if focused {
                                focusedButtonIDs.insert(item.id)
                            } else {
                                focusedButtonIDs.remove(item.id)
                            }
                            let anyFocused = !focusedButtonIDs.isEmpty
                            let locked = isExternallyLocked
                            updateCoordinator {
                                $0.setExternallyLocked(locked)
                                $0.setButtonFocused(anyFocused)
                            }
                        }
                    )
                    .frame(width: size.width, height: size.height)
                    .background {
                        if isVisible {
                            buttonBackdrop(style: item.shapeStyle, isHighlighted: isItemHighlighted)
                                .allowsHitTesting(false)
                        }
                    }
                    .scaleEffect(isVisible ? 1.0 : (usesReducedMotion ? 1.0 : 0.96), anchor: .topTrailing)
                    .environment(\.ttButtonHelpEnabled, isVisible)
                    .ttButtonHelp(item.helpText)
                }
            }
            .padding(.top, 16)
            .padding(.trailing, 24)
        }
        .onChange(of: isExternallyLocked, initial: true) { _, locked in
            updateCoordinator { $0.setExternallyLocked(locked) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { notification in
            let menuID = (notification.object as? NSMenu).map { ObjectIdentifier($0) }
            let targetWindow = hostWindowBox.window
            guard let menuID,
                  CodeReadingToolsInteractionCoordinator.beginTrackedMenu(menuID: menuID, for: targetWindow),
                  activeCoordinator.isPresented() else {
                return
            }
            activeTrackingMenuIDs.insert(menuID)
            updateCoordinator { $0.setExternallyLocked(true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { notification in
            let menuID = (notification.object as? NSMenu).map { ObjectIdentifier($0) }
            let targetWindow = hostWindowBox.window
            guard let menuID else { return }
            let relatedIDs = CodeReadingToolsInteractionCoordinator.relatedMenuIDs(forEndOf: menuID)
            _ = CodeReadingToolsInteractionCoordinator.endTrackedMenu(menuID: menuID, for: targetWindow)
            let hadLocalTracking = !activeTrackingMenuIDs.isDisjoint(with: relatedIDs)
            activeTrackingMenuIDs.subtract(relatedIDs)
            guard hadLocalTracking else { return }
            let locked = isExternallyLocked
            updateCoordinator { $0.setExternallyLocked(locked) }
        }
        .onChange(of: envControlsVisibility?.lifecycleGeneration) { _, _ in
            activeTrackingMenuIDs.removeAll()
            hoveredButtonIDs.removeAll()
            focusedButtonIDs.removeAll()
            CodeReadingToolsInteractionCoordinator.invalidateOwnedMenus(for: hostWindowBox.window)
            activeCoordinator.tearDown()
        }
        .onDisappear {
            activeTrackingMenuIDs.removeAll()
            hoveredButtonIDs.removeAll()
            focusedButtonIDs.removeAll()
            CodeReadingToolsInteractionCoordinator.invalidateOwnedMenus(for: hostWindowBox.window)
            activeCoordinator.tearDown()
        }
    }

    @ViewBuilder
    private func buttonBackdrop(
        style: VideoWindowCornerButtonShapeStyle,
        isHighlighted: Bool
    ) -> some View {
        switch style {
        case .circle:
            let shape = Circle()
            if usesHighContrastOrReducedTransparency {
                shape.fill(TTZipUniversalTokens.Mineral.obsidianBlack.opacity(isHighlighted ? 0.94 : 0.88))
            } else {
                shape
                    .fill(TTZipUniversalTokens.Mineral.obsidianBlack.opacity(isHighlighted ? 0.64 : 0.42))
                    .background(.ultraThinMaterial, in: shape)
            }
        case .roundedPill:
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            if usesHighContrastOrReducedTransparency {
                shape.fill(TTZipUniversalTokens.Mineral.obsidianBlack.opacity(isHighlighted ? 0.94 : 0.88))
            } else {
                shape
                    .fill(TTZipUniversalTokens.Mineral.obsidianBlack.opacity(isHighlighted ? 0.64 : 0.42))
                    .background(.ultraThinMaterial, in: shape)
            }
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
internal final class VideoCornerWindowWeakBox {
    weak var window: NSWindow?
}

private struct VideoWindowCornerButtonRepresentable: NSViewRepresentable {
    let item: VideoWindowCornerControlItem
    let isVisible: Bool
    let isHighlighted: Bool
    let usesReducedTransparency: Bool
    let hostWindowBox: VideoCornerWindowWeakBox
    let onHoverChange: @MainActor (Bool) -> Void
    let onFocusChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> VideoWindowCornerClusterNSButton {
        let button = VideoWindowCornerClusterNSButton(frame: .zero)
        configure(button)
        return button
    }

    func updateNSView(_ nsView: VideoWindowCornerClusterNSButton, context: Context) {
        configure(nsView)
    }

    private func configure(_ button: VideoWindowCornerClusterNSButton) {
        button.setAccessibilityIdentifier(item.id)
        button.setAccessibilityLabel(item.accessibilityLabel)
        button.symbolName = item.symbolName
        button.buttonTitleText = item.title
        button.shapeStyle = item.shapeStyle
        button.isEnabled = item.isEnabled
        button.customTint = item.customTint
        button.isChromeVisible = isVisible
        button.isChromeHighlighted = isHighlighted
        button.usesReducedTransparency = usesReducedTransparency
        button.hostWindowBox = hostWindowBox
        button.onHoverChange = onHoverChange
        button.onFocusChange = onFocusChange
        button.onAction = item.action
        if let win = button.window {
            hostWindowBox.window = win
        }
        button.needsDisplay = true
    }
}

/// Native `NSButton` for full-window video corner controls (`Return to Preview`, `Close`, `Previous`, `Next`, etc.).
/// Remains focusable in the keyboard Tab loop (`acceptsFirstResponder == isEnabled`) even while visually hidden,
/// while yielding `hitTest(_:) -> nil` and drawing `0` pixels when `isChromeVisible == false`.
@MainActor
public final class VideoWindowCornerClusterNSButton: NSButton {
    public var symbolName: String = "" {
        didSet { if oldValue != symbolName { needsDisplay = true } }
    }
    public var buttonTitleText: String? {
        didSet { if oldValue != buttonTitleText { needsDisplay = true } }
    }
    public var shapeStyle: VideoWindowCornerButtonShapeStyle = .roundedPill {
        didSet { if oldValue != shapeStyle { needsDisplay = true } }
    }
    public var customTint: NSColor? {
        didSet { needsDisplay = true }
    }
    public var isChromeVisible: Bool = false {
        didSet { if oldValue != isChromeVisible { needsDisplay = true } }
    }
    public var isChromeHighlighted: Bool = false {
        didSet { if oldValue != isChromeHighlighted { needsDisplay = true } }
    }
    public var usesReducedTransparency: Bool = false {
        didSet { if oldValue != usesReducedTransparency { needsDisplay = true } }
    }

    internal weak var hostWindowBox: VideoCornerWindowWeakBox?
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

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hostWindowBox?.window = window
        if window == nil {
            isPointerHovered = false
        }
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard isChromeVisible, !isHidden else { return nil }
        return super.hitTest(point)
    }

    @objc
    private func handleTriggered(_ sender: Any?) {
        guard isEnabled, !isHidden, isChromeVisible else { return }
        onAction?()
    }

    private var isPressedInside = false

    override public func mouseDown(with event: NSEvent) {
        guard isEnabled, !isHidden, isChromeVisible else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint), hitTest(convert(localPoint, to: superview)) === self else {
            return
        }
        isPressedInside = true
        isHighlighted = true
        needsDisplay = true
    }

    override public func mouseUp(with event: NSEvent) {
        let wasPressed = isPressedInside
        isPressedInside = false
        isHighlighted = false
        needsDisplay = true
        guard wasPressed, isEnabled, !isHidden, isChromeVisible else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        if bounds.contains(localPoint) {
            onAction?()
        }
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
        let activeHighlight = isChromeHighlighted || isHighlighted || isPointerHovered
        drawPlateAndBorder(activeHighlight: activeHighlight)
        drawSymbolAndTitle(activeHighlight: activeHighlight)
    }

    private func drawPlateAndBorder(activeHighlight: Bool) {
        let insetRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path: NSBezierPath = switch shapeStyle {
        case .circle:
            NSBezierPath(ovalIn: insetRect)
        case .roundedPill:
            NSBezierPath(roundedRect: insetRect, xRadius: 6.0, yRadius: 6.0)
        }
        let fillAlpha: CGFloat = usesReducedTransparency
            ? (activeHighlight ? 0.94 : 0.88)
            : (activeHighlight ? 0.72 : 0.52)
        NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: fillAlpha).setFill()
        path.fill()

        let strokeAlpha: CGFloat = activeHighlight ? 0.42 : 0.24
        NSColor.white.withAlphaComponent(strokeAlpha).setStroke()
        path.lineWidth = 0.75
        path.stroke()
    }

    private func drawSymbolAndTitle(activeHighlight: Bool) {
        let fgAlpha: CGFloat = isEnabled ? (activeHighlight ? 0.98 : 0.90) : 0.32
        let fgColor = (customTint ?? NSColor.white).withAlphaComponent(fgAlpha)
        let ptSize: CGFloat = (shapeStyle == .circle) ? 12.0 : 11.0
        let weight: NSFont.Weight = (shapeStyle == .circle) ? .semibold : .medium
        let symConfig = NSImage.SymbolConfiguration(pointSize: ptSize, weight: weight)

        let tintedSymbol: NSImage? = {
            guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(symConfig),
                  let copy = base.copy() as? NSImage else {
                return nil
            }
            copy.lockFocus()
            fgColor.set()
            NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
            copy.unlockFocus()
            return copy
        }()

        if let titleText = buttonTitleText, !titleText.isEmpty {
            let font = NSFont.systemFont(ofSize: 11.0, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fgColor]
            let textSize = (titleText as NSString).size(withAttributes: attrs)
            let symSize = tintedSymbol?.size ?? NSSize(width: 12.0, height: 12.0)
            let totalWidth = symSize.width + 4.0 + textSize.width
            let startX = max(8.0, (bounds.width - totalWidth) * 0.5)
            if let tintedSymbol {
                let symRect = NSRect(
                    x: startX,
                    y: (bounds.height - symSize.height) * 0.5,
                    width: symSize.width,
                    height: symSize.height
                )
                tintedSymbol.draw(in: symRect)
            }
            let textRect = NSRect(
                x: startX + symSize.width + 4.0,
                y: (bounds.height - textSize.height) * 0.5,
                width: textSize.width,
                height: textSize.height
            )
            (titleText as NSString).draw(in: textRect, withAttributes: attrs)
        } else if let tintedSymbol {
            let symSize = tintedSymbol.size
            let symRect = NSRect(
                x: (bounds.width - symSize.width) * 0.5,
                y: (bounds.height - symSize.height) * 0.5,
                width: symSize.width,
                height: symSize.height
            )
            tintedSymbol.draw(in: symRect)
        }
    }
}
