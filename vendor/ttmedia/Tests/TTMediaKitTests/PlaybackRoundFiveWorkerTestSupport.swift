// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@testable import TTMediaKit

final class R4InProcessWorkerBridge: MediaWorkerTransport, @unchecked Sendable {
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

final class R4AsyncLatch: @unchecked Sendable {
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

final class R4ControlledWorkerServiceTransport: MediaWorkerServiceTransport, @unchecked Sendable {
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
    private var holdTargetSeekGeneration: Int? = nil
    private var shouldHoldClose = false
    private var shouldFailCloseAfterRelease = false

    var currentSessionId: String? { lock.withLock { activeSessionId } }
    var hasExitedRead: Bool { readExitLatch.isSignalled }
    var hasEnteredClose: Bool { closeEntryLatch.isSignalled }
    var seekCallCount: Int { lock.withLock { seeks } }
    var operationTimeline: [String] { lock.withLock { timeline } }

    func holdFirstRead() {
        lock.withLock {
            shouldHoldRead = true
            holdTargetSeekGeneration = 0
        }
    }

    func holdNextClose() { lock.withLock { shouldHoldClose = true } }
    func failCloseAfterRelease() { lock.withLock { shouldFailCloseAfterRelease = true } }
    func releaseRead() { readReleaseLatch.signal() }
    func releaseClose() { closeReleaseLatch.signal() }

    func resetReadGateAndHoldNext(cooperativeCancellation: Bool, forSeekGeneration expectedSeekGen: Int? = nil) {
        _ = cooperativeCancellation
        lock.withLock {
            shouldHoldRead = true
            holdTargetSeekGeneration = expectedSeekGen
        }
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
            guard shouldHoldRead else { return false }
            if let expectedSeekGen = holdTargetSeekGeneration, seeks != expectedSeekGen {
                return false
            }
            shouldHoldRead = false
            holdTargetSeekGeneration = nil
            return true
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
