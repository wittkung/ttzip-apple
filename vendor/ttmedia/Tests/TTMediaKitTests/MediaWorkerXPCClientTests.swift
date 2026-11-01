// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreMedia
import Foundation
import XCTest
@testable import TTMediaKit

// MARK: - Mock In-Process XPC Worker Service

final class MockMediaWorkerService: NSObject, TTMediaWorkerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    var openedPath: String?
    var packetsQueue: [Data] = []
    var seekTargetTime: Double = 0.0
    var closedSessionId: String?
    var sleepStateRecorded: Int?
    var shouldFailOpen: Bool = false
    var shouldFailSeek: Bool = false

    func openMedia(
        at path: String,
        targetTracks: [NSNumber]?,
        reply: @escaping @Sendable (Bool, String?, [String: Any]?) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        if shouldFailOpen {
            reply(false, "Simulated open failure", nil)
            return
        }
        self.openedPath = path
        let sid = UUID().uuidString
        let metadata: [String: Any] = [
            "format": "mkv",
            "duration": 120.0,
            "videoTracks": [
                ["trackIndex": 0, "codec": "hevc", "width": 3840, "height": 2160, "bitrate": 8_000_000]
            ],
            "audioTracks": [
                ["trackIndex": 1, "codec": "aac", "sampleRate": 48000.0, "channels": 2, "bitrate": 320_000]
            ],
            "metadata": ["title": "Test Title"]
        ]
        reply(true, sid, metadata)
    }

    func readNextPacket(
        forSession sessionId: String,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        if packetsQueue.isEmpty {
            reply(nil, nil)
        } else {
            let data = packetsQueue.removeFirst()
            reply(data, nil)
        }
    }

    func seek(
        to timestamp: Double,
        sessionId: String,
        accurate: Bool,
        reply: @escaping @Sendable (Bool, Double, String?) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        if shouldFailSeek {
            reply(false, 0.0, "Simulated seek failure")
            return
        }
        self.seekTargetTime = timestamp
        reply(true, timestamp, nil)
    }

    func closeMedia(
        forSession sessionId: String,
        reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.closedSessionId = sessionId
        reply(true, nil)
    }

    func setSleepState(
        state: Int,
        reply: @escaping @Sendable (Bool) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.sleepStateRecorded = state
        reply(true)
    }
}

// MARK: - Listener Delegate Helper

final class MockListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: MockMediaWorkerService

    init(service: MockMediaWorkerService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface.makeMediaWorkerInterface()
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

// MARK: - MediaWorkerXPCClient Unit Tests

final class MediaWorkerXPCClientTests: XCTestCase {

    func testClientLifecycleOpenReadSeekClose() async throws {
        let service = MockMediaWorkerService()
        let delegate = MockListenerDelegate(service: service)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        let client = MediaWorkerXPCClient(endpoint: listener.endpoint)
        XCTAssertEqual(client.lifecycleState, .idle)
        XCTAssertEqual(client.crashCount, 0)
        XCTAssertNil(client.activeSessionId)
        XCTAssertEqual(client.lastKnownTimestamp, 0.0)

        // 1. Open media URL
        let testURL = URL(fileURLWithPath: "/tmp/sample_media.mkv")
        let metadata = try await client.open(url: testURL)
        XCTAssertEqual(metadata.format, "mkv")
        XCTAssertEqual(metadata.durationSeconds, 120.0)
        XCTAssertEqual(metadata.videoTracks.count, 1)
        XCTAssertEqual(metadata.videoTracks[0].width, 3840)
        XCTAssertEqual(metadata.audioTracks.count, 1)
        XCTAssertEqual(metadata.audioTracks[0].channels, 2)
        XCTAssertEqual(client.lifecycleState, .activePlayback)
        XCTAssertEqual(client.activeSessionId, metadata.sessionId)
        XCTAssertEqual(client.currentURL, testURL)

        // 2. Read packet
        let samplePayload = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42])
        let testPacket = try MediaPacketDTO(
            streamIndex: 0,
            mediaType: .video,
            ptsValue: 2400,
            ptsTimescale: 1200,
            dtsValue: 2400,
            dtsTimescale: 1200,
            durationValue: 50,
            durationTimescale: 1200,
            payloadData: samplePayload,
            isKeyframe: true,
            doNotDisplay: false
        )
        let encodedPacket = try JSONEncoder().encode(testPacket)
        service.packetsQueue.append(encodedPacket)

        let receivedPacket = try await client.readNextPacket(sessionId: metadata.sessionId)
        XCTAssertNotNil(receivedPacket)
        XCTAssertEqual(receivedPacket?.ptsValue, 2400)
        XCTAssertEqual(receivedPacket?.mediaType, .video)
        XCTAssertEqual(client.lastKnownTimestamp, 2.0, accuracy: 0.001)

        // 3. Read packet EOF
        let eofPacket = try await client.readNextPacket(sessionId: metadata.sessionId)
        XCTAssertNil(eofPacket)

        // 4. Seek
        let landed = try await client.seek(to: 45.5, sessionId: metadata.sessionId, accurate: true)
        XCTAssertEqual(landed, 45.5, accuracy: 0.001)
        XCTAssertEqual(client.lastKnownTimestamp, 45.5, accuracy: 0.001)

        // 5. Close
        try await client.close(sessionId: metadata.sessionId)
        XCTAssertNil(client.activeSessionId)
        XCTAssertEqual(client.lifecycleState, .warmStandby)
        XCTAssertEqual(service.closedSessionId, metadata.sessionId)

        listener.invalidate()
    }

    func testCrashResilienceAndTypedErrors() async throws {
        let service = MockMediaWorkerService()
        let delegate = MockListenerDelegate(service: service)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        let client = MediaWorkerXPCClient(endpoint: listener.endpoint)
        let testURL = URL(fileURLWithPath: "/tmp/crash_sample.mkv")
        let metadata = try await client.open(url: testURL)
        XCTAssertEqual(client.lifecycleState, .activePlayback)

        // Invalidate listener to simulate daemon termination / crash
        client.simulateInvalidation()

        XCTAssertEqual(client.lifecycleState, .crashed)
        XCTAssertGreaterThanOrEqual(client.crashCount, 1)

        // Assert subsequent calls throw typed MediaWorkerError without crashing host
        do {
            _ = try await client.readNextPacket(sessionId: metadata.sessionId)
            XCTFail("Expected connectionInvalidated error")
        } catch let error as MediaWorkerError {
            XCTAssertEqual(error, .connectionInvalidated)
        }

        do {
            _ = try await client.seek(to: 10.0, sessionId: metadata.sessionId)
            XCTFail("Expected connectionInvalidated error")
        } catch let error as MediaWorkerError {
            XCTAssertEqual(error, .connectionInvalidated)
        }

        do {
            _ = try await client.open(url: testURL)
            XCTFail("Expected connectionInvalidated error")
        } catch let error as MediaWorkerError {
            XCTAssertEqual(error, .connectionInvalidated)
        }

        listener.invalidate()
    }

    func testReconnectionAndResumeRestoringLastKnownTimestamp() async throws {
        let service = MockMediaWorkerService()
        let delegate = MockListenerDelegate(service: service)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        let client = MediaWorkerXPCClient(endpoint: listener.endpoint)
        let testURL = URL(fileURLWithPath: "/tmp/resume_sample.mp4")
        let metadata = try await client.open(url: testURL)

        _ = try await client.seek(to: 33.7, sessionId: metadata.sessionId, accurate: true)
        XCTAssertEqual(client.lastKnownTimestamp, 33.7, accuracy: 0.001)

        // Simulate crash
        client.simulateInvalidation()
        XCTAssertEqual(client.lifecycleState, .crashed)
        XCTAssertEqual(client.lastKnownTimestamp, 33.7, accuracy: 0.001)

        // Resume re-opens and restores timestamp position
        let resumedMetadata = try await client.resume()
        XCTAssertNotNil(resumedMetadata)
        XCTAssertEqual(client.lifecycleState, .activePlayback)
        XCTAssertEqual(client.lastKnownTimestamp, 33.7, accuracy: 0.001)

        listener.invalidate()
    }

    func testSleepStateTransitions() async throws {
        let service = MockMediaWorkerService()
        let delegate = MockListenerDelegate(service: service)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        let client = MediaWorkerXPCClient(endpoint: listener.endpoint)
        XCTAssertEqual(client.currentSleepState, .activePlayback)

        client.setSleepState(.warmStandby)
        XCTAssertEqual(client.currentSleepState, .warmStandby)
        XCTAssertEqual(client.lifecycleState, .warmStandby)

        let success = try await client.setSleepStateAsync(.coldHibernation)
        XCTAssertTrue(success)
        XCTAssertEqual(client.currentSleepState, .coldHibernation)
        XCTAssertEqual(client.lifecycleState, .coldHibernation)

        listener.invalidate()
    }

    func testWorkerPipeChannelFramingRoundTrip() throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        // Write to inputPipe, read from inputPipe
        let channel = WorkerPipeChannel(
            readHandle: inputPipe.fileHandleForReading,
            writeHandle: inputPipe.fileHandleForWriting
        )

        let sampleString = "{\"command\":\"open\",\"sessionId\":\"test-uuid\"}"
        let payload = sampleString.data(using: .utf8)!

        try channel.writeFrame(payload)
        let received = try channel.readFrame()
        XCTAssertEqual(received, payload)

        _ = outputPipe
    }

    func testProcessTransportCommandFraming() async throws {
        let pipeA = Pipe()
        let pipeB = Pipe()

        let clientChannel = WorkerPipeChannel(
            readHandle: pipeB.fileHandleForReading,
            writeHandle: pipeA.fileHandleForWriting
        )
        let transport = MediaWorkerProcessTransport(channel: clientChannel)

        // Run mock worker response in background task
        let workerTask = Task {
            let serverChannel = WorkerPipeChannel(
                readHandle: pipeA.fileHandleForReading,
                writeHandle: pipeB.fileHandleForWriting
            )
            let receivedRequest = try serverChannel.readFrame()
            let contract = try JSONDecoder().decode(TTMediaWorkerContract.self, from: receivedRequest)
            XCTAssertEqual(contract.command, .open)

            let mockResponse: [String: Any] = [
                "sessionId": contract.sessionId,
                "format": "webm",
                "duration": 55.0,
                "metadata": ["artist": "Framing Artist"]
            ]
            let responseData = try JSONSerialization.data(withJSONObject: mockResponse)
            try serverChannel.writeFrame(responseData)
        }

        let openResult = try await transport.openMedia(path: "/path/video.webm", targetTracks: nil)
        _ = await workerTask.result
        XCTAssertEqual(openResult.metadata["format"] as? String, "webm")
        XCTAssertEqual(openResult.metadata["durationSeconds"] as? Double, 55.0)
        XCTAssertNil(openResult.metadata["duration"], "Legacy duration key must be standardized into durationSeconds")

        let parsedInfo = TTMediaStreamInfo(sessionId: openResult.sessionId, dictionary: openResult.metadata)
        XCTAssertEqual(parsedInfo.format, "webm")
        XCTAssertEqual(parsedInfo.durationSeconds, 55.0, accuracy: 0.001)
        XCTAssertEqual(parsedInfo.metadata["artist"], "Framing Artist")
        XCTAssertNil(parsedInfo.metadata["duration"], "Numeric duration must not be stuffed into custom [String: String] metadata")
    }

    func testStreamMetadataModelParsing() {
        let rawDict: [String: Any] = [
            "format": "mp4",
            "duration": 99.5,
            "videoTracks": [
                ["trackIndex": 0, "codec": "h264", "width": 1920, "height": 1080, "bitrate": 4_000_000]
            ],
            "audioTracks": [
                ["trackIndex": 1, "codec": "aac", "sampleRate": 44100.0, "channels": 2, "bitrate": 192_000]
            ],
            "metadata": ["artist": "Test Artist"]
        ]

        let normalizedDict = MediaWorkerDirectTransport.normalizeTransportMetadataDictionary(rawDict)
        XCTAssertEqual(normalizedDict["durationSeconds"] as? Double, 99.5)
        XCTAssertNil(normalizedDict["duration"])

        let info = TTMediaStreamInfo(sessionId: "session-123", dictionary: normalizedDict)
        XCTAssertEqual(info.sessionId, "session-123")
        XCTAssertEqual(info.format, "mp4")
        XCTAssertEqual(info.durationSeconds, 99.5)
        XCTAssertEqual(info.videoTracks.count, 1)
        XCTAssertEqual(info.videoTracks[0].codec, .h264)
        XCTAssertEqual(info.audioTracks.count, 1)
        XCTAssertEqual(info.audioTracks[0].sampleRate, 44100.0)
        XCTAssertEqual(info.metadata["artist"], "Test Artist")
        XCTAssertNil(info.metadata["duration"])
    }

    func testDurationPrecedenceAndCustomMetadataPreservationAcrossNormalization() {
        // 1. Canonical durationSeconds takes precedence over legacy duration when both coexist
        let coexistingCamel: [String: Any] = [
            "format": "mkv",
            "duration": 12.0,
            "durationSeconds": 88.25,
            "metadata": ["title_tag": "Canonical Wins"]
        ]
        let normCamel = MediaWorkerDirectTransport.normalizeTransportMetadataDictionary(coexistingCamel)
        let infoCamel = TTMediaStreamInfo(sessionId: "s-camel", dictionary: normCamel)
        XCTAssertEqual(normCamel["durationSeconds"] as? Double, 88.25)
        XCTAssertEqual(infoCamel.durationSeconds, 88.25, accuracy: 0.001)
        XCTAssertEqual(infoCamel.metadata["title_tag"], "Canonical Wins")

        // 2. Canonical snake_case duration_seconds takes precedence over legacy duration when both coexist
        let coexistingSnake: [String: Any] = [
            "container_format": "matroska",
            "duration": 15.0,
            "duration_seconds": 72.5,
            "metadata": ["encoder": "libebml"]
        ]
        let normSnake = MediaWorkerDirectTransport.normalizeTransportMetadataDictionary(coexistingSnake)
        let infoSnake = TTMediaStreamInfo(sessionId: "s-snake", dictionary: normSnake)
        XCTAssertEqual(normSnake["durationSeconds"] as? Double, 72.5)
        XCTAssertEqual(infoSnake.durationSeconds, 72.5, accuracy: 0.001)
        XCTAssertEqual(infoSnake.metadata["encoder"], "libebml")

        // 3. duration_nanos fallback converts to seconds via * 1e-9
        let nanosDict: [String: Any] = [
            "format": "webm",
            "duration_nanos": Int64(12_500_000_000)
        ]
        let normNanos = MediaWorkerDirectTransport.normalizeTransportMetadataDictionary(nanosDict)
        let infoNanos = TTMediaStreamInfo(sessionId: "s-nanos", dictionary: normNanos)
        XCTAssertEqual(infoNanos.durationSeconds, 12.5, accuracy: 0.001)
    }
}
