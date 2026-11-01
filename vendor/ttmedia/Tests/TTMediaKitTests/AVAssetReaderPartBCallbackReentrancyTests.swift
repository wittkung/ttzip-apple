// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import TTMediaKit

// MARK: - 10 & 11. Synchronous Callback Reentrancy & Request Submission Identity Tests

extension AVAssetReaderPartBRetirementTests {

    func testPartBOnTimeUpdateSynchronousRedirectSeekPreservesLatestTargetAndGeneration() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_b_reentrant_seek_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await Self.createSyntheticH264AndPCMFile(at: tempURL, frameCount: 25)

        let harness = R4PartBProbeHarness(parkedKind: .video, autoReleaseAfterCancelMs: nil)
        let controller = AVAssetReaderPlaybackController(url: tempURL)
        controller.registersWithCoordinator = false
        controller.lifecycleProbe = harness.makeProbe()
        var completedSeeks: [(Double, UInt64)] = []
        controller.onSeekCompleted = { time, gen in
            completedSeeks.append((CMTimeGetSeconds(time), gen))
        }
        defer {
            harness.releaseGateIfNeeded()
            controller.stop()
        }

        try await controller.load(autoPlay: true)
        let session0 = try XCTUnwrap(controller.activeSessionID)
        let parked = await harness.waitForParkedCopyEntry(boundedBy: 2.0)
        XCTAssertTrue(parked, "Session 0 must park in willCopy:video")

        let target1 = CMTime(seconds: 0.12, preferredTimescale: 600)
        let target2 = CMTime(seconds: 0.28, preferredTimescale: 600)
        var didRedirectTarget1 = false
        controller.onTimeUpdate = { [weak controller] time in
            guard let controller, !didRedirectTarget1 else { return }
            if abs(CMTimeGetSeconds(time) - CMTimeGetSeconds(target1)) < 0.01 {
                didRedirectTarget1 = true
                controller.seek(to: target2)
            }
        }

        // Initiate outer seek(target1); its synchronous onTimeUpdate redirects once to seek(target2)
        controller.seek(to: target1)
        harness.recordCallerReturned(for: session0)
        XCTAssertTrue(didRedirectTarget1, "onTimeUpdate for target1 must have synchronously triggered seek(target2)")

        // Verify outer seek(target1) did NOT overwrite pendingStartRequest back to G1/target1
        let pending = try XCTUnwrap(controller.pendingStartRequest, "pendingStartRequest must remain set for target2")
        XCTAssertEqual(controller.seekGeneration, 2, "Two seeks (target1 -> target2) must produce seekGeneration == 2")
        XCTAssertEqual(pending.seekGeneration, 2, "pendingStartRequest must belong to inner G2, not overwritten by outer G1")
        XCTAssertEqual(pending.transitionGeneration, controller.transitionGeneration)
        XCTAssertEqual(CMTimeGetSeconds(pending.startTime), CMTimeGetSeconds(target2), accuracy: 0.01)
        XCTAssertEqual(CMTimeGetSeconds(controller.currentTime), CMTimeGetSeconds(target2), accuracy: 0.01)
        XCTAssertEqual(controller.createdSessionCount, 1, "No intermediate AVAssetReader may be created before S0 finishes L3")
        XCTAssertTrue(completedSeeks.isEmpty, "onSeekCompleted must not fire before S1 actually starts")

        // Release S0's parked video read and wait for S0 L3 retirement + S1 video enqueue
        harness.releaseGateIfNeeded()
        let retired0 = await harness.waitForRetirementCompletion(of: session0, boundedBy: 2.0)
        XCTAssertTrue(retired0, "Session 0 must complete L3 retirement")
        let s1Enqueued = await harness.waitForLaterSessionVideoEnqueue(boundedBy: 2.0)
        XCTAssertTrue(s1Enqueued, "New session S1 for target2 must start after S0 L3 and enqueue video frames")

        XCTAssertEqual(controller.createdSessionCount, 2, "Exactly one new AVAssetReader (for target2) must be created")
        XCTAssertEqual(completedSeeks.count, 1, "onSeekCompleted must fire exactly once for target2")
        XCTAssertEqual(completedSeeks.first?.0 ?? -1.0, CMTimeGetSeconds(target2), accuracy: 0.02)
        XCTAssertEqual(completedSeeks.first?.1, 2)
    }

    func testPartBOnTimeUpdateSynchronousStopDoesNotResurrectCancelledSeekRequest() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_b_reentrant_stop_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await Self.createSyntheticH264AndPCMFile(at: tempURL, frameCount: 20)

        let harness = R4PartBProbeHarness(parkedKind: .video, autoReleaseAfterCancelMs: nil)
        let controller = AVAssetReaderPlaybackController(url: tempURL)
        controller.registersWithCoordinator = false
        controller.lifecycleProbe = harness.makeProbe()
        var completedSeeks: [(Double, UInt64)] = []
        controller.onSeekCompleted = { time, gen in
            completedSeeks.append((CMTimeGetSeconds(time), gen))
        }
        defer {
            harness.releaseGateIfNeeded()
            controller.stop()
        }

        try await controller.load(autoPlay: true)
        let session0 = try XCTUnwrap(controller.activeSessionID)
        let parked = await harness.waitForParkedCopyEntry(boundedBy: 2.0)
        XCTAssertTrue(parked, "Session 0 must park in willCopy:video")

        let target1 = CMTime(seconds: 0.15, preferredTimescale: 600)
        var didStopInCallback = false
        controller.onTimeUpdate = { [weak controller] time in
            guard let controller, !didStopInCallback else { return }
            if abs(CMTimeGetSeconds(time) - CMTimeGetSeconds(target1)) < 0.01 {
                didStopInCallback = true
                controller.stop()
            }
        }

        // Initiate outer seek(target1); its synchronous onTimeUpdate calls stop()
        controller.seek(to: target1)
        harness.recordCallerReturned(for: session0)
        XCTAssertTrue(didStopInCallback, "onTimeUpdate for target1 must have synchronously called stop()")

        // Outer seek(target1) must NOT re-insert its cancelled request into pendingStartRequest after stop() returned
        XCTAssertNil(controller.pendingStartRequest, "Outer seek must not re-populate pendingStartRequest after synchronous stop() inside onTimeUpdate")
        XCTAssertFalse(controller.userPlaybackIntent)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.createdSessionCount, 1)

        // Release S0's parked video read and verify S0 retires cleanly with zero new readers started.
        // didCompleteRetirement fires on @MainActor at the end of completeSessionRetirement after
        // pendingStartRequest evaluation/submission, and outer seek(to: target1) has already returned.
        harness.releaseGateIfNeeded()
        let retired0 = await harness.waitForRetirementCompletion(of: session0, boundedBy: 2.0)
        XCTAssertTrue(retired0, "Session 0 must complete L3 retirement")
        XCTAssertEqual(controller.createdSessionCount, 1, "No new AVAssetReader may be started after stop() in onTimeUpdate")
        XCTAssertNil(controller.activeSessionID)
        XCTAssertTrue(completedSeeks.isEmpty, "Cancelled seek must never fire onSeekCompleted")
    }
}
