// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import TTMediaKit
import TTZipCore
import XCTest
@testable import TTZipApp
@testable import TTZipPreviewKit

@MainActor
final class VideoFullWindowCornerControlsOnDemandTests: XCTestCase {
    private var activeTestClocks: [DeterministicMediaTestClock] = []
    var hoveredPlayerViewIDs: Set<ObjectIdentifier> = []

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        hoveredPlayerViewIDs.removeAll()
        await StandalonePlaybackWindowManager.shared.resetForTesting()
    }

    override func tearDown() async throws {
        for clock in activeTestClocks {
            clock.cancelAll()
        }
        activeTestClocks.removeAll()
        hoveredPlayerViewIDs.removeAll()
        await StandalonePlaybackWindowManager.shared.resetForTesting()
        try await super.tearDown()
    }

    private func makeTestClock() -> DeterministicMediaTestClock {
        let clock = DeterministicMediaTestClock()
        activeTestClocks.append(clock)
        return clock
    }

    // MARK: - 1. Initial Hidden, Real-Clock Wiring & Hit-Test Pass-Through

    func testStandaloneVideoWindowInitialHiddenAndCanvasHitTestPassThroughInBothPlayingAndPausedStates() async throws {
        let origin = AppViewState()
        BrowserWindowRegistry.shared.register(origin)
        defer {
            BrowserWindowRegistry.shared.unregister(id: origin.windowID)
        }

        let (videoURL, window, host, size) = try await openOffscreenStandaloneVideoWindow(
            named: "initial-hidden.mp4",
            origin: origin,
            clock: nil
        )
        defer {
            try? FileManager.default.removeItem(at: videoURL)
        }
        XCTAssertFalse(window.isVisible, "Offscreen test must never activate or order front a GUI window")
        XCTAssertTrue(
            window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        )
        let playerView = try await waitForPlayerView(in: host, window: window)
        let returnBtn = try XCTUnwrap(
            findButton(id: "StandalonePlaybackReturnToPreviewButton", in: host) as? VideoWindowCornerClusterNSButton
        )
        let closeBtn = try XCTUnwrap(
            findButton(id: "StandalonePlaybackCloseButton", in: host) as? VideoWindowCornerClusterNSButton
        )
        let trafficController = try XCTUnwrap(window.trafficLightsController)
        let frameView = try XCTUnwrap(host.superview)

        for playState in [true, false] {
            if playState {
                playerView.play()
            } else {
                playerView.pause()
            }
            XCTAssertEqual(playerView.isPlaying, playState)
            flushWindowLayout(window)
            try assertBothTopCornersHiddenAndHitTestPassThrough(
                window: window,
                host: host,
                frameView: frameView,
                playerView: playerView,
                returnBtn: returnBtn,
                closeBtn: closeBtn,
                trafficController: trafficController,
                size: size,
                playState: playState
            )
        }

        var canvasDoubleClicks = 0
        playerView.onCanvasDoubleClick = {
            canvasDoubleClicks += 1
        }
        let closeCenterInWin = closeBtn.convert(NSPoint(x: closeBtn.bounds.midX, y: closeBtn.bounds.midY), to: nil)
        try dispatchClick(in: host, window: window, locationInWindow: closeCenterInWin, clickCount: 2)
        XCTAssertEqual(canvasDoubleClicks, 1, "Double-click at hidden corner button coordinate must reach video canvas")
        XCTAssertTrue(StandalonePlaybackWindowManager.shared.hasActivePlaybackSession)

        // Production default real-clock wiring check on real component
        try dispatchPointerMove(in: host, window: window, locationInWindow: closeCenterInWin)
        trafficController.handlePointerLocationInWindow(NSPoint(x: 20, y: size.height - 20))
        await waitUntil(in: window, description: "real-clock corner reveal") {
            closeBtn.isChromeVisible && trafficController.isTrafficLightsVisible
        }
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 300, y: 260))
        trafficController.handlePointerLocationInWindow(NSPoint(x: 300, y: 260))
        await waitUntil(in: window, timeout: .seconds(1.5), description: "real-clock 260ms corner auto-hide") {
            !closeBtn.isChromeVisible && !trafficController.isTrafficLightsVisible
        }
    }

    // MARK: - 2. Non-Corner Video Hover Isolation & Top-Right Cluster Lifecycle (259/260/261ms & 3s)

    func testNonCornerVideoHoverIsolationAndTopRightCornerLifecycle() async throws {
        let clock = makeTestClock()
        let (videoURL, window, host, size) = try await openOffscreenStandaloneVideoWindow(
            named: "top-right-lifecycle.mp4",
            origin: nil,
            clock: clock
        )
        defer {
            try? FileManager.default.removeItem(at: videoURL)
        }
        let playerView = try await waitForPlayerView(in: host, window: window)
        if playerView.isPlaying {
            playerView.togglePlayPause()
        }
        playerView.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600))
        await waitUntil(in: window, description: "0.5s seek convergence") {
            !playerView.isPlaying && abs(playerView.synchronizer.currentTime().seconds - 0.5) < 0.02
        }
        let baselineTime = playerView.synchronizer.currentTime().seconds

        let sensor = try XCTUnwrap(findSensor(id: "StandalonePlaybackTopRightControls.HoverSensor", in: host))
        let returnBtn = try XCTUnwrap(
            findButton(id: "StandalonePlaybackReturnToPreviewButton", in: host) as? VideoWindowCornerClusterNSButton
        )
        let closeBtn = try XCTUnwrap(
            findButton(id: "StandalonePlaybackCloseButton", in: host) as? VideoWindowCornerClusterNSButton
        )
        let trafficController = try XCTUnwrap(window.trafficLightsController)
        let topRightRegion = NSRect(x: size.width - 220, y: size.height - 56, width: 216, height: 52)
        let bgSample = NSPoint(x: 300, y: 260)

        let closeCenterInWin = try await assertNonCornerHoverIsolationAndSensorEntryReveal(
            clock: clock,
            window: window,
            host: host,
            size: size,
            bgSample: bgSample,
            topRightRegion: topRightRegion,
            sensor: sensor,
            returnBtn: returnBtn,
            closeBtn: closeBtn,
            trafficController: trafficController
        )

        try await assertTopRightLocksReentryAndExactBoundaries(
            clock: clock,
            window: window,
            host: host,
            size: size,
            bgSample: bgSample,
            topRightRegion: topRightRegion,
            closeCenterInWin: closeCenterInWin,
            returnBtn: returnBtn,
            closeBtn: closeBtn
        )
        XCTAssertFalse(playerView.isPlaying)
        XCTAssertEqual(playerView.synchronizer.currentTime().seconds, baselineTime, accuracy: 0.05)

        try await assertBottomBarThreeSecondBoundaryAndSpaceIsolation(
            clock: clock,
            window: window,
            host: host,
            playerView: playerView,
            returnBtn: returnBtn,
            closeBtn: closeBtn,
            trafficController: trafficController
        )
    }

    private func assertNonCornerHoverIsolationAndSensorEntryReveal(
        clock: DeterministicMediaTestClock,
        window: StandalonePlaybackNSWindow,
        host: NSView,
        size: NSSize,
        bgSample: NSPoint,
        topRightRegion: NSRect,
        sensor: VideoWindowCornerSensorNSView,
        returnBtn: VideoWindowCornerClusterNSButton,
        closeBtn: VideoWindowCornerClusterNSButton,
        trafficController: StandalonePlaybackTrafficLightsController
    ) async throws -> NSPoint {
        let nonCornerPoints = [
            NSPoint(x: 440, y: 270),
            NSPoint(x: 440, y: 36),
            NSPoint(x: 440, y: size.height - 22)
        ]
        for pt in nonCornerPoints {
            try dispatchPointerMove(in: host, window: window, locationInWindow: pt)
            flushWindowLayout(window)
            XCTAssertFalse(sensor.isPointerInside, "Non-corner point \(pt) must not trigger top-right sensor")
            XCTAssertFalse(returnBtn.isChromeVisible)
            XCTAssertFalse(closeBtn.isChromeVisible)
            XCTAssertFalse(trafficController.isTrafficLightsVisible)
        }
        await clock.advance(by: .milliseconds(500))
        flushWindowLayout(window)
        XCTAssertFalse(closeBtn.isChromeVisible, "Advancing virtual clock without corner reveal must never wake controls")

        let sensorEntryPt = NSPoint(x: size.width - sensor.bounds.width + 8, y: size.height - 28)
        try dispatchPointerMove(in: host, window: window, locationInWindow: sensorEntryPt)
        await waitUntil(in: window, description: "top-right sensor reveal") {
            sensor.isPointerInside && returnBtn.isChromeVisible && closeBtn.isChromeVisible
        }
        let revealedPixels = try sampleContrastingPixels(
            in: host,
            logicalSize: size,
            bgPoint: bgSample,
            region: topRightRegion
        )
        XCTAssertGreaterThan(revealedPixels, 15)
        let closeCenterInWin = closeBtn.convert(NSPoint(x: closeBtn.bounds.midX, y: closeBtn.bounds.midY), to: nil)
        let closeHitPt = host.superview?.convert(closeCenterInWin, from: nil) ?? closeCenterInWin
        XCTAssertTrue(host.hitTest(closeHitPt) === closeBtn)
        return closeCenterInWin
    }

    private func assertTopRightLocksReentryAndExactBoundaries(
        clock: DeterministicMediaTestClock,
        window: StandalonePlaybackNSWindow,
        host: NSView,
        size: NSSize,
        bgSample: NSPoint,
        topRightRegion: NSRect,
        closeCenterInWin: NSPoint,
        returnBtn: VideoWindowCornerClusterNSButton,
        closeBtn: VideoWindowCornerClusterNSButton
    ) async throws {
        // Button hover holds cluster visible past 260ms
        try dispatchPointerMove(in: host, window: window, locationInWindow: closeCenterInWin)
        await waitUntil(in: window, description: "close button hover highlight") {
            closeBtn.isPointerHovered && closeBtn.isChromeHighlighted
        }
        await clock.advance(by: .milliseconds(300))
        flushWindowLayout(window)
        XCTAssertTrue(closeBtn.isChromeVisible)

        // Active menu tracking holds cluster visible past 320ms when pointer leaves corner
        window.isMenuTrackingOverrideForTesting = true
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 300, y: 260))
        await clock.advance(by: .milliseconds(320))
        flushWindowLayout(window)
        XCTAssertTrue(closeBtn.isChromeVisible, "Active menu tracking must prevent top-right cluster from auto-hiding")
        window.isMenuTrackingOverrideForTesting = false

        // Leave -> 70ms -> re-enter (cancels stale hide) -> leave again -> 250ms (320ms since first leave) stays visible
        await clock.advance(by: .milliseconds(70))
        try dispatchPointerMove(in: host, window: window, locationInWindow: closeCenterInWin)
        flushWindowLayout(window)
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 300, y: 260))
        await clock.advance(by: .milliseconds(250))
        flushWindowLayout(window)
        XCTAssertTrue(closeBtn.isChromeVisible, "Re-entering corner before 260ms must cancel stale hide task")

        // Exact 259ms / 260ms / 261ms boundaries on second leave
        await clock.advance(by: .milliseconds(9))
        flushWindowLayout(window)
        XCTAssertTrue(returnBtn.isChromeVisible, "Top-right cluster must remain visible at 259ms")
        XCTAssertTrue(closeBtn.isChromeVisible, "Top-right close button must remain visible at 259ms")

        await clock.advance(by: .milliseconds(1))
        await waitUntil(in: window, description: "top-right hides at 260ms") {
            !returnBtn.isChromeVisible && !closeBtn.isChromeVisible
        }
        let hiddenPixels = try sampleContrastingPixels(
            in: host,
            logicalSize: size,
            bgPoint: bgSample,
            region: topRightRegion
        )
        XCTAssertEqual(hiddenPixels, 0)
        await clock.advance(by: .milliseconds(1))
        flushWindowLayout(window)
        XCTAssertFalse(closeBtn.isChromeVisible)

        // Keyboard focus reveals cluster, holds past 300ms, and hides at 260ms (not 259ms) after blur
        XCTAssertTrue(window.makeFirstResponder(returnBtn))
        await waitUntil(in: window, description: "keyboard focus reveals top-right") {
            returnBtn.isChromeVisible && closeBtn.isChromeVisible
        }
        await clock.advance(by: .milliseconds(300))
        flushWindowLayout(window)
        XCTAssertTrue(returnBtn.isChromeVisible)
        _ = window.makeFirstResponder(nil)
        await clock.advance(by: .milliseconds(259))
        flushWindowLayout(window)
        XCTAssertTrue(returnBtn.isChromeVisible, "Top-right cluster must remain visible at 259ms after blur")
        await clock.advance(by: .milliseconds(1))
        await waitUntil(in: window, description: "top-right hides at 260ms after blur") {
            !returnBtn.isChromeVisible
        }
    }

    private func assertBottomBarThreeSecondBoundaryAndSpaceIsolation(
        clock: DeterministicMediaTestClock,
        window: StandalonePlaybackNSWindow,
        host: NSView,
        playerView: AVSampleBufferPlayerNSView,
        returnBtn: VideoWindowCornerClusterNSButton,
        closeBtn: VideoWindowCornerClusterNSButton,
        trafficController: StandalonePlaybackTrafficLightsController
    ) async throws {
        playerView.play()
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 412, y: 244))
        await waitUntil(in: window, description: "bottom control bar revealed") {
            playerView.isControlBarVisible
        }
        await clock.advance(by: .milliseconds(2_990))
        flushWindowLayout(window)
        XCTAssertTrue(playerView.isControlBarVisible, "Bottom control bar must remain visible at 2.99s")

        await clock.advance(by: .milliseconds(10))
        await waitUntil(in: window, description: "bottom control bar auto-hides at 3.00s") {
            !playerView.isControlBarVisible
        }
        await clock.advance(by: .milliseconds(10))
        flushWindowLayout(window)
        XCTAssertFalse(playerView.isControlBarVisible)

        let spacePauseEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: NSPoint(x: 412, y: 244),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )
        for _ in 0..<2 {
            playerView.keyDown(with: spacePauseEvent)
            flushWindowLayout(window)
            XCTAssertFalse(
                playerView.isControlBarVisible,
                "Space pause/resume while stationary must NEVER reveal bottom bar"
            )
            XCTAssertFalse(returnBtn.isChromeVisible)
            XCTAssertFalse(closeBtn.isChromeVisible)
            XCTAssertFalse(trafficController.isTrafficLightsVisible)
        }
    }

    // MARK: - 3. Top-Left Native Traffic Lights Lifecycle, System Fullscreen Separation & Native Actions

    func testTopLeftTrafficLightsOnDemandLifecycleSystemFullScreenLayerSeparationAndNativeActions() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let origin = AppViewState()
        BrowserWindowRegistry.shared.register(origin)
        defer {
            BrowserWindowRegistry.shared.unregister(id: origin.windowID)
        }

        let clock = makeTestClock()
        let (videoURL, window, host, size) = try await openOffscreenStandaloneVideoWindow(
            named: "traffic-lights-lifecycle.mp4",
            origin: origin,
            clock: clock
        )
        defer {
            try? FileManager.default.removeItem(at: videoURL)
        }
        _ = try await waitForPlayerView(in: host, window: window)

        let frameView = try XCTUnwrap(host.superview)
        let trafficController = try XCTUnwrap(window.trafficLightsController)
        let closeNativeBtn = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let topLeftSensor = try XCTUnwrap(findSensor(id: "StandalonePlaybackTrafficLights.HoverSensor", in: host))
        let returnBtn = try XCTUnwrap(
            findButton(id: "StandalonePlaybackReturnToPreviewButton", in: host) as? VideoWindowCornerClusterNSButton
        )
        let topLeftRegion = NSRect(x: 4, y: size.height - 42, width: 96, height: 38)

        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 84, y: size.height - 20))
        flushWindowLayout(window)
        XCTAssertTrue(topLeftSensor.isPointerInside)
        XCTAssertTrue(trafficController.isTrafficLightsVisible)
        XCTAssertFalse(closeNativeBtn.isHidden)
        XCTAssertEqual(closeNativeBtn.alphaValue, 1.0, accuracy: 0.001)
        let topLeftPixels = try sampleContrastingPixels(
            in: frameView,
            logicalSize: frameView.bounds.size,
            bgPoint: NSPoint(x: 300, y: 260),
            region: topLeftRegion
        )
        XCTAssertGreaterThan(topLeftPixels, 15)

        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 20, y: size.height - 20))
        flushWindowLayout(window)
        XCTAssertEqual(trafficController.hoveredStandardButtonKind, .closeButton)
        let nativeHit = try XCTUnwrap(frameView.hitTest(NSPoint(x: 20, y: size.height - 20)))
        XCTAssertTrue(nativeHit === closeNativeBtn || nativeHit.isDescendant(of: closeNativeBtn))

        try await assertTopLeftReentryKeyboardFocusAndFullScreenSeparation(
            clock: clock,
            window: window,
            host: host,
            size: size,
            trafficController: trafficController,
            closeNativeBtn: closeNativeBtn,
            returnBtn: returnBtn
        )

        let restored = expectation(description: "performClose while hidden restores origin preview")
        manager.onReturnToOriginPreview = { session in
            XCTAssertEqual(session.originBrowserWindowID, origin.windowID)
            restored.fulfill()
        }
        window.performClose(nil)
        await fulfillment(of: [restored], timeout: 3.0)
        XCTAssertFalse(manager.hasActivePlaybackSession)
    }

    private func assertTopLeftReentryKeyboardFocusAndFullScreenSeparation(
        clock: DeterministicMediaTestClock,
        window: StandalonePlaybackNSWindow,
        host: NSView,
        size: NSSize,
        trafficController: StandalonePlaybackTrafficLightsController,
        closeNativeBtn: NSButton,
        returnBtn: VideoWindowCornerClusterNSButton
    ) async throws {
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 300, y: 260))
        await clock.advance(by: .milliseconds(70))
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 20, y: size.height - 20))
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 300, y: 260))
        await clock.advance(by: .milliseconds(250))
        XCTAssertTrue(trafficController.isTrafficLightsVisible, "Re-entry must cancel first pending traffic-light hide")
        await clock.advance(by: .milliseconds(9))
        XCTAssertTrue(trafficController.isTrafficLightsVisible, "Traffic lights must stay visible at 259ms")
        XCTAssertFalse(closeNativeBtn.isHidden, "Traffic lights close button must stay visible at 259ms")
        await clock.advance(by: .milliseconds(1))
        XCTAssertFalse(trafficController.isTrafficLightsVisible)
        XCTAssertTrue(closeNativeBtn.isHidden)
        await clock.advance(by: .milliseconds(1))
        XCTAssertFalse(trafficController.isTrafficLightsVisible)

        XCTAssertTrue(window.makeFirstResponder(closeNativeBtn))
        XCTAssertTrue(trafficController.isTrafficLightsVisible)
        await clock.advance(by: .milliseconds(300))
        XCTAssertTrue(trafficController.isTrafficLightsVisible)
        _ = window.makeFirstResponder(nil)
        await clock.advance(by: .milliseconds(259))
        XCTAssertTrue(trafficController.isTrafficLightsVisible)
        await clock.advance(by: .milliseconds(1))
        XCTAssertFalse(trafficController.isTrafficLightsVisible)

        window.isSystemFullScreenOverrideForTesting = true
        XCTAssertTrue(trafficController.isSystemFullScreenManagedByMacOS)
        XCTAssertFalse(closeNativeBtn.isHidden)
        XCTAssertEqual(closeNativeBtn.alphaValue, 1.0, accuracy: 0.001)
        XCTAssertFalse(returnBtn.isChromeVisible)
        window.isSystemFullScreenOverrideForTesting = false
        XCTAssertTrue(closeNativeBtn.isHidden)
    }

    // MARK: - 4. ImmersiveMediaBrowserView Video Host & Main Browser Window Positive Control

    func testImmersiveMediaBrowserVideoCanvasTopRightOnDemandAndNormalMainBrowserWindowPositiveControl() async throws {
        let videoURL = try makeTempVideoFile(named: "immersive-host.mp4")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
        }

        var closeCount = 0
        var prevCount = 0
        var nextCount = 0
        let item = ImmersiveMediaItem(url: videoURL, name: videoURL.lastPathComponent)
        let browserView = ImmersiveMediaBrowserView(
            item: item,
            onClose: {
                closeCount += 1
            },
            onNavigatePrevious: {
                prevCount += 1
            },
            onNavigateNext: {
                nextCount += 1
            }
        )

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let size = NSSize(width: 860, height: 520)
        let host = NSHostingView(rootView: browserView.frame(width: size.width, height: size.height))
        host.sizingOptions = []
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        await waitUntil(in: window, description: "ImmersiveMediaBrowserView corner buttons mounted") {
            self.findButton(id: "ImmersiveMediaCloseButton", in: host) != nil
        }

        let closeBtn = try XCTUnwrap(
            findButton(id: "ImmersiveMediaCloseButton", in: host) as? VideoWindowCornerClusterNSButton
        )
        let prevBtn = try XCTUnwrap(
            findButton(id: "ImmersiveMediaPreviousButton", in: host) as? VideoWindowCornerClusterNSButton
        )
        let nextBtn = try XCTUnwrap(
            findButton(id: "ImmersiveMediaNextButton", in: host) as? VideoWindowCornerClusterNSButton
        )
        XCTAssertFalse(closeBtn.isChromeVisible)
        XCTAssertFalse(prevBtn.isChromeVisible)
        XCTAssertFalse(nextBtn.isChromeVisible)

        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 400, y: 260))
        flushWindowLayout(window)
        XCTAssertFalse(closeBtn.isChromeVisible)

        let closeCenter = closeBtn.convert(NSPoint(x: closeBtn.bounds.midX, y: closeBtn.bounds.midY), to: nil)
        let nextCenter = nextBtn.convert(NSPoint(x: nextBtn.bounds.midX, y: nextBtn.bounds.midY), to: nil)
        try dispatchPointerMove(in: host, window: window, locationInWindow: nextCenter)
        await waitUntil(in: window, description: "ImmersiveMediaBrowserView corner reveal") {
            closeBtn.isChromeVisible
        }
        try dispatchClick(in: host, window: window, locationInWindow: nextCenter, clickCount: 1)
        try dispatchClick(in: host, window: window, locationInWindow: closeCenter, clickCount: 1)
        XCTAssertEqual(nextCount, 1)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(prevCount, 0)

        try assertMainBrowserWindowTrafficLightsRemainVisible()
    }

    // MARK: - 5. Two-Window (A/B) Menu Ownership, Keep-Alive vs. Reveal Intent & Space Isolation

    func testTwoPlayerWindowsMenuOwnershipKeepAliveAndSpaceIsolation() async throws {
        let urlA = try makeTempVideoFile(named: "window-ab-shared.mp4")
        defer {
            try? FileManager.default.removeItem(at: urlA)
        }

        let clock = makeTestClock()
        let context = try await makeTwoPlayerWindowsContext(videoURL: urlA, clock: clock)
        defer {
            context.tearDown()
        }
        XCTAssertTrue(context.playerViewA !== context.playerViewB)
        XCTAssertNil(context.hostA.menu)
        XCTAssertNil(context.playerViewA.menu)

        let rightClickA = try makeMouseEvent(
            type: .rightMouseDown,
            location: NSPoint(x: 200, y: 200),
            window: context.windowA,
            clickCount: 1
        )
        let rightClickB = try makeMouseEvent(
            type: .rightMouseDown,
            location: NSPoint(x: 200, y: 200),
            window: context.windowB,
            clickCount: 1
        )
        try await assertUnownedAndCrossWindowMenusNeverWakeHiddenControls(
            context: context,
            clock: clock,
            rightClickA: rightClickA,
            rightClickB: rightClickB
        )

        let closeCenterA = context.closeBtnA.convert(
            NSPoint(x: context.closeBtnA.bounds.midX, y: context.closeBtnA.bounds.midY),
            to: nil
        )
        try await assertResetForNewItemDiscardsStaleMenuWithoutClearingNewOwner(
            clock: clock,
            hostA: context.hostA,
            windowA: context.windowA,
            playerViewA: context.playerViewA,
            closeBtnA: context.closeBtnA,
            trafficA: context.trafficA,
            controlsA: context.controlsA,
            closeCenterA: closeCenterA,
            rightClickA: rightClickA
        )
    }

    private func assertUnownedAndCrossWindowMenusNeverWakeHiddenControls(
        context: TwoPlayerWindowsTestContext,
        clock: DeterministicMediaTestClock,
        rightClickA: NSEvent,
        rightClickB: NSEvent
    ) async throws {
        let menuB = try XCTUnwrap(context.playerViewB.menu(for: rightClickB))
        let unownedObjects: [Any?] = [menuB, NSMenu(title: "Unowned"), nil]
        for object in unownedObjects {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: object)
        }
        flushWindowLayout(context.windowA)
        flushWindowLayout(context.windowB)
        XCTAssertFalse(context.closeBtnA.isChromeVisible)
        XCTAssertFalse(context.trafficA.isTrafficLightsVisible)
        XCTAssertFalse(context.controlsA.isVisible)
        XCTAssertFalse(context.closeBtnB.isChromeVisible)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menuB)

        let closeCenterA = context.closeBtnA.convert(
            NSPoint(x: context.closeBtnA.bounds.midX, y: context.closeBtnA.bounds.midY),
            to: nil
        )
        try dispatchPointerMove(in: context.hostA, window: context.windowA, locationInWindow: closeCenterA)
        context.trafficA.handlePointerLocationInWindow(NSPoint(x: 24, y: context.size.height - 20))
        await waitUntil(in: context.windowA, description: "Window A corner controls revealed") {
            context.closeBtnA.isChromeVisible && context.trafficA.isTrafficLightsVisible
        }

        let menuA = try XCTUnwrap(context.playerViewA.menu(for: rightClickA))
        let rotSubmenuA = try XCTUnwrap(menuA.items.compactMap(\.submenu).first)
        for object in [menuA, menuA, rotSubmenuA] {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: object)
        }
        try dispatchPointerMove(in: context.hostA, window: context.windowA, locationInWindow: NSPoint(x: 300, y: 250))
        context.trafficA.handlePointerLocationInWindow(NSPoint(x: 300, y: 250))
        let partialEndObjects: [Any?] = [nil, menuB, rotSubmenuA]
        for object in partialEndObjects {
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: object)
        }
        await clock.advance(by: .milliseconds(320))
        flushWindowLayout(context.windowA)
        XCTAssertTrue(context.closeBtnA.isChromeVisible)
        XCTAssertTrue(context.trafficA.isTrafficLightsVisible)
        XCTAssertTrue(context.controlsA.isVisible)
        XCTAssertFalse(context.closeBtnB.isChromeVisible)
        XCTAssertFalse(context.trafficB.isTrafficLightsVisible)

        for _ in 0..<2 {
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menuA)
        }
        await clock.advance(by: .milliseconds(259))
        flushWindowLayout(context.windowA)
        XCTAssertTrue(context.closeBtnA.isChromeVisible)
        XCTAssertTrue(context.trafficA.isTrafficLightsVisible)
        await clock.advance(by: .milliseconds(1))
        await waitUntil(in: context.windowA, description: "Window A corner controls hide at 260ms after menu end") {
            !context.closeBtnA.isChromeVisible && !context.trafficA.isTrafficLightsVisible
        }
    }

    private func assertResetForNewItemDiscardsStaleMenuWithoutClearingNewOwner(
        clock: DeterministicMediaTestClock,
        hostA: NSView,
        windowA: NSWindow,
        playerViewA: AVSampleBufferPlayerNSView,
        closeBtnA: VideoWindowCornerClusterNSButton,
        trafficA: StandalonePlaybackTrafficLightsController,
        controlsA: MediaControlsVisibility,
        closeCenterA: NSPoint,
        rightClickA: NSEvent
    ) async throws {
        try dispatchPointerMove(in: hostA, window: windowA, locationInWindow: closeCenterA)
        await waitUntil(in: windowA, description: "Window A corner reveal before resetForNewItem") {
            closeBtnA.isChromeVisible
        }
        let staleMenuA = try XCTUnwrap(playerViewA.menu(for: rightClickA))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: staleMenuA)
        try dispatchPointerMove(in: hostA, window: windowA, locationInWindow: NSPoint(x: 300, y: 250))
        controlsA.resetForNewItem()
        trafficA.resetForNewItem()
        await waitUntil(in: windowA, description: "resetForNewItem hides corner cluster") {
            !closeBtnA.isChromeVisible
        }

        try dispatchPointerMove(in: hostA, window: windowA, locationInWindow: closeCenterA)
        await waitUntil(in: windowA, description: "Window A corner reveal for freshMenuA") {
            closeBtnA.isChromeVisible
        }
        let freshMenuA = try XCTUnwrap(playerViewA.menu(for: rightClickA))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: freshMenuA)
        try assertReverseSyntheticHoverInterleavingMechanismAndRecovery(
            hostA: hostA,
            windowA: windowA,
            playerViewA: playerViewA,
            controlsA: controlsA
        )
        try dispatchPointerMove(in: hostA, window: windowA, locationInWindow: NSPoint(x: 300, y: 250))
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: staleMenuA)
        await clock.advance(by: .milliseconds(320))
        flushWindowLayout(windowA)
        XCTAssertTrue(closeBtnA.isChromeVisible, "Late didEndTrackingNotification from staleMenuA must NOT clear freshMenuA")

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: freshMenuA)
        await clock.advance(by: .milliseconds(260))
        await waitUntil(in: windowA, description: "Window A hides after freshMenuA end + 260ms") {
            !closeBtnA.isChromeVisible
        }
        XCTAssertTrue(controlsA.isVisible)
        await clock.advance(by: .milliseconds(2_420))
        await waitUntil(in: windowA, description: "Window A bottom bar hides at 3s") {
            !controlsA.isVisible
        }
        controlsA.isPlaying = true
        controlsA.isPlaying = false
        XCTAssertFalse(controlsA.isVisible)
        XCTAssertFalse(closeBtnA.isChromeVisible)
    }
}
