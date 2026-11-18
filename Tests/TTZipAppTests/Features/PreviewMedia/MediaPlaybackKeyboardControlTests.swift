// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import AVFoundation
import CoreMedia
@testable import TTMediaKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class MediaPlaybackKeyboardControlTests: XCTestCase {
    
    // MARK: - Test 1: Session Registration, Play/Pause Toggle & State Sync
    
    @MainActor
    func testMediaPlaybackCoordinatorPlayPauseToggle() throws {
        let coordinator = MediaPlaybackCoordinator.shared
        let testSessionID = "test_session_\(UUID().uuidString)"
        
        let window = bindKeyboardWindow(coordinator: coordinator, sessionID: testSessionID)
        defer {
            coordinator.unregisterSession(id: testSessionID)
            window.close()
        }

        var playPauseCalled = false
        var lastSeekAmount: Double = 0
        
        coordinator.registerSession(
            id: testSessionID,
            isPlaying: false,
            togglePlayPause: {
                playPauseCalled = true
            },
            seekBy: { delta in
                lastSeekAmount = delta
            }
        )
        
        XCTAssertTrue(coordinator.isMediaActive, "Coordinator should mark media session as active")
        XCTAssertFalse(coordinator.isPlaying, "Initial playback state should be false")
        
        // Trigger play/pause
        coordinator.triggerPlayPause()
        XCTAssertTrue(playPauseCalled, "playPauseHandler closure should be called")
        
        // Update playback state
        coordinator.updatePlaybackState(id: testSessionID, isPlaying: true)
        XCTAssertTrue(coordinator.isPlaying, "Coordinator playback state should update to true")
        XCTAssertTrue(coordinator.shouldInterceptMediaKeys(in: window), "shouldInterceptMediaKeys should return true during playback")
        
        // Trigger seek forward/backward
        coordinator.triggerSeek(by: -5.0)
        XCTAssertEqual(lastSeekAmount, -5.0, "Seek backward by 5 seconds dispatched incorrectly")
        
        coordinator.triggerSeek(by: 5.0)
        XCTAssertEqual(lastSeekAmount, 5.0, "Seek forward by 5 seconds dispatched incorrectly")
        
        coordinator.triggerSeek(by: 15.0)
        XCTAssertEqual(lastSeekAmount, 15.0, "Shift seek by 15 seconds dispatched incorrectly")
        
        // Unregister session
        coordinator.unregisterSession(id: testSessionID)
        XCTAssertFalse(coordinator.isMediaActive, "isMediaActive should reset to false after unregistering")
        XCTAssertFalse(coordinator.isPlaying, "isPlaying should reset to false after unregistering")
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(in: window), "shouldInterceptMediaKeys should return false after unregistering")
    }
    
    // MARK: - Test 2: AVSampleBufferPlayerCoordinator seekBy Bounds Clamping
    
    @MainActor
    func testSharedVideoPlayerStoreSeekByBoundsClamping() throws {
        let coordinator = AVSampleBufferPlayerCoordinator()
        let duration = CMTime(seconds: 100.0, preferredTimescale: 600)
        coordinator.prepare(duration: duration)
        coordinator.seek(to: CMTime(seconds: 10.0, preferredTimescale: 600), preroll: false)
        
        // 1. Normal backward seek 5s -> 5.0
        coordinator.seek(by: -5.0, preroll: false)
        XCTAssertEqual(CMTimeGetSeconds(coordinator.currentTime), 5.0, accuracy: 0.01, "Current time after seeking backward 5s should be 5.0")
        
        // 2. Out-of-bounds backward seek -> Clamped to 0.0
        coordinator.seek(by: -20.0, preroll: false)
        XCTAssertEqual(CMTimeGetSeconds(coordinator.currentTime), 0.0, accuracy: 0.01, "Out-of-bounds backward seek should clamp to 0.0")
        
        // 3. Normal forward seek 15s -> 15.0
        coordinator.seek(by: 15.0, preroll: false)
        XCTAssertEqual(CMTimeGetSeconds(coordinator.currentTime), 15.0, accuracy: 0.01, "Current time after seeking forward 15s should be 15.0")
        
        // 4. Out-of-bounds forward seek -> Clamped to duration (100.0)
        coordinator.seek(by: 200.0, preroll: false)
        XCTAssertEqual(CMTimeGetSeconds(coordinator.currentTime), 100.0, accuracy: 0.01, "Out-of-bounds forward seek should clamp to duration 100.0")
        
        coordinator.teardown()
    }
    
    // MARK: - Test 3: Hover & Focus State Interception Logic
    
    @MainActor
    func testHoverAndFocusStateInterception() throws {
        let coordinator = MediaPlaybackCoordinator.shared
        let sessionID = "hover_test_session_\(UUID().uuidString)"
        
        let window = bindKeyboardWindow(coordinator: coordinator, sessionID: sessionID)
        defer {
            coordinator.unregisterSession(id: sessionID)
            window.close()
        }

        coordinator.registerSession(
            id: sessionID,
            isPlaying: false,
            togglePlayPause: {},
            seekBy: { _ in }
        )
        
        // Neither playing nor hovered -> Do not intercept arrow keys (allow directory navigation)
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(in: window), "Should allow directory arrow key navigation when neither playing nor hovered")
        
        // Mouse hovered over player -> Intercept arrow keys (allow seeking)
        coordinator.setHovered(id: sessionID, isHovered: true)
        XCTAssertTrue(coordinator.isFocusedOrHovered)
        XCTAssertTrue(coordinator.shouldInterceptMediaKeys(in: window), "Should intercept arrow keys when mouse is hovered over player")
        
        // Mouse moved out
        coordinator.setHovered(id: sessionID, isHovered: false)
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(in: window), "Should not intercept arrow keys when mouse moved out and not playing")
        
        let replacementID = "replacement_\(UUID().uuidString)"
        coordinator.setHovered(id: sessionID, isHovered: true)
        coordinator.setFullScreenPresentation(id: sessionID, isFullScreen: true)
        coordinator.bindWindow(id: replacementID, window: window)
        coordinator.registerSession(id: replacementID, isPlaying: false, togglePlayPause: {}, seekBy: { _ in })
        XCTAssertFalse(coordinator.isFocusedOrHovered, "A replacement session must not inherit hover")
        XCTAssertFalse(coordinator.isFullScreenPresentation, "A replacement session must not inherit presentation")
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(in: window), "A paused replacement must preserve directory arrows")
        coordinator.unregisterSession(id: replacementID)
        coordinator.unregisterSession(id: sessionID)
    }

    @MainActor
    func testTextInputOtherWindowAndSuspendedPopoverAlwaysTakePriority() throws {
        let coordinator = MediaPlaybackCoordinator.shared
        let sessionID = "window_guard_\(UUID().uuidString)"
        let window = bindKeyboardWindow(coordinator: coordinator, sessionID: sessionID)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer {
            coordinator.unregisterSession(id: sessionID)
            window.close()
            other.close()
        }
        coordinator.registerSession(id: sessionID, isPlaying: true, togglePlayPause: {}, seekBy: { _ in })
        XCTAssertTrue(coordinator.shouldInterceptMediaKeys(in: window))
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        window.contentView?.addSubview(input)
        XCTAssertTrue(window.makeFirstResponder(input))
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(in: window), "Text editing must retain arrows even while media plays")
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertTrue(coordinator.shouldInterceptMediaKeys(in: window))
        coordinator.setShortcutSuspended(id: sessionID, suspended: true)
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(in: window), "A subtitle/style popover must retain its own keys")
        coordinator.setShortcutSuspended(id: sessionID, suspended: false)
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(in: other), "Playback in another window must not steal directory keys")
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(in: nil), "No key window must not acquire media shortcuts")
        XCTAssertTrue(coordinator.shouldInterceptMediaKeys(in: window))
    }

    @MainActor
    private func bindKeyboardWindow(coordinator: MediaPlaybackCoordinator, sessionID: String) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        coordinator.bindWindow(id: sessionID, window: window)
        return window
    }

}
