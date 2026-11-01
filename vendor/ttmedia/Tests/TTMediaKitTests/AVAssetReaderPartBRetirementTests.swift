// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import CoreMedia
import Darwin
import XCTest
@testable import TTMediaKit

@MainActor
final class AVAssetReaderPartBRetirementTests: XCTestCase {

    // MARK: - 1. Video Hung / Audio Active Cross-Queue Quiescence Barrier

    func testPartBVideoHungAudioActiveCrossQueueBarrierAndSingleRetirement() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_b_video_hung_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await Self.createSyntheticH264AndPCMFile(at: tempURL, frameCount: 15)

        let controller = AVAssetReaderPlaybackController(url: tempURL)
        controller.registersWithCoordinator = false
        let harness = R4PartBProbeHarness(parkedKind: .video)
        defer {
            harness.releaseGateIfNeeded()
            controller.stop()
        }

        controller.lifecycleProbe = harness.makeProbe()
        try await controller.load(autoPlay: false)
        let enteredVideoCopy = await harness.waitForParkedCopyEntry(boundedBy: 3.0)
        XCTAssertTrue(enteredVideoCopy)
        let session0 = try XCTUnwrap(harness.targetSessionID)
        XCTAssertEqual(controller.activeSessionID, session0)
        XCTAssertTrue(controller.isReading)
        XCTAssertTrue(controller.isSessionActive)

        // Call stop() twice to verify Boundary 1: retirement starts at most once per session
        controller.stop()
        controller.stop()
        harness.recordCallerReturned(for: session0)
        XCTAssertFalse(controller.isReading)
        XCTAssertFalse(controller.isSessionActive)

        // Wait for audio queue to quiesce while video read gate is still held
        let audioQuiesced = await harness.waitForQueueQuiesced(.audio, boundedBy: 2.0)
        XCTAssertTrue(audioQuiesced)

        let frozen = harness.snapshot()
        XCTAssertTrue(frozen.callerReturnedWhileGateHeld)
        XCTAssertEqual(frozen.events.filter { $0 == "didRequestCancel" }.count, 1)
        XCTAssertTrue(frozen.events.contains("didFlush:audio"))
        XCTAssertTrue(frozen.events.contains("didQuiesce:audio"))
        XCTAssertFalse(frozen.events.contains("willCancelReading"), "reader.cancelReading() must not run while video copy is still in flight")
        XCTAssertFalse(frozen.events.contains("didCompleteRetirement"))

        harness.releaseGateIfNeeded()
        let retired = await harness.waitForRetirementCompletion(of: session0, boundedBy: 3.0)
        XCTAssertTrue(retired)

        let finalSnap = harness.snapshot()
        XCTAssertFalse(finalSnap.events.contains("didEnqueue:video"))
        let quiesceVideoIdx = try XCTUnwrap(finalSnap.events.firstIndex(of: "didQuiesce:video"))
        let quiesceAudioIdx = try XCTUnwrap(finalSnap.events.firstIndex(of: "didQuiesce:audio"))
        let willCancelIdx = try XCTUnwrap(finalSnap.events.firstIndex(of: "willCancelReading"))
        let didCancelIdx = try XCTUnwrap(finalSnap.events.firstIndex(of: "didCancelReading"))
        let didRetireIdx = try XCTUnwrap(finalSnap.events.firstIndex(of: "didCompleteRetirement"))
        XCTAssertLessThan(quiesceAudioIdx, willCancelIdx)
        XCTAssertLessThan(quiesceVideoIdx, willCancelIdx)
        XCTAssertLessThan(willCancelIdx, didCancelIdx)
        XCTAssertLessThan(didCancelIdx, didRetireIdx)
        XCTAssertNil(controller.activeSessionID)
    }

    // MARK: - 2. Audio Hung / Video Exited Cross-Queue Quiescence Barrier

    func testPartBAudioHungVideoExitedCrossQueueBarrierPreventsEarlyCancelReading() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_b_audio_hung_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await Self.createSyntheticH264AndPCMFile(at: tempURL, frameCount: 15)

        let controller = AVAssetReaderPlaybackController(url: tempURL)
        controller.registersWithCoordinator = false
        let harness = R4PartBProbeHarness(parkedKind: .audio)
        defer {
            harness.releaseGateIfNeeded()
            controller.stop()
        }

        controller.lifecycleProbe = harness.makeProbe()
        try await controller.load(autoPlay: false)
        let enteredAudioCopy = await harness.waitForParkedCopyEntry(boundedBy: 3.0)
        XCTAssertTrue(enteredAudioCopy)
        let session0 = try XCTUnwrap(harness.targetSessionID)

        controller.stop()
        harness.recordCallerReturned(for: session0)

        // Video queue is not parked, so it must flush and quiesce while audio gate is still held
        let videoQuiesced = await harness.waitForQueueQuiesced(.video, boundedBy: 2.0)
        XCTAssertTrue(videoQuiesced)

        let frozen = harness.snapshot()
        XCTAssertTrue(frozen.callerReturnedWhileGateHeld)
        XCTAssertTrue(frozen.events.contains("didFlush:video"))
        XCTAssertTrue(frozen.events.contains("didQuiesce:video"))
        XCTAssertFalse(frozen.events.contains("willCancelReading"), "videoFeedQueue exiting must not call cancelReading() while audioFeedQueue is still in copyNextSampleBuffer()")

        harness.releaseGateIfNeeded()
        let retired = await harness.waitForRetirementCompletion(of: session0, boundedBy: 3.0)
        XCTAssertTrue(retired)

        let finalSnap = harness.snapshot()
        XCTAssertTrue(finalSnap.events.contains("didCopy:audio:true"), "Because cancelReading() waited for audio copy exit, the in-flight audio copy returned a valid buffer before being discarded by Fix A")
        XCTAssertFalse(finalSnap.events.contains("didEnqueue:audio"))
        let didCopyAudioIdx = try XCTUnwrap(finalSnap.events.firstIndex(of: "didCopy:audio:true"))
        let quiesceAudioIdx = try XCTUnwrap(finalSnap.events.firstIndex(of: "didQuiesce:audio"))
        let willCancelIdx = try XCTUnwrap(finalSnap.events.firstIndex(of: "willCancelReading"))
        XCTAssertLessThan(didCopyAudioIdx, quiesceAudioIdx)
        XCTAssertLessThan(quiesceAudioIdx, willCancelIdx)
    }

    // MARK: - 3. Single-Queue Video-Only Container Retirement

    func testPartBVideoOnlySingleQueueRetiresAndCancelsWithoutAudioTrack() async throws {
        let videoOnlyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_b_video_only_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: videoOnlyURL) }
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: videoOnlyURL, frameCount: 15)

        let controller = AVAssetReaderPlaybackController(url: videoOnlyURL)
        controller.registersWithCoordinator = false
        let harness = R4PartBProbeHarness(parkedKind: .video)
        defer {
            harness.releaseGateIfNeeded()
            controller.stop()
        }

        controller.lifecycleProbe = harness.makeProbe()
        try await controller.load(autoPlay: false)
        XCTAssertFalse(controller.hasAudio)
        let enteredVideoCopy = await harness.waitForParkedCopyEntry(boundedBy: 3.0)
        XCTAssertTrue(enteredVideoCopy)
        let session0 = try XCTUnwrap(harness.targetSessionID)

        controller.stop()
        harness.recordCallerReturned(for: session0)
        XCTAssertTrue(harness.snapshot().callerReturnedWhileGateHeld)

        harness.releaseGateIfNeeded()
        let retired = await harness.waitForRetirementCompletion(of: session0, boundedBy: 3.0)
        XCTAssertTrue(retired)

        let finalSnap = harness.snapshot()
        XCTAssertEqual(
            finalSnap.events,
            [
                "willCopy:video",
                "didRequestCancel",
                "callerReturned",
                "didCopy:video:true",
                "didFlush:video",
                "didQuiesce:video",
                "willCancelReading",
                "didCancelReading",
                "didCompleteRetirement"
            ]
        )
    }

    // MARK: - 4. Rapid Seek A -> B -> C Coalescing & Reader Creation Bound

    func testPartBRapidSeekABCWhileReadParkedCoalescesToSingleReaderAfterFullQuiescence() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_b_seek_coalesce_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await Self.createSyntheticH264AndPCMFile(at: tempURL, frameCount: 30)

        let controller = AVAssetReaderPlaybackController(url: tempURL)
        controller.registersWithCoordinator = false
        let harness = R4PartBProbeHarness(parkedKind: .video)
        var timeUpdates: [Double] = []
        var completedSeeks: [(Double, UInt64)] = []
        controller.onTimeUpdate = { timeUpdates.append(CMTimeGetSeconds($0)) }
        controller.onSeekCompleted = { completedSeeks.append((CMTimeGetSeconds($0), $1)) }
        defer {
            harness.releaseGateIfNeeded()
            controller.stop()
        }

        controller.lifecycleProbe = harness.makeProbe()
        try await controller.load(autoPlay: true)
        let enteredVideoCopy = await harness.waitForParkedCopyEntry(boundedBy: 3.0)
        XCTAssertTrue(enteredVideoCopy)
        let session0 = try XCTUnwrap(harness.targetSessionID)
        XCTAssertEqual(controller.createdSessionCount, 1)

        // Rapid consecutive seeks A (0.1s), B (0.2s), C (0.3s) while session0 video read is parked
        controller.seek(to: CMTime(seconds: 0.1, preferredTimescale: 600))
        let genA = controller.seekGeneration
        controller.seek(to: CMTime(seconds: 0.2, preferredTimescale: 600))
        let genB = controller.seekGeneration
        controller.seek(to: CMTime(seconds: 0.3, preferredTimescale: 600))
        let genC = controller.seekGeneration
        harness.recordCallerReturned(for: session0)

        XCTAssertLessThan(genA, genB)
        XCTAssertLessThan(genB, genC)
        XCTAssertEqual(controller.createdSessionCount, 1, "No new AVAssetReader may be created while session0 is still retiring")
        XCTAssertTrue(completedSeeks.isEmpty, "seek() returning on MainActor must not prematurely report onSeekCompleted before new reader starts")
        XCTAssertGreaterThanOrEqual(timeUpdates.count, 3)

        // Release parked read in session0 and wait for session0 retirement + coalesced sessionC start
        harness.releaseGateIfNeeded()
        let retired = await harness.waitForRetirementCompletion(of: session0, boundedBy: 3.0)
        XCTAssertTrue(retired)
        let newVideoEnqueued = await harness.waitForLaterSessionVideoEnqueue(boundedBy: 3.0)
        XCTAssertTrue(newVideoEnqueued)

        XCTAssertEqual(controller.createdSessionCount, 2, "Seeks A, B, C must coalesce into exactly 1 new AVAssetReader (total 2 including initial load)")
        XCTAssertEqual(completedSeeks.count, 1, "Only the coalesced latest seek C may fire onSeekCompleted")
        XCTAssertEqual(completedSeeks.first?.0 ?? -1, 0.3, accuracy: 0.02)
        XCTAssertEqual(completedSeeks.first?.1, genC)

        let snap = harness.snapshot()
        XCTAssertFalse(snap.events.contains("didEnqueue:video"), "Session0 must not enqueue after cancel")
        let flushVideoIdx = try XCTUnwrap(snap.globalTimeline.firstIndex(of: "didFlush:\(session0.uuidString):video"))
        let cancelIdx = try XCTUnwrap(snap.globalTimeline.firstIndex(of: "didCancelReading:\(session0.uuidString)"))
        let newSessionID = try XCTUnwrap(snap.createdSessionIDs.last)
        XCTAssertNotEqual(newSessionID, session0)
        let armNewVideoIdx = try XCTUnwrap(snap.globalTimeline.firstIndex(of: "didArm:\(newSessionID.uuidString):video"))
        XCTAssertLessThan(flushVideoIdx, cancelIdx)
        XCTAssertLessThan(cancelIdx, armNewVideoIdx, "New session feeder must only be armed after old session flush and cancelReading complete")
    }

    // MARK: - 5. Stop Clears Pending Seek & Immediate Re-Load Respects Quiescence Admission

    func testPartBStopClearsPendingSeekAndImmediateReloadWaitsForOldSessionRetirement() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_b_stop_reload_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await Self.createSyntheticH264AndPCMFile(at: tempURL, frameCount: 20)

        let controller = AVAssetReaderPlaybackController(url: tempURL)
        controller.registersWithCoordinator = false
        let harness = R4PartBProbeHarness(parkedKind: .video)
        var completedSeeks: [UInt64] = []
        controller.onSeekCompleted = { _, gen in completedSeeks.append(gen) }
        defer {
            harness.releaseGateIfNeeded()
            controller.stop()
        }

        controller.lifecycleProbe = harness.makeProbe()
        try await controller.load(autoPlay: false)
        let enteredFirstCopy = await harness.waitForParkedCopyEntry(boundedBy: 3.0)
        XCTAssertTrue(enteredFirstCopy)
        let session0 = try XCTUnwrap(harness.targetSessionID)

        // 5a: seek(to: 0.2) then immediate stop() while session0 is parked -> pending seek must be cleared
        controller.seek(to: CMTime(seconds: 0.2, preferredTimescale: 600))
        XCTAssertNotNil(controller.pendingStartRequest)
        controller.stop()
        XCTAssertNil(controller.pendingStartRequest)

        harness.releaseGateIfNeeded()
        let retired0 = await harness.waitForRetirementCompletion(of: session0, boundedBy: 3.0)
        XCTAssertTrue(retired0)
        XCTAssertEqual(controller.createdSessionCount, 1, "Cleared pending seek must not create a new session after stop()")
        XCTAssertNil(controller.activeSessionID)
        XCTAssertTrue(completedSeeks.isEmpty)

        // 5b: Start a fresh session1, park its video read, then call stop() + immediate load(autoPlay: true)
        // before session1 finishes retiring -> load() must defer reader creation until session1 retires.
        harness.resetAndParkNext(kind: .video)
        controller.play()
        let enteredSecondCopy = await harness.waitForParkedCopyEntry(boundedBy: 3.0)
        XCTAssertTrue(enteredSecondCopy)
        let session1 = try XCTUnwrap(harness.targetSessionID)
        XCTAssertNotEqual(session1, session0)
        XCTAssertEqual(controller.createdSessionCount, 2)

        controller.stop()
        try await controller.load(autoPlay: true)
        // Because session1's video read gate is still held, load() must have registered pendingStartRequest
        // rather than creating session2 concurrently with session1!
        XCTAssertEqual(controller.createdSessionCount, 2, "load() completing while old session1 is still retiring must not create a second concurrent AVAssetReader")
        XCTAssertNotNil(controller.pendingStartRequest)

        harness.releaseGateIfNeeded()
        let retired1 = await harness.waitForRetirementCompletion(of: session1, boundedBy: 3.0)
        XCTAssertTrue(retired1)
        let enqueuedAfterReload = await harness.waitForLaterSessionVideoEnqueue(boundedBy: 3.0)
        XCTAssertTrue(enqueuedAfterReload)
        XCTAssertEqual(controller.createdSessionCount, 3)
        XCTAssertNotNil(controller.activeSessionID)
        XCTAssertNotEqual(controller.activeSessionID, session1)
    }

    // MARK: - 6. Controller Deinit / Weak Reference Release After L3 Retirement

    func testPartBControllerDeinitRetiresSessionAndReleasesWeakSessionReferenceAfterL3() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_b_deinit_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await Self.createSyntheticH264AndPCMFile(at: tempURL, frameCount: 15)

        let harness = R4PartBProbeHarness(parkedKind: .video)
        defer { harness.releaseGateIfNeeded() }

        var controller: AVAssetReaderPlaybackController? = AVAssetReaderPlaybackController(url: tempURL)
        controller?.registersWithCoordinator = false
        controller?.lifecycleProbe = harness.makeProbe()
        try await controller?.load(autoPlay: false)

        let enteredCopy = await harness.waitForParkedCopyEntry(boundedBy: 3.0)
        XCTAssertTrue(enteredCopy)
        let session0 = try XCTUnwrap(harness.targetSessionID)
        weak let weakReader: AVAssetReader? = controller?.activeSessionReaderForTesting

        // Drop strong reference to controller while video read is parked
        controller = nil
        XCTAssertNotNil(weakReader, "While in-flight copyNextSampleBuffer is parked, queue closure retains SessionState.reader so it is never deallocated mid-call")

        harness.releaseGateIfNeeded()
        let retired = await harness.waitForRetirementCompletion(of: session0, boundedBy: 3.0)
        XCTAssertTrue(retired)
        // Give the queue block stack frame a brief moment to unwind after didCompleteRetirement
        for _ in 0..<20 where weakReader != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(weakReader, "After L3 retirement completes and queue block unwinds, TTZip holds zero strong references to AVAssetReader")
    }

    // MARK: - 7. Late Retirement Callback Owner Validation & EOF/Error Gating

    func testPartBLateRetirementCallbackDoesNotClearNewActiveSessionAndCancelledEOFIsSuppressed() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_b_late_owner_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await Self.createSyntheticH264AndPCMFile(at: tempURL, frameCount: 10)

        let controller = AVAssetReaderPlaybackController(url: tempURL)
        controller.registersWithCoordinator = false
        var endedCount = 0
        var errorCount = 0
        controller.onPlaybackEnded = { endedCount += 1 }
        controller.onError = { _ in errorCount += 1 }
        defer { controller.stop() }

        try await controller.load(autoPlay: true)
        let activeID = try XCTUnwrap(controller.activeSessionID)
        XCTAssertTrue(controller.isReading)

        // Simulate a late retirement callback from an older session ID arriving after `activeID` is already active
        let staleSessionID = UUID()
        controller.completeSessionRetirement(sessionID: staleSessionID, probe: nil)
        XCTAssertEqual(controller.activeSessionID, activeID, "Stale retirement callback must not clear a newer activeSession")
        XCTAssertTrue(controller.isReading)

        // Stop before presentation reaches duration; neither onPlaybackEnded nor onError may fire
        controller.stop()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(endedCount, 0)
        XCTAssertEqual(errorCount, 0)
    }

    // MARK: - 8. Stop -> Play During Retirement Restarts Exactly One Session Without Rebuilding on Normal Pause -> Play

    func testPartBStopThenPlayBeforeRetirementCompletesRestartsExactlyOneSessionAndPausePlayReusesActiveSession() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_b_stop_play_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await Self.createSyntheticH264AndPCMFile(at: tempURL, frameCount: 15)

        let harness = R4PartBProbeHarness(parkedKind: .video, autoReleaseAfterCancelMs: nil)
        let controller = AVAssetReaderPlaybackController(url: tempURL)
        controller.registersWithCoordinator = false
        controller.lifecycleProbe = harness.makeProbe()
        var seekCompletedCalls: [(Double, UInt64)] = []
        controller.onSeekCompleted = { time, gen in
            seekCompletedCalls.append((CMTimeGetSeconds(time), gen))
        }
        defer {
            harness.releaseGateIfNeeded()
            controller.stop()
        }

        try await controller.load(autoPlay: true)
        let session0 = try XCTUnwrap(controller.activeSessionID)
        let parked = await harness.waitForParkedCopyEntry(boundedBy: 2.0)
        XCTAssertTrue(parked, "Session 0 must park in willCopy:video")

        // Positive control on pause/play intent & stop -> play while S0 is still retiring (before L3):
        controller.stop()
        harness.recordCallerReturned(for: session0)
        XCTAssertFalse(controller.userPlaybackIntent)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(controller.isReading)

        // Call play() BEFORE S0 reaches L3; also call play() a second time to verify idempotency,
        // then pause() -> play() to verify intent toggling while pending still reuses the single pendingStartRequest
        controller.play()
        controller.play()
        XCTAssertTrue(controller.userPlaybackIntent, "play() after stop() must set userPlaybackIntent = true")
        let pendingAfterPlay = try XCTUnwrap(controller.pendingStartRequest, "play() while old session is retiring must record a single pendingStartRequest")
        controller.pause()
        XCTAssertFalse(controller.userPlaybackIntent, "pause() after stop->play must flip userPlaybackIntent = false")
        XCTAssertEqual(controller.pendingStartRequest, pendingAfterPlay, "pause() while pending preserves pendingStartRequest target")
        controller.play()
        XCTAssertTrue(controller.userPlaybackIntent, "subsequent play() restores userPlaybackIntent = true on the same pendingStartRequest")
        XCTAssertTrue(controller.isPlaying, "isPlaying reflects active playback intent while pendingStartRequest is waiting for handoff")
        XCTAssertEqual(controller.pendingStartRequest, pendingAfterPlay, "subsequent play() reuses existing pendingStartRequest without replacing or duplicating")
        XCTAssertEqual(controller.synchronizer.rate, 0.0, accuracy: 0.001, "Master clock must remain frozen (synchronizer.rate == 0) until S0 finishes L3 and S1 starts")
        XCTAssertEqual(controller.createdSessionCount, 1, "No second AVAssetReader may be created before S0 finishes L3")
        XCTAssertEqual(controller.seekGeneration, 0, "play() restart after stop() must not fabricate a public seekGeneration increment")

        // Release S0's parked video read and wait for S0 L3 retirement + S1 video enqueue
        harness.releaseGateIfNeeded()
        let retired0 = await harness.waitForRetirementCompletion(of: session0, boundedBy: 2.0)
        XCTAssertTrue(retired0, "Session 0 must complete L3 retirement")
        let s1Enqueued = await harness.waitForLaterSessionVideoEnqueue(boundedBy: 2.0)
        XCTAssertTrue(s1Enqueued, "New session S1 must start after S0 L3 and enqueue video frames")

        XCTAssertEqual(controller.createdSessionCount, 2, "Exactly one new AVAssetReader (S1) must be created after stop -> play")
        let session1 = try XCTUnwrap(controller.activeSessionID)
        XCTAssertNotEqual(session1, session0)
        XCTAssertTrue(controller.isReading)
        XCTAssertTrue(controller.userPlaybackIntent)
        XCTAssertTrue(controller.isPlaying, "After S1 starts, playback rate must be restored to playing")
        XCTAssertTrue(seekCompletedCalls.isEmpty, "Internal restart from play() must not fire spurious onSeekCompleted")

        // Positive control: pause() -> play() on healthy active session S1 must reuse S1 without creating S2
        controller.pause()
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.activeSessionID, session1)
        controller.play()
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.activeSessionID, session1, "pause() -> play() on healthy session must reuse the same SessionState")
        XCTAssertEqual(controller.createdSessionCount, 2, "pause() -> play() must not create a new AVAssetReader")
    }

    // MARK: - 9. Near-EOF Seek While Read Parked Freezes Clock Until New Pipeline Starts (No Premature EOF)

    func testPartBNearEndSeekWhileReadParkedFreezesClockWithoutSpuriousEOFAndAppliesLatestIntentOnStart() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_b_near_eof_clock_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await Self.createSyntheticH264AndPCMFile(at: tempURL, frameCount: 15)

        let harness = R4PartBProbeHarness(parkedKind: .video, autoReleaseAfterCancelMs: nil)
        let controller = AVAssetReaderPlaybackController(url: tempURL)
        controller.registersWithCoordinator = false
        controller.lifecycleProbe = harness.makeProbe()
        var endedCount = 0
        var timeUpdates: [Double] = []
        var seekCompletedGens: [UInt64] = []
        controller.onPlaybackEnded = { endedCount += 1 }
        controller.onTimeUpdate = { t in timeUpdates.append(CMTimeGetSeconds(t)) }
        controller.onSeekCompleted = { _, gen in seekCompletedGens.append(gen) }
        defer {
            harness.releaseGateIfNeeded()
            controller.stop()
        }

        try await controller.load(autoPlay: true)
        let session0 = try XCTUnwrap(controller.activeSessionID)
        let parked = await harness.waitForParkedCopyEntry(boundedBy: 2.0)
        XCTAssertTrue(parked)

        let durSec = CMTimeGetSeconds(controller.duration)
        let nearEndTarget = CMTime(seconds: max(0.05, durSec - 0.06), preferredTimescale: 600)

        // Seek near EOF while S0 is parked in willCopy:video
        controller.seek(to: nearEndTarget)
        XCTAssertTrue(controller.userPlaybackIntent, "User playback intent remains true across seek while playing")
        XCTAssertTrue(controller.isPlaying, "Public isPlaying remains true across seek while playing (matching V2SeekAndPresentationTests)")
        XCTAssertEqual(controller.synchronizer.rate, 0.0, accuracy: 0.001, "Actual synchronizer rate must be 0.0 while waiting for S0 retirement handoff")
        let anchoredSec = CMTimeGetSeconds(controller.currentTime)
        XCTAssertEqual(anchoredSec, max(0.0, durSec - 0.06), accuracy: 0.02, "Playhead target is immediately anchored for UI display")
        XCTAssertEqual(seekCompletedGens, [], "onSeekCompleted must not fire before new pipeline actually starts")

        // Update playbackRate while pending to verify latest rate is honored when S1 starts
        controller.playbackRate = 1.5

        // Wait 150ms (well over the 60ms remaining to duration if the clock had been running at 1.0x/1.5x)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(endedCount, 0, "Synchronizer clock must not advance to duration or fire spurious onPlaybackEnded before S1 starts")
        XCTAssertFalse(controller.isEndOfStream, "isEndOfStream must remain false while S1 has not even been created")
        XCTAssertEqual(CMTimeGetSeconds(controller.currentTime), anchoredSec, accuracy: 0.005, "Clock time must stay frozen at target while pending")

        // Now release S0 gate and verify S1 starts with the latest playbackRate (1.5x) and fires onSeekCompleted
        harness.releaseGateIfNeeded()
        let retired0 = await harness.waitForRetirementCompletion(of: session0, boundedBy: 2.0)
        XCTAssertTrue(retired0)
        let s1Enqueued = await harness.waitForLaterSessionVideoEnqueue(boundedBy: 2.0)
        XCTAssertTrue(s1Enqueued)
        XCTAssertEqual(seekCompletedGens, [1], "onSeekCompleted must fire once S1 actually starts")
        XCTAssertEqual(controller.synchronizer.rate, 1.5, accuracy: 0.01, "S1 must start with the latest playbackRate updated during pending handoff")
    }

    internal static func createSyntheticH264AndPCMFile(at url: URL, frameCount: Int) async throws {
        let videoOnlyURL = url.deletingLastPathComponent().appendingPathComponent("v_\(UUID().uuidString).mp4")
        let audioOnlyURL = url.deletingLastPathComponent().appendingPathComponent("a_\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: videoOnlyURL)
            try? FileManager.default.removeItem(at: audioOnlyURL)
        }
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: videoOnlyURL, frameCount: frameCount)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let pcmBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        pcmBuffer.frameLength = 4_410
        let audioFile = try AVAudioFile(forWriting: audioOnlyURL, settings: format.settings)
        for _ in 0..<5 { try audioFile.write(from: pcmBuffer) }

        let composition = AVMutableComposition()
        let vAsset = AVURLAsset(url: videoOnlyURL)
        let aAsset = AVURLAsset(url: audioOnlyURL)
        let vTracks = try await vAsset.loadTracks(withMediaType: .video)
        let aTracks = try await aAsset.loadTracks(withMediaType: .audio)
        let vTrack = try XCTUnwrap(vTracks.first)
        let aTrack = try XCTUnwrap(aTracks.first)
        let vDur = try await vAsset.load(.duration)
        let compV = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let compA = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try compV.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vTrack, at: .zero)
        try compA.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: aTrack, at: .zero)
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: url, as: .mov)
    }
}

// MARK: - Deterministic Non-Main-Thread Watchdog & Probe Harness for Part B

internal struct R4PartBProbeSnapshot: Sendable {
    let callerReturnedWhileGateHeld: Bool
    let events: [String]
    let globalTimeline: [String]
    let createdSessionIDs: [UUID]
}

internal final class R4PartBProbeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let watchdogQueue = DispatchQueue(label: "com.metastudyline.ttmedia.tests.r4.partb.watchdog")
    private var parkedKind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind?
    private var autoReleaseAfterCancelMs: Int?
    private var readGate = DispatchSemaphore(value: 0)
    private var parkedCopyEntered = DispatchSemaphore(value: 0)
    private var videoQuiesced = DispatchSemaphore(value: 0)
    private var audioQuiesced = DispatchSemaphore(value: 0)
    private var retirementCompleted = DispatchSemaphore(value: 0)
    private var laterSessionEnqueued = DispatchSemaphore(value: 0)

    private var capturedSessionID: UUID?
    private var hasParkedFirstRead = false
    private var hasReleasedGate = false
    private var callerReturned = false
    private var callerReturnedWhileGateHeld = false
    private var events: [String] = []
    private var globalTimeline: [String] = []
    private var createdSessionIDs: [UUID] = []

    init(
        parkedKind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind?,
        autoReleaseAfterCancelMs: Int? = 150
    ) {
        self.parkedKind = parkedKind
        self.autoReleaseAfterCancelMs = autoReleaseAfterCancelMs
    }

    var targetSessionID: UUID? { lock.withLock { capturedSessionID } }

    func resetAndParkNext(kind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind) {
        lock.withLock {
            parkedKind = kind
            readGate = DispatchSemaphore(value: 0)
            parkedCopyEntered = DispatchSemaphore(value: 0)
            videoQuiesced = DispatchSemaphore(value: 0)
            audioQuiesced = DispatchSemaphore(value: 0)
            retirementCompleted = DispatchSemaphore(value: 0)
            laterSessionEnqueued = DispatchSemaphore(value: 0)
            capturedSessionID = nil
            hasParkedFirstRead = false
            hasReleasedGate = false
            callerReturned = false
            callerReturnedWhileGateHeld = false
            events.removeAll()
        }
    }

    func releaseGateIfNeeded() {
        let gateToSignal: DispatchSemaphore? = lock.withLock {
            guard !hasReleasedGate else { return nil }
            hasReleasedGate = true
            return readGate
        }
        gateToSignal?.signal()
    }

    func recordCallerReturned(for sessionID: UUID) {
        lock.withLock {
            guard capturedSessionID == sessionID else { return }
            callerReturned = true
            if !hasReleasedGate {
                callerReturnedWhileGateHeld = true
            }
            events.append("callerReturned")
            globalTimeline.append("callerReturned:\(sessionID.uuidString)")
        }
    }

    func snapshot() -> R4PartBProbeSnapshot {
        lock.withLock {
            R4PartBProbeSnapshot(
                callerReturnedWhileGateHeld: callerReturnedWhileGateHeld,
                events: events,
                globalTimeline: globalTimeline,
                createdSessionIDs: createdSessionIDs
            )
        }
    }

    func waitForParkedCopyEntry(boundedBy seconds: TimeInterval) async -> Bool {
        let sem = lock.withLock { parkedCopyEntered }
        return await Self.waitOnSemaphore(sem, boundedBy: seconds)
    }

    func waitForQueueQuiesced(
        _ kind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind,
        boundedBy seconds: TimeInterval
    ) async -> Bool {
        let sem = lock.withLock { kind == .video ? videoQuiesced : audioQuiesced }
        return await Self.waitOnSemaphore(sem, boundedBy: seconds)
    }

    func waitForRetirementCompletion(of sessionID: UUID, boundedBy seconds: TimeInterval) async -> Bool {
        let sem = lock.withLock { retirementCompleted }
        return await Self.waitOnSemaphore(sem, boundedBy: seconds)
    }

    func waitForLaterSessionVideoEnqueue(boundedBy seconds: TimeInterval) async -> Bool {
        let sem = lock.withLock { laterSessionEnqueued }
        return await Self.waitOnSemaphore(sem, boundedBy: seconds)
    }

    private static func waitOnSemaphore(_ semaphore: DispatchSemaphore, boundedBy seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = semaphore.wait(timeout: .now() + seconds) == .success
                if ok { semaphore.signal() }
                continuation.resume(returning: ok)
            }
        }
    }

    func makeProbe() -> AVAssetReaderPlaybackController.NativeReaderLifecycleProbe {
        AVAssetReaderPlaybackController.NativeReaderLifecycleProbe(
            didCreateSession: { [weak self] id in
                self?.lock.withLock {
                    self?.createdSessionIDs.append(id)
                    self?.globalTimeline.append("didCreate:\(id.uuidString)")
                }
            },
            willCopyNextSampleBuffer: { [weak self] id, kind in
                self?.handleWillCopy(sessionID: id, kind: kind)
            },
            didCopyNextSampleBuffer: { [weak self] id, kind, hasBuffer in
                self?.recordTargetEvent(sessionID: id, kind: kind, "didCopy:\(kind.rawValue):\(hasBuffer)")
            },
            didEnqueueSampleBuffer: { [weak self] id, kind, _ in
                self?.handleDidEnqueue(sessionID: id, kind: kind)
            },
            didRequestCancel: { [weak self] id in
                self?.handleDidRequestCancel(sessionID: id)
            },
            didQuiesceQueue: { [weak self] id, kind in
                self?.handleDidQuiesce(sessionID: id, kind: kind)
            },
            didFlushRenderer: { [weak self] id, kind in
                self?.recordSessionEvent(sessionID: id, "didFlush:\(kind.rawValue)", globalTag: "didFlush:\(id.uuidString):\(kind.rawValue)")
            },
            willCancelReading: { [weak self] id in
                self?.recordSessionEvent(sessionID: id, "willCancelReading", globalTag: "willCancelReading:\(id.uuidString)")
            },
            didCancelReading: { [weak self] id in
                self?.recordSessionEvent(sessionID: id, "didCancelReading", globalTag: "didCancelReading:\(id.uuidString)")
            },
            didArmFeederQueue: { [weak self] id, kind in
                self?.lock.withLock {
                    self?.globalTimeline.append("didArm:\(id.uuidString):\(kind.rawValue)")
                }
            },
            didCompleteRetirement: { [weak self] id in
                self?.handleDidCompleteRetirement(sessionID: id)
            }
        )
    }

    private func handleWillCopy(
        sessionID: UUID,
        kind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind
    ) {
        let (shouldPark, entrySem, gateSem): (Bool, DispatchSemaphore, DispatchSemaphore) = lock.withLock {
            guard let parkedKind, kind == parkedKind, !hasParkedFirstRead else {
                return (false, parkedCopyEntered, readGate)
            }
            hasParkedFirstRead = true
            capturedSessionID = sessionID
            events.append("willCopy:\(kind.rawValue)")
            globalTimeline.append("willCopy:\(sessionID.uuidString):\(kind.rawValue)")
            return (true, parkedCopyEntered, readGate)
        }
        guard shouldPark else { return }
        entrySem.signal()
        _ = gateSem.wait(timeout: .now() + 5.0)
    }

    private func handleDidEnqueue(
        sessionID: UUID,
        kind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind
    ) {
        let signalLater: DispatchSemaphore? = lock.withLock {
            globalTimeline.append("didEnqueue:\(sessionID.uuidString):\(kind.rawValue)")
            if capturedSessionID == sessionID, kind == parkedKind {
                events.append("didEnqueue:\(kind.rawValue)")
                return nil
            } else if capturedSessionID != nil, capturedSessionID != sessionID, kind == .video {
                return laterSessionEnqueued
            }
            return nil
        }
        signalLater?.signal()
    }

    private func handleDidRequestCancel(sessionID: UUID) {
        let delayMs: Int? = lock.withLock {
            globalTimeline.append("didRequestCancel:\(sessionID.uuidString)")
            guard capturedSessionID == sessionID else { return nil }
            events.append("didRequestCancel")
            return autoReleaseAfterCancelMs
        }
        guard let delayMs else { return }
        watchdogQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            self?.releaseGateIfNeeded()
        }
    }

    private func handleDidQuiesce(
        sessionID: UUID,
        kind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind
    ) {
        let sem: DispatchSemaphore? = lock.withLock {
            globalTimeline.append("didQuiesce:\(sessionID.uuidString):\(kind.rawValue)")
            guard capturedSessionID == sessionID else { return nil }
            events.append("didQuiesce:\(kind.rawValue)")
            return kind == .video ? videoQuiesced : audioQuiesced
        }
        sem?.signal()
    }

    private func handleDidCompleteRetirement(sessionID: UUID) {
        let sem: DispatchSemaphore? = lock.withLock {
            globalTimeline.append("didCompleteRetirement:\(sessionID.uuidString)")
            guard capturedSessionID == sessionID else { return nil }
            events.append("didCompleteRetirement")
            return retirementCompleted
        }
        sem?.signal()
    }

    private func recordTargetEvent(
        sessionID: UUID,
        kind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind,
        _ event: String
    ) {
        lock.withLock {
            guard capturedSessionID == sessionID, kind == parkedKind else { return }
            events.append(event)
            globalTimeline.append("\(event):\(sessionID.uuidString)")
        }
    }

    private func recordSessionEvent(sessionID: UUID, _ event: String, globalTag: String? = nil) {
        lock.withLock {
            if let globalTag {
                globalTimeline.append(globalTag)
            } else {
                globalTimeline.append("\(event):\(sessionID.uuidString)")
            }
            guard capturedSessionID == sessionID else { return }
            events.append(event)
        }
    }
}
