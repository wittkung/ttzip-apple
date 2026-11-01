// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import CoreAudioTypes
import CoreMedia
import Foundation
import TTI18nCore
import TTMediaDemux
import XCTest
@testable import TTMediaKit

// MARK: - Deterministic Transport & XPC Harness for V2 Verification

private final class V2ScriptedWorkerTransport: MediaWorkerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let metadataBuilder: @Sendable () -> [String: Any]
    private var packets: [MediaPacketDTO]
    private let crashAfterPacketCount: Int?
    private let onPacketReadHook: (@Sendable (Int) async -> Void)?
    private var crashHandler: (@Sendable (MediaWorkerError) -> Void)?
    private var activeSessionId: String?
    private var readCount = 0
    private(set) var readPacketCalls = 0
    private(set) var crashHandlerInvocations = 0
    private(set) var closeMediaCalls = 0
    private(set) var reconnectCalls = 0
    private(set) var seekTimestamps: [Double] = []

    init(
        metadataBuilder: @escaping @Sendable () -> [String: Any],
        packets: [MediaPacketDTO],
        crashAfterPacketCount: Int? = nil,
        onPacketReadHook: (@Sendable (Int) async -> Void)? = nil
    ) {
        self.metadataBuilder = metadataBuilder
        self.packets = packets
        self.crashAfterPacketCount = crashAfterPacketCount
        self.onPacketReadHook = onPacketReadHook
    }

    func openMedia(path: String, targetTracks: [Int]?) async throws -> (sessionId: String, metadata: [String: Any]) {
        let sid = UUID().uuidString
        lock.withLock {
            activeSessionId = sid
            readCount = 0
            readPacketCalls = 0
        }
        return (sid, metadataBuilder())
    }

    func readNextPacket(sessionId: String) async throws -> Data? {
        let step: (index: Int, packet: MediaPacketDTO?, handler: (@Sendable (MediaWorkerError) -> Void)?) = try lock.withLock {
            guard activeSessionId == sessionId else {
                throw MediaWorkerError.sessionNotFound(sessionId)
            }
            readPacketCalls += 1
            if let crashLimit = crashAfterPacketCount, readCount >= crashLimit {
                crashHandlerInvocations += 1
                return (readCount, nil, crashHandler)
            }
            guard !packets.isEmpty else {
                return (readCount, nil, nil)
            }
            let current = readCount
            readCount += 1
            return (current, packets.removeFirst(), nil)
        }
        if let handler = step.handler {
            handler(.connectionInvalidated)
            throw MediaWorkerError.connectionInvalidated
        }
        if let hook = onPacketReadHook {
            await hook(step.index)
        }
        guard let pkt = step.packet else { return nil }
        return try JSONEncoder().encode(pkt)
    }

    func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double {
        try lock.withLock {
            guard activeSessionId == sessionId else {
                throw MediaWorkerError.sessionNotFound(sessionId)
            }
            seekTimestamps.append(timestamp)
            return timestamp
        }
    }

    func closeMedia(sessionId: String) async throws {
        lock.withLock {
            closeMediaCalls += 1
            if activeSessionId == sessionId { activeSessionId = nil }
        }
    }

    func setSleepState(state: Int) async throws {}
    func invalidate() { lock.withLock { activeSessionId = nil } }
    func reconnect() async throws { lock.withLock { reconnectCalls += 1 } }
    func setCrashHandler(_ handler: (@Sendable (MediaWorkerError) -> Void)?) {
        lock.withLock { crashHandler = handler }
    }
    var isConnected: Bool { lock.withLock { activeSessionId != nil } }
}

private final class V2RealServiceXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = MediaWorkerService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface.makeMediaWorkerInterface()
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

private final class V2LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&storage) }
    }
}

// MARK: - V2 Audio Fault Isolation & V1 Track Metadata Contract Tests

final class V2AudioFaultIsolationTests: XCTestCase {

    // Minimal valid H.264 avcC extradata & IDR slice (Baseline 320x240)
    private static let sampleH264AvcC = Data([
        0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1, 0x00, 0x0D,
        0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x01, 0x40, 0x16,
        0xE8, 0x06, 0xD0, 0xA1, 0x35, 0x01, 0x00, 0x04,
        0x68, 0xCE, 0x3C, 0x80
    ])
    private static let sampleH264Frame = Data([0x00, 0x00, 0x00, 0x02, 0x65, 0x01])

    // Valid 2-byte AudioSpecificConfig for AAC-LC 48kHz Stereo (0x11, 0x90)
    private static let validAACAudioSpecificConfig = Data([0x11, 0x90])

    override func tearDown() async throws {
        await MainActor.run {
            PreviewSessionCoordinator.shared.cancelCurrentSession()
        }
        try await super.tearDown()
    }

    // MARK: - 1. V1 Contract Fixtures (S1, S2, S3a, S3b) & Native -> DirectTransport -> Real XPC Parity

    func testV1ContractFixturesS1NormalAACAndS2RefV6FiveChannelAC3() throws {
        let s1JSON = """
        {
          "schema_version": 1, "container_format": "matroska", "duration_nanos": 1000000000,
          "has_cues_index": true, "selected_video_track_number": 1, "selected_audio_track_number": 2, "primary_audio_track_number": 2,
          "selected_tracks": [
            { "container_track_number": 1, "packet_stream_index": 1, "media_type": "video", "raw_codec_id": "V_MPEG4/ISO/AVC", "canonical_codec": "h264", "demux_selectable": true, "is_selected_for_packets": true, "is_primary_track": true, "codec_private_format": "avcc", "codec_private_hex": "0164001fffe100046764001f01000468ebecb2", "codec_private_sha256": "ec41522b7bd01bc876ef8be6c37371588bfaa74c90913d76d090400dc2ed115b", "video": { "pixel_width": 64, "pixel_height": 64, "effective_width": 64, "effective_height": 64 } },
            { "container_track_number": 2, "packet_stream_index": 2, "media_type": "audio", "raw_codec_id": "A_AAC", "canonical_codec": "aac", "demux_selectable": true, "is_selected_for_packets": true, "is_primary_track": true, "codec_private_format": "aac_asc", "codec_private_hex": "1190", "codec_private_sha256": "76a5cd432c5f936a406ceebbe96f3a8448fb5e1ceee9b1aa2f1f14e3d2148ab2", "audio": { "sample_rate_hz": 48000.0, "sample_rate_source": "mkv_sampling_frequency", "channels": 2, "channels_source": "mkv_channels" } }
          ],
          "tracks_catalog": []
        }
        """.data(using: .utf8)!

        let s1 = try TTMediaStreamInfo(sessionId: "s1", v1ContractJSON: s1JSON)
        XCTAssertEqual(s1.format, "matroska")
        XCTAssertEqual(s1.durationSeconds, 1.0, accuracy: 1e-6)
        XCTAssertTrue(s1.hasCuesIndex)
        XCTAssertEqual(s1.selectedVideoTrackNumber, 1)
        XCTAssertEqual(s1.selectedAudioTrackNumber, 2)
        XCTAssertEqual(s1.videoTracks.first?.trackIndex, 1)
        XCTAssertEqual(s1.videoTracks.first?.codec, .h264)
        XCTAssertEqual(s1.videoTracks.first?.rawCodecId, "V_MPEG4/ISO/AVC")
        XCTAssertEqual(s1.videoTracks.first?.width, 64)
        XCTAssertEqual(s1.videoTracks.first?.height, 64)
        XCTAssertEqual(s1.audioTracks.first?.trackIndex, 2)
        XCTAssertEqual(s1.audioTracks.first?.codec, .aac)
        XCTAssertEqual(s1.audioTracks.first?.rawCodecId, "A_AAC")
        XCTAssertEqual(s1.audioTracks.first?.sampleRate, 48000.0)
        XCTAssertEqual(s1.audioTracks.first?.channels, 2)
        XCTAssertEqual(s1.audioTracks.first?.extradata, Data([0x11, 0x90]))
        XCTAssertEqual(s1.audioTracks.first?.codecPrivateFormat, "aac_asc")

        let s2JSON = """
        {"schema_version":1,"container_format":"matroska","duration_nanos":1020000000,"has_cues_index":false,"selected_video_track_number":1,"selected_audio_track_number":2,"primary_audio_track_number":2,"selected_tracks":[{"container_track_number":1,"packet_stream_index":1,"media_type":"video","raw_codec_id":"V_MPEG4/ISO/AVC","canonical_codec":"h264","demux_selectable":true,"is_selected_for_packets":true,"codec_private_format":"avcc","codec_private_hex":"0164001f","video":{"effective_width":1280,"effective_height":720}},{"container_track_number":2,"packet_stream_index":2,"media_type":"audio","raw_codec_id":"A_AC3","canonical_codec":"ac3","demux_selectable":true,"is_selected_for_packets":true,"codec_private_format":"absent","audio":{"sample_rate_hz":48000.0,"channels":5}}],"tracks_catalog":[{"container_track_number":1,"packet_stream_index":1,"media_type":"video","raw_codec_id":"V_MPEG4/ISO/AVC","canonical_codec":"h264","demux_selectable":true,"is_selected_for_packets":true,"video":{"effective_width":1280,"effective_height":720}},{"container_track_number":2,"packet_stream_index":2,"media_type":"audio","raw_codec_id":"A_AC3","canonical_codec":"ac3","demux_selectable":true,"is_selected_for_packets":true,"audio":{"sample_rate_hz":48000.0,"channels":5}},{"container_track_number":3,"packet_stream_index":3,"media_type":"subtitle","raw_codec_id":"S_TEXT/UTF8","canonical_codec":"unknown","demux_selectable":false,"is_selected_for_packets":false}]}
        """.data(using: .utf8)!

        let s2 = try TTMediaStreamInfo(sessionId: "s2", v1ContractJSON: s2JSON)
        XCTAssertEqual(s2.audioTracks.count, 1)
        XCTAssertEqual(s2.audioTracks[0].trackIndex, 2)
        XCTAssertEqual(s2.audioTracks[0].codec, .ac3)
        XCTAssertEqual(s2.audioTracks[0].rawCodecId, "A_AC3")
        XCTAssertEqual(s2.audioTracks[0].channels, 5)
        XCTAssertEqual(s2.audioTracks[0].sampleRate, 48000.0)
        XCTAssertNil(s2.audioTracks[0].extradata)
    }

    func testV1ContractFixturesS3aMultiAudioAndS3bMissingCodecPrivate() throws {
        let s3aJSON = """
        {"schema_version":1,"container_format":"matroska","duration_nanos":1000000000,"has_cues_index":true,"selected_video_track_number":1,"selected_audio_track_number":2,"primary_audio_track_number":2,"selected_tracks":[{"container_track_number":1,"packet_stream_index":1,"media_type":"video","raw_codec_id":"V_MPEG4/ISO/AVC","canonical_codec":"h264","demux_selectable":true,"is_selected_for_packets":true,"codec_private_hex":"0164001f","video":{"effective_width":64,"effective_height":64}},{"container_track_number":2,"packet_stream_index":2,"media_type":"audio","raw_codec_id":"A_AAC","canonical_codec":"aac","demux_selectable":true,"is_selected_for_packets":true,"codec_private_format":"aac_asc","codec_private_hex":"1190","audio":{"sample_rate_hz":48000.0,"channels":2}}],"tracks_catalog":[{"container_track_number":2,"packet_stream_index":2,"media_type":"audio","raw_codec_id":"A_AAC","canonical_codec":"aac","demux_selectable":true,"is_selected_for_packets":true,"codec_private_format":"aac_asc","codec_private_hex":"1190","audio":{"sample_rate_hz":48000.0,"channels":2}},{"container_track_number":3,"packet_stream_index":3,"media_type":"audio","raw_codec_id":"A_AC3","canonical_codec":"ac3","demux_selectable":true,"is_selected_for_packets":false,"audio":{"sample_rate_hz":48000.0,"channels":6}}]}
        """.data(using: .utf8)!

        let s3a = try TTMediaStreamInfo(sessionId: "s3a", v1ContractJSON: s3aJSON)
        XCTAssertEqual(s3a.selectedAudioTrackNumber, 2)
        XCTAssertEqual(s3a.audioTracks.count, 1)
        XCTAssertEqual(s3a.catalogAudioTracks.count, 2)
        XCTAssertEqual(s3a.catalogAudioTracks[1].trackIndex, 3)
        XCTAssertFalse(s3a.catalogAudioTracks[1].isSelectedForPackets)

        let s3bJSON = """
        {"schema_version":1,"container_format":"matroska","duration_nanos":1000000000,"has_cues_index":false,"selected_video_track_number":1,"selected_audio_track_number":2,"primary_audio_track_number":2,"selected_tracks":[{"container_track_number":1,"packet_stream_index":1,"media_type":"video","raw_codec_id":"V_MPEG4/ISO/AVC","canonical_codec":"h264","demux_selectable":true,"is_selected_for_packets":true,"codec_private_hex":"0164001f","video":{"effective_width":64,"effective_height":64}},{"container_track_number":2,"packet_stream_index":2,"media_type":"audio","raw_codec_id":"A_AAC","canonical_codec":"aac","demux_selectable":true,"is_selected_for_packets":true,"codec_private_format":"missing","audio":{"sample_rate_hz":48000.0,"channels":2}}],"tracks_catalog":[]}
        """.data(using: .utf8)!

        let s3b = try TTMediaStreamInfo(sessionId: "s3b", v1ContractJSON: s3bJSON)
        XCTAssertEqual(s3b.audioTracks.first?.codecPrivateFormat, "missing")
        XCTAssertNil(s3b.audioTracks.first?.extradata)
    }

    func testV1NativeToDirectTransportToRealXPCMetadataParity() async throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixtureRoot = ProcessInfo.processInfo.environment["TEST_SRCDIR"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("_main/infra/ttmedia/Tests")
        } ?? sourceRoot
        let clipURL = fixtureRoot.appendingPathComponent("Fixtures/preview/video/clip.mkv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipURL.path))

        // Stage 1: V1 Native C-ABI (ttmedia_demux_open + ttmedia_demux_query_tracks_json)
        var handle: UnsafeMutableRawPointer?
        var cInfo = TTMediaDemux.TTMediaStreamInfo()
        let openStatus = clipURL.path.withCString { ttmedia_demux_open($0, &handle, &cInfo) }
        XCTAssertEqual(openStatus, 0)
        guard let validHandle = handle else {
            XCTFail("Expected non-nil native demuxer handle")
            return
        }
        defer { ttmedia_demux_close(validHandle) }

        var requiredLen = 0
        XCTAssertEqual(ttmedia_demux_query_tracks_json(UnsafeRawPointer(validHandle), nil, 0, &requiredLen), 0)
        XCTAssertGreaterThan(requiredLen, 0)
        var jsonBuf = [CChar](repeating: 0, count: requiredLen + 1)
        var writtenLen = 0
        let copyStatus = jsonBuf.withUnsafeMutableBufferPointer { ptr in
            ttmedia_demux_query_tracks_json(UnsafeRawPointer(validHandle), ptr.baseAddress, ptr.count, &writtenLen)
        }
        XCTAssertEqual(copyStatus, 0)
        let v1NativeJSON = Data(bytes: jsonBuf, count: writtenLen)
        let nativeInfo = try TTMediaStreamInfo(sessionId: "native", v1ContractJSON: v1NativeJSON)

        // Stage 2: DirectTransport
        let directTransport = MediaWorkerDirectTransport()
        let directOpened = try await directTransport.openMedia(path: clipURL.path, targetTracks: nil)
        defer { Task { try? await directTransport.closeMedia(sessionId: directOpened.sessionId) } }
        let directInfo = TTMediaStreamInfo(sessionId: directOpened.sessionId, dictionary: directOpened.metadata)

        // Stage 3: Real XPC Service (NSXPCListener.anonymous + MediaWorkerService + MediaWorkerXPCTransport)
        let xpcDelegate = V2RealServiceXPCListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = xpcDelegate
        listener.resume()
        defer { listener.invalidate() }

        let xpcTransport = MediaWorkerXPCTransport(endpoint: listener.endpoint, useFileHandleCapability: true)
        let xpcClient = MediaWorkerXPCClient(transport: xpcTransport)
        let xpcInfo = try await xpcClient.open(url: clipURL)
        defer { Task { try? await xpcClient.close(sessionId: xpcInfo.sessionId) } }

        // Compare all 3 stages
        XCTAssertEqual(nativeInfo.format, directInfo.format)
        XCTAssertEqual(directInfo.format, xpcInfo.format)
        XCTAssertEqual(nativeInfo.metadataCapability, "v1_structured_contract_v1")
        XCTAssertEqual(directInfo.metadataCapability, "v1_structured_contract_v1")
        XCTAssertEqual(xpcInfo.metadataCapability, "v1_structured_contract_v1")
        XCTAssertEqual(nativeInfo.selectedVideoTrackNumber, directInfo.selectedVideoTrackNumber)
        XCTAssertEqual(directInfo.selectedVideoTrackNumber, xpcInfo.selectedVideoTrackNumber)
        XCTAssertEqual(nativeInfo.selectedAudioTrackNumber, directInfo.selectedAudioTrackNumber)
        XCTAssertEqual(directInfo.selectedAudioTrackNumber, xpcInfo.selectedAudioTrackNumber)
        XCTAssertEqual(nativeInfo.videoTracks, directInfo.videoTracks)
        XCTAssertEqual(directInfo.videoTracks, xpcInfo.videoTracks)
        XCTAssertEqual(nativeInfo.audioTracks, directInfo.audioTracks)
        XCTAssertEqual(directInfo.audioTracks, xpcInfo.audioTracks)
        XCTAssertEqual(nativeInfo.catalogVideoTracks, xpcInfo.catalogVideoTracks)
        XCTAssertEqual(nativeInfo.catalogAudioTracks, xpcInfo.catalogAudioTracks)
    }

    // MARK: - 2. Backpressure Recovery, Pause/AutoPlay/Seek Protection & Explicit Renderer Failure

    @MainActor
    func testNormalAudioTemporaryBackpressureRecoversWithoutIsolation() async throws {
        let transport = V2ScriptedWorkerTransport(
            metadataBuilder: { Self.makeValidAVMetadata() },
            packets: Self.makeInterleavedAVPackets(count: 4)
        )
        let client = MediaWorkerXPCClient(transport: transport)
        let controller = AVSampleBufferWorkerPlaybackController(
            url: URL(fileURLWithPath: "/tmp/v2_backpressure_recover.mkv"),
            client: client
        )
        let pipeline = controller.audioPipeline
        let pollCount = V2LockedBox(0)
        pipeline.readinessOverride = {
            pollCount.withValue { count in
                count += 1
                return count >= 4
            }
        }
        controller.backpressurePollIntervalNanos = 2_000_000 // 2ms

        await controller.startPlayback(autoPlay: true)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertFalse(controller.isAudioIsolated, "Temporary backpressure that recovers must not isolate the audio track")
        XCTAssertNil(controller.audioFault)
        XCTAssertNil(controller.fatalError)
        XCTAssertGreaterThanOrEqual(controller.enqueuedAudioPacketCount, 2)
        XCTAssertGreaterThanOrEqual(controller.enqueuedVideoPacketCount, 2)
        XCTAssertTrue(pipeline.isAttachedToSynchronizer)
        await controller.stop()
    }

    @MainActor
    func testAutoPlayFalsePauseAndSeekDoNotMisclassifyBackpressureAsFault() async throws {
        let transport = V2ScriptedWorkerTransport(
            metadataBuilder: { Self.makeValidAVMetadata() },
            packets: Self.makeInterleavedAVPackets(count: 4)
        )
        let client = MediaWorkerXPCClient(transport: transport)
        let controller = AVSampleBufferWorkerPlaybackController(
            url: URL(fileURLWithPath: "/tmp/v2_pause_seek_protect.mkv"),
            client: client
        )
        let releaseBackpressure = V2LockedBox(false)
        controller.audioPipeline.readinessOverride = { releaseBackpressure.withValue { $0 } }
        controller.backpressurePollIntervalNanos = 2_000_000
        controller.stallPollThreshold = 5

        // Start with autoPlay = false while audio renderer is not ready (simulating prebuffer full while paused)
        await controller.startPlayback(autoPlay: false)
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(controller.isAudioIsolated, "Paused / autoPlay=false prebuffering must never trigger stall isolation")
        XCTAssertNil(controller.audioFault)

        // Release backpressure, seek while paused, and verify no false isolation
        releaseBackpressure.withValue { $0 = true }
        await controller.seek(to: 0.5)
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertFalse(controller.isAudioIsolated, "Seeking must not misclassify backpressure as an audio fault")
        XCTAssertEqual(transport.seekTimestamps, [0.5])
        await controller.stop()
    }

    @MainActor
    func testExplicitRendererFailureUnblocksBackpressureAndAdvancesVideo() async throws {
        let transport = V2ScriptedWorkerTransport(
            metadataBuilder: { Self.makeValidAVMetadata() },
            packets: Self.makeInterleavedAVPackets(count: 6)
        )
        let client = MediaWorkerXPCClient(transport: transport)
        let controller = AVSampleBufferWorkerPlaybackController(
            url: URL(fileURLWithPath: "/tmp/v2_renderer_failed.mkv"),
            client: client
        )
        let pipeline = controller.audioPipeline
        let coordinator = controller.coordinator

        // Simulate renderer stuck not-ready and reporting explicit AVQueuedSampleBufferRenderingStatus.failed ('fmt?')
        pipeline.readinessOverride = { false }
        pipeline.rendererFailureOverride = {
            NSError(domain: NSOSStatusErrorDomain, code: 1_718_449_215, userInfo: [NSLocalizedDescriptionKey: "kAudioConverterErr_FormatNotSupported"])
        }
        controller.backpressurePollIntervalNanos = 2_000_000

        var reportedFault: AVSampleBufferAudioFault?
        controller.onAudioFault = { fault in reportedFault = fault }

        await controller.startPlayback(autoPlay: true)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(controller.isAudioIsolated, "Explicit renderer failure must isolate audio")
        XCTAssertNotNil(reportedFault)
        XCTAssertEqual(reportedFault?.kind, .audioInitializationFailed)
        XCTAssertFalse(pipeline.isAttachedToSynchronizer, "Failed audio renderer must be detached from synchronizer")
        XCTAssertNil(controller.fatalError, "Audio isolation must not produce a fatal playback error")
        XCTAssertTrue(controller.isPlaying, "Video playback must remain active after audio isolation")
        XCTAssertEqual(controller.enqueuedVideoPacketCount, 3, "All video packets must continue to be enqueued after audio isolation")
        XCTAssertGreaterThan(CMTimeGetSeconds(coordinator.synchronizer.currentTime()), 0.0, "Synchronizer clock must advance after audio renderer detachment")
        await controller.stop()
    }

    @MainActor
    func testPersistentStallWithFrozenClockIsolatesAudioAndRestoresVideoClock() async throws {
        var controllerRef: AVSampleBufferWorkerPlaybackController?
        let transport = V2ScriptedWorkerTransport(
            metadataBuilder: { Self.makeValidAVMetadata() },
            packets: Self.makeInterleavedAVPackets(count: 6),
            onPacketReadHook: { index in
                if index == 1 {
                    await MainActor.run {
                        // Simulate broken audio renderer MasterClock holding synchronizer rate at 0 despite isPlaying = true
                        controllerRef?.coordinator.synchronizer.setRate(0.0, time: .zero)
                    }
                }
            }
        )
        let client = MediaWorkerXPCClient(transport: transport)
        let controller = AVSampleBufferWorkerPlaybackController(
            url: URL(fileURLWithPath: "/tmp/v2_persistent_stall.mkv"),
            client: client
        )
        controllerRef = controller
        let pipeline = controller.audioPipeline
        let coordinator = controller.coordinator

        // Allow first audio packet to enqueue, then block readiness while keeping synchronizer clock frozen at 0
        let checkCount = V2LockedBox(0)
        pipeline.readinessOverride = {
            checkCount.withValue { count in
                count += 1
                return count <= 1
            }
        }
        controller.backpressurePollIntervalNanos = 2_000_000
        controller.stallPollThreshold = 5

        await controller.startPlayback(autoPlay: true)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(controller.isAudioIsolated, "Persistent stall with play intent + queued packets + frozen clock must isolate audio")
        XCTAssertFalse(pipeline.isAttachedToSynchronizer)
        XCTAssertEqual(controller.enqueuedVideoPacketCount, 3)
        XCTAssertGreaterThan(coordinator.synchronizer.rate, 0.0, "Isolating stalled audio renderer must restore synchronizer playback rate")
        await controller.stop()
    }

    // MARK: - 3. AAC Configuration Evidence vs. Unsubstantiated Guessing & Multi-Track Stream Index Verification

    func testMissingOrInvalidAACConfigurationIsRejectedWithoutFabricatingAACLC() throws {
        let pipeline = AVSampleBufferAudioPipeline()

        // 1. Missing extradata must not fabricate AAC-LC 48kHz Stereo cookie; packet enqueue without ADTS throws missingCodecConfiguration
        let missingParams = AudioFormatParameters(
            codec: .aac,
            sampleRate: 48000.0,
            channelCount: 2,
            bitsPerChannel: 16,
            channelLayoutTag: 0,
            extradata: Data()
        )
        let rawFormatDesc = try pipeline.createAudioFormatDescription(from: missingParams)
        var cookieSize = 0
        XCTAssertNil(
            CMAudioFormatDescriptionGetMagicCookie(rawFormatDesc, sizeOut: &cookieSize),
            "Missing AAC extradata must not fabricate a synthetic magic cookie"
        )
        let rawAACPacket = try MediaPacketDTO(
            streamIndex: 2, mediaType: .audio,
            ptsValue: 0, ptsTimescale: 1000, dtsValue: 0, dtsTimescale: 1000,
            durationValue: 21, durationTimescale: 1000,
            payloadData: Data([0xDE, 0x04, 0x00, 0x26]), isKeyframe: true, doNotDisplay: false
        )
        XCTAssertThrowsError(try pipeline.reconstructAndEnqueue(packet: rawAACPacket, formatDescription: rawFormatDesc)) { error in
            guard case AVSampleBufferAudioPipelineError.missingCodecConfiguration = error else {
                XCTFail("Expected missingCodecConfiguration for raw AAC without extradata or ADTS, got \(error)")
                return
            }
        }

        // 2. Corrupted / zero-object-type AudioSpecificConfig (0x00, 0x00) must throw invalidCodecConfiguration
        let invalidASCParams = AudioFormatParameters(
            codec: .aac,
            sampleRate: 48000.0,
            channelCount: 2,
            bitsPerChannel: 16,
            channelLayoutTag: 0,
            extradata: Data([0x00, 0x00])
        )
        XCTAssertThrowsError(try pipeline.createAudioFormatDescription(from: invalidASCParams))

        // 3. Sampling frequency index 0x0E (reserved) must throw invalidCodecConfiguration
        let reservedFreqASC = Data([0x17, 0x00]) // AOT=2, freqIndex=14 (reserved)
        XCTAssertThrowsError(try AVSampleBufferAudioPipeline.validateAACAudioSpecificConfig(reservedFreqASC))

        // 4. Valid 2-byte AudioSpecificConfig (0x11, 0x90 -> AAC-LC 48kHz 2ch) succeeds
        let validParams = AudioFormatParameters(
            codec: .aac,
            sampleRate: 48000.0,
            channelCount: 2,
            bitsPerChannel: 16,
            channelLayoutTag: 0,
            extradata: Self.validAACAudioSpecificConfig
        )
        let formatDesc = try pipeline.createAudioFormatDescription(from: validParams)
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        XCTAssertEqual(asbd?.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(asbd?.mSampleRate ?? 0, 48000.0, accuracy: 1.0)
        XCTAssertEqual(asbd?.mChannelsPerFrame, 2)

        // 5. Valid 7-byte ADTS header extraction (AAC-LC 44.1kHz Stereo, frameLength = 9)
        let adtsFrame = Data([0xFF, 0xF1, 0x50, 0x80, 0x01, 0x3F, 0xFC, 0xDE, 0x04])
        let extractedASC = AVSampleBufferAudioPipeline.extractADTSAudioSpecificConfig(from: adtsFrame)
        XCTAssertEqual(extractedASC?.asc, Data([0x12, 0x10]))
        XCTAssertEqual(extractedASC?.headerLength, 7)
    }

    func testRefV6FiveChannelAC3AndChannelLayoutVerification() throws {
        let pipeline = AVSampleBufferAudioPipeline()

        // 1. REF-V6 5-channel AC-3 with channelLayoutTag == 0 must NOT assign kAudioChannelLayoutTag_Stereo
        let ac3FiveChParams = AudioFormatParameters(
            codec: .ac3,
            sampleRate: 48000.0,
            channelCount: 5,
            bitsPerChannel: 0,
            channelLayoutTag: 0,
            extradata: Data()
        )
        let desc = try pipeline.createAudioFormatDescription(from: ac3FiveChParams)
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
        XCTAssertEqual(asbd?.mFormatID, kAudioFormatAC3)
        XCTAssertEqual(asbd?.mChannelsPerFrame, 5)
        XCTAssertEqual(asbd?.mSampleRate ?? 0, 48000.0, accuracy: 1.0)

        var layoutSize: Int = 0
        let layoutPtr = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: &layoutSize)
        if let layoutPtr, layoutSize > 0 {
            XCTAssertNotEqual(
                layoutPtr.pointee.mChannelLayoutTag,
                kAudioChannelLayoutTag_Stereo,
                "5-channel AC-3 must never be assigned a Stereo channel layout tag"
            )
        }

        // 2. Mismatched explicit channelLayoutTag (e.g. Stereo tag with 5 channels) must be rejected
        let mismatchedParams = AudioFormatParameters(
            codec: .ac3,
            sampleRate: 48000.0,
            channelCount: 5,
            bitsPerChannel: 0,
            channelLayoutTag: kAudioChannelLayoutTag_Stereo,
            extradata: Data()
        )
        XCTAssertThrowsError(try pipeline.createAudioFormatDescription(from: mismatchedParams))
    }

    @MainActor
    func testMultiTrackAudioPacketStreamIndexVerificationIgnoresUnselectedTrackPackets() async throws {
        let packets: [MediaPacketDTO] = [
            try MediaPacketDTO(
                streamIndex: 1, mediaType: .video, ptsValue: 0, ptsTimescale: 1000, dtsValue: 0, dtsTimescale: 1000,
                durationValue: 33, durationTimescale: 1000, payloadData: Self.sampleH264Frame, isKeyframe: true, doNotDisplay: false
            ),
            try MediaPacketDTO(
                streamIndex: 3, mediaType: .audio, ptsValue: 0, ptsTimescale: 1000, dtsValue: 0, dtsTimescale: 1000,
                durationValue: 21, durationTimescale: 1000, payloadData: Data([0x0B, 0x77, 0x01, 0x02]), isKeyframe: true, doNotDisplay: false
            ),
            try MediaPacketDTO(
                streamIndex: 2, mediaType: .audio, ptsValue: 0, ptsTimescale: 1000, dtsValue: 0, dtsTimescale: 1000,
                durationValue: 21, durationTimescale: 1000, payloadData: Data([0xDE, 0x04, 0x00, 0x26, 0x20, 0x00]), isKeyframe: true, doNotDisplay: false
            )
        ]

        let transport = V2ScriptedWorkerTransport(
            metadataBuilder: {
                [
                    "format": "matroska", "durationSeconds": 1.0,
                    "selectedVideoTrackNumber": 1, "selectedAudioTrackNumber": 2,
                    "metadataCapability": "v1_structured_contract_v1",
                    "videoTracks": [
                        ["trackIndex": 1, "codec": "h264", "rawCodecId": "V_MPEG4/ISO/AVC", "width": 320, "height": 240, "extradata": Self.sampleH264AvcC, "isSelectedForPackets": true]
                    ],
                    "audioTracks": [
                        ["trackIndex": 2, "codec": "aac", "rawCodecId": "A_AAC", "sampleRate": 48000.0, "channels": 2, "extradata": Self.validAACAudioSpecificConfig, "isSelectedForPackets": true],
                        ["trackIndex": 3, "codec": "ac3", "rawCodecId": "A_AC3", "sampleRate": 48000.0, "channels": 6, "isSelectedForPackets": false]
                    ]
                ]
            },
            packets: packets
        )
        let controller = AVSampleBufferWorkerPlaybackController(
            url: URL(fileURLWithPath: "/tmp/v2_multitrack_filter.mkv"),
            client: MediaWorkerXPCClient(transport: transport)
        )

        await controller.startPlayback(autoPlay: true)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.ignoredMismatchedStreamPackets, 1, "Packet from unselected audio track 3 must be filtered out")
        XCTAssertEqual(controller.enqueuedAudioPacketCount, 1, "Packet from selected audio track 2 must be enqueued")
        XCTAssertFalse(controller.isAudioIsolated)
        await controller.stop()
    }

    // MARK: - 4. Fatal Errors (Container Corruption, Legacy C-ABI Missing Identity, Worker Crash)

    @MainActor
    func testVideoPacketWithoutValidTrackConfigurationMustFailWithContainerCorrupted() async throws {
        let missingVideoConfigTransport = V2ScriptedWorkerTransport(
            metadataBuilder: { ["format": "matroska", "durationSeconds": 10.0, "videoTracks": [], "audioTracks": []] },
            packets: Self.makeInterleavedAVPackets(count: 2)
        )
        let missingConfigClient = MediaWorkerXPCClient(transport: missingVideoConfigTransport)
        let missingConfigSession = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/v2_missing_video_track_config.mkv"))
        missingConfigSession.workerClientProvider = { missingConfigClient }
        missingConfigSession.start(autoPlay: true)
        let deadline = ContinuousClock.now + .seconds(2)
        while (missingConfigSession.isLoading || missingVideoConfigTransport.closeMediaCalls == 0), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(missingConfigSession.isLoading)
        XCTAssertNotNil(missingConfigSession.playbackError, "Video packet arriving without valid videoTrack config must report fatal error")
        XCTAssertEqual(missingConfigSession.playbackFaultCategory, .containerCorrupted)
        XCTAssertFalse(missingConfigSession.isPlaying)
        XCTAssertNil(missingConfigSession.activeController, "Corrupted container controller must be discarded on initial load failure")
        XCTAssertEqual(missingVideoConfigTransport.closeMediaCalls, 1, "Broken worker session must be closed cleanly")
        XCTAssertNil(missingConfigClient.activeSessionId, "Broken worker session must not remain active after close")
        XCTAssertEqual(missingVideoConfigTransport.crashHandlerInvocations, 0, "Container error must not fake a worker crash")
        XCTAssertEqual(missingConfigClient.crashCount, 0)
        XCTAssertEqual(missingVideoConfigTransport.reconnectCalls, 0, "Healthy worker connection must not enter recovery or restart")
        XCTAssertEqual(missingConfigClient.lifecycleState, .warmStandby, "Healthy worker connection must return to warmStandby after closing broken container session")
        missingConfigSession.stop(reason: "test_cleanup")
    }

    @MainActor
    func testContainerCorruptedLegacyCAbiAndWorkerCrashProduceFatalPlaybackError() async throws {
        // 1. Legacy C-ABI missing track identity -> fatal .containerCorrupted
        let legacyTransport = V2ScriptedWorkerTransport(
            metadataBuilder: {
                [
                    "format": "matroska", "durationSeconds": 1.0,
                    "metadataCapability": "legacy_c_abi_missing_track_identity",
                    "metadata": ["metadataCapability": "legacy_c_abi_missing_track_identity"],
                    "videoTracks": [["trackIndex": -1, "codec": "h264", "width": 320, "height": 240]]
                ]
            },
            packets: []
        )
        let legacySession = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/v2_legacy_cabi.mkv"))
        legacySession.workerClientProvider = { MediaWorkerXPCClient(transport: legacyTransport) }
        legacySession.start(autoPlay: true)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNotNil(legacySession.playbackError, "Legacy C-ABI missing track identity must surface a fatal compatibility error")
        XCTAssertEqual(legacySession.playbackFaultCategory, .containerCorrupted)
        XCTAssertFalse(legacySession.isPlaying)
        legacySession.stop(reason: "test_cleanup")

        // 2. Scheduled mid-stream Worker crash with valid minimal metadata & packets must reach crash index, fire invalidation callback, and enter .crashed
        let crashTransport = V2ScriptedWorkerTransport(
            metadataBuilder: { Self.makeValidAVMetadata() },
            packets: Self.makeInterleavedAVPackets(count: 6),
            crashAfterPacketCount: 2
        )
        let crashClient = MediaWorkerXPCClient(transport: crashTransport)
        let crashSession = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/v2_worker_crash.mkv"))
        crashSession.workerClientProvider = { crashClient }
        crashSession.start(autoPlay: true)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(crashTransport.readPacketCalls, 3, "Must pump packets 1 and 2 normally and reach scheduled crash on packet 3")
        XCTAssertEqual(crashTransport.crashHandlerInvocations, 1, "Must invoke transport connection invalidation callback")
        XCTAssertEqual(crashClient.lifecycleState, .crashed, "Client lifecycle state must transition to .crashed")
        XCTAssertNotNil(crashSession.playbackError, "Worker crash must stop playback and display fatal error")
        XCTAssertEqual(crashSession.playbackFaultCategory, .workerCrashed)
        XCTAssertFalse(crashSession.isPlaying)
        crashSession.stop(reason: "test_cleanup")
    }

    // MARK: - 5. Stale Session Isolation & Full-Window Transfer State Preservation

    @MainActor
    func testStaleControllerCallbacksIgnoredAndFullWindowTransferPreservesState() async throws {
        let urlA = URL(fileURLWithPath: "/tmp/v2_session_a.mkv")
        let urlB = URL(fileURLWithPath: "/tmp/v2_session_b.mkv")

        let sessionA = VideoPlaybackSession(url: urlA)
        let staleTransport = V2ScriptedWorkerTransport(metadataBuilder: { Self.makeValidAVMetadata() }, packets: [])
        let staleController = AVSampleBufferWorkerPlaybackController(url: urlA, client: MediaWorkerXPCClient(transport: staleTransport))
        let activeTransport = V2ScriptedWorkerTransport(metadataBuilder: { Self.makeValidAVMetadata() }, packets: [])
        let activeController = AVSampleBufferWorkerPlaybackController(url: urlA, client: MediaWorkerXPCClient(transport: activeTransport))

        sessionA.activeController = .worker(activeController)
        staleController.onAudioFault?(
            AVSampleBufferAudioFault(kind: .unsupportedAudioTrack, codecName: "dts", statusCode: nil, diagnosticDetail: "stale")
        )
        XCTAssertFalse(sessionA.isAudioFaultIsolated, "Late callback from non-active controller must not mutate active session")

        sessionA.applyAudioFault(
            AVSampleBufferAudioFault(kind: .unsupportedAudioTrack, codecName: "A_DTS", statusCode: nil, diagnosticDetail: "Unsupported audio codec")
        )
        sessionA.seek(to: CMTime(seconds: 42.5, preferredTimescale: 600))
        sessionA.setPlaybackRate(1.5)
        sessionA.selectedSubtitleID = "embedded:0"

        let transferredSession = VideoPlaybackSession(url: urlB)
        transferredSession.restorePreservedContext(from: sessionA)

        XCTAssertEqual(CMTimeGetSeconds(transferredSession.currentTime), 42.5, accuracy: 1e-3)
        XCTAssertEqual(transferredSession.playbackRate, 1.5)
        XCTAssertEqual(transferredSession.selectedSubtitleID, "embedded:0")
        XCTAssertTrue(transferredSession.isAudioFaultIsolated)
        XCTAssertEqual(transferredSession.playbackFaultCategory, .unsupportedAudioTrack)
        XCTAssertNotNil(transferredSession.audioFaultNotice)
    }

    // MARK: - 6. Real Corpus Verification moved to the hermetic corpus

    // The personal-film corpus (REF-V4 / REF-V5 / REF-V6) used to live here with hard-coded
    // `~/Downloads` paths, which made the default Swift media gate unrunnable on every
    // machine that did not own the original films. The same three production-chain
    // semantics (AC-3 6ch, E-AC-3 6ch, AC-3 5ch) are now verified against a committed,
    // regenerable hermetic corpus:
    //   - `HermeticDolbyCorpusTests`         : the default, always-on verification.
    //   - `RealFilmDolbyCorpusOptInTests`    : the explicit opt-in real-film entry point.

    // MARK: - Fixture Builders

    private static func makeValidAVMetadata() -> [String: Any] {
        [
            "format": "matroska", "durationSeconds": 2.0,
            "selectedVideoTrackNumber": 1, "selectedAudioTrackNumber": 2,
            "metadataCapability": "v1_structured_contract_v1",
            "videoTracks": [
                ["trackIndex": 1, "codec": "h264", "rawCodecId": "V_MPEG4/ISO/AVC", "width": 320, "height": 240, "extradata": sampleH264AvcC, "isSelectedForPackets": true]
            ],
            "audioTracks": [
                ["trackIndex": 2, "codec": "aac", "rawCodecId": "A_AAC", "sampleRate": 48000.0, "channels": 2, "extradata": validAACAudioSpecificConfig, "isSelectedForPackets": true]
            ]
        ]
    }

    private static func makeInterleavedAVPackets(count: Int) -> [MediaPacketDTO] {
        (0..<count).compactMap { idx in
            let isVideo = (idx % 2 == 0)
            let ptsMs = Int64((idx / 2) * 33)
            return try? MediaPacketDTO(
                streamIndex: isVideo ? 1 : 2, mediaType: isVideo ? .video : .audio,
                ptsValue: ptsMs, ptsTimescale: 1000, dtsValue: ptsMs, dtsTimescale: 1000,
                durationValue: isVideo ? 33 : 21, durationTimescale: 1000,
                payloadData: isVideo ? sampleH264Frame : Data([0xDE, 0x04, 0x00, 0x26, 0x20, 0x00]),
                isKeyframe: true, doNotDisplay: false
            )
        }
    }
}
