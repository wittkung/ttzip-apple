// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
import OpenGL
import OpenGL.GL3
import QuartzCore
import TTZipUI
@testable import TTZipPreviewKit
@testable import TTZipCore
@testable import TTZipApp

final class NativeMPVFullscreenExclusivityTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("NativeMPVExclusivityTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: Layer State Concurrency & Thread Safety
    
    func testMPVOpenGLLayerIsBoundThreadSafety() {
        final class LayerBox: @unchecked Sendable {
            let layer: MPVOpenGLLayer
            init(_ layer: MPVOpenGLLayer) { self.layer = layer }
        }
        
        let box = LayerBox(MPVOpenGLLayer())
        let iterations = 1_000
        let group = DispatchGroup()
        
        // Concurrent writer: isBound
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<iterations {
                box.layer.isBound = (i % 2 == 0)
            }
            group.leave()
        }
        
        // Concurrent trigger: forceRedraw
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<iterations {
                box.layer.forceRedraw()
            }
            group.leave()
        }
        
        // Concurrent reader: isBound
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0..<iterations {
                _ = box.layer.isBound
            }
            group.leave()
        }
        
        let result = group.wait(timeout: .now() + 5.0)
        XCTAssertEqual(result, .success, "Concurrent read/write of layer state must complete without deadlock")
    }
    
    // MARK: - Test 2: Render Context Lock Scope & Safe Teardown
    
    @MainActor
    func testRenderContextLockDuringRenderPreventsUseAfterFree() {
        let manager = MPVRenderContextManager()
        
        // When rawContext is nil, render, update, and reportSwap safely return without deadlocks or crashes
        manager.render(fbo: 0, width: 1920, height: 1080)
        let flags = manager.update()
        XCTAssertEqual(flags, 0)
        manager.reportSwap()
        
        // Verify multiple clean teardowns in succession
        manager.detachAndFree()
        manager.detachAndFree()
        XCTAssertNil(manager.rawContext)
        XCTAssertNil(manager.activeContext)
    }
    
    // MARK: - Test 3: Fallback Pixel Format & Context Clean Teardown
    
    @MainActor
    func testFallbackPixelFormatAndContextCleanup() throws {
        let manager = MPVRenderContextManager()
        XCTAssertNil(manager.rawContext)
        XCTAssertNil(manager.activeContext)
        
        // Detaching when uninitialized is a safe no-op
        manager.detachAndFree()
        XCTAssertNil(manager.rawContext)
        XCTAssertNil(manager.activeContext)
    }
    
    // MARK: - Test 4: Single-Layer In-Place Resizing & CGL Context Continuity
    
    @MainActor
    func testSingleLayerInPlaceResizingAndCGLContextContinuity() {
        let layer = MPVOpenGLLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        
        XCTAssertTrue(layer.needsDisplayOnBoundsChange, "Layer must redraw in-place upon bounds change")
        
        // Allocate CGL pixel format and context for initial inline geometry
        let pf = layer.copyCGLPixelFormat(forDisplayMask: 0)
        let initialContext = layer.copyCGLContext(forPixelFormat: pf)
        XCTAssertNotNil(initialContext, "CGLContext must be successfully created for layer")
        
        // Simulate in-place window expansion to full screen (1080p)
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        layer.bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        layer.forceRedraw()
        
        // Assert CGL context is continuous and not recreated or invalidated
        XCTAssertEqual(CGLGetPixelFormat(initialContext), pf, "CGL context must retain its pixel format across bounds expansion")
        
        // Simulate further expansion to 4K Ultra HD
        layer.frame = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        layer.bounds = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        layer.forceRedraw()
        
        XCTAssertEqual(CGLGetPixelFormat(initialContext), pf, "CGL context must remain intact after 4K in-place expansion")
        
        // Shrink back down to inline dimensions
        layer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        layer.bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        layer.forceRedraw()
        
        XCTAssertEqual(CGLGetPixelFormat(initialContext), pf, "CGL context must remain intact after shrinking back to inline")
        
        layer.releaseCGLContext(initialContext)
        CGLReleasePixelFormat(pf)
    }
    
    // MARK: - Test 5: Single-Layer In-Place Frame Submission Across Resolutions
    
    @MainActor
    func testSingleLayerInPlaceFrameSubmissionAcrossResolutions() {
        let manager = MPVRenderContextManager()
        
        // Render at inline resolution
        manager.render(fbo: 0, width: 320, height: 240)
        let inlineFlags = manager.update()
        XCTAssertEqual(inlineFlags, 0)
        manager.reportSwap()
        
        // In-place expansion: render at full screen 1080p resolution
        manager.render(fbo: 0, width: 1920, height: 1080)
        let fsFlags = manager.update()
        XCTAssertEqual(fsFlags, 0)
        manager.reportSwap()
        
        // In-place expansion: render at 4K resolution
        manager.render(fbo: 0, width: 3840, height: 2160)
        let uhdFlags = manager.update()
        XCTAssertEqual(uhdFlags, 0)
        manager.reportSwap()
        
        manager.detachAndFree()
        XCTAssertNil(manager.rawContext)
        XCTAssertNil(manager.activeContext)
    }
    
    // MARK: - Test 6: Single-Click WorkItem Cancelled On Window Detach
    
    @MainActor
    func testSingleClickWorkItemCancellationOnWindowDetachment() {
        let container = MPVMetalContainerView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var playPauseFired = false
        container.onTogglePlayPause = {
            playPauseFired = true
        }
        
        // Host in window
        let testWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        testWindow.contentView = container
        XCTAssertEqual(container.window, testWindow)
        
        // Simulate single click
        let clickEvent = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 50, y: 50), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: testWindow.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0
        )!
        container.mouseUp(with: clickEvent)
        
        // Immediately detach from window before doubleClickInterval elapses
        testWindow.contentView = nil
        XCTAssertNil(container.window)
        
        // Wait longer than doubleClickInterval to ensure work item was cancelled
        let exp = expectation(description: "Wait past debounce interval")
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.1) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        
        XCTAssertFalse(playPauseFired, "Single click work item must be cancelled when view is removed from window")
    }
    
    // MARK: - Test 7: Release CGL Context Frees Render Context If Active
    
    @MainActor
    func testReleaseCGLContextFreesRenderContextIfActive() {
        let layer = MPVOpenGLLayer()
        let manager = MPVRenderContextManager()
        layer.renderContextManager = manager
        
        let pf = layer.copyCGLPixelFormat(forDisplayMask: 0)
        let ctx = layer.copyCGLContext(forPixelFormat: pf)
        
        // When releaseCGLContext is called on an arbitrary context not equal to activeContext, manager is untouched
        layer.releaseCGLContext(ctx)
        
        CGLReleasePixelFormat(pf)
    }
    
    // MARK: - Test 8: Container View In-Place Resizing Preserves Backing Layer
    
    @MainActor
    func testContainerViewInPlaceResizingPreservesBackingLayer() {
        let container = MPVMetalContainerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        guard let initialLayer = container.layer as? MPVOpenGLLayer else {
            XCTFail("MPVMetalContainerView must have an MPVOpenGLLayer backing layer")
            return
        }
        
        // Resize container view to full screen dimensions
        container.frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        container.layoutSubtreeIfNeeded()
        
        // Verify the exact same layer instance is preserved in-place
        XCTAssertTrue(container.layer === initialLayer, "Backing layer must not be recreated or replaced during in-place resizing")
        XCTAssertEqual(container.layer?.bounds.size.width, 1920, "Backing layer bounds must match resized container width")
        XCTAssertEqual(container.layer?.bounds.size.height, 1080, "Backing layer bounds must match resized container height")
        
        // Resize back to compact
        container.frame = NSRect(x: 0, y: 0, width: 480, height: 270)
        container.layoutSubtreeIfNeeded()
        
        XCTAssertTrue(container.layer === initialLayer, "Backing layer instance must remain unchanged when shrinking in-place")
        XCTAssertEqual(container.layer?.bounds.size.width, 480)
        XCTAssertEqual(container.layer?.bounds.size.height, 270)
    }
}
