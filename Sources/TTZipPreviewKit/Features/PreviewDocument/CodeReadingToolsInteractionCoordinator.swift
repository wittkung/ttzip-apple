// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import TTMediaKit

/// Coordinates window-scoped Escape dismissal and the reading controls interaction lock.
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
            || TTMediaOwnedMenuRegistry.isMenuTrackingActive(for: targetWindow)
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
