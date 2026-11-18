// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import AVFoundation
import CoreMedia
import QuartzCore
import TTZipUI
import TTMediaKit
@testable import TTZipPreviewKit
@testable import TTZipCore
@testable import TTZipApp

final class NativeMPVFullscreenExclusivityTests: XCTestCase {
    
    // MARK: - Test 1: Coordinator State Concurrency & Thread Safety
    
    @MainActor
    func testAVSampleBufferPlayerStateConcurrency() async {
        let coordinator = AVSampleBufferPlayerCoordinator()
        coordinator.prepare(duration: CMTime(seconds: 60.0, preferredTimescale: 600))
        let iterations = 1_000
        
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                for _ in 0..<iterations {
                    _ = coordinator.isPlaying
                }
                return true
            }
            group.addTask { @MainActor in
                for _ in 0..<iterations {
                    _ = coordinator.currentTime
                }
                return true
            }
            for await completed in group {
                XCTAssertTrue(completed)
            }
        }
        
        coordinator.teardown()
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertFalse(coordinator.isReady)
    }
    
    // MARK: - Test 2: Clean Teardown Prevents Use-After-Free
    
    @MainActor
    func testCoordinatorTeardownPreventsUseAfterFree() {
        let coordinator = AVSampleBufferPlayerCoordinator()
        coordinator.prepare(duration: CMTime(seconds: 100.0, preferredTimescale: 600))
        coordinator.play()
        
        coordinator.teardown()
        coordinator.teardown()
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertFalse(coordinator.isReady)
    }
    
    // MARK: - Test 3: Uninitialized Teardown Safety
    
    @MainActor
    func testUninitializedCoordinatorTeardownIsSafe() {
        let coordinator = AVSampleBufferPlayerCoordinator()
        XCTAssertFalse(coordinator.isReady)
        XCTAssertFalse(coordinator.isPlaying)
        
        coordinator.teardown()
        XCTAssertFalse(coordinator.isReady)
        XCTAssertFalse(coordinator.isPlaying)
    }
    
    // MARK: - Test 4: Single-Layer In-Place Resizing & DisplayLayer Continuity
    
    @MainActor
    func testSingleLayerInPlaceResizingAndDisplayLayerContinuity() {
        let playerView = AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let initialDisplayLayer = playerView.displayLayer
        XCTAssertEqual(initialDisplayLayer.videoGravity, .resizeAspect, "DisplayLayer must enforce resizeAspect (zero distortion)")
        
        playerView.frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        playerView.layout()
        
        XCTAssertTrue(playerView.displayLayer === initialDisplayLayer, "Display layer must not be recreated across bounds expansion")
        XCTAssertEqual(playerView.displayLayer.frame, NSRect(x: 0, y: 0, width: 1920, height: 1080))
        
        playerView.frame = NSRect(x: 0, y: 0, width: 3840, height: 2160)
        playerView.layout()
        
        XCTAssertTrue(playerView.displayLayer === initialDisplayLayer)
        XCTAssertEqual(playerView.displayLayer.frame, NSRect(x: 0, y: 0, width: 3840, height: 2160))
        
        playerView.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        playerView.layout()
        
        XCTAssertTrue(playerView.displayLayer === initialDisplayLayer)
        XCTAssertEqual(playerView.displayLayer.frame, NSRect(x: 0, y: 0, width: 640, height: 360))
    }
    
    // MARK: - Test 5: Single-Layer In-Place Frame Submission Across Resolutions
    
    @MainActor
    func testSingleLayerInPlaceSeekAcrossResolutions() {
        let coordinator = AVSampleBufferPlayerCoordinator()
        coordinator.prepare(duration: CMTime(seconds: 300.0, preferredTimescale: 600))
        
        coordinator.seek(to: CMTime(seconds: 10.0, preferredTimescale: 600), preroll: false)
        XCTAssertEqual(CMTimeGetSeconds(coordinator.currentTime), 10.0, accuracy: 0.01)
        
        coordinator.seek(to: CMTime(seconds: 60.0, preferredTimescale: 600), preroll: false)
        XCTAssertEqual(CMTimeGetSeconds(coordinator.currentTime), 60.0, accuracy: 0.01)
        
        coordinator.seek(to: CMTime(seconds: 120.0, preferredTimescale: 600), preroll: false)
        XCTAssertEqual(CMTimeGetSeconds(coordinator.currentTime), 120.0, accuracy: 0.01)
        
        coordinator.teardown()
    }
    
    // MARK: - Test 6: Single-Click Task Cancelled On Window Detach
    
    @MainActor
    func testSingleClickTaskCancellationOnWindowDetachment() async {
        let playerView = AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var singleClickFired = false
        playerView.onCanvasSingleClick = {
            singleClickFired = true
        }
        
        let testWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        testWindow.contentView = playerView
        XCTAssertEqual(playerView.window, testWindow)
        
        let clickEvent = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 50, y: 50), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: testWindow.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0
        )!
        playerView.mouseUp(with: clickEvent)
        
        testWindow.contentView = nil
        XCTAssertNil(playerView.window)
        
        try? await Task.sleep(for: .milliseconds(300))
        
        XCTAssertFalse(singleClickFired, "Single click task must be cancelled when view is removed from window")
    }
    
    // MARK: - Test 7: Coordinator Reset Flushes Cleanly
    
    @MainActor
    func testCoordinatorResetFlushesRenderersCleanly() {
        let coordinator = AVSampleBufferPlayerCoordinator()
        coordinator.prepare(duration: CMTime(seconds: 60.0, preferredTimescale: 600))
        coordinator.reset()
        XCTAssertFalse(coordinator.isReady)
        XCTAssertEqual(coordinator.currentTime, .zero)
        XCTAssertEqual(coordinator.duration, .zero)
    }
    
    // MARK: - Test 8: Container View In-Place Resizing Preserves Backing Sublayer
    
    @MainActor
    func testPlayerNSViewInPlaceResizingPreservesSublayer() {
        let playerView = AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let initialLayer = playerView.displayLayer
        
        playerView.frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        playerView.layout()
        
        XCTAssertTrue(playerView.displayLayer === initialLayer, "Display layer must be preserved in-place")
        XCTAssertEqual(playerView.displayLayer.bounds.size.width, 1920)
        XCTAssertEqual(playerView.displayLayer.bounds.size.height, 1080)
        
        playerView.frame = NSRect(x: 0, y: 0, width: 480, height: 270)
        playerView.layout()
        
        XCTAssertTrue(playerView.displayLayer === initialLayer)
        XCTAssertEqual(playerView.displayLayer.bounds.size.width, 480)
        XCTAssertEqual(playerView.displayLayer.bounds.size.height, 270)
    }
}
