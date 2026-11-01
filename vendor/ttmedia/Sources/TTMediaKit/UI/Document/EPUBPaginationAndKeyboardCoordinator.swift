// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import SwiftUI
import Combine
import WebKit

// MARK: - W1 Keyboard Ownership Coordinator (v2, Backward-Compatible with v1)

@MainActor
public final class TTPreviewKeyboardOwnershipCoordinator {
    public static let shared = TTPreviewKeyboardOwnershipCoordinator()

    public struct SessionRegistration {
        public let instanceID: UUID
        public var windowNumber: Int?
        public weak var hostWindow: NSWindow?
        public weak var readerWebView: EPUBReaderWKWebView?
        public weak var readerContainerView: NSView?
        public var focusSource: TTPreviewFocusSource
        public var isReleasedByOutsideInteraction: Bool = false
        public var wasResponderInsideReaderLastSync: Bool = false
        public var isDOMTextInputFocused: Bool
        public var isDOMIMEComposing: Bool
        public var isAppKitIMEComposing: Bool
        public var lastFocusedTimestamp: TimeInterval
        public var layoutMode: EPUBReadingLayoutMode = .paginated
        public var onVerticalArrowKey: (@MainActor (Bool) -> Bool)? = nil
        public var onHorizontalArrowKey: @MainActor (Bool) -> Bool

        public var ownsHorizontalArrowKeys: Bool {
            focusSource != .none && !isReleasedByOutsideInteraction
        }

        public var ownsVerticalArrowKeys: Bool {
            focusSource == .readingArea && !isReleasedByOutsideInteraction && layoutMode == .scrolling
        }

        public var isDOMTextInputOrIMEActive: Bool {
            isDOMTextInputFocused || isDOMIMEComposing || isAppKitIMEComposing
        }
    }

    private struct EventSignature: Equatable {
        let windowNumber: Int?
        let keyCode: UInt16
        let timestampBits: UInt64
    }

    private var sessions: [UUID: SessionRegistration] = [:]
    private var lastHandledSignature: EventSignature?
    private var localKeyMonitor: Any?
    private var localMouseMonitor: Any?

    public init() {}

    private func resolveInitialFocus(
        existing: SessionRegistration?,
        markFocused: Bool,
        ownsKeys: Bool
    ) -> (focus: TTPreviewFocusSource, released: Bool) {
        if markFocused || ownsKeys {
            let focus = (existing?.focusSource != TTPreviewFocusSource.none) ? (existing?.focusSource ?? .readingArea) : .readingArea
            return (focus, false)
        }
        let focus = existing?.focusSource ?? TTPreviewFocusSource.none
        let released = existing?.isReleasedByOutsideInteraction ?? false
        return (focus, released)
    }

    private func createOrUpdateSessionRecord(
        existing: SessionRegistration?,
        instanceID: UUID,
        windowNumber: Int?,
        initialFocus: TTPreviewFocusSource,
        released: Bool,
        isDOMTextInputOrIMEActive: Bool,
        markFocused: Bool,
        now: TimeInterval,
        layoutMode: EPUBReadingLayoutMode,
        onVerticalArrowKey: (@MainActor (Bool) -> Bool)?,
        onHorizontalArrowKey: @escaping @MainActor (Bool) -> Bool
    ) -> SessionRegistration {
        if var session = existing {
            if let windowNumber { session.windowNumber = windowNumber }
            session.focusSource = initialFocus
            session.isReleasedByOutsideInteraction = released
            session.layoutMode = layoutMode
            if let onVerticalArrowKey { session.onVerticalArrowKey = onVerticalArrowKey }
            if isDOMTextInputOrIMEActive { session.isDOMTextInputFocused = true }
            if markFocused { session.lastFocusedTimestamp = now }
            session.onHorizontalArrowKey = onHorizontalArrowKey
            return session
        }
        return SessionRegistration(
            instanceID: instanceID,
            windowNumber: windowNumber,
            hostWindow: nil,
            readerWebView: nil,
            readerContainerView: nil,
            focusSource: initialFocus,
            isReleasedByOutsideInteraction: released,
            wasResponderInsideReaderLastSync: false,
            isDOMTextInputFocused: isDOMTextInputOrIMEActive,
            isDOMIMEComposing: false,
            isAppKitIMEComposing: false,
            lastFocusedTimestamp: now,
            layoutMode: layoutMode,
            onVerticalArrowKey: onVerticalArrowKey,
            onHorizontalArrowKey: onHorizontalArrowKey
        )
    }

    public func registerOrUpdateSession(
        instanceID: UUID,
        windowNumber: Int?,
        ownsHorizontalArrowKeys: Bool = false,
        isDOMTextInputOrIMEActive: Bool = false,
        markFocused: Bool = false,
        layoutMode: EPUBReadingLayoutMode = .paginated,
        onVerticalArrowKey: (@MainActor (Bool) -> Bool)? = nil,
        onHorizontalArrowKey: @escaping @MainActor (Bool) -> Bool
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let existing = sessions[instanceID]
        let (focus, released) = resolveInitialFocus(
            existing: existing,
            markFocused: markFocused,
            ownsKeys: ownsHorizontalArrowKeys
        )
        sessions[instanceID] = createOrUpdateSessionRecord(
            existing: existing,
            instanceID: instanceID,
            windowNumber: windowNumber,
            initialFocus: focus,
            released: released,
            isDOMTextInputOrIMEActive: isDOMTextInputOrIMEActive,
            markFocused: markFocused,
            now: now,
            layoutMode: layoutMode,
            onVerticalArrowKey: onVerticalArrowKey,
            onHorizontalArrowKey: onHorizontalArrowKey
        )
        installLocalMonitorsIfNeeded()
    }

    public func updateSessionLayoutMode(
        instanceID: UUID,
        layoutMode: EPUBReadingLayoutMode,
        onVerticalArrowKey: (@MainActor (Bool) -> Bool)? = nil
    ) {
        guard var session = sessions[instanceID] else { return }
        session.layoutMode = layoutMode
        if let onVerticalArrowKey {
            session.onVerticalArrowKey = onVerticalArrowKey
        }
        sessions[instanceID] = session
    }

    public func bindReaderViews(
        instanceID: UUID,
        webView: EPUBReaderWKWebView?,
        containerView: NSView? = nil
    ) {
        guard var session = sessions[instanceID] else { return }
        if let webView {
            session.readerWebView = webView
            if let win = webView.window {
                session.hostWindow = win
                session.windowNumber = win.windowNumber
                if !session.isReleasedByOutsideInteraction,
                   Self.isResponderInside(responder: win.firstResponder, targetView: webView) {
                    session.focusSource = .readingArea
                    session.wasResponderInsideReaderLastSync = true
                    session.lastFocusedTimestamp = ProcessInfo.processInfo.systemUptime
                }
            }
        }
        if let containerView {
            session.readerContainerView = containerView
            if let win = containerView.window {
                session.hostWindow = win
                session.windowNumber = win.windowNumber
            }
        }
        sessions[instanceID] = session
    }

    public func updateSessionWindow(
        instanceID: UUID,
        window: NSWindow?,
        windowNumber: Int? = nil,
        markFocused: Bool = false
    ) {
        guard var session = sessions[instanceID] else { return }
        if let window {
            session.hostWindow = window
            session.windowNumber = window.windowNumber
        } else if let windowNumber {
            session.windowNumber = windowNumber
        }
        if markFocused {
            session.focusSource = .readingArea
            session.isReleasedByOutsideInteraction = false
            session.lastFocusedTimestamp = ProcessInfo.processInfo.systemUptime
        } else if !session.isReleasedByOutsideInteraction,
                  let win = session.hostWindow,
                  let webView = session.readerWebView,
                  Self.isResponderInside(responder: win.firstResponder, targetView: webView) {
            session.focusSource = .readingArea
            session.wasResponderInsideReaderLastSync = true
        }
        sessions[instanceID] = session
    }

    public func updateSessionTextInputState(instanceID: UUID, isDOMTextInputOrIMEActive: Bool) {
        guard var session = sessions[instanceID] else { return }
        session.isDOMTextInputFocused = isDOMTextInputOrIMEActive
        if !isDOMTextInputOrIMEActive { session.isDOMIMEComposing = false }
        sessions[instanceID] = session
    }

    public func updateSessionDOMInputLifecycle(
        instanceID: UUID,
        isInputActive: Bool,
        isIMEComposing: Bool
    ) {
        guard var session = sessions[instanceID] else { return }
        session.isDOMTextInputFocused = isInputActive
        session.isDOMIMEComposing = isIMEComposing
        sessions[instanceID] = session
    }

    public func updateSessionAppKitIMEState(instanceID: UUID, isIMEComposing: Bool) {
        guard var session = sessions[instanceID] else { return }
        session.isAppKitIMEComposing = isIMEComposing
        sessions[instanceID] = session
    }

    public func setReaderFocusState(
        instanceID: UUID,
        isFocused: Bool,
        source: TTPreviewFocusSource = .readingArea
    ) {
        guard var session = sessions[instanceID] else { return }
        if isFocused {
            session.focusSource = (source == .none) ? .readingArea : source
            session.isReleasedByOutsideInteraction = false
            session.lastFocusedTimestamp = ProcessInfo.processInfo.systemUptime
        } else {
            session.focusSource = .none
            session.isReleasedByOutsideInteraction = true
        }
        sessions[instanceID] = session
    }

    public func markSessionFocused(instanceID: UUID) {
        setReaderFocusState(instanceID: instanceID, isFocused: true, source: .readingArea)
    }

    public func notifyToolbarInteraction(instanceID: UUID) {
        guard var session = sessions[instanceID] else { return }
        session.focusSource = .toolbarOrPopover
        session.isReleasedByOutsideInteraction = false
        session.lastFocusedTimestamp = ProcessInfo.processInfo.systemUptime
        let webView = session.readerWebView
        sessions[instanceID] = session
        if let webView, let win = webView.window,
           !Self.isResponderInside(responder: win.firstResponder, targetView: webView) {
            win.makeFirstResponder(webView)
        }
    }

    private static func isHitInsideReader(
        hitView: NSView,
        webView: NSView?,
        container: NSView?,
        isContainerValid: Bool
    ) -> Bool {
        if let webView, hitView === webView || hitView.isDescendant(of: webView) {
            return true
        }
        if isContainerValid, let container, hitView === container || hitView.isDescendant(of: container) {
            return true
        }
        return false
    }

    private static func resetSessionToOutsideState(
        _ session: inout SessionRegistration,
        wasInside: Bool = false
    ) {
        session.focusSource = .none
        session.isReleasedByOutsideInteraction = true
        session.wasResponderInsideReaderLastSync = wasInside
        session.isAppKitIMEComposing = false
        session.readerWebView?.clearMarkedTextState()
    }

    private func activateSessionFocus(
        _ session: inout SessionRegistration,
        source: TTPreviewFocusSource,
        window: NSWindow
    ) {
        session.focusSource = source
        session.isReleasedByOutsideInteraction = false
        session.wasResponderInsideReaderLastSync = true
        session.lastFocusedTimestamp = ProcessInfo.processInfo.systemUptime
        if source == .toolbarOrPopover, let webView = session.readerWebView {
            window.makeFirstResponder(webView)
        }
    }

    private func updateSessionOnMouseDown(
        session: inout SessionRegistration,
        window: NSWindow,
        locationInWindow: NSPoint,
        hitView: NSView?
    ) {
        if let hitView, Self.isAppKitEditableResponder(hitView) {
            Self.resetSessionToOutsideState(&session)
            return
        }
        let container = session.readerContainerView
        let isContainerValid = (container != nil && container !== window.contentView)
        if let hitView, !Self.isHitInsideReader(
            hitView: hitView,
            webView: session.readerWebView,
            container: container,
            isContainerValid: isContainerValid
        ) {
            Self.resetSessionToOutsideState(&session)
            return
        }
        if let webView = session.readerWebView, Self.isPoint(locationInWindow, insideView: webView) {
            activateSessionFocus(&session, source: .readingArea, window: window)
            return
        }
        if let container, isContainerValid, Self.isPoint(locationInWindow, insideView: container) {
            activateSessionFocus(&session, source: .toolbarOrPopover, window: window)
            return
        }
        let inWebView = session.readerWebView.map { Self.isResponderInside(responder: window.firstResponder, targetView: $0) } ?? false
        let inContainer = isContainerValid
            ? container.map { Self.isResponderInside(responder: window.firstResponder, targetView: $0) } ?? false
            : false
        Self.resetSessionToOutsideState(&session, wasInside: inWebView || inContainer)
    }

    public func handleWindowMouseDown(in window: NSWindow?, locationInWindow: NSPoint) {
        guard let window else { return }
        let winNum = window.windowNumber
        let hitView = window.contentView?.hitTest(locationInWindow)
        for (id, var session) in sessions where session.windowNumber == winNum || session.hostWindow === window {
            session.hostWindow = window
            session.windowNumber = winNum
            updateSessionOnMouseDown(
                session: &session,
                window: window,
                locationInWindow: locationInWindow,
                hitView: hitView
            )
            sessions[id] = session
        }
    }

    public func unregisterSession(instanceID: UUID) {
        sessions.removeValue(forKey: instanceID)
        if sessions.isEmpty {
            if let monitor = localKeyMonitor {
                NSEvent.removeMonitor(monitor)
                localKeyMonitor = nil
            }
            if let mouseMonitor = localMouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                localMouseMonitor = nil
            }
        }
    }

    public func activeSessionCount() -> Int {
        sessions.count
    }

    private func computeOwnershipFlags(
        session: SessionRegistration?,
        isInput: Bool
    ) -> (horizontal: Bool, vertical: Bool, focus: TTPreviewFocusSource) {
        if isInput {
            return (false, false, .none)
        }
        guard let session else {
            return (false, false, .none)
        }
        return (session.ownsHorizontalArrowKeys, session.ownsVerticalArrowKeys, session.focusSource)
    }

    public func queryOwnership(
        windowNumber: Int?,
        instanceID: UUID? = nil,
        eventTimestamp: TimeInterval? = nil,
        keyCode: UInt16? = nil
    ) -> TTPreviewKeyboardOwnershipQuery {
        synchronizeLiveResponderState(windowNumber: windowNumber, preferredInstanceID: instanceID)
        let resolvedSession = resolveSession(windowNumber: windowNumber, preferredInstanceID: instanceID)
        let targetWindow = resolvedSession?.hostWindow ?? resolveWindow(for: windowNumber)
        let appKitInputActive = isAppKitTextInputActive(in: targetWindow, session: resolvedSession)
        let domInputActive = resolvedSession?.isDOMTextInputOrIMEActive ?? false
        let alreadyHandled = isSignatureAlreadyHandled(
            windowNumber: windowNumber,
            keyCode: keyCode,
            eventTimestamp: eventTimestamp
        )
        let isInput = appKitInputActive || domInputActive
        let (ownsH, ownsV, focusSrc) = computeOwnershipFlags(session: resolvedSession, isInput: isInput)
        let resolvedWinNum = resolvedSession?.windowNumber ?? windowNumber
        return TTPreviewKeyboardOwnershipQuery(
            contractVersion: .v2,
            ownsHorizontalArrowKeys: ownsH,
            ownsVerticalArrowKeys: ownsV,
            isTextInputActive: isInput,
            isEventAlreadyHandled: alreadyHandled,
            focusSource: focusSrc,
            ownerInstanceID: resolvedSession?.instanceID,
            windowNumber: resolvedWinNum
        )
    }

    public func handleOrBlockOuterHorizontalArrow(
        event: NSEvent,
        preferredInstanceID: UUID? = nil
    ) -> TTPreviewKeyboardDisposition {
        let keyCode = event.keyCode
        guard keyCode == 123 || keyCode == 124 else { return .passThrough }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        if !modifiers.intersection(disallowedModifiers).isEmpty { return .passThrough }
        let eventWindowNumber = event.window?.windowNumber ?? NSApp?.keyWindow?.windowNumber
        return performHorizontalArrowStepIfOwned(
            isRightArrow: keyCode == 124,
            windowNumber: eventWindowNumber,
            preferredInstanceID: preferredInstanceID,
            eventTimestamp: event.timestamp
        )
    }

    public func performHorizontalArrowStepIfOwned(
        isRightArrow: Bool,
        windowNumber: Int?,
        preferredInstanceID: UUID? = nil,
        eventTimestamp: TimeInterval? = nil,
        isAppKitTextInputOverride: Bool? = nil
    ) -> TTPreviewKeyboardDisposition {
        let keyCode: UInt16 = isRightArrow ? 124 : 123
        if isSignatureAlreadyHandled(windowNumber: windowNumber, keyCode: keyCode, eventTimestamp: eventTimestamp) {
            return .consumedByPreviewOwner
        }
        synchronizeLiveResponderState(windowNumber: windowNumber, preferredInstanceID: preferredInstanceID)
        let session = resolveSession(windowNumber: windowNumber, preferredInstanceID: preferredInstanceID)
        let targetWindow = session?.hostWindow ?? resolveWindow(for: windowNumber)
        let appKitInput = isAppKitTextInputOverride ?? isAppKitTextInputActive(in: targetWindow, session: session)
        if appKitInput || (session?.isDOMTextInputOrIMEActive == true) {
            return .yieldToTextInput
        }
        guard let session, session.ownsHorizontalArrowKeys else {
            return .passThrough
        }
        let handled = session.onHorizontalArrowKey(isRightArrow)
        if handled {
            recordHandledSignature(windowNumber: windowNumber, keyCode: keyCode, eventTimestamp: eventTimestamp)
            return .consumedByPreviewOwner
        }
        return .passThrough
    }

    public func handleOrBlockOuterVerticalArrow(
        event: NSEvent,
        preferredInstanceID: UUID? = nil
    ) -> TTPreviewKeyboardDisposition {
        let keyCode = event.keyCode
        guard keyCode == 125 || keyCode == 126 else { return .passThrough }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        if !modifiers.intersection(disallowedModifiers).isEmpty { return .passThrough }
        let eventWindowNumber = event.window?.windowNumber ?? NSApp?.keyWindow?.windowNumber
        return performVerticalArrowStepIfOwned(
            isDownArrow: keyCode == 125,
            windowNumber: eventWindowNumber,
            preferredInstanceID: preferredInstanceID,
            eventTimestamp: event.timestamp
        )
    }

    public func performVerticalArrowStepIfOwned(
        isDownArrow: Bool,
        windowNumber: Int?,
        preferredInstanceID: UUID? = nil,
        eventTimestamp: TimeInterval? = nil,
        isAppKitTextInputOverride: Bool? = nil
    ) -> TTPreviewKeyboardDisposition {
        let keyCode: UInt16 = isDownArrow ? 125 : 126
        if isSignatureAlreadyHandled(windowNumber: windowNumber, keyCode: keyCode, eventTimestamp: eventTimestamp) {
            return .consumedByPreviewOwner
        }
        synchronizeLiveResponderState(windowNumber: windowNumber, preferredInstanceID: preferredInstanceID)
        let session = resolveSession(windowNumber: windowNumber, preferredInstanceID: preferredInstanceID)
        let targetWindow = session?.hostWindow ?? resolveWindow(for: windowNumber)
        let appKitInput = isAppKitTextInputOverride ?? isAppKitTextInputActive(in: targetWindow, session: session)
        if appKitInput || (session?.isDOMTextInputOrIMEActive == true) {
            return .yieldToTextInput
        }
        guard let session, session.ownsVerticalArrowKeys, let onVertical = session.onVerticalArrowKey else {
            return .passThrough
        }
        let handled = onVertical(isDownArrow)
        if handled {
            recordHandledSignature(windowNumber: windowNumber, keyCode: keyCode, eventTimestamp: eventTimestamp)
            return .consumedByPreviewOwner
        }
        return .passThrough
    }

    private func resolveCandidateSessionIDs(windowNumber: Int?, preferredInstanceID: UUID?) -> [UUID] {
        if let preferredInstanceID, sessions[preferredInstanceID] != nil {
            return [preferredInstanceID]
        }
        if let windowNumber {
            return sessions.values.filter { $0.windowNumber == windowNumber }.map(\.instanceID)
        }
        return Array(sessions.keys)
    }

    private func resolveSessionWindow(for session: SessionRegistration, fallbackWindowNumber: Int?) -> NSWindow? {
        if let window = session.hostWindow { return window }
        if let window = session.readerWebView?.window { return window }
        if let window = session.readerContainerView?.window { return window }
        return resolveWindow(for: session.windowNumber ?? fallbackWindowNumber)
    }

    private func evaluateInsideReaderFocus(
        wasInsideLastSync: Bool,
        isReleasedByOutside: Bool,
        inWebView: Bool,
        currentFocusSource: TTPreviewFocusSource
    ) -> (focusSource: TTPreviewFocusSource, isReleased: Bool) {
        if isReleasedByOutside {
            return (.none, true)
        }
        if !wasInsideLastSync {
            return (inWebView ? .readingArea : .toolbarOrPopover, false)
        }
        if inWebView && currentFocusSource == .none {
            return (.readingArea, false)
        }
        if !inWebView {
            return (.toolbarOrPopover, false)
        }
        return (currentFocusSource, false)
    }

    private func syncSessionResponder(id: UUID, fallbackWindowNumber: Int?) {
        guard var session = sessions[id] else { return }
        guard let window = resolveSessionWindow(for: session, fallbackWindowNumber: fallbackWindowNumber) else {
            return
        }
        session.hostWindow = window
        session.windowNumber = window.windowNumber
        let responder = window.firstResponder

        if Self.isAppKitEditableResponder(responder) {
            session.focusSource = .none
            session.wasResponderInsideReaderLastSync = false
            sessions[id] = session
            return
        }

        let inWebView = session.readerWebView.map { Self.isResponderInside(responder: responder, targetView: $0) } ?? false
        let container = session.readerContainerView
        let isContainerValid = (container != nil && container !== window.contentView)
        let inContainer = isContainerValid
            ? container.map { Self.isResponderInside(responder: responder, targetView: $0) } ?? false
            : false

        if inWebView || inContainer {
            let (source, isReleased) = evaluateInsideReaderFocus(
                wasInsideLastSync: session.wasResponderInsideReaderLastSync,
                isReleasedByOutside: session.isReleasedByOutsideInteraction,
                inWebView: inWebView,
                currentFocusSource: session.focusSource
            )
            session.focusSource = source
            session.isReleasedByOutsideInteraction = isReleased
            session.wasResponderInsideReaderLastSync = true
            sessions[id] = session
            return
        }

        session.wasResponderInsideReaderLastSync = false
        if let responderView = responder as? NSView, responderView !== window.contentView {
            session.focusSource = .none
        }
        sessions[id] = session
    }

    private func synchronizeLiveResponderState(windowNumber: Int?, preferredInstanceID: UUID?) {
        let candidateIDs = resolveCandidateSessionIDs(windowNumber: windowNumber, preferredInstanceID: preferredInstanceID)
        for id in candidateIDs {
            syncSessionResponder(id: id, fallbackWindowNumber: windowNumber)
        }
    }

    private static func isResponderInside(responder: NSResponder?, targetView: NSView) -> Bool {
        guard let responder else { return false }
        if responder === targetView { return true }
        if let respView = responder as? NSView {
            return respView.isDescendant(of: targetView)
        }
        return false
    }

    private static func isPoint(_ locationInWindow: NSPoint, insideView view: NSView) -> Bool {
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
        let localPoint = view.convert(locationInWindow, from: nil)
        return view.bounds.contains(localPoint)
    }

    private static func isAppKitEditableResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSTextView || responder is NSTextField {
            return true
        }
        if let textClient = responder as? NSTextInputClient, textClient.hasMarkedText() {
            return true
        }
        return false
    }

    private func resolveWindow(for windowNumber: Int?) -> NSWindow? {
        for session in sessions.values {
            if let win = session.hostWindow ?? session.readerWebView?.window ?? session.readerContainerView?.window {
                if windowNumber == nil || win.windowNumber == windowNumber {
                    return win
                }
            }
        }
        guard let app = NSApp else { return nil }
        if let windowNumber {
            return app.windows.first(where: { $0.windowNumber == windowNumber })
        }
        return app.keyWindow
    }

    private func isAppKitTextInputActive(in window: NSWindow?, session: SessionRegistration?) -> Bool {
        if session?.isAppKitIMEComposing == true || session?.readerWebView?.isAppKitMarkedTextActive() == true {
            return true
        }
        guard let responder = window?.firstResponder else { return false }
        return Self.isAppKitEditableResponder(responder)
    }

    private func resolveSession(windowNumber: Int?, preferredInstanceID: UUID?) -> SessionRegistration? {
        if let preferredInstanceID, let explicit = sessions[preferredInstanceID] {
            if let windowNumber, let sessionWindow = explicit.windowNumber, sessionWindow != windowNumber {
                return nil
            }
            return explicit
        }
        if let windowNumber {
            let matching = sessions.values.filter { $0.windowNumber == windowNumber }
            return matching.max(by: { $0.lastFocusedTimestamp < $1.lastFocusedTimestamp })
        }
        return sessions.values.max(by: { $0.lastFocusedTimestamp < $1.lastFocusedTimestamp })
    }

    private func isSignatureAlreadyHandled(
        windowNumber: Int?,
        keyCode: UInt16?,
        eventTimestamp: TimeInterval?
    ) -> Bool {
        guard let keyCode, let eventTimestamp, let last = lastHandledSignature else { return false }
        return last.windowNumber == windowNumber
            && last.keyCode == keyCode
            && last.timestampBits == eventTimestamp.bitPattern
    }

    private func recordHandledSignature(
        windowNumber: Int?,
        keyCode: UInt16,
        eventTimestamp: TimeInterval?
    ) {
        guard let eventTimestamp else { return }
        lastHandledSignature = EventSignature(
            windowNumber: windowNumber,
            keyCode: keyCode,
            timestampBits: eventTimestamp.bitPattern
        )
    }

    private func installLocalMonitorsIfNeeded() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let keyCode = event.keyCode
                if keyCode == 123 || keyCode == 124 {
                    let disposition = self.handleOrBlockOuterHorizontalArrow(event: event)
                    if disposition == .consumedByPreviewOwner {
                        return nil
                    }
                } else if keyCode == 125 || keyCode == 126 {
                    let disposition = self.handleOrBlockOuterVerticalArrow(event: event)
                    if disposition == .consumedByPreviewOwner {
                        return nil
                    }
                }
                return event
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.handleWindowMouseDown(in: event.window, locationInWindow: event.locationInWindow)
                return event
            }
        }
    }
}
