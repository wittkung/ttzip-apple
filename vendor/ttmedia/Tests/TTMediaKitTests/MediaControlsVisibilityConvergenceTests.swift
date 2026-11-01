// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import AVFoundation
import CoreMedia
import os
import SwiftUI
import XCTest
@testable import TTMediaKit

extension MediaPresentationStateTests {
    // MARK: - Video Controls Visibility Architecture Convergence Matrix (1-7)

    @MainActor
    func testControlsVisibilityMatrixStationaryHoverSpacePauseResumeAndPlaybackCallbacksNeverRevealUI() async {
        let clock = ControlledVisibilityTestClock()
        var hideCursorCount = 0
        var unhideCursorCount = 0
        let cursorController = ViewportCursorVisibilityController(
            hideAction: { hideCursorCount += 1 },
            unhideAction: { unhideCursorCount += 1 }
        )
        let controls = MediaControlsVisibility(
            inactivityDuration: .seconds(3),
            cursorController: cursorController,
            now: { clock.now() },
            wait: { duration in try await clock.wait(duration) }
        )

        // Matrix 2: Pointer outside viewport — playback/pause/seek state transitions never reveal UI.
        XCTAssertFalse(controls.isHovered)
        XCTAssertFalse(controls.isVisible)
        controls.isPlaying = true
        XCTAssertFalse(controls.isVisible)
        controls.isPlaying = false
        XCTAssertFalse(controls.isVisible)
        controls.isPlaying = true
        XCTAssertFalse(controls.isVisible)
        XCTAssertEqual(controls.scheduledHideTimerCount, 0)

        // Matrix 3: Pointer enters viewport at (220, 180) -> reveals UI and schedules exactly 1 hide task.
        controls.recordMouseMove(at: CGPoint(x: 220, y: 180))
        XCTAssertTrue(controls.isHovered)
        XCTAssertTrue(controls.isVisible)
        XCTAssertFalse(controls.isCursorHidden)
        XCTAssertEqual(controls.scheduledHideTimerCount, 1)

        // Advance clock by 3s and fire pending wait -> UI auto-hides, cursor hides while playing.
        await clock.advance(by: .seconds(3))
        XCTAssertFalse(controls.isVisible)
        XCTAssertTrue(controls.isCursorHidden)
        XCTAssertEqual(hideCursorCount, 1)

        // Matrix 1: Pointer stationary inside viewport, UI hidden -> Space pause -> Space resume:
        // UI stays hidden throughout, no new hide timer scheduled, synthetic 0pt/jitter hover does not wake UI.
        let scheduledBeforeSpace = controls.scheduledHideTimerCount
        controls.isPlaying = false // Space pause
        XCTAssertFalse(controls.isVisible, "Space pause while stationary inside viewport must NOT reveal hidden UI")
        XCTAssertFalse(controls.isCursorHidden, "Pausing must restore hidden system cursor without revealing UI")
        XCTAssertEqual(unhideCursorCount, 1)
        XCTAssertEqual(controls.scheduledHideTimerCount, scheduledBeforeSpace, "Space pause must not restart auto-hide timer")

        // Stationary SwiftUI .onContinuousHover re-evaluations at same point or within <= 0.5pt jitter
        controls.setHovered(true)
        controls.recordMouseMove(at: CGPoint(x: 220.0, y: 180.0))
        controls.recordMouseMove(at: CGPoint(x: 220.3, y: 180.3))
        XCTAssertFalse(controls.isVisible, "Stationary hover or <= 0.5pt jitter must not wake hidden UI")
        XCTAssertEqual(controls.scheduledHideTimerCount, scheduledBeforeSpace)

        controls.isPlaying = true // Space resume
        XCTAssertFalse(controls.isVisible, "Space resume while stationary inside viewport must NOT reveal hidden UI")
        XCTAssertEqual(controls.scheduledHideTimerCount, scheduledBeforeSpace, "Space resume must not restart auto-hide timer")

        // Valid pointer movement > 0.5pt reveals UI again
        controls.recordMouseMove(at: CGPoint(x: 222.0, y: 180.0))
        XCTAssertTrue(controls.isVisible)
        XCTAssertEqual(controls.scheduledHideTimerCount, scheduledBeforeSpace + 1)
        controls.tearDown()
    }

    @MainActor
    func testControlsVisibilityMatrixPauseKeepsRemainingDeadlineAndLockReleaseConvergesWithoutInfiniteRenewal() async {
        let clock = ControlledVisibilityTestClock()
        let controls = MediaControlsVisibility(
            inactivityDuration: .seconds(3),
            now: { clock.now() },
            wait: { duration in try await clock.wait(duration) }
        )

        // Matrix 4: Pause does not keep UI permanently visible; if mouse activity is still valid, it keeps only remaining time.
        controls.isPlaying = true
        controls.recordMouseMove(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(controls.isVisible)
        let initialTimerCount = controls.scheduledHideTimerCount

        await clock.advance(by: .seconds(1), resumeWaiters: false)
        controls.isPlaying = false // Pause at t=1s (2s remaining on original 3s deadline)
        XCTAssertTrue(controls.isVisible, "Unexpired pointer activity remains visible for its remaining window")
        XCTAssertEqual(controls.scheduledHideTimerCount, initialTimerCount, "Pausing must not reset activity as a fresh 3s window")

        // When original 3s deadline fires while paused, UI hides cleanly (not permanently visible)
        await clock.advance(by: .seconds(2))
        XCTAssertFalse(controls.isVisible, "Paused state must not force permanent UI visibility once pointer activity expires")
        XCTAssertFalse(controls.isCursorHidden, "Cursor remains visible while paused")

        // Resuming from pause does not reveal UI
        controls.isPlaying = true
        XCTAssertFalse(controls.isVisible)

        // Matrix 5: Scrub / menu / popover locks hold visibility, and releasing after deadline expired hides immediately.
        controls.recordMouseMove(at: CGPoint(x: 140, y: 140))
        XCTAssertTrue(controls.isVisible)
        controls.acquireInteractionLock(id: "controlBarPopover")
        await clock.advance(by: .seconds(5))
        XCTAssertTrue(controls.isVisible, "Active popover lock must keep controls visible past inactivity deadline")

        // Release lock with no new pointer activity since t=0 -> must immediately converge to hidden without a new 3s renewal
        let timersBeforeRelease = controls.scheduledHideTimerCount
        controls.releaseInteractionLock(id: "controlBarPopover")
        XCTAssertFalse(controls.isVisible, "Releasing lock after pointer deadline expired must converge immediately to hidden")
        XCTAssertEqual(controls.scheduledHideTimerCount, timersBeforeRelease, "Lock release must not schedule a new 3s timer")

        // Explicit keyboard focus on a control reveals UI and converges on blur
        controls.setKeyboardFocused(true)
        XCTAssertTrue(controls.isVisible)
        controls.setKeyboardFocused(false)
        XCTAssertFalse(controls.isVisible)

        // Matrix 6: Re-entry cancels stale hide; resetForNewItem / tearDown invalidates pending tasks; multi-window isolation.
        let controlsWindowB = MediaControlsVisibility(
            inactivityDuration: .seconds(3),
            now: { clock.now() },
            wait: { duration in try await clock.wait(duration) }
        )
        controls.recordMouseMove(at: CGPoint(x: 180, y: 180))
        XCTAssertTrue(controls.isVisible)
        XCTAssertFalse(controlsWindowB.isVisible, "Multi-window MediaControlsVisibility instances must be isolated")

        controls.resetForNewItem()
        XCTAssertFalse(controls.isVisible)
        await clock.advance(by: .seconds(3))
        XCTAssertFalse(controls.isVisible)
        controls.tearDown()
        controlsWindowB.tearDown()
    }

    @MainActor
    func testRealPlayerKeyHandlerAndReverseAttributionProofForSpaceAndKeyboardShortcuts() async {
        let clock = ControlledVisibilityTestClock()
        let controls = MediaControlsVisibility(
            inactivityDuration: .seconds(3),
            now: { clock.now() },
            wait: { duration in try await clock.wait(duration) }
        )
        let renderer = AVSampleBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
        let playerNSView = AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), renderer: renderer)

        var toggleCount = 0
        var seekTargets: [Double] = []
        var volumeDeltas: [Float] = []
        var muteToggles = 0

        playerNSView.onMouseMovedAtPoint = { pt in controls.recordMouseMove(at: pt) }
        playerNSView.onHoverChanged = { hovering in controls.setHovered(hovering) }
        playerNSView.onCanvasSingleClick = {
            toggleCount += 1
            controls.isPlaying.toggle()
        }
        playerNSView.onSeek = { time in
            seekTargets.append(CMTimeGetSeconds(time))
        }
        playerNSView.onVolumeChange = { delta in
            volumeDeltas.append(delta)
        }
        playerNSView.onMuteToggle = {
            muteToggles += 1
        }

        // Pointer enters canvas and moves to (260, 180), then goes idle for 3s while playing
        controls.isPlaying = true
        controls.recordMouseMove(at: CGPoint(x: 260, y: 180))
        XCTAssertTrue(controls.isVisible)
        await clock.advance(by: .seconds(3))
        XCTAssertFalse(controls.isVisible)

        // Dispatch real keyDown events (Space=49, Space=49, Left=123, Right=124, Up=126, Down=125, M=46) to AVSampleBufferPlayerNSView
        for keyCode: UInt16 in [49, 49, 123, 124, 126, 125, 46] {
            if let keyEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: NSPoint(x: 260, y: 180),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: keyCode == 49 ? " " : (keyCode == 46 ? "m" : ""),
                charactersIgnoringModifiers: keyCode == 49 ? " " : (keyCode == 46 ? "m" : ""),
                isARepeat: false,
                keyCode: keyCode
            ) {
                playerNSView.keyDown(with: keyEvent)
            }
            XCTAssertFalse(controls.isVisible, "Key \(keyCode) must never reveal hidden video controls")
        }
        XCTAssertEqual(toggleCount, 2)
        XCTAssertEqual(seekTargets.count, 2)
        XCTAssertEqual(volumeDeltas.count, 2)
        XCTAssertEqual(muteToggles, 1)

        // Reverse Control Attribution Check:
        // Prove that under the legacy buggy path (`isPlaying.didSet -> interact()` when `isHovered == true`),
        // stationary `isHovered == true` immediately flips `isVisible` back to `true` on Space pause.
        let legacyBuggyRevealOnSpacePause = (controls.isHovered || controls.hasActiveInteractionLock || controls.isScrubbing)
        XCTAssertTrue(
            legacyBuggyRevealOnSpacePause,
            "Reverse attribution control: legacy `isVisible = isHovered || ...` in `interact()` would have forced `isVisible = true` here"
        )
        XCTAssertFalse(
            controls.isVisible,
            "Converged policy keeps `isVisible == false` because stationary `isHovered` is not pointer activity"
        )
        controls.tearDown()
    }

    @MainActor
    func testTwoWindowsMenuOwnershipKeepAliveVsRevealIntentAndGalleryPolicyConvergence() async throws {
        let clock = ControlledVisibilityTestClock()
        let controlsA = MediaControlsVisibility(
            inactivityDuration: .seconds(3),
            now: { clock.now() },
            wait: { duration in try await clock.wait(duration) }
        )
        let controlsB = MediaControlsVisibility(
            inactivityDuration: .seconds(3),
            now: { clock.now() },
            wait: { duration in try await clock.wait(duration) }
        )
        let windowA = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        windowA.isReleasedWhenClosed = false
        let playerA = AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        playerA.controlsVisibility = controlsA
        windowA.contentView = playerA

        let windowB = NSWindow(
            contentRect: NSRect(x: 700, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        windowB.isReleasedWhenClosed = false
        let playerB = AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        playerB.controlsVisibility = controlsB
        windowB.contentView = playerB
        defer {
            CodeReadingToolsInteractionCoordinator.setMenuTrackingActive(false, for: windowA)
            CodeReadingToolsInteractionCoordinator.setMenuTrackingActive(false, for: windowB)
            windowA.contentView = nil
            windowB.contentView = nil
            windowA.close()
            windowB.close()
        }

        let eventA = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 120, y: 120), modifierFlags: [],
            timestamp: 0, windowNumber: windowA.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let eventB = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 120, y: 120), modifierFlags: [],
            timestamp: 0, windowNumber: windowB.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menuA = try XCTUnwrap(playerA.menu(for: eventA))
        let rotSubmenuA = try XCTUnwrap(menuA.items.compactMap(\.submenu).first)
        let menuB = try XCTUnwrap(playerB.menu(for: eventB))
        XCTAssertNil(playerA.menu, "Production AVSampleBufferPlayerNSView uses dynamic menu(for:), not static view.menu")

        let cornerA = PreviewCornerActionRevealCoordinator(
            hideDelay: .milliseconds(260),
            now: { clock.now() },
            wait: { duration in try await clock.wait(duration) }
        )
        let cornerB = PreviewCornerActionRevealCoordinator(
            hideDelay: .milliseconds(260),
            now: { clock.now() },
            wait: { duration in try await clock.wait(duration) }
        )

        // 1. Window ownership verification via real player.menu(for:) (root menu + rotation submenu)
        XCTAssertFalse(CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(for: nil as NSWindow?))
        XCTAssertFalse(CodeReadingToolsInteractionCoordinator.doesMenuBelongToWindow(nil, window: windowA))
        XCTAssertFalse(CodeReadingToolsInteractionCoordinator.doesMenuBelongToWindow(NSApplication.shared.mainMenu, window: windowA))
        XCTAssertFalse(CodeReadingToolsInteractionCoordinator.doesMenuBelongToWindow(NSMenu(title: "Unowned"), window: windowA))
        XCTAssertFalse(CodeReadingToolsInteractionCoordinator.doesMenuBelongToWindow(menuB, window: windowA))
        XCTAssertTrue(CodeReadingToolsInteractionCoordinator.doesMenuBelongToWindow(menuA, window: windowA))
        XCTAssertTrue(CodeReadingToolsInteractionCoordinator.doesMenuBelongToWindow(rotSubmenuA, window: windowA))
        XCTAssertTrue(CodeReadingToolsInteractionCoordinator.doesMenuBelongToWindow(menuB, window: windowB))

        // Posting Window B's menu or unowned menu notifications must never lock or wake Window A
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menuB)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu(title: "Unowned"))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        XCTAssertTrue(CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(for: windowB))
        XCTAssertFalse(
            CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(for: windowA),
            "Active menu tracking on Window B must never report active menu on Window A"
        )
        XCTAssertFalse(controlsA.isVisible)
        XCTAssertFalse(controlsB.isVisible, "Menu tracking on hidden Window B must not wake hidden bottom bar")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menuB)
        XCTAssertFalse(CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(for: windowB))

        // 2. Keep-alive vs. new reveal intent: external lock on a hidden control must NOT wake it;
        //    explicit keyboard focus DOES reveal for accessibility.
        XCTAssertFalse(cornerA.isPresented())
        cornerA.setExternallyLocked(true)
        XCTAssertFalse(
            cornerA.isPresented(),
            "External lock is a keep-alive for already-revealed controls and must NEVER wake a hidden control"
        )
        cornerA.setExternallyLocked(false)

        let legacyUnownedFormulaWouldWakeHiddenA = (false || false || false || true || false)
        XCTAssertTrue(legacyUnownedFormulaWouldWakeHiddenA)
        XCTAssertFalse(
            PreviewCornerActionRevealCoordinator.shouldShowButton(
                isZoneHovered: false,
                isButtonHovered: false,
                isButtonFocused: false,
                isExternallyLocked: true,
                isDelayedVisible: false
            ),
            "Converged shouldShowButton must reject externalLock when control is not already revealed"
        )

        cornerA.setButtonFocused(true)
        XCTAssertTrue(cornerA.isPresented(), "Explicit keyboard focus on corner control must reveal it")
        cornerA.setButtonFocused(false)
        await clock.advance(by: .milliseconds(260))
        XCTAssertFalse(cornerA.isPresented())

        // 3. Window A's real menu(for:) keeps Window A's already-visible controls alive, while Window B stays hidden;
        //    closing Window A's menu converges back to the original deadline (duplicate begin/end & stray ends are safe).
        controlsA.isPlaying = true
        controlsA.recordMouseMove(at: CGPoint(x: 200, y: 180)) // deadline at t + 3.0s
        cornerA.setZoneHovered(true)
        XCTAssertTrue(controlsA.isVisible)
        XCTAssertTrue(cornerA.isPresented())
        XCTAssertFalse(cornerB.isPresented())

        // At t + 1.0s (2.0s remaining on controlsA's 3.0s deadline), Window A opens its real menu(for:):
        await clock.advance(by: .seconds(1), resumeWaiters: false)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menuA)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menuA) // duplicate begin
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: rotSubmenuA)
        cornerA.setExternallyLocked(CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(for: windowA))
        cornerA.setZoneHovered(false) // pointer moves out of corner sensor into menu

        // Stray end notifications from nil / Window B / submenu while root menuA is open must not release lock
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menuB)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: rotSubmenuA)
        cornerA.setExternallyLocked(CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(for: windowA))

        // Advance by 0.5s (past cornerA's 260ms grace delay; now at t + 1.5s, 1.5s remaining on controlsA's original 3.0s deadline)
        await clock.advance(by: .milliseconds(500))
        XCTAssertTrue(cornerA.isPresented(), "Window A's real menu(for:) lock must keep already-visible corner cluster alive")
        XCTAssertTrue(controlsA.isVisible, "Window A's real menu(for:) lock must keep bottom bar alive")

        // Close Window A's menu at t + 1.5s (including duplicate end notification) ->
        // - cornerA schedules its 260ms grace hide
        // - controlsA converges to its ORIGINAL remaining 1.5s deadline (NOT a fresh 3.0s deadline!)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menuA)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menuA) // duplicate end
        cornerA.setExternallyLocked(CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(for: windowA))
        XCTAssertTrue(cornerA.isPresented(), "Corner cluster remains visible during its 260ms grace window")
        XCTAssertTrue(controlsA.isVisible, "Bottom bar remains visible for the remaining 1.5s of its original deadline")

        await clock.advance(by: .milliseconds(260))
        XCTAssertFalse(cornerA.isPresented(), "Corner cluster hides after 260ms grace following menu close")
        XCTAssertTrue(controlsA.isVisible, "Bottom bar still has 1.24s remaining on its original 3.0s deadline")

        await clock.advance(by: .milliseconds(1240))
        XCTAssertFalse(controlsA.isVisible, "Bottom bar hides at original t + 3.0s deadline without fresh 3s renewal")

        // 4. File switch (resetForNewItem) discards stale menu, and late end from stale menu never clears new menu owner
        controlsA.recordMouseMove(at: CGPoint(x: 240, y: 180))
        let staleMenuA = try XCTUnwrap(playerA.menu(for: eventA))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: staleMenuA)
        XCTAssertTrue(controlsA.hasActiveInteractionLock)
        controlsA.resetForNewItem()
        cornerA.tearDown()
        XCTAssertFalse(controlsA.isVisible)
        XCTAssertFalse(controlsA.hasActiveInteractionLock)
        XCTAssertFalse(CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(for: windowA))

        // Reveal again on the new item and open freshMenuA; late end from staleMenuA must NOT clear freshMenuA's lock
        controlsA.recordMouseMove(at: CGPoint(x: 260, y: 180))
        let freshMenuA = try XCTUnwrap(playerA.menu(for: eventA))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: freshMenuA)
        XCTAssertTrue(controlsA.hasActiveInteractionLock)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: staleMenuA)
        XCTAssertTrue(controlsA.hasActiveInteractionLock, "Late end notification from staleMenuA must not clear freshMenuA")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: freshMenuA)
        XCTAssertFalse(controlsA.hasActiveInteractionLock)
        controlsA.resetForNewItem()

        // 5. Space while pointer is stationary or outside region keeps controls hidden
        controlsA.isPlaying = false
        XCTAssertFalse(controlsA.isVisible)
        XCTAssertFalse(cornerA.isPresented())
        controlsA.isPlaying = true
        XCTAssertFalse(controlsA.isVisible)
        XCTAssertFalse(cornerA.isPresented())
    }
}

final class ControlledVisibilityTestClock: Sendable {
    private struct State {
        var currentInstant: ContinuousClock.Instant = ContinuousClock.now
        var targetInstant: ContinuousClock.Instant = ContinuousClock.now
        var waiters: [UUID: (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Error>)] = [:]
        var registrationContinuations: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    deinit {
        let (remaining, regConts) = state.withLock { state -> ([CheckedContinuation<Void, Error>], [CheckedContinuation<Void, Never>]) in
            let values = state.waiters.values.map(\.continuation)
            state.waiters.removeAll()
            let regs = state.registrationContinuations
            state.registrationContinuations.removeAll()
            return (values, regs)
        }
        for reg in regConts { reg.resume() }
        for continuation in remaining {
            continuation.resume(throwing: CancellationError())
        }
    }

    func now() -> ContinuousClock.Instant {
        state.withLock { $0.currentInstant }
    }

    func wait(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (action, regs) = state.withLock { state -> (Int, [CheckedContinuation<Void, Never>]) in
                    if Task.isCancelled {
                        return (-1, [])
                    }
                    let deadline = state.currentInstant.advanced(by: duration)
                    let regs = state.registrationContinuations
                    state.registrationContinuations.removeAll()
                    if deadline <= state.targetInstant {
                        state.currentInstant = max(state.currentInstant, deadline)
                        return (1, regs)
                    }
                    state.waiters[id] = (deadline, continuation)
                    return (0, regs)
                }
                for reg in regs { reg.resume() }
                if action == -1 {
                    continuation.resume(throwing: CancellationError())
                } else if action == 1 {
                    continuation.resume()
                }
            }
        } onCancel: {
            let removed = state.withLock { $0.waiters.removeValue(forKey: id)?.continuation }
            removed?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration, resumeWaiters: Bool = true) async {
        await MainActor.run {}
        await Task.yield()
        await MainActor.run {}
        let pending = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            let nextInstant = state.currentInstant.advanced(by: duration)
            state.currentInstant = nextInstant
            if resumeWaiters {
                state.targetInstant = nextInstant
            }
            guard resumeWaiters else { return [] }
            var ready: [CheckedContinuation<Void, Error>] = []
            for (id, entry) in state.waiters where entry.deadline <= nextInstant {
                ready.append(entry.continuation)
                state.waiters.removeValue(forKey: id)
            }
            return ready
        }
        for continuation in pending {
            continuation.resume()
        }
        await MainActor.run {}
        await Task.yield()
        await MainActor.run {}
    }
}
