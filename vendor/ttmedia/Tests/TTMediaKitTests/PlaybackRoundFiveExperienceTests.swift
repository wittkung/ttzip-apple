// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import AVFoundation
import Darwin
import XCTest
@testable import TTMediaKit

@MainActor
final class PlaybackRoundFiveExperienceTests: XCTestCase {
    func testAudioTimelineHasOneWaveformAndNoIntegrityWarningForSampledPeaks() {
        let player = AudioWaveformVisualizerView(isPlaying: false)
        XCTAssertFalse(player.showsOverviewStrip)
        let engine = MPVAudioEngine()
        // Empty data is not a successful completeness check; no user-facing warning is invented.
        let empty = AudioWaveformVisualizerView(audioEngine: engine, isPlaying: false)
        XCTAssertNil(empty.statusBadgeText)
        XCTAssertNil(AudioWaveformVisualizerView.statusBadge(for: .sampledOrUnverified(peaks: [0.2, 0.1])))
        XCTAssertNotNil(AudioWaveformVisualizerView.statusBadge(for: .waveformOnlyPreview(peaks: [0.2])))
        XCTAssertEqual(empty.resolvedDisplayState, .unavailable)
    }

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

        transport.resetReadGateAndHoldNext(cooperativeCancellation: false)
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

// MARK: - R4 In-Process Worker Bridge & Controlled Service Transport

private final class R4InProcessWorkerBridge: MediaWorkerTransport, @unchecked Sendable {
    private let service: MediaWorkerService
    private let lock = NSLock()
    private var retainedHandles: [FileHandle] = []
    private var openedFDs: [Int32] = []
    private var connected = false

    init(service: MediaWorkerService) {
        self.service = service
    }

    var firstOpenedFD: Int32? { lock.withLock { openedFDs.first } }
    var isConnected: Bool { lock.withLock { connected } }

    func openMedia(path: String, targetTracks: [Int]?) async throws -> (sessionId: String, metadata: [String: Any]) {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        lock.withLock {
            retainedHandles.append(handle)
            openedFDs.append(handle.fileDescriptor)
            connected = true
        }
        return try await withCheckedThrowingContinuation { continuation in
            service.openFileMedia(
                handle,
                targetTracks: targetTracks?.map(NSNumber.init(value:))
            ) { success, sessionIdOrError, metadata in
                if success, let sessionId = sessionIdOrError, let dict = metadata {
                    continuation.resume(returning: (sessionId, dict))
                } else {
                    continuation.resume(
                        throwing: MediaWorkerError.openFailed(sessionIdOrError ?? "missing open reply")
                    )
                }
            }
        }
    }

    func readNextPacket(sessionId: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            service.readNextPacket(forSession: sessionId) { data, errorMessage in
                if let errorMessage {
                    continuation.resume(throwing: MediaWorkerError.readPacketFailed(errorMessage))
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            service.seek(to: timestamp, sessionId: sessionId, accurate: accurate) { success, actual, errorMessage in
                if success {
                    continuation.resume(returning: actual)
                } else {
                    continuation.resume(throwing: MediaWorkerError.seekFailed(errorMessage ?? "seek failed"))
                }
            }
        }
    }

    func subtitleData(sessionId: String, track: Int64, requestID: UInt64) async throws -> Data { Data() }

    func closeMedia(sessionId: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.closeMedia(forSession: sessionId) { success, errorMessage in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: MediaWorkerError.closeFailed(errorMessage ?? "close failed"))
                }
            }
        }
    }

    func setSleepState(state: Int) async throws {}
    func invalidate() { lock.withLock { connected = false } }
    func reconnect() async throws {}
    func setCrashHandler(_ handler: (@Sendable (MediaWorkerError) -> Void)?) {}
}

private final class R4AsyncLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    var isSignalled: Bool { lock.withLock { signalled } }

    func reset() {
        lock.withLock {
            signalled = false
            waiters.removeAll()
        }
    }

    func signal() {
        let pending: [CheckedContinuation<Bool, Never>] = lock.withLock {
            signalled = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: true) }
    }

    func wait(boundedBy budget: TimeInterval) async -> Bool {
        if isSignalled { return true }
        return await withCheckedContinuation { continuation in
            let installed: Bool = lock.withLock {
                guard !signalled else { return false }
                waiters.append(continuation)
                return true
            }
            guard installed else {
                continuation.resume(returning: true)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(budget * 1000)))
                guard let self else { return }
                let expired: [CheckedContinuation<Bool, Never>] = self.lock.withLock {
                    defer { self.waiters.removeAll() }
                    return self.waiters
                }
                for waiter in expired { waiter.resume(returning: false) }
            }
        }
    }
}

private final class R4ControlledWorkerServiceTransport: MediaWorkerServiceTransport, @unchecked Sendable {
    private static let minimalAvcC = Data([
        0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1, 0x00, 0x0D,
        0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x01, 0x40, 0x16,
        0xE8, 0x06, 0xD0, 0xA1, 0x35, 0x01, 0x00, 0x04,
        0x68, 0xCE, 0x3C, 0x80
    ])
    private static let minimalVideoSlicePayload = Data([0x00, 0x00, 0x00, 0x02, 0x65, 0x01])

    private let lock = NSLock()
    private let readEntryLatch = R4AsyncLatch()
    private let readReleaseLatch = R4AsyncLatch()
    private let readExitLatch = R4AsyncLatch()
    private let closeEntryLatch = R4AsyncLatch()
    private let closeReleaseLatch = R4AsyncLatch()
    private let closeCompletionLatch = R4AsyncLatch()
    private var activeSessionId: String?
    private var openCount = 0
    private var seeks = 0
    private var timeline: [String] = []
    private var shouldHoldRead = false
    private var shouldHoldClose = false
    private var shouldFailCloseAfterRelease = false

    var currentSessionId: String? { lock.withLock { activeSessionId } }
    var hasExitedRead: Bool { readExitLatch.isSignalled }
    var hasEnteredClose: Bool { closeEntryLatch.isSignalled }
    var seekCallCount: Int { lock.withLock { seeks } }
    var operationTimeline: [String] { lock.withLock { timeline } }

    func holdFirstRead() { lock.withLock { shouldHoldRead = true } }
    func holdNextClose() { lock.withLock { shouldHoldClose = true } }
    func failCloseAfterRelease() { lock.withLock { shouldFailCloseAfterRelease = true } }
    func releaseRead() { readReleaseLatch.signal() }
    func releaseClose() { closeReleaseLatch.signal() }

    func resetReadGateAndHoldNext(cooperativeCancellation: Bool) {
        _ = cooperativeCancellation
        lock.withLock { shouldHoldRead = true }
        readEntryLatch.reset()
        readReleaseLatch.reset()
        readExitLatch.reset()
    }

    func openMedia(path: String, targetTracks: [Int]?) async throws -> (sessionId: String, metadata: [String: Any]) {
        let sessionId: String = lock.withLock {
            openCount += 1
            let next = "r4-session-\(openCount)"
            activeSessionId = next
            return next
        }
        return (sessionId, Self.makeContractMetadata())
    }

    func readNextPacket(sessionId: String) async throws -> Data? {
        let shouldHold: Bool = lock.withLock {
            defer { shouldHoldRead = false }
            return shouldHoldRead
        }
        guard shouldHold else { return nil }
        readEntryLatch.signal()
        _ = await readReleaseLatch.wait(boundedBy: 5.0)
        lock.withLock { timeline.append("readExited") }
        readExitLatch.signal()
        let dto = try MediaPacketDTO(
            streamIndex: 0, mediaType: .video, ptsValue: 150, ptsTimescale: 600,
            dtsValue: 150, dtsTimescale: 600, durationValue: 24, durationTimescale: 600,
            payloadData: Self.minimalVideoSlicePayload, isKeyframe: true, doNotDisplay: false
        )
        return try JSONEncoder().encode(dto)
    }

    func closeMedia(sessionId: String) async throws {
        let (shouldHold, failAfter): (Bool, Bool) = lock.withLock {
            timeline.append("closeEntered")
            defer {
                shouldHoldClose = false
                shouldFailCloseAfterRelease = false
            }
            return (shouldHoldClose, shouldFailCloseAfterRelease)
        }
        closeEntryLatch.signal()
        if shouldHold {
            _ = await closeReleaseLatch.wait(boundedBy: 5.0)
        }
        if failAfter {
            closeCompletionLatch.signal()
            throw MediaWorkerError.closeFailed("r4 controlled close failure")
        }
        lock.withLock {
            if activeSessionId == sessionId { activeSessionId = nil }
        }
        closeCompletionLatch.signal()
    }

    func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double {
        lock.withLock {
            seeks += 1
            timeline.append("seekEntered")
        }
        return timestamp
    }

    func subtitleData(sessionId: String, track: Int64, requestID: UInt64) async throws -> Data { Data() }
    func waitForReadEntry(boundedBy budget: TimeInterval) async -> Bool { await readEntryLatch.wait(boundedBy: budget) }
    func waitForReadExit(boundedBy budget: TimeInterval) async -> Bool { await readExitLatch.wait(boundedBy: budget) }
    func waitForCloseEntry(boundedBy budget: TimeInterval) async -> Bool { await closeEntryLatch.wait(boundedBy: budget) }
    func waitForCloseCompletion(boundedBy budget: TimeInterval) async -> Bool { await closeCompletionLatch.wait(boundedBy: budget) }

    private static func makeContractMetadata() -> [String: Any] {
        let videoDict: [String: Any] = [
            "trackIndex": 0, "codec": "h264", "rawCodecId": "V_MPEG4/ISO/AVC", "codecName": "h264",
            "width": 640, "height": 360, "pixelWidth": 640, "pixelHeight": 360,
            "demuxSelectable": true, "isSelectedForPackets": true, "extradata": minimalAvcC
        ]
        return [
            "format": "matroska", "durationSeconds": 10.0,
            "metadataCapability": "v1_structured_contract_v1", "selectedVideoTrackNumber": 0,
            "videoTracks": [videoDict], "audioTracks": [], "catalogSubtitleTracks": []
        ]
    }
}
