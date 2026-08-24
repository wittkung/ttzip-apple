// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AppKit
import SwiftUI

/// Coordinates media playback shortcuts (Space to toggle play/pause, Left/Right arrow keys to seek)
/// across video, audio, and full-screen presentation contexts.
@MainActor
public final class MediaPlaybackCoordinator: ObservableObject {
    public static let shared = MediaPlaybackCoordinator()
    
    public typealias PlayPauseHandler = () -> Void
    public typealias SeekHandler = (Double) -> Void
    
    @Published public private(set) var isMediaActive: Bool = false
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var isFocusedOrHovered: Bool = false
    
    private var activeSessionID: String? = nil
    private var playPauseHandler: PlayPauseHandler? = nil
    private var seekHandler: SeekHandler? = nil
    private var eventMonitor: Any? = nil
    
    private init() {
        setupKeyMonitor()
    }
    
    private func setupKeyMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            // 1. Text editor non-interference: pass through if focus is in a text editing field
            if let responder = NSApp.keyWindow?.firstResponder {
                if responder is NSTextView || responder is NSTextField {
                    if let tv = responder as? NSTextView, tv.isFieldEditor {
                        return event
                    }
                    if responder is NSTextField {
                        return event
                    }
                }
            }
            
            guard self.isMediaActive, self.playPauseHandler != nil else {
                return event
            }
            
            let isFullScreen = FullScreenMediaWindowController.shared.isPresenting
            
            // KeyCode 49 is Space Bar
            if event.keyCode == 49 {
                self.playPauseHandler?()
                return nil // Consumed
            }
            
            // Left Arrow (KeyCode 123) / Right Arrow (KeyCode 124)
            if event.keyCode == 123 || event.keyCode == 124 {
                if self.isPlaying || self.isFocusedOrHovered || isFullScreen {
                    let step: Double = event.modifierFlags.contains(.shift) ? 15.0 : 5.0
                    if event.keyCode == 123 {
                        self.seekHandler?(-step)
                    } else {
                        self.seekHandler?(step)
                    }
                    return nil // Consumed
                }
            }
            
            return event
        }
    }
    
    /// Queries whether arrow keys should be intercepted for media seeking rather than directory navigation.
    public func shouldInterceptMediaKeys() -> Bool {
        let isFullScreen = FullScreenMediaWindowController.shared.isPresenting
        return isMediaActive && playPauseHandler != nil && (isPlaying || isFocusedOrHovered || isFullScreen)
    }
    
    /// Registers an active media session (video or audio player).
    public func registerSession(
        id: String,
        isPlaying: Bool,
        togglePlayPause: @escaping PlayPauseHandler,
        seekBy: @escaping SeekHandler
    ) {
        self.activeSessionID = id
        self.isPlaying = isPlaying
        self.isMediaActive = true
        self.playPauseHandler = togglePlayPause
        self.seekHandler = seekBy
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
    
    /// Unregisters an active session on teardown.
    public func unregisterSession(id: String) {
        guard self.activeSessionID == id else { return }
        self.activeSessionID = nil
        self.isMediaActive = false
        self.isPlaying = false
        self.isFocusedOrHovered = false
        self.playPauseHandler = nil
        self.seekHandler = nil
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
