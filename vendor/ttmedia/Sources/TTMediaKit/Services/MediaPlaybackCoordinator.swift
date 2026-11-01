// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import SwiftUI
import Observation
import WebKit

/// Coordinates media playback shortcuts (Space to toggle play/pause when focused or in full-screen modal, Left/Right arrow keys to seek)
/// across video, audio, and full-screen presentation contexts.
@Observable
@MainActor
public final class MediaPlaybackCoordinator {
    public static let shared = MediaPlaybackCoordinator()
    
    public typealias PlayPauseHandler = () -> Void
    public typealias SeekHandler = (Double) -> Void
    public typealias StopHandler = () -> Void
    
    public private(set) var isMediaActive: Bool = false
    public private(set) var isPlaying: Bool = false
    public private(set) var isFocusedOrHovered: Bool = false
    public private(set) var isFullScreenPresentation: Bool = false
    public private(set) var activeSessionID: String? = nil
    private var playPauseHandler: PlayPauseHandler? = nil
    private var seekHandler: SeekHandler? = nil
    private var stopHandler: StopHandler? = nil
    private var eventMonitor: Any? = nil
    private final class WindowReference {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private var menuTrackingDepth = 0
    private var menuObservers: [NSObjectProtocol] = []
    private var suspendedSessionIDs: Set<String> = []
    private var sessionWindows: [String: WindowReference] = [:]

    public func bindWindow(id: String, window: NSWindow) {
        sessionWindows = sessionWindows.filter { $0.value.window != nil }
        sessionWindows[id] = WindowReference(window)
    }

    public static func permitsShortcut(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        responderIsText: Bool, isOwningWindow: Bool, hasSheet: Bool
    ) -> Bool {
        guard [UInt16(49), 123, 124].contains(keyCode), isOwningWindow,
              !responderIsText, !hasSheet else { return false }
        return modifiers.intersection([.command, .control, .option]).isEmpty
    }
    
    private init() {
        setupMenuTracking()
        setupKeyMonitor()
    }

    public func setShortcutSuspended(id: String, suspended: Bool) {
        if suspended { suspendedSessionIDs.insert(id) } else { suspendedSessionIDs.remove(id) }
    }

    private func setupMenuTracking() {
        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTrackingDepth += 1 }
        })
        menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
            }
        })
    }
    
    private static func isTextOrWebResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSTextView || responder is NSTextField { return true }
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    private func setupKeyMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            let window = NSApp.keyWindow
            let responder = window?.firstResponder
            let isText = Self.isTextOrWebResponder(responder)
            let owningWindow = self.activeSessionID.flatMap { self.sessionWindows[$0]?.window }
            guard Self.permitsShortcut(
                keyCode: event.keyCode, modifiers: event.modifierFlags,
                responderIsText: isText,
                isOwningWindow: owningWindow != nil && owningWindow === window &&
                    (event.window == nil || event.window === window),
                hasSheet: window?.attachedSheet != nil
            ) else { return event }

            guard self.isMediaActive, self.playPauseHandler != nil, self.menuTrackingDepth == 0,
                  !self.suspendedSessionIDs.contains(self.activeSessionID ?? "") else {
                return event
            }
            
            if event.keyCode == 49 {
                self.playPauseHandler?()
                return nil
            }
            guard self.shouldInterceptMediaKeys() else { return event }
            let step: Double = event.modifierFlags.contains(.shift) ? 15 : 5
            self.seekHandler?(event.keyCode == 123 ? -step : step)
            return nil

        }
    }
    
    /// Queries whether arrow keys should be intercepted for media seeking rather than directory navigation.
    public func shouldInterceptMediaKeys() -> Bool {
        shouldInterceptMediaKeys(in: NSApp.keyWindow)
    }

    func shouldInterceptMediaKeys(in keyWindow: NSWindow?) -> Bool {
        guard let id = activeSessionID, let owningWindow = sessionWindows[id]?.window,
              owningWindow === keyWindow, !Self.isTextOrWebResponder(owningWindow.firstResponder),
              owningWindow.attachedSheet == nil else { return false }
        let mediaHasFocus = owningWindow.firstResponder is AVSampleBufferPlayerNSView
        return isMediaActive && playPauseHandler != nil && menuTrackingDepth == 0 &&
            !suspendedSessionIDs.contains(id) &&
            (isPlaying || isFocusedOrHovered || isFullScreenPresentation || mediaHasFocus)
    }
    
    /// Registers an active media session (video or audio player).
    public func registerSession(
        id: String,
        isPlaying: Bool,
        togglePlayPause: @escaping PlayPauseHandler,
        seekBy: @escaping SeekHandler,
        stop: StopHandler? = nil
    ) {
        if activeSessionID != id {
            isFocusedOrHovered = false
            isFullScreenPresentation = false
        }
        self.activeSessionID = id
        self.isPlaying = isPlaying
        self.isMediaActive = true
        self.playPauseHandler = togglePlayPause
        self.seekHandler = seekBy
        self.stopHandler = stop
    }
    
    /// Updates the playback state (playing vs paused) for an active session.
    public func updatePlaybackState(id: String, isPlaying: Bool) {
        guard self.activeSessionID == id else { return }
        self.isPlaying = isPlaying
    }
    
    /// Updates whether the media player view is currently hovered or focused.
    public func setHovered(id: String, isHovered: Bool) {
        guard self.activeSessionID == id else { return }
        self.isFocusedOrHovered = isHovered
    }

    /// Updates whether the active media session is currently presented in full-window/full-screen mode.
    public func setFullScreenPresentation(id: String, isFullScreen: Bool) {
        guard self.activeSessionID == id else { return }
        self.isFullScreenPresentation = isFullScreen
    }
    
    /// Unregisters an active session on teardown.
    public func unregisterSession(id: String) {
        sessionWindows.removeValue(forKey: id)
        suspendedSessionIDs.remove(id)
        guard self.activeSessionID == id else { return }
        self.activeSessionID = nil
        self.isMediaActive = false
        self.isPlaying = false
        self.isFocusedOrHovered = false
        self.isFullScreenPresentation = false
        self.playPauseHandler = nil
        self.seekHandler = nil
        self.stopHandler = nil
    }
    
    /// Stops any active playback session across video and audio engines.
    public func stopActivePlayback() {
        stopHandler?()
        self.activeSessionID = nil
        self.isMediaActive = false
        self.isPlaying = false
        self.isFocusedOrHovered = false
        self.isFullScreenPresentation = false
        self.playPauseHandler = nil
        self.seekHandler = nil
        self.stopHandler = nil
    }
    
    /// Programmatic playback trigger for tests or UI buttons.
    public func triggerPlayPause() {
        playPauseHandler?()
    }
    
    /// Programmatic seek trigger for tests or UI buttons.
    public func triggerSeek(by seconds: Double) {
        seekHandler?(seconds)
    }
}
