// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
@preconcurrency import AVFoundation
@testable import TTMediaKit

final class PlaybackLifecycleRegressionTests: XCTestCase {
    @MainActor
    func testNativeTimeCallbacksAdvanceAndFinishOnlyAtPresentationEnd() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: url, frameCount: 30)
        let controller = AVAssetReaderPlaybackController(url: url)
        defer { controller.stop() }
        let progressed = expectation(description: "Playback time advances")
        let finished = expectation(description: "Presentation reaches duration")
        var didProgress = false
        var endCount = 0
        controller.onTimeUpdate = { time in
            if CMTimeGetSeconds(time) > 0.1, !didProgress {
                didProgress = true
                progressed.fulfill()
            }
        }
        controller.onPlaybackEnded = {
            endCount += 1
            XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(controller.currentTime), CMTimeGetSeconds(controller.duration))
            finished.fulfill()
        }
        try await controller.load(autoPlay: true)
        await fulfillment(of: [progressed, finished], timeout: 4)
        XCTAssertEqual(endCount, 1)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testWorkerEOFDoesNotPauseAndSeekRestartsPacketPump() async throws {
        let transport = ExhaustedPlaybackTransport()
        let controller = AVSampleBufferWorkerPlaybackController(
            url: URL(fileURLWithPath: "/tmp/regression.mkv"),
            client: MediaWorkerXPCClient(transport: transport)
        )
        defer { controller.teardown() }
        await controller.startPlayback()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(controller.isPlaying, "Input EOF must not stop queued presentation")
        let reads = transport.readCount
        await controller.seek(to: 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertGreaterThan(transport.readCount, reads, "Seeking after EOF must restart the packet pump")
    }

    @MainActor
    func testWorkerRespectsPausedLoadAndReportsOpenError() async throws {
        let transport = ExhaustedPlaybackTransport()
        let controller = AVSampleBufferWorkerPlaybackController(
            url: URL(fileURLWithPath: "/tmp/regression.mkv"),
            client: MediaWorkerXPCClient(transport: transport)
        )
        defer { controller.teardown() }
        await controller.startPlayback(autoPlay: false)
        await controller.waitForInitialMediaReadinessOrFailure()
        XCTAssertTrue(controller.hasEnqueuedInitialMediaSample)
        XCTAssertFalse(controller.isLoading)
        XCTAssertTrue(controller.coordinator.isReady)
        XCTAssertFalse(controller.isPlaying, "autoPlay=false must ready initial sample without starting playback")
        let failed = expectation(description: "Open error reaches owner")
        transport.failOpen = true
        controller.onError = { _ in failed.fulfill() }
        await controller.startPlayback(autoPlay: false)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isPlaying)
    }
}

private final class ExhaustedPlaybackTransport: MediaWorkerTransport, @unchecked Sendable {
    private static let minimalAvcC = Data([
        0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1, 0x00, 0x0D, 0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x01,
        0x40, 0x16, 0xE8, 0x06, 0xD0, 0xA1, 0x35, 0x01, 0x00, 0x04, 0x68, 0xCE, 0x3C, 0x80
    ])
    private static let minimalVideoSlice = Data([0x00, 0x00, 0x00, 0x02, 0x65, 0x01])
    private let lock = NSLock()
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var reads = 0
    private var emittedInitialForCurrentCycle = false
    private var currentPTSSeconds: Double = 0.0
    var failOpen = false
    var zeroFrameEOF = false
    var audioOnly = false
    var holdFirstRead = false
    var readCount: Int { lock.withLock { reads } }

    func releaseHeldRead() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            holdFirstRead = false
            defer { readWaiters.removeAll() }
            return readWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func waitIfHoldingFirstRead() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let installed: Bool = lock.withLock {
                guard holdFirstRead else { return false }
                readWaiters.append(continuation)
                return true
            }
            guard installed else {
                continuation.resume()
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.releaseHeldRead()
            }
        }
    }

    func openMedia(path: String, targetTracks: [Int]?) async throws -> (sessionId: String, metadata: [String: Any]) {
        if failOpen { throw MediaWorkerError.openFailed("Regression fixture open failure") }
        lock.withLock { emittedInitialForCurrentCycle = false; currentPTSSeconds = 0.0 }
        if audioOnly {
            let audioDict: [String: Any] = [
                "trackIndex": 0, "codec": "pcm_s16le", "codecName": "pcm_s16le",
                "sampleRate": 48_000.0, "channels": 2, "bitDepth": 16,
                "demuxSelectable": true, "isSelectedForPackets": true
            ]
            return ("regression", [
                "durationSeconds": 10.0, "format": "matroska", "metadataCapability": "v1_structured_contract_v1",
                "selectedAudioTrackNumber": 0, "videoTracks": [], "audioTracks": [audioDict]
            ])
        }
        let videoDict: [String: Any] = [
            "trackIndex": 0, "codec": "h264", "rawCodecId": "V_MPEG4/ISO/AVC", "codecName": "h264",
            "width": 320, "height": 180, "pixelWidth": 320, "pixelHeight": 180,
            "demuxSelectable": true, "isSelectedForPackets": true, "extradata": Self.minimalAvcC
        ]
        return ("regression", [
            "durationSeconds": 10.0, "format": "matroska", "metadataCapability": "v1_structured_contract_v1",
            "selectedVideoTrackNumber": 0, "videoTracks": [videoDict], "audioTracks": []
        ])
    }
    func readNextPacket(sessionId: String) async throws -> Data? {
        await waitIfHoldingFirstRead()
        let (shouldEmit, ptsSec, isAudio): (Bool, Double, Bool) = lock.withLock {
            reads += 1
            if zeroFrameEOF || emittedInitialForCurrentCycle {
                return (false, currentPTSSeconds, audioOnly)
            }
            emittedInitialForCurrentCycle = true
            return (true, currentPTSSeconds, audioOnly)
        }
        guard shouldEmit else { return nil }
        let ptsVal = Int64((ptsSec * 600.0).rounded())
        let dto = try MediaPacketDTO(
            streamIndex: 0, mediaType: isAudio ? .audio : .video,
            ptsValue: ptsVal, ptsTimescale: 600, dtsValue: ptsVal, dtsTimescale: 600,
            durationValue: 24, durationTimescale: 600,
            payloadData: isAudio ? Data(repeating: 0, count: 1920 * 4) : Self.minimalVideoSlice,
            isKeyframe: true, doNotDisplay: false
        )
        return try JSONEncoder().encode(dto)
    }
    func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double {
        lock.withLock {
            currentPTSSeconds = timestamp
            emittedInitialForCurrentCycle = false
        }
        return timestamp
    }
    func closeMedia(sessionId: String) async throws {}
    func setSleepState(state: Int) async throws {}
    func invalidate() {}
    func reconnect() async throws {}
    var isConnected: Bool { true }
    func setCrashHandler(_ handler: (@Sendable (MediaWorkerError) -> Void)?) {}
}

extension PlaybackLifecycleRegressionTests {
    func testSandboxServiceRejectsUnbrokeredPathsAndWritableHandles() async {
        let service = MediaWorkerService()
        let rejectedPath = expectation(description: "Bare paths cannot bypass host authorization")
        service.openMedia(at: "/tmp/unbrokered.mkv", targetTracks: nil) { success, error, _ in
            XCTAssertFalse(success)
            XCTAssertNotNil(error)
            rejectedPath.fulfill()
        }
        let rejectedHandle = expectation(description: "Writable handles are rejected")
        let writablePipe = Pipe()
        service.openFileMedia(writablePipe.fileHandleForWriting, targetTracks: nil) { success, error, _ in
            XCTAssertFalse(success)
            XCTAssertNotNil(error)
            rejectedHandle.fulfill()
        }
        await fulfillment(of: [rejectedPath, rejectedHandle], timeout: 2)
    }
}

extension PlaybackLifecycleRegressionTests {
    @MainActor
    func testUnknownDurationDrainsToLastSampleAndEndsOnce() async throws {
        let coordinator = AVSampleBufferPlayerCoordinator()
        defer { coordinator.teardown() }
        let ended = expectation(description: "Unknown-duration input finishes at its final timestamp")
        ended.assertForOverFulfill = true
        coordinator.onPlaybackEnded = { ended.fulfill() }
        coordinator.prepare(duration: .indefinite)
        coordinator.play()
        coordinator.finishInput(at: CMTime(seconds: 0.15, preferredTimescale: 600))
        XCTAssertTrue(coordinator.isPlaying)
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertFalse(coordinator.isPlaying)
    }

    @MainActor
    func testNativeMP4TenRoundTripsPlayingAndPausedPreserveStateProgressSubtitlesAndLayerOwnership() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: url, frameCount: 90)

        let sessions = VideoPlaybackSessions()
        let inspectorID = UUID()
        let session = sessions.claim(url: url, viewportID: inspectorID, isFullScreen: false, caller: "inspector_open")
        session.start(autoPlay: false)
        try await waitUntilLoaded(session)
        defer { session.stop(reason: "test_cleanup") }

        guard case .native(let controller) = session.activeController else {
            return XCTFail("Expected native MP4 controller")
        }
        let initialControllerIdentity = ObjectIdentifier(controller)
        let inspectorView = makeHostView(for: controller, width: 320, height: 180, attachesImmediately: true)
        inspectorView.updatePresentationOwnership(
            sessionID: session.sessionID, viewportID: inspectorID, isPresenting: true, reason: "inspector_initial"
        )

        XCTAssertFalse(session.isPlaying)
        XCTAssertEqual(controller.synchronizer.rate, 0.0)
        XCTAssertTrue(controller.synchronizer.currentTime().isNumeric)

        controller.seek(to: CMTime(seconds: 0.8, preferredTimescale: 600))
        session.subtitleTrack = ExternalSubtitleTrack(cues: [.init(start: 0.1, end: 5.0, text: "Paused Subtitle")])
        session.selectedSubtitleID = "custom:srt"
        XCTAssertEqual(session.activeSubtitleText, "Paused Subtitle")

        try await assertNativePausedRoundTrips(
            sessions: sessions, session: session, controller: controller,
            inspectorID: inspectorID, inspectorView: inspectorView, url: url
        )
        assertNativePlayingRoundTrips(
            sessions: sessions, session: session, controller: controller,
            inspectorID: inspectorID, url: url
        )

        guard case .native(let finalController) = session.activeController else {
            return XCTFail("Native controller lost after 22 round-trips")
        }
        XCTAssertEqual(ObjectIdentifier(finalController), initialControllerIdentity)
    }

    @MainActor
    private func assertNativePausedRoundTrips(
        sessions: VideoPlaybackSessions,
        session: VideoPlaybackSession,
        controller: AVAssetReaderPlaybackController,
        inspectorID: UUID,
        inspectorView: AVSampleBufferPlayerNSView,
        url: URL
    ) async throws {
        for idx in 1...12 {
            let fullWindowID = UUID()
            let fullView = makeHostView(for: controller, width: 1280, height: 720, attachesImmediately: false)
            let claimed = sessions.claim(url: url, viewportID: fullWindowID, isFullScreen: true, caller: "enter_fullscreen_\(idx)")
            claimed.start(autoPlay: true)
            XCTAssertTrue(claimed === session)
            XCTAssertEqual(session.activePresenterViewportID, fullWindowID)
            XCTAssertFalse(session.isPlaying, "Round-trip \(idx) must not auto-play a paused session")

            syncViews(session: session, inspectorID: inspectorID, inspectorView: inspectorView, fullID: fullWindowID, fullView: fullView)
            inspectorView.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
            inspectorView.layout()
            XCTAssertTrue(controller.displayLayer.superlayer === fullView.layer)
            XCTAssertEqual(controller.displayLayer.frame.size, CGSize(width: 1280, height: 720))

            sessions.release(sessionID: session.sessionID, viewportID: inspectorID, caller: "inspector_disappear_\(idx)")
            if idx == 1 { try await Task.sleep(for: .milliseconds(380)) }
            XCTAssertFalse(session.isStopped)
            XCTAssertEqual(CMTimeGetSeconds(session.currentTime), 0.8, accuracy: 0.05)
            XCTAssertEqual(session.selectedSubtitleID, "custom:srt")

            let back = sessions.claim(url: url, viewportID: inspectorID, isFullScreen: false, caller: "exit_fullscreen_\(idx)")
            back.start(autoPlay: false)
            sessions.release(sessionID: session.sessionID, viewportID: fullWindowID, caller: "fullscreen_disappear_\(idx)")
            syncViews(session: session, inspectorID: inspectorID, inspectorView: inspectorView, fullID: fullWindowID, fullView: fullView)
            fullView.frame = NSRect(x: 0, y: 0, width: 999, height: 555)
            fullView.layout()
            XCTAssertTrue(controller.displayLayer.superlayer === inspectorView.layer)
        }
    }

    @MainActor
    func testInspectorLateTaskDoesNotStealPresentationOrLayerFromFullWindow() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: url, frameCount: 36)

        let sessions = VideoPlaybackSessions()
        let inspectorID = UUID()
        let fullWindowID = UUID()

        let s1 = sessions.claim(
            url: url, viewportID: inspectorID, isFullScreen: false,
            promoteToPresenter: true, caller: "onAppear(inspector)"
        )
        s1.start(autoPlay: false)
        try await waitUntilLoaded(s1)
        defer { s1.stop(reason: "interleaved_cleanup") }

        guard case .native(let controller) = s1.activeController else {
            return XCTFail("Expected native MP4 controller")
        }
        let inspectorView = makeHostView(for: controller, width: 320, height: 180, attachesImmediately: true)
        let fullView = makeHostView(for: controller, width: 1440, height: 900, attachesImmediately: false)
        syncViews(session: s1, inspectorID: inspectorID, inspectorView: inspectorView, fullID: fullWindowID, fullView: fullView)
        XCTAssertEqual(s1.activePresenterViewportID, inspectorID)
        XCTAssertTrue(controller.displayLayer.superlayer === inspectorView.layer)

        let s2 = sessions.claim(
            url: url, viewportID: fullWindowID, isFullScreen: true,
            promoteToPresenter: true, caller: "onAppear(fullScreen)"
        )
        XCTAssertTrue(s2 === s1)
        XCTAssertEqual(s1.activePresenterViewportID, fullWindowID)
        syncViews(session: s1, inspectorID: inspectorID, inspectorView: inspectorView, fullID: fullWindowID, fullView: fullView)
        XCTAssertTrue(controller.displayLayer.superlayer === fullView.layer)

        let s3 = sessions.claim(
            url: url, viewportID: inspectorID, isFullScreen: false,
            promoteToPresenter: true, caller: "task(inspector)"
        )
        XCTAssertTrue(s3 === s1)
        XCTAssertEqual(s1.activePresenterViewportID, fullWindowID, "Late Inspector task must not steal presenter from active Full-Window")
        syncViews(session: s1, inspectorID: inspectorID, inspectorView: inspectorView, fullID: fullWindowID, fullView: fullView)
        inspectorView.frame = NSRect(x: 0, y: 0, width: 240, height: 135)
        inspectorView.layout()
        XCTAssertTrue(controller.displayLayer.superlayer === fullView.layer)
        XCTAssertEqual(controller.displayLayer.frame.size, CGSize(width: 1440, height: 900))

        sessions.release(sessionID: s1.sessionID, viewportID: fullWindowID, caller: "onDisappear(fullScreen)")
        XCTAssertEqual(s1.activePresenterViewportID, inspectorID)
        syncViews(session: s1, inspectorID: inspectorID, inspectorView: inspectorView, fullID: fullWindowID, fullView: fullView)
        XCTAssertTrue(controller.displayLayer.superlayer === inspectorView.layer)
    }

    @MainActor
    private func assertNativePlayingRoundTrips(
        sessions: VideoPlaybackSessions,
        session: VideoPlaybackSession,
        controller: AVAssetReaderPlaybackController,
        inspectorID: UUID,
        url: URL
    ) {
        controller.togglePlayPause()
        session.isPlaying = controller.isPlaying
        XCTAssertTrue(session.isPlaying)
        for idx in 1...10 {
            let fullWindowID = UUID()
            let claimed = sessions.claim(url: url, viewportID: fullWindowID, isFullScreen: true, caller: "playing_enter_\(idx)")
            claimed.start(autoPlay: true)
            sessions.release(sessionID: session.sessionID, viewportID: inspectorID, caller: "playing_leave_inspector_\(idx)")
            XCTAssertTrue(session.isPlaying)
            XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(session.currentTime), 0.75)

            let back = sessions.claim(url: url, viewportID: inspectorID, isFullScreen: false, caller: "playing_exit_\(idx)")
            back.start(autoPlay: false)
            sessions.release(sessionID: session.sessionID, viewportID: fullWindowID, caller: "playing_leave_fullscreen_\(idx)")
            XCTAssertTrue(session.isPlaying)
        }
    }

    @MainActor
    func testWorkerMKVTenRoundTripsPlayingAndPausedMidLoadAndRecovery() async throws {
        let transport = ExhaustedPlaybackTransport()
        let sessions = VideoPlaybackSessions()
        sessions.workerClientProvider = { MediaWorkerXPCClient(transport: transport) }
        let url = URL(fileURLWithPath: "/tmp/roundtrip-worker.mkv")
        let manualDir = FileManager.default.temporaryDirectory.appendingPathComponent("manual-subs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: manualDir, withIntermediateDirectories: true)
        let manualSubURL = manualDir.appendingPathComponent("external_manual.srt")
        try "1\n00:00:01,000 --> 00:00:09,000\nManual External Primary Cue\n".write(
            to: manualSubURL, atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: manualDir) }

        let inspectorID = UUID()
        let session = sessions.claim(url: url, viewportID: inspectorID, isFullScreen: false, caller: "worker_inspector_open")
        session.start(autoPlay: false)
        let midLoadFullID = UUID()
        let midClaimed = sessions.claim(url: url, viewportID: midLoadFullID, isFullScreen: true, caller: "worker_mid_load_fullscreen")
        midClaimed.start(autoPlay: true)
        sessions.release(sessionID: session.sessionID, viewportID: inspectorID, caller: "worker_mid_load_inspector_leave")
        try await waitUntilLoaded(session)
        defer { session.stop(reason: "worker_test_cleanup") }

        XCTAssertTrue(session === midClaimed)
        XCTAssertFalse(session.isPlaying, "Mid-load viewport switch must preserve initial paused intent")
        guard case .worker(let wc) = session.activeController else {
            return XCTFail("Expected worker controller for MKV")
        }
        await wc.seek(to: 4.2)
        session.loadExternalSubtitle(manualSubURL, showFeedback: false)
        await session.subtitleLoadTask?.value
        let secondaryTrack = ExternalSubtitleTrack(cues: [.init(start: 1.0, end: 9.0, text: "Embedded Secondary Cue")])
        session.subtitleCache["embedded:3"] = secondaryTrack
        session.selectSecondarySubtitle("embedded:3")
        XCTAssertEqual(CMTimeGetSeconds(session.currentTime), 4.2, accuracy: 0.05)
        XCTAssertEqual(session.activeSubtitleText, "Manual External Primary Cue")
        XCTAssertEqual(session.activeSecondarySubtitleText, "Embedded Secondary Cue")

        _ = sessions.claim(url: url, viewportID: inspectorID, isFullScreen: false, caller: "worker_back_inspector")
        sessions.release(sessionID: session.sessionID, viewportID: midLoadFullID, caller: "worker_mid_load_full_leave")

        assertWorkerRoundTrips(sessions: sessions, session: session, inspectorID: inspectorID, url: url, expectedPrimaryID: manualSubURL.absoluteString)
        try await assertWorkerRecoveryDualViewportAndSeekToZero(
            sessions: sessions,
            session: session,
            inspectorID: inspectorID,
            url: url,
            manualSubURL: manualSubURL
        )
    }

    @MainActor
    private func assertWorkerRoundTrips(
        sessions: VideoPlaybackSessions,
        session: VideoPlaybackSession,
        inspectorID: UUID,
        url: URL,
        expectedPrimaryID: String
    ) {
        for modePlay in [false, true] {
            if modePlay != session.isPlaying {
                session.activeController?.togglePlayPause()
                session.isPlaying = session.activeController?.isPlaying ?? false
            }
            XCTAssertEqual(session.isPlaying, modePlay)
            for idx in 1...10 {
                let fullID = UUID()
                let enter = sessions.claim(url: url, viewportID: fullID, isFullScreen: true, caller: "worker_enter_\(idx)")
                enter.start(autoPlay: true)
                sessions.release(sessionID: session.sessionID, viewportID: inspectorID, caller: "worker_leave_insp_\(idx)")
                XCTAssertEqual(session.isPlaying, modePlay)
                XCTAssertEqual(CMTimeGetSeconds(session.currentTime), 4.2, accuracy: 0.5)
                XCTAssertEqual(session.selectedSubtitleID, expectedPrimaryID)
                XCTAssertEqual(session.activeSubtitleText, "Manual External Primary Cue")
                XCTAssertEqual(session.activeSecondarySubtitleText, "Embedded Secondary Cue")

                let exit = sessions.claim(url: url, viewportID: inspectorID, isFullScreen: false, caller: "worker_exit_\(idx)")
                exit.start(autoPlay: false)
                sessions.release(sessionID: session.sessionID, viewportID: fullID, caller: "worker_leave_full_\(idx)")
                XCTAssertEqual(session.isPlaying, modePlay)
            }
        }
    }

    @MainActor
    private func assertWorkerRecoveryDualViewportAndSeekToZero(
        sessions: VideoPlaybackSessions,
        session: VideoPlaybackSession,
        inspectorID: UUID,
        url: URL,
        manualSubURL: URL
    ) async throws {
        let fullWindowID = UUID()
        var inspectorBoundSession = session
        var fullBoundSession = sessions.claim(url: url, viewportID: fullWindowID, isFullScreen: true, caller: "dual_open_fs")
        sessions.bindViewport(viewportID: inspectorID, sessionID: session.sessionID) { inspectorBoundSession = $0 }
        sessions.bindViewport(viewportID: fullWindowID, sessionID: session.sessionID) { fullBoundSession = $0 }

        session.setVolume(0.35)
        session.setPlaybackRate(1.5)
        XCTAssertEqual(session.volume, 0.35, accuracy: 0.001)
        XCTAssertFalse(session.isMuted)
        XCTAssertEqual(session.playbackRate, 1.5, accuracy: 0.001)

        let oldSessionID = session.sessionID
        session.activeController = nil
        XCTAssertTrue(session.isUnexpectedlyEmptyController)

        let recovered = sessions.claim(url: url, viewportID: fullWindowID, isFullScreen: true, restart: true, caller: "user_retry_fs")
        sessions.release(sessionID: oldSessionID, viewportID: UUID(), caller: "stale_disappear")
        XCTAssertTrue(inspectorBoundSession === recovered, "Surviving Inspector viewport must rebind to recovered session")
        XCTAssertTrue(fullBoundSession === recovered)
        XCTAssertEqual(recovered.activeViewports, Set([inspectorID, fullWindowID]))
        XCTAssertEqual(recovered.activePresenterViewportID, fullWindowID)

        recovered.start(autoPlay: false)
        try await waitUntilLoaded(recovered)
        await recovered.subtitleDiscoveryTask?.value
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(recovered.isStopped)
        XCTAssertEqual(CMTimeGetSeconds(recovered.currentTime), 4.2, accuracy: 0.5)
        XCTAssertEqual(recovered.volume, 0.35, accuracy: 0.001)
        XCTAssertFalse(recovered.isMuted)
        XCTAssertEqual(recovered.playbackRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(recovered.activeController?.volume ?? -1, 0.35, accuracy: 0.001)
        XCTAssertEqual(recovered.activeController?.isMuted, false)
        XCTAssertEqual(recovered.activeController?.playbackRate ?? -1, 1.5, accuracy: 0.001)
        XCTAssertEqual(recovered.selectedSubtitleID, manualSubURL.absoluteString)
        XCTAssertEqual(recovered.selectedSecondarySubtitleID, "embedded:3")
        XCTAssertNotNil(recovered.subtitleTrack)
        XCTAssertNotNil(recovered.secondarySubtitleTrack)
        XCTAssertEqual(recovered.activeSubtitleText, "Manual External Primary Cue")
        XCTAssertEqual(recovered.activeSecondarySubtitleText, "Embedded Secondary Cue")
        XCTAssertTrue(recovered.subtitleOptions.contains { $0.id == manualSubURL.absoluteString })

        let recoveredAtZero = try await assertExitFullWindowSeekZeroAndFinalClose(
            sessions: sessions,
            recovered: recovered,
            inspectorID: inspectorID,
            fullWindowID: fullWindowID,
            url: url
        )
        sessions.release(sessionID: inspectorBoundSession.sessionID, viewportID: inspectorID, caller: "close_all")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(recoveredAtZero.isStopped)
        XCTAssertNil(sessions.current)
        XCTAssertTrue(sessions.activeBoundViewportIDs.isEmpty)
    }

    @MainActor
    private func assertExitFullWindowSeekZeroAndFinalClose(
        sessions: VideoPlaybackSessions,
        recovered: VideoPlaybackSession,
        inspectorID: UUID,
        fullWindowID: UUID,
        url: URL
    ) async throws -> VideoPlaybackSession {
        guard let controller = recovered.activeController else {
            XCTFail("Expected active controller on recovered session")
            return recovered
        }
        let inspectorView = makeWorkerHostView(for: controller, width: 320, height: 180, attachesImmediately: false)
        let fullView = makeWorkerHostView(for: controller, width: 1280, height: 720, attachesImmediately: true)
        syncViews(session: recovered, inspectorID: inspectorID, inspectorView: inspectorView, fullID: fullWindowID, fullView: fullView)
        XCTAssertTrue(controller.displayLayer.superlayer === fullView.layer)

        sessions.release(sessionID: recovered.sessionID, viewportID: fullWindowID, caller: "exit_fs_after_recovery")
        XCTAssertFalse(recovered.isStopped)
        XCTAssertEqual(recovered.activePresenterViewportID, inspectorID)
        syncViews(session: recovered, inspectorID: inspectorID, inspectorView: inspectorView, fullID: fullWindowID, fullView: fullView)
        XCTAssertTrue(controller.displayLayer.superlayer === inspectorView.layer)

        recovered.seek(to: .zero)
        recovered.toggleMute()
        XCTAssertTrue(recovered.isMuted)
        XCTAssertEqual(recovered.volume, 0.0, accuracy: 0.001)
        XCTAssertEqual(recovered.previousVolume, 0.35, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(recovered.currentTime), 0.0, accuracy: 0.01)
        XCTAssertEqual(CMTimeGetSeconds(recovered.lastKnownTime), 0.0, accuracy: 0.01)

        recovered.activeController = nil
        let recoveredAtZero = sessions.claim(url: url, viewportID: inspectorID, isFullScreen: false, restart: true, caller: "retry_at_zero")
        recoveredAtZero.start(autoPlay: false)
        try await waitUntilLoaded(recoveredAtZero)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(CMTimeGetSeconds(recoveredAtZero.currentTime), 0.0, accuracy: 0.05)
        XCTAssertEqual(CMTimeGetSeconds(recoveredAtZero.lastKnownTime), 0.0, accuracy: 0.05)
        XCTAssertTrue(recoveredAtZero.isMuted)
        XCTAssertEqual(recoveredAtZero.volume, 0.0, accuracy: 0.001)
        XCTAssertEqual(recoveredAtZero.previousVolume, 0.35, accuracy: 0.001)
        XCTAssertEqual(recoveredAtZero.playbackRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(recoveredAtZero.activeController?.isMuted, true)
        XCTAssertEqual(recoveredAtZero.activeController?.volume ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(recoveredAtZero.activeController?.playbackRate ?? -1, 1.5, accuracy: 0.001)
        recoveredAtZero.toggleMute()
        XCTAssertFalse(recoveredAtZero.isMuted)
        XCTAssertEqual(recoveredAtZero.volume, 0.35, accuracy: 0.001)
        XCTAssertEqual(recoveredAtZero.activeController?.volume ?? -1, 0.35, accuracy: 0.001)
        XCTAssertEqual(recoveredAtZero.activeController?.isMuted, false)
        return recoveredAtZero
    }

    @MainActor
    func testRestoredAudioRateAppliedToNativeControllerAndViewportBindingsCleanedAcrossVideoSwitchAndLateRelease() async throws {
        let urlA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-A.mp4")
        let urlB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-B.mp4")
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: urlA, frameCount: 36)
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: urlB, frameCount: 36)

        let sessions = VideoPlaybackSessions()
        let oldViewportA = UUID()
        let sharedViewport = UUID()

        let sA = sessions.claim(url: urlA, viewportID: oldViewportA, isFullScreen: false, caller: "open_A_old")
        _ = sessions.claim(url: urlA, viewportID: sharedViewport, isFullScreen: false, caller: "open_A_shared")
        sessions.bindViewport(viewportID: oldViewportA, sessionID: sA.sessionID) { _ in }
        var sharedReboundSession: VideoPlaybackSession = sA
        let genA = sessions.bindViewport(viewportID: sharedViewport, sessionID: sA.sessionID) { sharedReboundSession = $0 }

        sA.start(autoPlay: true)
        try await waitUntilLoaded(sA)
        sA.setVolume(0.42)
        sA.setPlaybackRate(1.5)
        sA.toggleMute()

        let sARecovered = sessions.claim(url: urlA, viewportID: sharedViewport, isFullScreen: false, restart: true, caller: "recover_A")
        sARecovered.start(autoPlay: true)
        try await waitUntilLoaded(sARecovered)
        defer { sARecovered.stop(reason: "cleanup_A") }
        guard case .native(let nativeController) = sARecovered.activeController else {
            return XCTFail("Expected native controller on recovered MP4 session")
        }
        XCTAssertTrue(sARecovered.isMuted)
        XCTAssertEqual(sARecovered.volume, 0.0, accuracy: 0.001)
        XCTAssertEqual(sARecovered.previousVolume, 0.42, accuracy: 0.001)
        XCTAssertEqual(sARecovered.playbackRate, 1.5, accuracy: 0.001)
        XCTAssertTrue(nativeController.audioRenderer.isMuted)
        XCTAssertEqual(nativeController.audioRenderer.volume, 0.0, accuracy: 0.001)
        XCTAssertEqual(nativeController.playbackRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(nativeController.synchronizer.rate, 1.5, accuracy: 0.001)
        sARecovered.toggleMute()
        XCTAssertFalse(nativeController.audioRenderer.isMuted)
        XCTAssertEqual(nativeController.audioRenderer.volume, 0.42, accuracy: 0.001)

        // Switch from Video A to Video B on sharedViewport; oldViewportA disappears later.
        let sB = sessions.claim(url: urlB, viewportID: sharedViewport, isFullScreen: false, caller: "switch_to_B")
        defer { sB.stop(reason: "cleanup_B") }
        let genB = sessions.bindViewport(viewportID: sharedViewport, sessionID: sB.sessionID) { sharedReboundSession = $0 }
        XCTAssertGreaterThan(genB, genA)

        // Late release for oldViewportA on stale session sARecovered must remove oldViewportA's stale binding.
        sessions.release(sessionID: sARecovered.sessionID, viewportID: oldViewportA, caller: "late_disappear_oldViewportA")
        XCTAssertFalse(sessions.activeBoundViewportIDs.contains(oldViewportA), "Stale session release must clean up old viewport binding")

        // Late release and stale-generation unbind for sharedViewport (which is now bound to sB) must NOT remove sharedViewport's B binding.
        sessions.release(sessionID: sARecovered.sessionID, viewportID: sharedViewport, caller: "late_release_shared_from_A")
        XCTAssertFalse(sessions.unbindViewport(viewportID: sharedViewport, generation: genA))
        XCTAssertTrue(sessions.activeBoundViewportIDs.contains(sharedViewport))
        XCTAssertEqual(sessions.boundSessionID(for: sharedViewport), sB.sessionID)

        // Trigger restart on Video B from a full-window viewport and verify sharedViewport still receives the rebind callback.
        let fullWindowB = UUID()
        _ = sessions.claim(url: urlB, viewportID: fullWindowB, isFullScreen: true, caller: "open_B_fs")
        let sBRecovered = sessions.claim(url: urlB, viewportID: fullWindowB, isFullScreen: true, restart: true, caller: "recover_B_fs")
        defer { sBRecovered.stop(reason: "cleanup_B_recovered") }
        XCTAssertTrue(sharedReboundSession === sBRecovered, "New binding on sharedViewport must survive late release from Video A")
    }

    @MainActor
    private func makeHostView(for controller: AVAssetReaderPlaybackController, width: CGFloat, height: CGFloat, attachesImmediately: Bool) -> AVSampleBufferPlayerNSView {
        AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: width, height: height), renderer: AVSampleBufferRenderer(displayLayer: controller.displayLayer), synchronizer: controller.synchronizer, audioRenderer: controller.audioRenderer, attachesDisplayLayerImmediately: attachesImmediately)
    }

    @MainActor
    private func makeWorkerHostView(for controller: VideoPlaybackController, width: CGFloat, height: CGFloat, attachesImmediately: Bool) -> AVSampleBufferPlayerNSView {
        AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: width, height: height), renderer: AVSampleBufferRenderer(displayLayer: controller.displayLayer), synchronizer: controller.synchronizer, audioRenderer: controller.audioRenderer, attachesDisplayLayerImmediately: attachesImmediately)
    }

    @MainActor
    private func syncViews(session: VideoPlaybackSession, inspectorID: UUID, inspectorView: AVSampleBufferPlayerNSView, fullID: UUID, fullView: AVSampleBufferPlayerNSView) {
        inspectorView.updatePresentationOwnership(sessionID: session.sessionID, viewportID: inspectorID, isPresenting: session.activePresenterViewportID == inspectorID, reason: "sync_inspector")
        fullView.updatePresentationOwnership(sessionID: session.sessionID, viewportID: fullID, isPresenting: session.activePresenterViewportID == fullID, reason: "sync_full")
    }

    @MainActor
    func testRealMKVDirectTransportTenRoundTripsPausedAndPlayingWhenAvailable() async throws {
        guard let mkvPath = ProcessInfo.processInfo.environment["TTMEDIA_REAL_MKV_FIXTURE"], !mkvPath.isEmpty else {
            throw XCTSkip("Set TTMEDIA_REAL_MKV_FIXTURE=/path/to/sample.mkv to run real MKV DirectTransport session state round-trip test (validates session state only, not GUI window or XPC boundary)")
        }
        let url = URL(fileURLWithPath: mkvPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }

        let sessions = VideoPlaybackSessions()
        sessions.workerClientProvider = { MediaWorkerXPCClient(transport: MediaWorkerDirectTransport()) }
        let inspectorID = UUID()
        let session = sessions.claim(url: url, viewportID: inspectorID, isFullScreen: false, caller: "real_mkv_inspector")
        session.start(autoPlay: false)
        try await waitUntilLoaded(session)
        defer { session.stop(reason: "real_mkv_cleanup") }

        guard case .worker(let wc) = session.activeController else { return XCTFail("Expected worker controller for real 4K MKV") }
        await wc.seek(to: 120.0)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(session.isPlaying)
        XCTAssertEqual(CMTimeGetSeconds(session.currentTime), 120.0, accuracy: 2.0)

        for idx in 1...10 {
            let fullID = UUID()
            let enter = sessions.claim(url: url, viewportID: fullID, isFullScreen: true, caller: "real_mkv_paused_enter_\(idx)")
            enter.start(autoPlay: true)
            sessions.release(sessionID: session.sessionID, viewportID: inspectorID, caller: "real_mkv_paused_leave_insp_\(idx)")
            XCTAssertFalse(session.isPlaying)
            XCTAssertEqual(session.activePresenterViewportID, fullID)

            let exit = sessions.claim(url: url, viewportID: inspectorID, isFullScreen: false, caller: "real_mkv_paused_exit_\(idx)")
            exit.start(autoPlay: false)
            sessions.release(sessionID: session.sessionID, viewportID: fullID, caller: "real_mkv_paused_leave_full_\(idx)")
            XCTAssertFalse(session.isPlaying)
            XCTAssertEqual(session.activePresenterViewportID, inspectorID)
        }

        wc.togglePlayPause()
        session.isPlaying = wc.isPlaying
        XCTAssertTrue(session.isPlaying)
        for idx in 1...10 {
            let fullID = UUID()
            let enter = sessions.claim(url: url, viewportID: fullID, isFullScreen: true, caller: "real_mkv_play_enter_\(idx)")
            enter.start(autoPlay: true)
            sessions.release(sessionID: session.sessionID, viewportID: inspectorID, caller: "real_mkv_play_leave_insp_\(idx)")
            XCTAssertTrue(session.isPlaying)

            let exit = sessions.claim(url: url, viewportID: inspectorID, isFullScreen: false, caller: "real_mkv_play_exit_\(idx)")
            exit.start(autoPlay: false)
            sessions.release(sessionID: session.sessionID, viewportID: fullID, caller: "real_mkv_play_leave_full_\(idx)")
            XCTAssertTrue(session.isPlaying)
        }
    }

    @MainActor
    func testWorkerZeroFrameEOFTransitionsControllerAndSessionToVisibleTerminalError() async throws {
        let transport = ExhaustedPlaybackTransport()
        transport.zeroFrameEOF = true
        transport.holdFirstRead = true
        let controller = AVSampleBufferWorkerPlaybackController(
            url: URL(fileURLWithPath: "/tmp/zero_frame_eof.mkv"), client: MediaWorkerXPCClient(transport: transport)
        )
        await controller.startPlayback(autoPlay: true)
        let seekTask = Task { @MainActor in await controller.seek(to: 2.0) }
        transport.releaseHeldRead()
        await seekTask.value
        await controller.waitForInitialMediaReadinessOrFailure()
        XCTAssertEqual(controller.enqueuedVideoPacketCount, 0)
        XCTAssertFalse(controller.hasEnqueuedInitialMediaSample, "0-frame seek reply must never satisfy initial media readiness")
        XCTAssertFalse(controller.isLoading)
        XCTAssertFalse(controller.coordinator.isReady, "0-frame video EOF after seek must never leave coordinator.isReady == true")
        XCTAssertFalse(controller.isPlaying, "0-frame video EOF after seek must never fake isPlaying == true")
        XCTAssertNotNil(controller.fatalError)
        XCTAssertNotNil(controller.errorMessage)
        await controller.stop()

        let sessionTransport = ExhaustedPlaybackTransport()
        sessionTransport.zeroFrameEOF = true
        sessionTransport.holdFirstRead = true
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/zero_frame_session.mkv"))
        session.workerClientProvider = { MediaWorkerXPCClient(transport: sessionTransport) }
        session.start(autoPlay: true)
        try await Task.sleep(for: .milliseconds(15))
        session.seek(to: CMTime(seconds: 3.0, preferredTimescale: 600))
        XCTAssertTrue(session.isLoading, "Seeking during initial load must keep session.isLoading == true before first sample")
        XCTAssertFalse(session.isPlaying, "Seeking during initial load must not fake session.isPlaying == true")
        sessionTransport.releaseHeldRead()
        try await waitUntilLoaded(session)
        defer { session.stop(reason: "test_cleanup") }
        XCTAssertFalse(session.isPlaying, "Session must not report playing on 0-frame video EOF after initial seek")
        XCTAssertNotNil(session.playbackError, "Session must surface visible playbackError on 0-frame video EOF after initial seek")
        XCTAssertNil(session.activeController, "Failed 0-frame controller must be discarded on terminal error")
    }

    @MainActor
    func testWorkerAudioOnlyStreamPlaysNormallyWithoutZeroFrameVideoFailure() async {
        let transport = ExhaustedPlaybackTransport()
        transport.audioOnly = true
        let controller = AVSampleBufferWorkerPlaybackController(
            url: URL(fileURLWithPath: "/tmp/audio_only_valid.mkv"),
            client: MediaWorkerXPCClient(transport: transport)
        )
        await controller.startPlayback(autoPlay: true)
        await controller.waitForInitialMediaReadinessOrFailure()
        XCTAssertEqual(controller.enqueuedVideoPacketCount, 0)
        XCTAssertGreaterThanOrEqual(controller.enqueuedAudioPacketCount, 1)
        XCTAssertNil(controller.fatalError, "Normal audio-only stream must not be misclassified as 0-frame video failure")
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.isLoading)
        XCTAssertTrue(controller.coordinator.isReady)
        XCTAssertTrue(controller.isPlaying)
        await controller.stop()
    }

    @MainActor
    private func waitUntilLoaded(_ session: VideoPlaybackSession) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while session.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertFalse(session.isLoading)
    }
}
