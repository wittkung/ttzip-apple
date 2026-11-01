// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Observation
import SwiftUI
import TTMediaKit
import TTZipPreviewKit
import TTZipUI

/// Manages on-demand visibility for the top-left native macOS traffic lights
/// (`closeButton`, `miniaturizeButton`, `zoomButton`) on `StandalonePlaybackNSWindow`.
///
/// Architectural separation of the two window control layers:
/// 1. **macOS System Fullscreen (`isSystemFullScreenActive == true`)**:
///    macOS manages the system menu bar and native window buttons. This controller yields completely
///    (`isSystemFullScreenManagedByMacOS == true`) and never hides or overrides standard window buttons.
/// 2. **Normal Full-Window Video Playback (`isSystemFullScreenActive == false`, playing or paused)**:
///    Native traffic lights and their backdrop are hidden by default (`isHidden = true`, `alphaValue = 0.0`,
///    `0` contrasting pixels, `hitTest(_:) -> contentView`), while preserving `[.titled, .closable, .miniaturizable, .resizable]`.
///    Entering the top-left corner proximity zone (`104 × 44 pt`), hovering any standard button, focusing a button via keyboard,
///    or opening a window menu reveals the traffic lights and fades them out after `260ms` upon leaving.
@MainActor
@Observable
public final class StandalonePlaybackTrafficLightsController {
    public nonisolated static let sensorSize = CGSize(width: 104.0, height: 44.0)

    public weak var window: StandalonePlaybackNSWindow?
    public let coordinator: PreviewCornerActionRevealCoordinator

    public private(set) var hoveredStandardButtonKind: NSWindow.ButtonType?
    public private(set) var focusedStandardButtonKind: NSWindow.ButtonType?
    private var activeTrackingMenuIDs: Set<ObjectIdentifier> = []
    public var isAppKitMenuTracking: Bool {
        guard let window else { return false }
        return activeTrackingMenuIDs.contains { menuID in
            CodeReadingToolsInteractionCoordinator.doesMenuBelongToWindow(menuID: menuID, window: window)
        }
    }

    private weak var titlebarTrackingView: TrafficLightsTitlebarBackdropNSView?
    private var menuBeginObserver: NSObjectProtocol?
    private var menuEndObserver: NSObjectProtocol?
    private var fullScreenEnterObserver: NSObjectProtocol?
    private var fullScreenExitObserver: NSObjectProtocol?

    public init(
        window: StandalonePlaybackNSWindow,
        coordinator: PreviewCornerActionRevealCoordinator = PreviewCornerActionRevealCoordinator()
    ) {
        self.window = window
        self.coordinator = coordinator
        coordinator.onVisibilityChanged = { [weak self] in
            self?.applyNativeTrafficLightsVisibility()
        }
        setupMenuAndFullScreenObservers(for: window)
        observeCoordinatorVisibility()
    }

    public func resetForNewItem() {
        activeTrackingMenuIDs.removeAll()
        hoveredStandardButtonKind = nil
        focusedStandardButtonKind = nil
        if let window {
            CodeReadingToolsInteractionCoordinator.setMenuTrackingActive(false, for: window)
        }
        coordinator.tearDown()
        applyNativeTrafficLightsVisibility()
    }

    public func tearDown() {
        let nc = NotificationCenter.default
        for token in [menuBeginObserver, menuEndObserver, fullScreenEnterObserver, fullScreenExitObserver].compactMap({ $0 }) {
            nc.removeObserver(token)
        }
        menuBeginObserver = nil
        menuEndObserver = nil
        fullScreenEnterObserver = nil
        fullScreenExitObserver = nil
        activeTrackingMenuIDs.removeAll()
        hoveredStandardButtonKind = nil
        focusedStandardButtonKind = nil
        if let window {
            CodeReadingToolsInteractionCoordinator.setMenuTrackingActive(false, for: window)
        }
        coordinator.tearDown()
    }

    /// True when the window is in macOS system fullscreen, where macOS owns the menu bar and native window buttons.
    public var isSystemFullScreenManagedByMacOS: Bool {
        guard let window else { return false }
        return window.isSystemFullScreenActive
    }

    /// True when the native traffic lights should be visible in the current window state.
    public var isTrafficLightsVisible: Bool {
        if isSystemFullScreenManagedByMacOS {
            return true
        }
        return coordinator.isPresented()
    }

    public func standardButtons() -> [NSButton] {
        guard let window else { return [] }
        return [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }
    }

    public func isStandardWindowButton(_ responder: NSResponder?) -> NSWindow.ButtonType? {
        guard let window, let button = responder as? NSButton else { return nil }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if window.standardWindowButton(kind) === button {
                return kind
            }
        }
        return nil
    }

    public func handleSensorHoverChange(_ hovering: Bool) {
        reconcileExternalLock()
        if !hovering {
            hoveredStandardButtonKind = nil
            coordinator.setButtonHovered(false)
        }
        coordinator.setZoneHovered(hovering)
        applyNativeTrafficLightsVisibility()
    }

    public func handlePointerLocationInWindow(_ locationInWindow: NSPoint?) {
        reconcileExternalLock()
        guard let window, let point = locationInWindow else {
            hoveredStandardButtonKind = nil
            coordinator.setButtonHovered(false)
            coordinator.setZoneHovered(false)
            applyNativeTrafficLightsVisibility()
            return
        }

        let contentHeight = window.contentView?.bounds.height ?? window.frame.height
        let inTopLeftSensor = point.x >= -1.0
            && point.x <= Self.sensorSize.width + 1.0
            && point.y >= max(0.0, contentHeight - Self.sensorSize.height - 1.0)
            && point.y <= contentHeight + 4.0

        var matchedKind: NSWindow.ButtonType?
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let btn = window.standardWindowButton(kind) else { continue }
            let rectInWindow = standardButtonRectInWindow(btn, kind: kind, contentHeight: contentHeight)
            if rectInWindow.insetBy(dx: -2.0, dy: -2.0).contains(point) {
                matchedKind = kind
                break
            }
        }

        hoveredStandardButtonKind = matchedKind
        coordinator.setButtonHovered(matchedKind != nil)
        coordinator.setZoneHovered(inTopLeftSensor || matchedKind != nil)
        applyNativeTrafficLightsVisibility()
    }

    public func setFocusedStandardButton(_ kind: NSWindow.ButtonType?) {
        focusedStandardButtonKind = kind
        reconcileExternalLock()
        coordinator.setButtonFocused(kind != nil)
        applyNativeTrafficLightsVisibility()
    }

    public func reconcileExternalLock() {
        guard let window else { return }
        let hasChildWindow = (window.childWindows ?? []).contains { $0.isVisible }
        let hasMenu = isAppKitMenuTracking
            || window.isMenuTrackingOverrideForTesting
            || CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(for: window)
        coordinator.setExternallyLocked(hasChildWindow || hasMenu)
    }

    public func applyNativeTrafficLightsVisibility() {
        guard let window else { return }
        let buttons = standardButtons()
        guard let firstButton = buttons.first,
              let titlebarView = firstButton.superview else {
            return
        }
        let titlebarContainer = titlebarView.superview
        let themeFrame = window.contentView?.superview

        if isSystemFullScreenManagedByMacOS {
            titlebarTrackingView?.isChromeVisible = false
            titlebarContainer?.isHidden = false
            titlebarContainer?.alphaValue = 1.0
            titlebarView.isHidden = false
            titlebarView.alphaValue = 1.0
            for button in buttons {
                button.isHidden = false
                button.alphaValue = 1.0
            }
            return
        }

        let visible = coordinator.isPresented()
        ensureTitlebarBackdropView(in: titlebarView)

        if visible {
            if let titlebarContainer, let themeFrame {
                var containerFrame = titlebarContainer.frame
                containerFrame.origin.x = 0
                containerFrame.origin.y = max(0, themeFrame.bounds.height - 38.0)
                containerFrame.size.width = min(Self.sensorSize.width, themeFrame.bounds.width)
                containerFrame.size.height = 38.0
                titlebarContainer.frame = containerFrame
                titlebarView.frame = titlebarContainer.bounds
                if let contentView = window.contentView {
                    themeFrame.addSubview(titlebarContainer, positioned: .above, relativeTo: contentView)
                }
            }
            titlebarContainer?.isHidden = false
            titlebarContainer?.alphaValue = 1.0
            titlebarView.isHidden = false
            titlebarView.alphaValue = 1.0
            for (idx, button) in buttons.enumerated() {
                let xOrigin = CGFloat(14 + idx * 20)
                button.setFrameOrigin(NSPoint(x: xOrigin, y: 11.0))
                button.isHidden = false
                button.alphaValue = 1.0
            }
            titlebarTrackingView?.frame = NSRect(x: 8.0, y: 6.0, width: 72.0, height: 24.0)
            titlebarTrackingView?.isChromeVisible = true
        } else {
            titlebarTrackingView?.isChromeVisible = false
            for button in buttons {
                button.alphaValue = 0.0
                button.isHidden = true
            }
            titlebarView.alphaValue = 0.0
            titlebarView.isHidden = true
            titlebarContainer?.alphaValue = 0.0
            titlebarContainer?.isHidden = true
            if let titlebarContainer, let contentView = window.contentView, let themeFrame {
                themeFrame.addSubview(contentView, positioned: .above, relativeTo: titlebarContainer)
            }
        }
        themeFrame?.needsDisplay = true
    }

    private func standardButtonRectInWindow(
        _ button: NSButton,
        kind: NSWindow.ButtonType,
        contentHeight: CGFloat
    ) -> NSRect {
        let index: Int = switch kind {
        case .closeButton: 0
        case .miniaturizeButton: 1
        case .zoomButton: 2
        default: 0
        }
        let defaultRect = NSRect(
            x: CGFloat(14 + index * 20),
            y: max(0.0, contentHeight - 27.0),
            width: max(14.0, button.frame.width),
            height: max(14.0, button.frame.height)
        )
        guard !button.isHidden, let superview = button.superview, superview.window != nil else {
            return defaultRect
        }
        let converted = superview.convert(button.frame, to: nil)
        if converted.width > 0, converted.height > 0, converted.minY >= 0 {
            return converted
        }
        return defaultRect
    }

    private func ensureTitlebarBackdropView(in titlebarView: NSView) {
        for subview in titlebarView.subviews {
            let typeName = String(describing: type(of: subview))
            if typeName.contains("VisualEffect") || typeName.contains("Separator") || typeName.contains("Border") {
                subview.isHidden = true
                subview.alphaValue = 0.0
            }
        }
        if let existing = titlebarTrackingView, existing.superview === titlebarView {
            return
        }
        let backdrop = TrafficLightsTitlebarBackdropNSView(frame: NSRect(x: 8.0, y: 6.0, width: 72.0, height: 24.0))
        backdrop.controller = self
        titlebarView.addSubview(backdrop, positioned: .below, relativeTo: nil)
        titlebarTrackingView = backdrop
    }

    private func observeCoordinatorVisibility() {
        withObservationTracking {
            _ = coordinator.isPresented()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyNativeTrafficLightsVisibility()
                self.observeCoordinatorVisibility()
            }
        }
    }

    private func setupMenuAndFullScreenObservers(for window: StandalonePlaybackNSWindow) {
        let nc = NotificationCenter.default
        menuBeginObserver = nc.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let menuID = (notification.object as? NSMenu).map { ObjectIdentifier($0) }
            MainActor.assumeIsolated {
                guard let self,
                      let menuID,
                      let window = self.window,
                      CodeReadingToolsInteractionCoordinator.beginTrackedMenu(
                          menuID: menuID,
                          for: window
                      ),
                      self.coordinator.isPresented() else {
                    return
                }
                self.activeTrackingMenuIDs.insert(menuID)
                self.reconcileExternalLock()
                self.applyNativeTrafficLightsVisibility()
            }
        }
        menuEndObserver = nc.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let menuID = (notification.object as? NSMenu).map { ObjectIdentifier($0) }
            MainActor.assumeIsolated {
                guard let self, let menuID, let window = self.window else { return }
                let relatedIDs = CodeReadingToolsInteractionCoordinator.relatedMenuIDs(forEndOf: menuID)
                _ = CodeReadingToolsInteractionCoordinator.endTrackedMenu(
                    menuID: menuID,
                    for: window
                )
                let hadLocalTracking = !self.activeTrackingMenuIDs.isDisjoint(with: relatedIDs)
                self.activeTrackingMenuIDs.subtract(relatedIDs)
                guard hadLocalTracking else { return }
                self.reconcileExternalLock()
                self.applyNativeTrafficLightsVisibility()
            }
        }
        fullScreenEnterObserver = nc.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyNativeTrafficLightsVisibility()
            }
        }
        fullScreenExitObserver = nc.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyNativeTrafficLightsVisibility()
            }
        }
    }
}

/// Passive backdrop & tracking view installed behind the 3 standard traffic lights inside `NSTitlebarView`.
@MainActor
private final class TrafficLightsTitlebarBackdropNSView: NSView {
    weak var controller: StandalonePlaybackTrafficLightsController?
    private var trackingAreaRef: NSTrackingArea?

    var isChromeVisible = false {
        didSet {
            if oldValue != isChromeVisible {
                needsDisplay = true
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds.insetBy(dx: -8.0, dy: -6.0),
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        controller?.handlePointerLocationInWindow(event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        controller?.handlePointerLocationInWindow(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.handlePointerLocationInWindow(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isChromeVisible, bounds.width > 0, bounds.height > 0 else { return }
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 12.0, yRadius: 12.0)
        NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.58).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        path.lineWidth = 0.75
        path.stroke()
    }
}

/// Top-left corner proximity sensor overlay mounted inside `StandalonePlaybackWindowContentView`.
/// Forwards pointer entry/movement/exit to `StandalonePlaybackTrafficLightsController` while returning `nil` from `hitTest(_:)`.
@MainActor
public struct StandalonePlaybackTrafficLightsSensorOverlay: View {
    public weak var window: StandalonePlaybackNSWindow?

    public init(window: StandalonePlaybackNSWindow?) {
        self.window = window
    }

    public var body: some View {
        VideoWindowCornerHoverSensorView(
            sensorID: "StandalonePlaybackTrafficLights.HoverSensor",
            onHoverChange: { hovering in
                window?.trafficLightsController?.handleSensorHoverChange(hovering)
            },
            onPointerLocationInWindow: { locationInWindow in
                window?.trafficLightsController?.handlePointerLocationInWindow(locationInWindow)
            }
        )
        .frame(
            width: StandalonePlaybackTrafficLightsController.sensorSize.width,
            height: StandalonePlaybackTrafficLightsController.sensorSize.height
        )
    }
}
