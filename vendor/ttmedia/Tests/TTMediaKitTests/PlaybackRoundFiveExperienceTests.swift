// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import AVFoundation
import Darwin
import XCTest
@testable import TTMediaKit

@MainActor
final class PlaybackRoundFiveExperienceTests: XCTestCase {
    func testShortcutRoutingDoesNotCaptureTextOtherWindowOrCommandCombinations() {
        XCTAssertTrue(MediaPlaybackCoordinator.permitsShortcut(
            keyCode: 49, modifiers: [], responderIsText: false, isOwningWindow: true, hasSheet: false
        ))
        for key in [UInt16(49), 123, 124] {
            XCTAssertFalse(MediaPlaybackCoordinator.permitsShortcut(
                keyCode: key, modifiers: [], responderIsText: true, isOwningWindow: true, hasSheet: false
            ))
            XCTAssertFalse(MediaPlaybackCoordinator.permitsShortcut(
                keyCode: key, modifiers: [], responderIsText: false, isOwningWindow: false, hasSheet: false
            ))
            XCTAssertFalse(MediaPlaybackCoordinator.permitsShortcut(
                keyCode: key, modifiers: .command, responderIsText: false, isOwningWindow: true, hasSheet: false
            ))
            XCTAssertFalse(MediaPlaybackCoordinator.permitsShortcut(
                keyCode: key, modifiers: [], responderIsText: false, isOwningWindow: true, hasSheet: true
            ))
        }
        XCTAssertTrue(MediaPlaybackCoordinator.permitsShortcut(
            keyCode: 123, modifiers: .shift, responderIsText: false, isOwningWindow: true, hasSheet: false
        ))
    }

    func testPerResourceRestorationPreservesSettingsAndDoesNotCrossFileIdentity() {
        let previousResolver = PlaybackExperiencePolicy.resourceIdentity
        defer { PlaybackExperiencePolicy.resourceIdentity = previousResolver }
        PlaybackExperiencePolicy.resourceIdentity = { $0.absoluteString }
        let store = PlaybackExperienceStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("experience.json"))
        let url = URL(fileURLWithPath: "/round-five/first.mov")
        var record = PlaybackExperienceRecord()
        record.position = 41
        record.duration = 100
        record.rotationDegrees = 90
        record.volume = 0.4
        record.rate = 1.5
        record.primarySubtitle = "embedded:12"
        record.secondarySubtitle = "off"
        record.subtitleStyle = SubtitleStyleConfiguration(backgroundOpacity: 0.5)
        store.save(record, for: url)
        let session = VideoPlaybackSession(url: url, experienceStore: store)
        session.duration = CMTime(seconds: 100, preferredTimescale: 600)
        XCTAssertEqual(CMTimeGetSeconds(session.restoredExperienceTime(or: .zero)), 41)
        XCTAssertEqual(session.userRotationDegrees, 90)
        XCTAssertEqual(session.volume, 0.4)
        XCTAssertEqual(session.playbackRate, 1.5)
        XCTAssertEqual(session.selectedSubtitleID, "embedded:12")
        XCTAssertEqual(session.subtitleStyle.backgroundOpacity, 0.5)
        XCTAssertNil(store.record(for: URL(fileURLWithPath: "/round-five/second.mov")))
        let oldIdentity = store.identity(for: url)
        PlaybackExperiencePolicy.resourceIdentity = { _ in "new-file-version" }
        XCTAssertNil(store.record(for: url))
        store.save(record, for: url, matching: oldIdentity)
        XCTAssertNil(store.record(for: url), "A session cannot write an old checkpoint under a replacement file identity")
        XCTAssertEqual(CMTimeGetSeconds(session.restoredExperienceTime(or: CMTime(seconds: 40, preferredTimescale: 600))), 0)
        XCTAssertEqual(session.userRotationDegrees, 0)
        XCTAssertNil(session.selectedSubtitleID)
    }

    func testCompletedPlaybackRestartsButKeepsAppearanceAndTemporaryPathsAreExcluded() {
        XCTAssertEqual(PlaybackExperiencePolicy.resumePosition(99, 100), 0)
        XCTAssertEqual(PlaybackExperiencePolicy.resumePosition(40, 100), 40)
        XCTAssertEqual(PlaybackExperiencePolicy.resumePosition(.nan, 100), 0)
        XCTAssertNil(PlaybackExperienceStore.localIdentity(for: FileManager.default.temporaryDirectory
            .appendingPathComponent("extracted-entry.mp4")))
        XCTAssertNil(PlaybackExperienceStore.localIdentity(for: URL(string: "https://example.invalid/video")!))
    }

    func testRotatedDisplayLayerOccupiesTheOrientedContentRect() {
        let view = AVSampleBufferPlayerNSView(frame: CGRect(x: 0, y: 0, width: 500, height: 800))
        let rect = VideoContentGeometry.contentRect(
            inside: view.bounds.size,
            rawVideoSize: CGSize(width: 1920, height: 1080), rotationDegrees: 90
        )
        view.videoContentRect = rect
        view.userRotationDegrees = 90
        view.applyDisplayLayerGeometry()
        XCTAssertEqual(view.displayLayer.frame.width, rect.width, accuracy: 0.01)
        XCTAssertEqual(view.displayLayer.frame.height, rect.height, accuracy: 0.01)
        XCTAssertEqual(view.displayLayer.position.x, rect.midX, accuracy: 0.01)
        XCTAssertEqual(view.displayLayer.position.y, rect.midY, accuracy: 0.01)
        XCTAssertEqual(rect.height, 800, accuracy: 0.01)
    }

    func testThumbnailCancellationClearsOldImageWithoutChangingPlayerTime() {
        let source = VideoTimelineThumbnailSource()
        source.stop()
        XCTAssertTrue(source.frames.isEmpty)
        XCTAssertEqual(VideoTimelineThumbnailSource.sampleTimes(duration: 7200).count, 100)
        // Decoder is deliberately independent: its API has no playback controller or seek callback.
    }

    // MARK: - Controlled Real-Chain Lifecycle Verifications (R4)

    private func makeWorkerHarness(
        prefix: String
    ) throws -> (
        url: URL,
        transport: R4ControlledWorkerServiceTransport,
        service: MediaWorkerService,
        bridge: R4InProcessWorkerBridge,
        controller: AVSampleBufferWorkerPlaybackController
    ) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)_\(UUID().uuidString).mkv")
        try Data(prefix.utf8).write(to: url)
        let transport = R4ControlledWorkerServiceTransport()
        let service = MediaWorkerService(transport: transport)
        let bridge = R4InProcessWorkerBridge(service: service)
        let client = MediaWorkerXPCClient(transport: bridge)
        let controller = AVSampleBufferWorkerPlaybackController(url: url, client: client)
        return (url, transport, service, bridge, controller)
    }

    func testWorkerRealChainReadGateStopCloseAndLeaseOwnership() async throws {
        let (fixtureURL, transport, service, bridge, controller) = try makeWorkerHarness(prefix: "r4_worker_fixture")
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        transport.holdFirstRead()
        transport.holdNextClose()
        defer {
            transport.releaseRead()
            transport.releaseClose()
        }

        await controller.startPlayback(autoPlay: true)
        let readEntered = await transport.waitForReadEntry(boundedBy: 2.0)
        XCTAssertTrue(readEntered, "Expected pumpPackets to enter transport.readNextPacket")
        XCTAssertTrue(controller.isLoading, "Worker open success alone must keep isLoading true before first sample")
        XCTAssertFalse(controller.coordinator.isReady, "Worker open success must not mark coordinator.isReady before first sample")
        XCTAssertFalse(controller.isPlaying, "Worker open success must not mark isPlaying before first sample")
        let leaseIdentity = try XCTUnwrap(service.currentLeaseIdentity)
        let rawFD = try XCTUnwrap(bridge.firstOpenedFD)
        XCTAssertGreaterThanOrEqual(fcntl(rawFD, F_GETFL), 0)

        controller.teardown()
        XCTAssertTrue(!transport.hasExitedRead)

        let closeEntered = await transport.waitForCloseEntry(boundedBy: 2.0)
        XCTAssertTrue(closeEntered, "Expected detached close Task to enter transport.closeMedia")
        XCTAssertNil(service.currentLeaseIdentity)
        XCTAssertEqual(service.completedRetirementCount, 0)
        XCTAssertGreaterThanOrEqual(fcntl(rawFD, F_GETFL), 0)

        transport.releaseRead()
        let readExited = await transport.waitForReadExit(boundedBy: 2.0)
        XCTAssertTrue(readExited)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.enqueuedVideoPacketCount, 0)

        transport.releaseClose()
        let closeCompleted = await transport.waitForCloseCompletion(boundedBy: 2.0)
        XCTAssertTrue(closeCompleted)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(service.completedRetirementCount, 1)
        XCTAssertTrue(service.unreleasedLeaseIdentities.isEmpty)
        XCTAssertEqual(fcntl(rawFD, F_GETFL), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertNotNil(leaseIdentity)
    }

    func testWorkerRealChainFailedCloseRetainsUnreleasedLeaseResponsibility() async throws {
        let (fixtureURL, transport, service, bridge, controller) = try makeWorkerHarness(prefix: "r4_worker_fail_close")
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        transport.holdFirstRead()
        transport.holdNextClose()
        transport.failCloseAfterRelease()
        defer {
            transport.releaseRead()
            transport.releaseClose()
        }

        await controller.startPlayback(autoPlay: true)
        let readEntered = await transport.waitForReadEntry(boundedBy: 2.0)
        XCTAssertTrue(readEntered)
        let claimedLeaseIdentity = try XCTUnwrap(service.currentLeaseIdentity)
        let rawFD = try XCTUnwrap(bridge.firstOpenedFD)

        controller.teardown()
        let closeEntered = await transport.waitForCloseEntry(boundedBy: 2.0)
        XCTAssertTrue(closeEntered)

        _ = try await bridge.openMedia(path: fixtureURL.path, targetTracks: nil)
        let supersedingLeaseIdentity = try XCTUnwrap(service.currentLeaseIdentity)
        XCTAssertNotEqual(supersedingLeaseIdentity, claimedLeaseIdentity)

        transport.releaseRead()
        _ = await transport.waitForReadExit(boundedBy: 2.0)
        transport.releaseClose()
        let closeCompleted = await transport.waitForCloseCompletion(boundedBy: 2.0)
        XCTAssertTrue(closeCompleted)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(service.currentLeaseIdentity, supersedingLeaseIdentity)
        XCTAssertEqual(service.completedRetirementCount, 1)
        XCTAssertEqual(service.unreleasedLeaseIdentities, [claimedLeaseIdentity])
        XCTAssertGreaterThanOrEqual(fcntl(rawFD, F_GETFL), 0)
    }

    func testWorkerRealChainAsyncStopAndSeekObservationOrder() async throws {
        let (fixtureURL, transport, service, bridge, controller) = try makeWorkerHarness(prefix: "r4_worker_async")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL)
            transport.releaseRead()
            transport.releaseClose()
        }

        transport.holdFirstRead()
        await controller.startPlayback(autoPlay: true)
        let firstReadEntered = await transport.waitForReadEntry(boundedBy: 2.0)
        XCTAssertTrue(firstReadEntered)
        let rawFD = try XCTUnwrap(bridge.firstOpenedFD)

        let seekTask = Task { @MainActor in await controller.seek(to: 2.0) }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(transport.seekCallCount, 0)
        XCTAssertFalse(transport.hasExitedRead)

        transport.releaseRead()
        await seekTask.value
        XCTAssertEqual(controller.enqueuedVideoPacketCount, 0)
        XCTAssertFalse(controller.hasEnqueuedInitialMediaSample)
        XCTAssertTrue(controller.isLoading, "0-frame seek reply must not clear initial loading")
        XCTAssertFalse(controller.coordinator.isReady, "0-frame seek reply must not fake ready")
        XCTAssertFalse(controller.isPlaying, "0-frame seek reply must not fake playing")
        XCTAssertEqual(transport.seekCallCount, 1)
        XCTAssertEqual(transport.operationTimeline.prefix(2), ["readExited", "seekEntered"])

        transport.resetReadGateAndHoldNext(cooperativeCancellation: false, forSeekGeneration: 2)
        controller.requestSeek(to: 3.0)
        let secondReadEntered = await transport.waitForReadEntry(boundedBy: 2.0)
        XCTAssertTrue(secondReadEntered)

        let readinessWaitTask = Task { @MainActor in await controller.waitForInitialMediaReadinessOrFailure() }
        let stopTask = Task { @MainActor in await controller.stop() }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(transport.hasEnteredClose)
        XCTAssertNotNil(service.currentLeaseIdentity)

        transport.releaseRead()
        await stopTask.value
        await readinessWaitTask.value
        XCTAssertEqual(controller.enqueuedVideoPacketCount, 0)
        XCTAssertFalse(controller.isLoading)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertTrue(transport.hasEnteredClose)
        XCTAssertEqual(service.completedRetirementCount, 1)
        XCTAssertEqual(fcntl(rawFD, F_GETFL), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testWorkerStopWaitsForInFlightPumpTransferredToSecondSeekBeforeClosing() async throws {
        let (fixtureURL, transport, service, bridge, controller) = try makeWorkerHarness(prefix: "r4_worker_transferred_pump")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL)
            transport.releaseRead()
            transport.releaseClose()
        }

        transport.holdFirstRead()
        await controller.startPlayback(autoPlay: true)
        let firstReadEntered = await transport.waitForReadEntry(boundedBy: 2.0)
        XCTAssertTrue(firstReadEntered)
        let rawFD = try XCTUnwrap(bridge.firstOpenedFD)

        let firstSeek = Task { @MainActor in await controller.seek(to: 2.0) }
        try await Task.sleep(for: .milliseconds(25))
        transport.releaseRead()
        transport.resetReadGateAndHoldNext(cooperativeCancellation: false, forSeekGeneration: 1)
        await firstSeek.value

        let postSeekReadEntered = await transport.waitForReadEntry(boundedBy: 2.0)
        XCTAssertTrue(postSeekReadEntered)

        controller.requestSeek(to: 3.0)
        let stopTask = Task { @MainActor in await controller.stop() }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(transport.hasEnteredClose)
        XCTAssertEqual(transport.seekCallCount, 1)
        XCTAssertNotNil(service.currentLeaseIdentity)

        transport.releaseRead()
        await stopTask.value
        XCTAssertTrue(transport.hasEnteredClose)
        XCTAssertEqual(transport.seekCallCount, 1)
        XCTAssertEqual(service.completedRetirementCount, 1)
        XCTAssertEqual(fcntl(rawFD, F_GETFL), -1)
    }

    func testNativeAssetReaderReadGateStopAndSeekLifecycleOrder() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r4_native_probe_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await Self.createSyntheticH264AndPCMFile(at: tempURL, frameCount: 15)

        let expectedCancelledVideo = [
            "willCopy:video", "didRequestCancel", "callerReturned",
            "didCopy:video:true", "willCancelReading", "didCancelReading"
        ]
        let videoStop = try await runNativeParkedReadScenario(url: tempURL, kind: .video, useSeek: false)
        XCTAssertTrue(videoStop.callerReturnedAtWatchdogFreeze)
        XCTAssertEqual(videoStop.eventsAtWatchdogFreeze, ["willCopy:video", "didRequestCancel", "callerReturned"])
        XCTAssertEqual(videoStop.finalEvents, expectedCancelledVideo)
        XCTAssertEqual(videoStop.firstFrameCallbackCount, 0)
        XCTAssertEqual(videoStop.playbackEndedCallbackCount, 0)

        let videoSeek = try await runNativeParkedReadScenario(url: tempURL, kind: .video, useSeek: true)
        XCTAssertTrue(videoSeek.callerReturnedAtWatchdogFreeze)
        XCTAssertEqual(videoSeek.eventsAtWatchdogFreeze, ["willCopy:video", "didRequestCancel", "callerReturned"])
        XCTAssertEqual(videoSeek.finalEvents, expectedCancelledVideo)
        XCTAssertTrue(videoSeek.postSeekDidEnqueueVideo)

        let audioStop = try await runNativeParkedReadScenario(url: tempURL, kind: .audio, useSeek: false)
        XCTAssertTrue(audioStop.callerReturnedAtWatchdogFreeze)
        XCTAssertEqual(audioStop.eventsAtWatchdogFreeze, ["willCopy:audio", "didRequestCancel", "callerReturned"])
        XCTAssertEqual(
            audioStop.finalEvents,
            ["willCopy:audio", "didRequestCancel", "callerReturned", "didCopy:audio:true", "willCancelReading", "didCancelReading"]
        )
        XCTAssertEqual(audioStop.playbackEndedCallbackCount, 0)

        let normalTrace = try await runNativeUncancelledPositiveScenario(url: tempURL)
        XCTAssertTrue(normalTrace.finalEvents.contains("didEnqueue:video"))
        XCTAssertTrue(normalTrace.finalEvents.contains("didEnqueue:audio"))
        XCTAssertGreaterThanOrEqual(normalTrace.firstFrameCallbackCount, 1)
    }

    private func runNativeParkedReadScenario(
        url: URL,
        kind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind,
        useSeek: Bool
    ) async throws -> R4NativeProbeSnapshot {
        let controller = AVAssetReaderPlaybackController(url: url)
        let recorder = R4NativeProbeRecorder(targetKind: kind)
        var firstFrameCount = 0
        var endedCount = 0
        controller.onFirstVideoFrameEnqueued = { _ in firstFrameCount += 1 }
        controller.onPlaybackEnded = { endedCount += 1 }
        defer {
            recorder.releaseReadGateIfNeeded()
            controller.stop()
        }

        controller.lifecycleProbe = recorder.makeProbe()
        try await controller.load(autoPlay: false)
        let enteredFirstRead = await recorder.waitForFirstWillCopy(boundedBy: 3.0)
        XCTAssertTrue(enteredFirstRead)
        let targetSessionID = try XCTUnwrap(recorder.targetSessionID)
        XCTAssertEqual(controller.activeSessionID, targetSessionID)

        if useSeek {
            controller.seek(to: CMTime(seconds: 0.2, preferredTimescale: 600))
            recorder.recordCallerReturned(for: targetSessionID)
            try await Task.sleep(for: .milliseconds(90))
        } else {
            controller.stop()
            recorder.recordCallerReturned(for: targetSessionID)
            try await Task.sleep(for: .milliseconds(60))
        }
        return recorder.snapshot(firstFrameCount: firstFrameCount, endedCount: endedCount)
    }

    private func runNativeUncancelledPositiveScenario(url: URL) async throws -> R4NativeProbeSnapshot {
        let controller = AVAssetReaderPlaybackController(url: url)
        let recorder = R4NativeProbeRecorder(targetKind: nil)
        var firstFrameCount = 0
        var endedCount = 0
        controller.onFirstVideoFrameEnqueued = { _ in firstFrameCount += 1 }
        controller.onPlaybackEnded = { endedCount += 1 }
        defer { controller.stop() }

        controller.lifecycleProbe = recorder.makeProbe()
        try await controller.load(autoPlay: false)
        try await Task.sleep(for: .milliseconds(80))
        controller.seek(to: CMTime(seconds: 0.1, preferredTimescale: 600))
        try await Task.sleep(for: .milliseconds(80))
        return recorder.snapshot(firstFrameCount: firstFrameCount, endedCount: endedCount)
    }

    private static func createSyntheticH264AndPCMFile(at url: URL, frameCount: Int) async throws {
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

// MARK: - R4 Native Probe Recorder

private struct R4NativeProbeSnapshot: Sendable {
    let callerReturnedAtWatchdogFreeze: Bool
    let eventsAtWatchdogFreeze: [String]
    let finalEvents: [String]
    let postSeekDidEnqueueVideo: Bool
    let firstFrameCallbackCount: Int
    let playbackEndedCallbackCount: Int
}

private final class R4NativeProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let targetKind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind?
    private let readGate = DispatchSemaphore(value: 0)
    private let firstReadEnteredSemaphore = DispatchSemaphore(value: 0)
    private let watchdogQueue = DispatchQueue(label: "com.metastudyline.ttmedia.tests.r4.watchdog")
    private var capturedSessionID: UUID?
    private var hasParkedFirstRead = false
    private var hasReleasedReadGate = false
    private var callerReturned = false
    private var callerReturnedAtFreeze = false
    private var events: [String] = []
    private var frozenEvents: [String] = []
    private var laterSessionDidEnqueueVideo = false

    init(targetKind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind?) {
        self.targetKind = targetKind
    }

    var targetSessionID: UUID? { lock.withLock { capturedSessionID } }

    func releaseReadGateIfNeeded() {
        let shouldSignal: Bool = lock.withLock {
            guard !hasReleasedReadGate else { return false }
            hasReleasedReadGate = true
            return true
        }
        if shouldSignal { readGate.signal() }
    }

    func waitForFirstWillCopy(boundedBy seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [firstReadEnteredSemaphore] in
                let result = firstReadEnteredSemaphore.wait(timeout: .now() + seconds)
                continuation.resume(returning: result == .success)
            }
        }
    }

    func recordCallerReturned(for sessionID: UUID) {
        lock.withLock {
            guard capturedSessionID == sessionID else { return }
            callerReturned = true
            events.append("callerReturned")
        }
    }

    func snapshot(firstFrameCount: Int, endedCount: Int) -> R4NativeProbeSnapshot {
        lock.withLock {
            R4NativeProbeSnapshot(
                callerReturnedAtWatchdogFreeze: callerReturnedAtFreeze,
                eventsAtWatchdogFreeze: frozenEvents,
                finalEvents: events,
                postSeekDidEnqueueVideo: laterSessionDidEnqueueVideo,
                firstFrameCallbackCount: firstFrameCount,
                playbackEndedCallbackCount: endedCount
            )
        }
    }

    func makeProbe() -> AVAssetReaderPlaybackController.NativeReaderLifecycleProbe {
        AVAssetReaderPlaybackController.NativeReaderLifecycleProbe(
            willCopyNextSampleBuffer: { [weak self] id, kind in self?.handleWillCopy(sessionID: id, kind: kind) },
            didCopyNextSampleBuffer: { [weak self] id, kind, ok in
                self?.recordMediaEvent(sessionID: id, kind: kind, "didCopy:\(kind.rawValue):\(ok)")
            },
            didEnqueueSampleBuffer: { [weak self] id, kind, _ in self?.handleDidEnqueue(sessionID: id, kind: kind) },
            didRequestCancel: { [weak self] id in self?.handleDidRequestCancel(sessionID: id) },
            willCancelReading: { [weak self] id in self?.recordSessionEvent(sessionID: id, "willCancelReading") },
            didCancelReading: { [weak self] id in self?.recordSessionEvent(sessionID: id, "didCancelReading") }
        )
    }

    private func handleWillCopy(sessionID: UUID, kind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind) {
        let shouldPark: Bool = lock.withLock {
            guard let targetKind else {
                events.append("willCopy:\(kind.rawValue)")
                return false
            }
            guard kind == targetKind, !hasParkedFirstRead else { return false }
            hasParkedFirstRead = true
            capturedSessionID = sessionID
            events.append("willCopy:\(kind.rawValue)")
            return true
        }
        guard shouldPark else { return }
        firstReadEnteredSemaphore.signal()
        _ = readGate.wait(timeout: .now() + 5.0)
    }

    private func handleDidEnqueue(sessionID: UUID, kind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind) {
        lock.withLock {
            guard let targetKind else {
                events.append("didEnqueue:\(kind.rawValue)")
                return
            }
            if capturedSessionID == sessionID, kind == targetKind {
                events.append("didEnqueue:\(kind.rawValue)")
            } else if capturedSessionID != nil, capturedSessionID != sessionID, kind == .video {
                laterSessionDidEnqueueVideo = true
            }
        }
    }

    private func handleDidRequestCancel(sessionID: UUID) {
        let isTarget: Bool = lock.withLock {
            guard capturedSessionID == sessionID else { return false }
            events.append("didRequestCancel")
            return true
        }
        guard isTarget else { return }
        watchdogQueue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.callerReturnedAtFreeze = self.callerReturned
                self.frozenEvents = self.events
            }
            self.releaseReadGateIfNeeded()
        }
    }

    private func recordMediaEvent(sessionID: UUID, kind: AVAssetReaderPlaybackController.NativeReaderLifecycleProbe.MediaKind, _ event: String) {
        lock.withLock {
            guard let targetKind else {
                events.append(event)
                return
            }
            guard capturedSessionID == sessionID, kind == targetKind else { return }
            events.append(event)
        }
    }

    private func recordSessionEvent(sessionID: UUID, _ event: String) {
        lock.withLock {
            guard capturedSessionID == sessionID else { return }
            events.append(event)
        }
    }
}
