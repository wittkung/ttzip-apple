// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import AppKit
import AVFoundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class MediaPlaybackKeyboardControlTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("MediaKeyTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: Session Registration, Play/Pause Toggle & State Sync
    
    @MainActor
    func testMediaPlaybackCoordinatorPlayPauseToggle() throws {
        let coordinator = MediaPlaybackCoordinator.shared
        let testSessionID = "test_session_\(UUID().uuidString)"
        
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
        XCTAssertTrue(coordinator.shouldInterceptMediaKeys(), "shouldInterceptMediaKeys should return true during playback")
        
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
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(), "shouldInterceptMediaKeys should return false after unregistering")
    }
    
    // MARK: - Test 2: SharedVideoPlayerStore seekBy Bounds Clamping
    
    @MainActor
    func testSharedVideoPlayerStoreSeekByBoundsClamping() throws {
        let store = SharedVideoPlayerStore()
        let testMediaURL = tempDirURL.appendingPathComponent("sample_video.mp4")
        try Data("mock media binary stream".utf8).write(to: testMediaURL)
        
        store.setup(url: testMediaURL)
        store.duration = 100.0
        store.currentTime = 10.0
        
        // 1. Normal backward seek 5s -> 5.0
        store.seekBy(-5.0)
        XCTAssertEqual(store.currentTime, 5.0, accuracy: 0.01, "Current time after seeking backward 5s should be 5.0")
        
        // 2. Out-of-bounds backward seek -> Clamped to 0.0
        store.seekBy(-20.0)
        XCTAssertEqual(store.currentTime, 0.0, accuracy: 0.01, "Out-of-bounds backward seek should clamp to 0.0")
        
        // 3. Normal forward seek 15s -> 15.0
        store.seekBy(15.0)
        XCTAssertEqual(store.currentTime, 15.0, accuracy: 0.01, "Current time after seeking forward 15s should be 15.0")
        
        // 4. Out-of-bounds forward seek -> Clamped to duration (100.0)
        store.seekBy(200.0)
        XCTAssertEqual(store.currentTime, 100.0, accuracy: 0.01, "Out-of-bounds forward seek should clamp to duration 100.0")
        
        store.cleanUp()
    }
    
    // MARK: - Test 3: Hover & Focus State Interception Logic
    
    @MainActor
    func testHoverAndFocusStateInterception() throws {
        let coordinator = MediaPlaybackCoordinator.shared
        let sessionID = "hover_test_session_\(UUID().uuidString)"
        
        coordinator.registerSession(
            id: sessionID,
            isPlaying: false,
            togglePlayPause: {},
            seekBy: { _ in }
        )
        
        // Neither playing nor hovered -> Do not intercept arrow keys (allow directory navigation)
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(), "Should allow directory arrow key navigation when neither playing nor hovered")
        
        // Mouse hovered over player -> Intercept arrow keys (allow seeking)
        coordinator.setHovered(id: sessionID, isHovered: true)
        XCTAssertTrue(coordinator.isFocusedOrHovered)
        XCTAssertTrue(coordinator.shouldInterceptMediaKeys(), "Should intercept arrow keys when mouse is hovered over player")
        
        // Mouse moved out
        coordinator.setHovered(id: sessionID, isHovered: false)
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(), "Should not intercept arrow keys when mouse moved out and not playing")
        
        coordinator.unregisterSession(id: sessionID)
    }
}
