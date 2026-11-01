// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import XCTest
@testable import TTMediaKit

@MainActor
final class DelayedButtonHelpTests: XCTestCase {
    func testColdUnhoveredButtonsDoNotMountAppKitHelpAnchors() {
        let host = NSHostingView(rootView: HStack {
            ForEach(0..<20) { index in
                Button("Action \(index)") {}.ttButtonHelp("Help \(index)")
            }
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 80)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(containsHelpTrackingView(host), "Cold buttons must not register AppKit help views or their observers")
        XCTAssertFalse(window.isVisible, "This test must not display or activate a window")
    }

    private func containsHelpTrackingView(_ view: NSView) -> Bool {
        if String(describing: type(of: view)).contains("TTButtonHelpTrackingView") { return true }
        return view.subviews.contains { containsHelpTrackingView($0) }
    }

    func testHoverWaitsForInjectedDeadlineAndUsesOneSecondDefault() async throws {
        let clock = ButtonHelpTestClock()
        let delay = TTButtonHelpDelay(wait: { await clock.wait($0) })
        var presentations = 0
        delay.begin { presentations += 1 }
        let task = try XCTUnwrap(delay.pendingTask)
        await clock.waitUntilRequested(1)
        XCTAssertEqual(presentations, 0)
        let durations = await clock.durations
        XCTAssertEqual(durations, [.seconds(1)])
        await clock.releaseNext()
        await task.value
        XCTAssertEqual(presentations, 1)
    }

    func testExitCancelsPendingHelpEvenWhenClockCompletesLate() async throws {
        let clock = ButtonHelpTestClock()
        let delay = TTButtonHelpDelay(wait: { await clock.wait($0) })
        var presentations = 0
        delay.begin { presentations += 1 }
        let task = try XCTUnwrap(delay.pendingTask)
        await clock.waitUntilRequested(1)
        delay.cancel()
        await clock.releaseNext()
        await task.value
        XCTAssertEqual(presentations, 0)
        XCTAssertNil(delay.pendingTask)
    }

    func testNewHoverRejectsPreviousGenerationAndPresentsOnlyLatest() async throws {
        let clock = ButtonHelpTestClock()
        let delay = TTButtonHelpDelay(delay: .milliseconds(250), wait: { await clock.wait($0) })
        var labels: [String] = []
        delay.begin { labels.append("previous") }
        let previous = try XCTUnwrap(delay.pendingTask)
        await clock.waitUntilRequested(1)
        delay.begin { labels.append("latest") }
        let latest = try XCTUnwrap(delay.pendingTask)
        await clock.waitUntilRequested(2)
        await clock.releaseNext()
        await previous.value
        XCTAssertTrue(labels.isEmpty)
        await clock.releaseNext()
        await latest.value
        XCTAssertEqual(labels, ["latest"])
        let durations = await clock.durations
        XCTAssertEqual(durations, [.milliseconds(250), .milliseconds(250)])
    }

    func testDisabledControlCancelsPendingAndRejectsFurtherHoverRequests() async throws {
        let clock = ButtonHelpTestClock()
        let delay = TTButtonHelpDelay(wait: { await clock.wait($0) })
        var presentations = 0
        var hidden = 0
        delay.onDisabled = { hidden += 1 }
        delay.begin { presentations += 1 }
        let task = try XCTUnwrap(delay.pendingTask)
        await clock.waitUntilRequested(1)
        delay.setEnabled(false)
        XCTAssertFalse(delay.isEnabled)
        XCTAssertNil(delay.pendingTask)
        XCTAssertEqual(hidden, 1)
        delay.begin { presentations += 1 }
        XCTAssertNil(delay.pendingTask)
        await clock.releaseNext()
        await task.value
        XCTAssertEqual(presentations, 0)
        let durations = await clock.durations
        XCTAssertEqual(durations, [.seconds(1)], "Disabled tracking must not schedule another wait")
    }

    func testDisablingVisibleHelpHidesAndReenableRequiresFreshDeadline() async throws {
        let clock = ButtonHelpTestClock()
        let delay = TTButtonHelpDelay(wait: { await clock.wait($0) })
        var isPresented = false
        delay.onDisabled = { isPresented = false }
        delay.begin { isPresented = true }
        let initial = try XCTUnwrap(delay.pendingTask)
        await clock.waitUntilRequested(1)
        await clock.releaseNext()
        await initial.value
        XCTAssertTrue(isPresented)
        delay.setEnabled(false)
        XCTAssertFalse(isPresented, "Opacity-hidden controls must actively request hiding already shown help")
        delay.setEnabled(true)
        XCTAssertFalse(isPresented)
        delay.begin { isPresented = true }
        let next = try XCTUnwrap(delay.pendingTask)
        await clock.waitUntilRequested(2)
        XCTAssertFalse(isPresented)
        await clock.releaseNext()
        await next.value
        XCTAssertTrue(isPresented)
    }

    func testWaitingFailureDoesNotPresentHelp() async throws {
        enum ClockFailure: Error { case unavailable }
        let delay = TTButtonHelpDelay(wait: { _ in throw ClockFailure.unavailable })
        var presentations = 0
        delay.begin { presentations += 1 }
        let task = try XCTUnwrap(delay.pendingTask)
        await task.value
        XCTAssertEqual(presentations, 0)
    }
}

private actor ButtonHelpTestClock {
    private(set) var durations: [Duration] = []
    private var deadlines: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func wait(_ duration: Duration) async {
        durations.append(duration)
        await withCheckedContinuation { continuation in
            deadlines.append(continuation)
            var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
            for (count, waiter) in requestWaiters {
                if durations.count >= count { waiter.resume() } else { waiting.append((count, waiter)) }
            }
            requestWaiters = waiting
        }
    }

    func waitUntilRequested(_ count: Int) async {
        if durations.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func releaseNext() {
        guard !deadlines.isEmpty else { return }
        deadlines.removeFirst().resume()
    }
}
