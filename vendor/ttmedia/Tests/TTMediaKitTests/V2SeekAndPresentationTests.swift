// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import TTMediaKit

// MARK: - Deterministic Worker Transport Harness for V2 Seek & Presentation Tests

private final class V2SeekScriptedTransport: MediaWorkerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let metadata: [String: Any]
    private var initialPackets: [MediaPacketDTO]
    private var postSeekPacketFactory: @Sendable (Double) -> [MediaPacketDTO]
    private var activePackets: [MediaPacketDTO] = []
    private var activeSessionId: String?
    private(set) var seekTimestamps: [Double] = []
    var openDelayNanoseconds: UInt64 = 0
    var seekDelayProvider: (@Sendable (Double) -> UInt64)?

    init(
        metadata: [String: Any],
        initialPackets: [MediaPacketDTO],
        postSeekPacketFactory: @escaping @Sendable (Double) -> [MediaPacketDTO]
    ) {
        self.metadata = metadata
        self.initialPackets = initialPackets
        self.postSeekPacketFactory = postSeekPacketFactory
    }

    func openMedia(path: String, targetTracks: [Int]?) async throws -> (sessionId: String, metadata: [String: Any]) {
        if openDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: openDelayNanoseconds)
        }
        let sid = UUID().uuidString
        lock.withLock {
            activeSessionId = sid
            activePackets = initialPackets
        }
        return (sid, metadata)
    }

    func readNextPacket(sessionId: String) async throws -> Data? {
        let pkt: MediaPacketDTO? = try lock.withLock {
            guard activeSessionId == sessionId else {
                throw MediaWorkerError.sessionNotFound(sessionId)
            }
            guard !activePackets.isEmpty else { return nil }
            return activePackets.removeFirst()
        }
        guard let pkt else { return nil }
        return try JSONEncoder().encode(pkt)
    }

    func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double {
        let delayNanos = lock.withLock { seekDelayProvider?(timestamp) ?? 0 }
        if delayNanos > 0 {
            try await Task.sleep(nanoseconds: delayNanos)
        }
        let generated = postSeekPacketFactory(timestamp)
        return try lock.withLock {
            guard activeSessionId == sessionId else {
                throw MediaWorkerError.sessionNotFound(sessionId)
            }
            seekTimestamps.append(timestamp)
            activePackets = generated
            return timestamp
        }
    }

    func closeMedia(sessionId: String) async throws {
        lock.withLock {
            if activeSessionId == sessionId { activeSessionId = nil }
        }
    }

    func setSleepState(state: Int) async throws {}
    func invalidate() { lock.withLock { activeSessionId = nil } }
    func reconnect() async throws {}
    func setCrashHandler(_ handler: (@Sendable (MediaWorkerError) -> Void)?) {}
    var isConnected: Bool { lock.withLock { activeSessionId != nil } }
}

@MainActor
final class V2SeekAndPresentationTests: XCTestCase {

    // MARK: - Synthetic Media Helpers

    private static let minimalAvcC = Data([
        0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1, 0x00, 0x0D,
        0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x01, 0x40, 0x16,
        0xE8, 0x06, 0xD0, 0xA1, 0x35, 0x01, 0x00, 0x04,
        0x68, 0xCE, 0x3C, 0x80
    ])

    nonisolated private static let minimalVideoSlicePayload = Data([0x00, 0x00, 0x00, 0x02, 0x65, 0x01])

    private static func makeWorkerMetadata(
        pixelWidth: Int = 1920,
        pixelHeight: Int = 1080,
        displayWidth: Int? = nil,
        displayHeight: Int? = nil,
        dynamicRange: String? = "hdr10",
        bitDepth: Int? = 10,
        transferCharacteristics: String? = "SMPTE_ST_2084_PQ",
        codecName: String = "h264",
        rawCodecId: String = "V_MPEG4/ISO/AVC",
        subtitleTracks: [[String: Any]] = []
    ) -> [String: Any] {
        var videoDict: [String: Any] = [
            "trackIndex": 0,
            "codec": codecName == "av1" ? "av1" : "h264",
            "rawCodecId": rawCodecId,
            "codecName": codecName,
            "width": displayWidth ?? pixelWidth,
            "height": displayHeight ?? pixelHeight,
            "pixelWidth": pixelWidth,
            "pixelHeight": pixelHeight,
            "demuxSelectable": true,
            "isSelectedForPackets": true,
            "extradata": minimalAvcC
        ]
        if let bitDepth { videoDict["bitDepth"] = bitDepth }
        if let dynamicRange { videoDict["dynamicRange"] = dynamicRange }
        if let transferCharacteristics {
            videoDict["colorPrimaries"] = "ITU_R_2020"
            videoDict["transferCharacteristics"] = transferCharacteristics
            videoDict["matrixCoefficients"] = "ITU_R_2020_NCL"
        }
        if let displayWidth, let displayHeight {
            videoDict["displayWidth"] = displayWidth
            videoDict["displayHeight"] = displayHeight
        }
        return [
            "format": "matroska",
            "durationSeconds": 120.0,
            "metadataCapability": "v1_structured_contract_v1",
            "selectedVideoTrackNumber": 0,
            "videoTracks": [videoDict],
            "audioTracks": [],
            "catalogSubtitleTracks": subtitleTracks
        ]
    }

    nonisolated private static func makePacket(
        streamIndex: UInt32,
        isVideo: Bool,
        ptsSeconds: Double,
        durationSeconds: Double,
        payload: Data
    ) -> MediaPacketDTO {
        let ptsVal = Int64(ptsSeconds * 600.0)
        let durVal = Int64(durationSeconds * 600.0)
        // swiftlint:disable:next force_try
        return try! MediaPacketDTO(
            streamIndex: streamIndex,
            mediaType: isVideo ? .video : .audio,
            ptsValue: ptsVal,
            ptsTimescale: 600,
            dtsValue: ptsVal,
            dtsTimescale: 600,
            durationValue: durVal,
            durationTimescale: 600,
            payloadData: payload,
            isKeyframe: true,
            doNotDisplay: false
        )
    }

    nonisolated private static func makeVideoPacket(ptsSeconds: Double, durationSeconds: Double = 0.04) -> MediaPacketDTO {
        makePacket(streamIndex: 0, isVideo: true, ptsSeconds: ptsSeconds, durationSeconds: durationSeconds, payload: minimalVideoSlicePayload)
    }

    private static func makeReconstructedVideoSample(ptsSeconds: Double, durationSeconds: Double = 0.04) throws -> CMSampleBuffer {
        let reconstructor = SampleBufferReconstructor()
        let params = VideoFormatParameters(
            codec: .h264,
            width: 1920,
            height: 1080,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            extradata: minimalAvcC
        )
        let desc = try reconstructor.createVideoFormatDescription(from: params)
        return try reconstructor.reconstruct(packet: makeVideoPacket(ptsSeconds: ptsSeconds, durationSeconds: durationSeconds), formatDescription: desc)
    }

    nonisolated private static func makeAudioPacket(ptsSeconds: Double, durationSeconds: Double = 0.02) -> MediaPacketDTO {
        makePacket(streamIndex: 1, isVideo: false, ptsSeconds: ptsSeconds, durationSeconds: durationSeconds, payload: Data([0xDE, 0x04, 0x00, 0x20]))
    }

    private static func createTemporaryMP4(
        width: Int = 640,
        height: Int = 360,
        preferredTransform: CGAffineTransform = .identity,
        frameCount: Int = 15
    ) async throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("v2_test_\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = preferredTransform
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else {
                XCTFail("Missing pixelBufferPool")
                break
            }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            if let pixelBuffer {
                _ = adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(index * 20), timescale: 600))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return tempURL
    }

    // MARK: - Priority 1 (⑥): Coordinator & Worker Seek Intent, Long GOP & Out-of-Order Seeks

    func testCoordinatorSeekPreservesPlayingAndPausedIntentAndDiscardsPrerollAudio() throws {
        let coordinator = AVSampleBufferPlayerCoordinator()
        coordinator.prepare(duration: CMTime(seconds: 60.0, preferredTimescale: 600))
        coordinator.playbackRate = 1.5
        coordinator.volume = 0.65
        coordinator.isMuted = false

        // 1. Paused seek stays paused, suppresses pre-target frames, and completes only on target frame
        coordinator.pause()
        let pausedGen = coordinator.beginSeekIntent(to: CMTime(seconds: 12.0, preferredTimescale: 600))
        XCTAssertEqual(pausedGen, 1)
        XCTAssertFalse(coordinator.userPlaybackIntent)
        XCTAssertTrue(coordinator.isPrerolling)
        XCTAssertTrue(
            coordinator.shouldDiscardPrerollAudio(
                pts: CMTime(seconds: 11.5, preferredTimescale: 600),
                duration: CMTime(seconds: 0.02, preferredTimescale: 600)
            )
        )
        coordinator.enqueueVideoBuffer(try Self.makeReconstructedVideoSample(ptsSeconds: 11.0))
        XCTAssertTrue(coordinator.isPrerolling, "Pre-target frame must not end preroll")
        XCTAssertEqual(coordinator.preTargetSuppressedFrameCount, 1)
        coordinator.drainPrerollVideoQueueForBackpressure()
        XCTAssertTrue(coordinator.isPrerolling, "Draining backpressured preroll queue must keep preroll active")
        XCTAssertEqual(CMTimeGetSeconds(coordinator.currentTime), 12.0, accuracy: 0.001)

        coordinator.enqueueVideoBuffer(try Self.makeReconstructedVideoSample(ptsSeconds: 12.0))
        XCTAssertFalse(coordinator.isPrerolling)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(coordinator.synchronizer.rate, 0.0)
        XCTAssertEqual(CMTimeGetSeconds(coordinator.firstVisibleFramePTSAfterSeek ?? .zero), 12.0, accuracy: 0.001)

        // 2. Playing seek resumes at preserved playbackRate after target frame arrives
        coordinator.play()
        let playSeekGen = coordinator.beginSeekIntent(to: CMTime(seconds: 25.0, preferredTimescale: 600))
        XCTAssertEqual(playSeekGen, 2)
        coordinator.seek(to: CMTime(seconds: 25.0, preferredTimescale: 600), preroll: true, preserveCurrentIntent: true)
        XCTAssertEqual(coordinator.synchronizer.rate, 0.0, "Synchronizer rate is 0 during preroll")

        coordinator.enqueueVideoBuffer(try Self.makeReconstructedVideoSample(ptsSeconds: 25.0))
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(coordinator.synchronizer.rate, 1.5, accuracy: 0.001)
        XCTAssertEqual(coordinator.volume, 0.65, accuracy: 0.001)

        // 3. Explicit user pause during in-flight seek overrides pre-seek play intent
        _ = coordinator.beginSeekIntent(to: CMTime(seconds: 40.0, preferredTimescale: 600))
        coordinator.seek(to: CMTime(seconds: 40.0, preferredTimescale: 600), preroll: true, preserveCurrentIntent: true)
        coordinator.pause()
        coordinator.enqueueVideoBuffer(try Self.makeReconstructedVideoSample(ptsSeconds: 40.0))
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(coordinator.synchronizer.rate, 0.0)
        coordinator.teardown()
    }

    func testLongGOPSeekBackpressureDrainsPreTargetQueueWithoutDisplayingPreTargetFrames() async {
        // Keyframe at 0.0s, target at 10.0s: 9 pre-target frames (0.0s ..< 9.0s) before 10.0s
        let transport = V2SeekScriptedTransport(
            metadata: Self.makeWorkerMetadata(),
            initialPackets: [Self.makeVideoPacket(ptsSeconds: 0.0)],
            postSeekPacketFactory: { target in
                var pkts = (0..<9).map { idx in Self.makeVideoPacket(ptsSeconds: Double(idx) * 1.0) }
                pkts.append(Self.makeVideoPacket(ptsSeconds: target))
                pkts.append(Self.makeVideoPacket(ptsSeconds: target + 0.04))
                return pkts
            }
        )
        let controller = AVSampleBufferWorkerPlaybackController(
            url: URL(fileURLWithPath: "/tmp/v2_long_gop_seek.mkv"),
            client: MediaWorkerXPCClient(transport: transport)
        )
        controller.backpressurePollIntervalNanos = 1_000_000
        controller.prerollBackpressureDrainThreshold = 2
        controller.coordinator.playbackRate = 1.5

        // Simulate hardware video queue filling up every 3 pre-target frames until drained
        var queuedSinceDrain = 0
        controller.coordinator.onPrerollQueueDrained = { queuedSinceDrain = 0 }
        controller.videoQueueReadinessOverride = { [weak controller] in
            guard let controller else { return true }
            if controller.coordinator.isPrerolling {
                let suppressed = controller.coordinator.preTargetSuppressedFrameCount
                let drains = controller.coordinator.prerollBackpressureDrainCount
                queuedSinceDrain = suppressed - (drains * 3)
                return queuedSinceDrain < 3
            }
            return true
        }

        await controller.startPlayback(autoPlay: true)
        try? await Task.sleep(nanoseconds: 30_000_000)

        // 1. Playing long-GOP seek to 10.0s (queue saturates 3 times before reaching 10.0s)
        await controller.seek(to: 10.0)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertGreaterThanOrEqual(controller.coordinator.prerollBackpressureDrainCount, 3)
        XCTAssertEqual(controller.coordinator.preTargetSuppressedFrameCount, 9)
        XCTAssertEqual(CMTimeGetSeconds(controller.coordinator.firstVisibleFramePTSAfterSeek ?? .zero), 10.0, accuracy: 0.001)
        XCTAssertFalse(controller.coordinator.isPrerolling)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.coordinator.synchronizer.rate, 1.5, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(controller.coordinator.currentTime), 10.0)

        // 2. Paused long-GOP seek to 12.0s (queue saturates 3 times before reaching 12.0s, stays paused)
        controller.togglePlayPause()
        XCTAssertFalse(controller.isPlaying)
        await controller.seek(to: 12.0)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertGreaterThanOrEqual(controller.coordinator.prerollBackpressureDrainCount, 3)
        XCTAssertEqual(controller.coordinator.preTargetSuppressedFrameCount, 9)
        XCTAssertEqual(CMTimeGetSeconds(controller.coordinator.firstVisibleFramePTSAfterSeek ?? .zero), 12.0, accuracy: 0.001)
        XCTAssertFalse(controller.coordinator.isPrerolling)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(controller.userPlaybackIntent)
        XCTAssertEqual(controller.coordinator.synchronizer.rate, 0.0)
        XCTAssertEqual(CMTimeGetSeconds(controller.coordinator.currentTime), 12.0, accuracy: 0.001)

        await controller.stop()
    }

    func testWorkerControllerSeekPreservesPlayingAndPausedStateAndOutOfOrderOverlappingSeeks() async {
        let transport = V2SeekScriptedTransport(
            metadata: Self.makeWorkerMetadata(),
            initialPackets: [Self.makeVideoPacket(ptsSeconds: 0.0), Self.makeVideoPacket(ptsSeconds: 0.04)],
            postSeekPacketFactory: { target in
                [
                    Self.makeAudioPacket(ptsSeconds: max(0.0, target - 0.5)),
                    Self.makeVideoPacket(ptsSeconds: target),
                    Self.makeVideoPacket(ptsSeconds: target + 0.04)
                ]
            }
        )
        // Earlier seek (10.0s) is delayed 90ms in transport; newer seek (35.0s) finishes in 10ms
        transport.seekDelayProvider = { target in target < 20.0 ? 90_000_000 : 10_000_000 }
        let client = MediaWorkerXPCClient(transport: transport)
        let controller = AVSampleBufferWorkerPlaybackController(url: URL(fileURLWithPath: "/tmp/v2_worker_seek.mkv"), client: client)
        controller.coordinator.playbackRate = 1.25
        controller.coordinator.volume = 0.75

        await controller.startPlayback(autoPlay: true)
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(controller.isPlaying)

        // Launch slow seek(10.0) first, then fast seek(35.0) 15ms later so 10.0 returns AFTER 35.0 completes
        let firstSeekTask = Task { @MainActor in await controller.seek(to: 10.0) }
        try? await Task.sleep(nanoseconds: 15_000_000)
        let secondSeekTask = Task { @MainActor in await controller.seek(to: 35.0) }
        await firstSeekTask.value
        await secondSeekTask.value
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertGreaterThanOrEqual(controller.ignoredStaleSeekResponseCount, 1, "Late out-of-order seek response must be ignored")
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(controller.userPlaybackIntent)
        XCTAssertEqual(controller.coordinator.playbackRate, 1.25, accuracy: 0.001)
        XCTAssertEqual(controller.coordinator.volume, 0.75, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(controller.coordinator.firstVisibleFramePTSAfterSeek ?? .zero), 35.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(controller.coordinator.currentTime), 35.0)

        // Pause then seek -> stays paused
        controller.togglePlayPause()
        await controller.seek(to: 45.0)
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(controller.userPlaybackIntent)
        XCTAssertEqual(controller.coordinator.synchronizer.rate, 0.0)

        await controller.stop()
    }

    // MARK: - Priority 1 (⑥): Native AVAssetReader Seek & Rotation Geometry

    func testNativeAssetReaderSeekPreservesIntentAndExtractsRotationGeometry() async throws {
        let rotatedTransform = CGAffineTransform(rotationAngle: .pi / 2)
        let mp4URL = try await Self.createTemporaryMP4(
            width: 640,
            height: 360,
            preferredTransform: rotatedTransform
        )
        defer { try? FileManager.default.removeItem(at: mp4URL) }

        let controller = AVAssetReaderPlaybackController(url: mp4URL)
        controller.registersWithCoordinator = false
        controller.playbackRate = 1.5
        controller.volume = 0.5

        try await controller.load(autoPlay: true)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(controller.userPlaybackIntent)
        XCTAssertEqual(controller.rawVideoNaturalSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(controller.videoRotationDegrees, 90)
        XCTAssertEqual(controller.naturalSize, CGSize(width: 360, height: 640))

        // Seek while playing -> remains playing
        controller.seek(to: CMTime(seconds: 0.1, preferredTimescale: 600))
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(controller.userPlaybackIntent)
        XCTAssertEqual(controller.playbackRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(controller.volume, 0.5, accuracy: 0.001)
        XCTAssertEqual(controller.seekGeneration, 1)

        // Pause then seek -> remains paused
        controller.pause()
        XCTAssertFalse(controller.isPlaying)
        controller.seek(to: CMTime(seconds: 0.05, preferredTimescale: 600))
        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(controller.userPlaybackIntent)
        XCTAssertEqual(controller.seekGeneration, 2)

        controller.stop()
    }

    func testCanvasControlBarExclusionZonePreventsClickBubblePause() {
        let displayLayer = AVSampleBufferDisplayLayer()
        let sync = AVSampleBufferRenderSynchronizer()
        let audio = AVSampleBufferAudioRenderer()
        let nsView = AVSampleBufferPlayerNSView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 500),
            renderer: AVSampleBufferRenderer(displayLayer: displayLayer),
            synchronizer: sync,
            audioRenderer: audio
        )
        nsView.isControlBarVisible = true
        nsView.bottomControlBarExclusionHeight = 96.0

        // Point inside bottom 96pt control bar area (in AppKit unflipped coordinates: y = 24)
        XCTAssertTrue(nsView.shouldIgnoreCanvasClick(at: CGPoint(x: 400, y: 24)))
        // Point in upper video canvas area (y = 300)
        XCTAssertFalse(nsView.shouldIgnoreCanvasClick(at: CGPoint(x: 400, y: 300)))

        // When control bar is hidden, bottom area is clickable again
        nsView.isControlBarVisible = false
        XCTAssertFalse(nsView.shouldIgnoreCanvasClick(at: CGPoint(x: 400, y: 24)))
    }

    // MARK: - Feedback ①: Silent Loading Indicator Threshold & Error Preservation

    func testSilentLoadingSuppressesFastLoadAndShowsOnlyOnSlowLoad() async {
        let fastTransport = V2SeekScriptedTransport(
            metadata: Self.makeWorkerMetadata(),
            initialPackets: [Self.makeVideoPacket(ptsSeconds: 0.0)],
            postSeekPacketFactory: { _ in [] }
        )
        let fastSession = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/v2_fast.mkv"))
        fastSession.loadingIndicatorDelayNanoseconds = 200_000_000
        fastSession.workerClientProvider = { MediaWorkerXPCClient(transport: fastTransport) }
        fastSession.start(autoPlay: false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(fastSession.isShowingLoadingIndicator)
        fastSession.stop()

        let slowTransport = V2SeekScriptedTransport(
            metadata: Self.makeWorkerMetadata(),
            initialPackets: [Self.makeVideoPacket(ptsSeconds: 0.0)],
            postSeekPacketFactory: { _ in [] }
        )
        slowTransport.openDelayNanoseconds = 160_000_000
        let slowSession = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/v2_slow.mkv"))
        slowSession.loadingIndicatorDelayNanoseconds = 30_000_000
        slowSession.workerClientProvider = { MediaWorkerXPCClient(transport: slowTransport) }
        slowSession.start(autoPlay: false)
        try? await Task.sleep(nanoseconds: 140_000_000)
        XCTAssertTrue(slowSession.isShowingLoadingIndicator, "Slow load must show loading indicator after threshold")
        try? await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertFalse(slowSession.isShowingLoadingIndicator, "Loading indicator must hide once load completes")
        slowSession.stop()
    }

    // MARK: - Feedback ④: 3-Second Cursor & Control Bar Synchronization

    func testCursorAndControlBarHideAfterInactivityAndRestoreBalancedOnAllTriggers() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
        var hideEvents = 0
        var unhideEvents = 0
        let cursorController = ViewportCursorVisibilityController(
            hideAction: { hideEvents += 1 },
            unhideAction: { unhideEvents += 1 }
        )
        let visibility = MediaControlsVisibility(inactivityDuration: .milliseconds(60), cursorController: cursorController)
        visibility.isPlaying = true
        visibility.setHovered(true)
        XCTAssertTrue(visibility.isVisible)
        XCTAssertFalse(visibility.isCursorHidden)

        try? await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertFalse(visibility.isVisible)
        XCTAssertTrue(visibility.isCursorHidden)
        XCTAssertEqual(hideEvents, 1)

        visibility.recordMouseMove(at: CGPoint(x: 120, y: 120))
        XCTAssertTrue(visibility.isVisible)
        XCTAssertFalse(visibility.isCursorHidden)
        XCTAssertEqual(unhideEvents, 1)

        try? await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertFalse(visibility.isVisible)
        XCTAssertTrue(visibility.isCursorHidden)
        visibility.isPlaying = false
        XCTAssertFalse(visibility.isVisible, "Pausing while controls are hidden must not reveal UI")
        XCTAssertFalse(visibility.isCursorHidden, "Pausing must still restore a hidden system cursor")
        XCTAssertEqual(unhideEvents, 2)

        visibility.isPlaying = true
        XCTAssertFalse(visibility.isVisible, "Resuming from pause must not reveal UI")
        visibility.recordMouseMove(at: CGPoint(x: 160, y: 160))
        XCTAssertTrue(visibility.isVisible)
        visibility.setScrubbing(true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(visibility.isVisible)
        XCTAssertFalse(visibility.isCursorHidden)
        visibility.setScrubbing(false)

        try? await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertFalse(visibility.isVisible)
        XCTAssertTrue(visibility.isCursorHidden)
        visibility.setHovered(false)
        XCTAssertFalse(visibility.isCursorHidden)
        XCTAssertEqual(cursorController.hideCallCount, cursorController.unhideCallCount)
    }

    // MARK: - Feedback ③ (S1): Video Content Rect, Single Rotation/PAR, Fallback & Subtitle Format

    func testVideoContentGeometrySingleRotationAndAnamorphicPARWithoutDoubleTransform() {
        let viewport = CGSize(width: 1600, height: 900)
        let rotatedRect = VideoContentGeometry.contentRect(
            inside: viewport,
            rawVideoSize: CGSize(width: 1920, height: 1080),
            pixelAspectRatio: CGSize(width: 1, height: 1),
            rotationDegrees: 90
        )
        XCTAssertEqual(rotatedRect.height, 900.0, accuracy: 0.5)
        XCTAssertEqual(rotatedRect.width, 506.25, accuracy: 0.5)
        XCTAssertEqual(rotatedRect.minX, (1600.0 - 506.25) * 0.5, accuracy: 0.5)

        let s1Geometry = SubtitleVideoContentGeometry(
            viewportSize: viewport,
            videoNaturalSize: CGSize(width: 1920, height: 1080),
            pixelAspectRatio: CGSize(width: 1, height: 1),
            rotationDegrees: 90,
            explicitVideoRect: rotatedRect
        )
        let s1Resolution = SubtitleRelativeSizingResolver.resolveVideoContentRect(for: s1Geometry)
        XCTAssertEqual(s1Resolution.source, .explicitRect)
        XCTAssertEqual(s1Resolution.rect.width, rotatedRect.width, accuracy: 0.01)
        XCTAssertEqual(s1Resolution.rect.height, rotatedRect.height, accuracy: 0.01)

        let par = VideoContentGeometry.pixelAspectRatio(pixelWidth: 1440, pixelHeight: 1080, displayWidth: 1920, displayHeight: 1080)
        XCTAssertEqual(par, CGSize(width: 4, height: 3))
        let anamorphicRect = VideoContentGeometry.contentRect(
            inside: viewport,
            rawVideoSize: CGSize(width: 1440, height: 1080),
            pixelAspectRatio: par,
            rotationDegrees: 0
        )
        XCTAssertEqual(anamorphicRect.width, 1600.0, accuracy: 0.5)
        XCTAssertEqual(anamorphicRect.height, 900.0, accuracy: 0.5)

        let converted = VideoContentGeometry.convertLayerVideoRectToViewport(
            layerVideoRect: CGRect(x: 0, y: 50, width: 800, height: 300),
            layerBounds: CGRect(x: 0, y: 0, width: 800, height: 400),
            viewportSize: CGSize(width: 1600, height: 800),
            isLayerGeometryFlipped: true
        )
        XCTAssertEqual(converted, CGRect(x: 0, y: 100, width: 1600, height: 600))
    }

    func testTemporaryFallbackImmediatelyReplacedByRealTrackGeometryAndActiveSubtitleCodec() async {
        let viewport = CGSize(width: 1600, height: 1200)
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/v2_geometry_sub.mkv"))

        XCTAssertNil(session.rawVideoNaturalSize)
        XCTAssertNil(session.videoContentRect(in: viewport))
        let preLoadRes = SubtitleRelativeSizingResolver.resolveVideoContentRect(for: session.subtitleVideoGeometry(for: viewport))
        XCTAssertEqual(preLoadRes.source, .canonicalAspectFallback)
        XCTAssertNil(session.lastKnownVideoContentRect)

        let subtitleCatalog: [[String: Any]] = [
            ["playbackTrackId": 10, "containerTrackNumber": 3, "trackIndex": 2, "codec": "pgs", "codecName": "hdmv_pgs_subtitle", "rawCodecId": "S_HDMV/PGS", "isImageBased": true],
            ["playbackTrackId": 11, "containerTrackNumber": 4, "trackIndex": 3, "codec": "ass", "codecName": "ass", "rawCodecId": "S_TEXT/ASS", "isImageBased": false]
        ]
        let transport = V2SeekScriptedTransport(
            metadata: Self.makeWorkerMetadata(pixelWidth: 1920, pixelHeight: 800, subtitleTracks: subtitleCatalog),
            initialPackets: [Self.makeVideoPacket(ptsSeconds: 0.0)],
            postSeekPacketFactory: { _ in [] }
        )
        session.workerClientProvider = { MediaWorkerXPCClient(transport: transport) }
        session.start(autoPlay: false)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(session.rawVideoNaturalSize, CGSize(width: 1920, height: 800))
        let postLoadRes = SubtitleRelativeSizingResolver.resolveVideoContentRect(for: session.subtitleVideoGeometry(for: viewport))
        XCTAssertEqual(postLoadRes.source, .explicitRect)
        XCTAssertEqual(postLoadRes.rect.width, 1600.0, accuracy: 0.5)
        XCTAssertEqual(postLoadRes.rect.height, 666.67, accuracy: 0.5)
        XCTAssertNotNil(session.lastKnownVideoContentRect)

        session.selectedSubtitleID = "embedded:10"
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: session.activeSubtitleCodec), .bitmapUntouched)
        session.selectedSubtitleID = "embedded:11"
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: session.activeSubtitleCodec), .assPlainTextExtracts)
        session.selectedSubtitleID = URL(fileURLWithPath: "/tmp/external.sup").absoluteString
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: session.activeSubtitleCodec), .bitmapUntouched)
        session.selectedSubtitleID = URL(fileURLWithPath: "/tmp/external.srt").absoluteString
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: session.activeSubtitleCodec), .textOverlay)
        session.stop()
    }

    func testProductionSessionSubtitleStyleUpdateDoesNotAlterProgressPlayStateOrSubtitleGeneration() async {
        let transport = V2SeekScriptedTransport(
            metadata: Self.makeWorkerMetadata(),
            initialPackets: [Self.makeVideoPacket(ptsSeconds: 0.0), Self.makeVideoPacket(ptsSeconds: 0.04)],
            postSeekPacketFactory: { target in [Self.makeVideoPacket(ptsSeconds: target)] }
        )
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/v2_style_invariance.mkv"))
        session.workerClientProvider = { MediaWorkerXPCClient(transport: transport) }
        session.start(autoPlay: true)
        try? await Task.sleep(nanoseconds: 150_000_000)

        session.subtitleTrack = ExternalSubtitleTrack(cues: [.init(start: 0.0, end: 60.0, text: "Primary line")])
        session.secondarySubtitleTrack = ExternalSubtitleTrack(cues: [.init(start: 0.0, end: 60.0, text: "Secondary line")])
        session.seek(to: CMTime(seconds: 18.5, preferredTimescale: 600))
        try? await Task.sleep(nanoseconds: 60_000_000)

        let timeBefore = CMTimeGetSeconds(session.currentTime)
        let seekGenBefore = session.seekGeneration
        let primarySubGenBefore = session.subtitleLoadGeneration
        let secondarySubGenBefore = session.secondarySubtitleLoadGeneration

        var updatedStyle = session.subtitleStyle
        updatedStyle.scale = 1.25
        updatedStyle.relativeFontRatio = 0.06
        updatedStyle.fontFamilyName = "PingFang SC"
        session.updateSubtitleStyle(updatedStyle)

        XCTAssertEqual(CMTimeGetSeconds(session.currentTime), timeBefore, accuracy: 0.1)
        XCTAssertEqual(session.seekGeneration, seekGenBefore)
        XCTAssertTrue(session.isPlaying)
        XCTAssertTrue(session.userPlaybackIntent)
        XCTAssertEqual(session.subtitleLoadGeneration, primarySubGenBefore)
        XCTAssertEqual(session.secondarySubtitleLoadGeneration, secondarySubGenBefore)
        XCTAssertEqual(session.activeSubtitleText, "Primary line")
        XCTAssertEqual(session.activeSecondarySubtitleText, "Secondary line")
        session.stop()
    }

    // MARK: - Priority 2 (②): Honest HDR / Dolby Vision Source vs Output & Screen Switching

    func testHonestHDRDolbyVisionSourceVsOutputAndScreenSwitchingContracts() async {
        // 1. Missing dynamic range & bitDepth evidence -> sourceDynamicRange == .unknown, bitDepth == nil
        let missingEvidenceMeta = Self.makeWorkerMetadata(
            dynamicRange: nil,
            bitDepth: nil,
            transferCharacteristics: nil,
            codecName: "h264"
        )
        let missingInfo = TTMediaStreamInfo(sessionId: "s-missing", dictionary: missingEvidenceMeta)
        let missingState = AVSampleBufferWorkerPlaybackController.makeFormatPresentationState(from: missingInfo.videoTracks[0])
        XCTAssertEqual(missingState.sourceDynamicRange, .unknown, "Missing color/HDR evidence must not guess SDR")
        XCTAssertEqual(missingState.activeOutputDynamicRange, .unknown)
        XCTAssertNil(missingState.bitDepth, "Missing bitDepth must remain nil instead of guessing 8")
        XCTAssertFalse(missingState.isToneMappedFallbackToSDR)
        XCTAssertEqual(
            VideoFormatPresentationState.detectDynamicRange(formatDescription: nil, rawCodecName: "H264", transferFunctionHint: nil),
            .unknown
        )

        // 2. Dolby Vision + AV1 must NOT assume SDR tone-mapping from codec name alone; output is .unknown until observed
        let doviAv1Meta = Self.makeWorkerMetadata(
            pixelWidth: 3840,
            pixelHeight: 2160,
            dynamicRange: "dolby_vision",
            bitDepth: 10,
            transferCharacteristics: "SMPTE_ST_2084_PQ",
            codecName: "av1",
            rawCodecId: "dav1"
        )
        let doviInfo = TTMediaStreamInfo(sessionId: "s-dovi", dictionary: doviAv1Meta)
        let doviState = AVSampleBufferWorkerPlaybackController.makeFormatPresentationState(from: doviInfo.videoTracks[0])
        XCTAssertEqual(doviState.sourceDynamicRange, .dolbyVision)
        XCTAssertEqual(doviState.activeOutputDynamicRange, .unknown, "Output dynamic range must be .unknown when rendering output is unobserved")
        XCTAssertFalse(doviState.isToneMappedFallbackToSDR, "Dolby Vision + AV1 must not claim SDR tone-mapping without renderer confirmation")
        XCTAssertEqual(doviState.bitDepth, 10)

        // 3. Screen capability alone (without renderer confirmation) keeps activeOutputDynamicRange == .unknown
        let unconfirmedEDR = doviState.applyingDisplayObservation(.init(screenSupportsEDR: true, isHDRPresentationConfirmed: false))
        XCTAssertEqual(unconfirmedEDR.activeOutputDynamicRange, .unknown)
        XCTAssertFalse(unconfirmedEDR.isToneMappedFallbackToSDR)

        let unconfirmedSDRScreen = doviState.applyingDisplayObservation(.init(screenSupportsEDR: false, isToneMappedFallbackConfirmed: false))
        XCTAssertEqual(unconfirmedSDRScreen.activeOutputDynamicRange, .unknown)
        XCTAssertFalse(unconfirmedSDRScreen.isToneMappedFallbackToSDR)

        // 4. Confirmed EDR HDR presentation: never borrows source Dolby Vision; PQ sample transfer confirms .hdr10
        let unconfirmedWithoutSampleTR = doviState.applyingDisplayObservation(.init(screenSupportsEDR: true, isHDRPresentationConfirmed: true))
        XCTAssertEqual(unconfirmedWithoutSampleTR.activeOutputDynamicRange, .unknown, "Must not borrow source Dolby Vision to claim Dolby Vision output")
        let confirmedEDR = doviState.applyingDisplayObservation(.init(screenSupportsEDR: true, isHDRPresentationConfirmed: true, observedSampleDynamicRange: .hdr10))
        XCTAssertEqual(confirmedEDR.sourceDynamicRange, .dolbyVision)
        XCTAssertEqual(confirmedEDR.activeOutputDynamicRange, .hdr10)
        XCTAssertFalse(confirmedEDR.isToneMappedFallbackToSDR)

        // 5. Switching from EDR screen to SDR screen invalidates HDR; confirmed SDR sample transitions to .sdr
        let switchedToSDRUnconfirmed = confirmedEDR.applyingDisplayObservation(.init(screenSupportsEDR: false, isToneMappedFallbackConfirmed: false, observedSampleDynamicRange: .hdr10))
        XCTAssertEqual(switchedToSDRUnconfirmed.activeOutputDynamicRange, .unknown)
        XCTAssertFalse(switchedToSDRUnconfirmed.isToneMappedFallbackToSDR)
        let confirmedFallback = switchedToSDRUnconfirmed.applyingDisplayObservation(.init(screenSupportsEDR: false, isToneMappedFallbackConfirmed: true, observedSampleDynamicRange: .sdr))
        XCTAssertEqual(confirmedFallback.sourceDynamicRange, .dolbyVision)
        XCTAssertEqual(confirmedFallback.activeOutputDynamicRange, .sdr)
        XCTAssertTrue(confirmedFallback.isToneMappedFallbackToSDR)
        XCTAssertEqual(confirmedFallback.badgeText, "SDR")
        XCTAssertEqual(confirmedFallback.namedSourceAndOutputBadgeText, "源 4K · AV1 | 输出 SDR")
        XCTAssertTrue(confirmedFallback.comparisonSnapshot.outputSection.colorMappingText.contains("DoVi → SDR"))
    }

    // MARK: - Priority 3 (③): W1 Exact SessionID Handoff & Enqueue vs Visual Telemetry

    func testSessionBridgeHandoffAndFormatBadgeAndTelemetryContracts() throws {
        let url = URL(fileURLWithPath: "/tmp/v2_bridge_handoff.mp4")
        let inspectorViewport = UUID()
        let fullScreenViewport = UUID()

        let handle = VideoPlaybackSessionBridge.acquireSessionHandle(for: url, viewportID: inspectorViewport, isFullScreen: false)
        XCTAssertEqual(VideoPlaybackSessionBridge.activeSessionHandle(for: url), handle)

        // Stale handle with the SAME URL but a DIFFERENT sessionID must be rejected
        let staleSameURLHandle = VideoPlaybackSessionHandle(sessionID: UUID(), canonicalURL: handle.canonicalURL, sourceURL: url)
        XCTAssertNil(VideoPlaybackSessionBridge.performHandoff(staleSameURLHandle, toViewportID: fullScreenViewport, isFullScreen: true))
        XCTAssertFalse(VideoPlaybackSessionBridge.handoffSession(staleSameURLHandle, toViewportID: fullScreenViewport, isFullScreen: true))

        // Exact sessionID handoff succeeds synchronously and returns verified VideoPlaybackSessionHandoffResult
        let handoffResult = try XCTUnwrap(
            VideoPlaybackSessionBridge.performHandoff(handle, toViewportID: fullScreenViewport, isFullScreen: true)
        )
        XCTAssertTrue(handoffResult.didHandoff)
        XCTAssertEqual(handoffResult.sessionID, handle.sessionID)
        XCTAssertEqual(handoffResult.targetViewportID, fullScreenViewport)
        XCTAssertEqual(handoffResult.activePresenterViewportID, fullScreenViewport)
        VideoPlaybackSessionBridge.releaseViewport(handle: handle, viewportID: fullScreenViewport)
        VideoPlaybackSessionBridge.releaseViewport(handle: handle, viewportID: inspectorViewport)

        // Verify onFirstVideoFrameEnqueued fires AFTER displayLayer.enqueue and records sample enqueue (not visual presentation)
        let coordinator = AVSampleBufferPlayerCoordinator()
        coordinator.prepare(duration: CMTime(seconds: 10.0, preferredTimescale: 600))
        var callbackPTS: CMTime?
        coordinator.onFirstVideoFrameEnqueued = { pts in callbackPTS = pts }
        coordinator.enqueueVideoBuffer(try Self.makeReconstructedVideoSample(ptsSeconds: 0.0))
        XCTAssertEqual(CMTimeGetSeconds(callbackPTS ?? .invalid), 0.0, accuracy: 0.001)
        coordinator.teardown()

        var telemetry = VideoPlaybackTelemetryMetrics()
        telemetry.recordLoadStart(at: 10.0)
        telemetry.recordFirstVideoSampleEnqueued(at: 10.12)
        telemetry.recordSeekRequested(at: 20.0)
        telemetry.recordSeekPipelineCompleted(at: 20.045)
        XCTAssertTrue(telemetry.hasEnqueuedFirstVideoSample)
        XCTAssertEqual(telemetry.firstVideoSampleEnqueueLatencyMs ?? 0, 120.0, accuracy: 0.1)
        XCTAssertNil(telemetry.firstFrameVisualPresentationLatencyMs, "Pipeline enqueue must not claim visual first-frame presentation")
        XCTAssertFalse(telemetry.hasVerifiedVisualFirstFramePresentation)
        XCTAssertEqual(telemetry.lastSeekPipelineCompletionLatencyMs ?? 0, 45.0, accuracy: 0.1)
        XCTAssertNil(telemetry.lastSeekVisiblePresentationLatencyMs, "Pipeline seek completion must not claim visible screen presentation")
        XCTAssertEqual(telemetry.completedSeekCount, 1)
    }
}
