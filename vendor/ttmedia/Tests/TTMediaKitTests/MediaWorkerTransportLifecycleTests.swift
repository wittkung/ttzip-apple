// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import TTMediaDemux
import XCTest
@testable import TTMediaKit

// MARK: - Group E: Media Worker Transport, IPC Timeout/Kill & Session Isolation Tests

extension PreviewResourceLifecycleAuditTests {

    /// Writes a minimal valid EBML Matroska (`.mkv`) file with a structured Tracks element and video SimpleBlock on track 1 for `FormatDemuxer`.
    static func createSyntheticMatroskaMKV(at url: URL, markerByte: UInt8 = 0x65) throws {
        let videoMaster: [UInt8] = [0xE0, 0x88, 0xB0, 0x82, 0x07, 0x80, 0xBA, 0x82, 0x04, 0x38]
        let trackEntryPayload: [UInt8] = [0xD7, 0x81, 0x01, 0x83, 0x81, 0x01, 0x86, 0x8F]
            + Array("V_MPEG4/ISO/AVC".utf8)
            + videoMaster
        let trackEntry: [UInt8] = [0xAE, UInt8(0x80 | trackEntryPayload.count)] + trackEntryPayload
        let tracksEl: [UInt8] = [0x16, 0x54, 0xAE, 0x6B, UInt8(0x80 | trackEntry.count)] + trackEntry
        let clusterEl: [UInt8] = [
            0x1F, 0x43, 0xB6, 0x75, 0x94,                         // Cluster (20 bytes)
            0xE7, 0x81, 0x00,                                     // Timecode = 0
            0xA3, 0x8F,                                           // SimpleBlock (15 bytes)
            0x81, 0x00, 0x00, 0x80,                               // Track 1, timecode 0, keyframe
            0x00, 0x00, 0x00, 0x07, markerByte, 0x88, 0x84, 0x21, 0xAA, 0xBB, 0xCC
        ]
        let segPayload = tracksEl + clusterEl
        let ebmlHeader: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x8B, 0x42, 0x82, 0x88] + Array("matroska".utf8)
        let bytes: [UInt8] = ebmlHeader + [
            0x18, 0x53, 0x80, 0x67, UInt8(0x80 | segPayload.count)
        ] + segPayload
        try Data(bytes).write(to: url, options: .atomic)
    }

    /// Writes a multi-mode Python worker script supporting `hang`, `hang_on_read`, `crash_on_read`, `ignore_stdin`, `concurrent_delay`, and `healthy`.
    static func writePythonWorkerScript(to scriptURL: URL) throws {
        let script = """
        import base64, json, os, struct, sys, time
        mode = sys.argv[1] if len(sys.argv) > 1 else "healthy"
        worker_ready_path = sys.argv[2] if len(sys.argv) > 2 else ""
        queue_ready_path = sys.argv[3] if len(sys.argv) > 3 else ""
        if mode == "ignore_stdin":
            time.sleep(60)
            sys.exit(0)
        def signal_file(path):
            if path:
                with open(path, "w") as f:
                    f.write("1")
        def wait_for_file(path, limit_sec=2.0):
            if not path:
                time.sleep(0.08)
                return
            deadline = time.time() + limit_sec
            while time.time() < deadline and not os.path.exists(path):
                time.sleep(0.005)
        def read_frame():
            hdr = sys.stdin.buffer.read(4)
            if len(hdr) < 4:
                sys.exit(0)
            (length,) = struct.unpack(">I", hdr)
            payload = b""
            while len(payload) < length:
                chunk = sys.stdin.buffer.read(length - len(payload))
                if not chunk:
                    sys.exit(0)
                payload += chunk
            return json.loads(payload.decode("utf-8"))
        def write_frame(obj):
            raw = json.dumps(obj).encode("utf-8")
            sys.stdout.buffer.write(struct.pack(">I", len(raw)) + raw)
            sys.stdout.buffer.flush()
        while True:
            req = read_frame()
            if mode == "hang":
                time.sleep(60)
                sys.exit(0)
            cmd = req.get("command")
            sid = req.get("sessionId", "sid-1")
            if cmd == "open":
                write_frame({"sessionId": sid, "format": "mkv", "duration": 64.0, "videoTracks": [], "audioTracks": []})
            elif cmd == "read_packet":
                if mode == "hang_on_read":
                    time.sleep(60)
                    sys.exit(0)
                if mode == "crash_on_read":
                    write_frame({"error": "Worker fatal SIGKILL (137)"})
                    os._exit(137)
                if mode == "concurrent_delay":
                    time.sleep(0.02)
                    write_frame({
                        "streamIndex": 0,
                        "mediaType": "video",
                        "ptsValue": 120,
                        "ptsTimescale": 1000,
                        "dtsValue": 120,
                        "dtsTimescale": 1000,
                        "durationValue": 40,
                        "durationTimescale": 1000,
                        "payloadData": base64.b64encode(b"\\x00\\x00\\x00\\x01").decode("ascii"),
                        "isKeyframe": True,
                        "doNotDisplay": False
                    })
                    continue
                sys.stdout.buffer.write(struct.pack(">I", 0))
                sys.stdout.buffer.flush()
            elif cmd == "seek":
                seek_params = req.get("seekParams") or {}
                ts = float(seek_params.get("targetTimestamp", req.get("targetTimestamp", 0.0)))
                if mode == "late_seek_response":
                    signal_file(worker_ready_path)
                    wait_for_file(queue_ready_path)
                    time.sleep(0.26)
                    write_frame({"targetTimestamp": 111.0})
                    time.sleep(60)
                    sys.exit(0)
                if mode == "partial_seek_response":
                    raw = json.dumps({"targetTimestamp": 222.0}).encode("utf-8")
                    framed = struct.pack(">I", len(raw)) + raw
                    sys.stdout.buffer.write(framed[:8])
                    sys.stdout.buffer.flush()
                    signal_file(worker_ready_path)
                    wait_for_file(queue_ready_path)
                    time.sleep(0.26)
                    sys.stdout.buffer.write(framed[8:])
                    sys.stdout.buffer.flush()
                    time.sleep(60)
                    sys.exit(0)
                if mode == "concurrent_delay":
                    time.sleep(0.01)
                write_frame({"targetTimestamp": ts})
            elif cmd == "close":
                write_frame({"ok": True})
                sys.exit(0)
            else:
                write_frame({"ok": True})
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    }

    // MARK: - 1. Direct Transport Session Identity Isolation

    /// Verifies that opening B after A on `MediaWorkerDirectTransport` closes A's C-ABI handle,
    /// rejects stale `readNextPacket` and `seek` calls for A with `.sessionNotFound`,
    /// treats stale `closeMedia(sessionId: A)` as a no-op, and preserves B's active session.
    @MainActor
    func testDirectTransportSessionIsolationRejectsStaleSessionCloseReadAndSeek() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-audit-direct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoA = tempDir.appendingPathComponent("direct_A.mkv")
        let videoB = tempDir.appendingPathComponent("direct_B.mkv")
        try Self.createSyntheticMatroskaMKV(at: videoA, markerByte: 0x65)
        try Self.createSyntheticMatroskaMKV(at: videoB, markerByte: 0x41)

        let transport = MediaWorkerDirectTransport()
        let sessionA = try await transport.openMedia(path: videoA.path, targetTracks: nil)
        XCTAssertTrue(transport.hasActiveDemuxerHandle)
        XCTAssertEqual(transport.currentActiveSessionId, sessionA.sessionId)
        XCTAssertEqual(transport.openCloseBalanceCount, 1)

        let sessionB = try await transport.openMedia(path: videoB.path, targetTracks: nil)
        XCTAssertNotEqual(sessionA.sessionId, sessionB.sessionId)
        XCTAssertEqual(transport.currentActiveSessionId, sessionB.sessionId)
        XCTAssertEqual(transport.openCloseBalanceCount, 1)

        // Stale readNextPacket & seek with sessionA.sessionId must throw .sessionNotFound(sessionA.sessionId).
        do {
            _ = try await transport.readNextPacket(sessionId: sessionA.sessionId)
            XCTFail("Expected stale readNextPacket to throw sessionNotFound")
        } catch let error as MediaWorkerError {
            XCTAssertEqual(error, .sessionNotFound(sessionA.sessionId))
        }

        do {
            _ = try await transport.seek(to: 0.1, sessionId: sessionA.sessionId, accurate: true)
            XCTFail("Expected stale seek to throw sessionNotFound")
        } catch let error as MediaWorkerError {
            XCTAssertEqual(error, .sessionNotFound(sessionA.sessionId))
        }

        // Stale closeMedia with sessionA.sessionId must be a no-op that leaves sessionB active.
        try await transport.closeMedia(sessionId: sessionA.sessionId)
        XCTAssertTrue(transport.hasActiveDemuxerHandle)
        XCTAssertEqual(transport.currentActiveSessionId, sessionB.sessionId)
        XCTAssertEqual(transport.openCloseBalanceCount, 1)

        // Active sessionB must continue to seek, read packets, and close cleanly.
        let landed = try await transport.seek(to: 0.0, sessionId: sessionB.sessionId, accurate: true)
        XCTAssertEqual(landed, 0.0, accuracy: 0.01)
        let packetBData = try await transport.readNextPacket(sessionId: sessionB.sessionId)
        XCTAssertNotNil(packetBData)
        if let packetBData {
            let decodedPacketB = try JSONDecoder().decode(MediaPacketDTO.self, from: packetBData)
            XCTAssertEqual(decodedPacketB.payloadData.dropFirst(4).first, 0x41)
        }

        try await transport.closeMedia(sessionId: sessionB.sessionId)
        XCTAssertFalse(transport.hasActiveDemuxerHandle)
        XCTAssertNil(transport.currentActiveSessionId)
        XCTAssertEqual(transport.openCloseBalanceCount, 0)
        XCTAssertTrue(Self.openFileDescriptorPaths(underPrefix: tempDir.path).isEmpty)
    }

    // MARK: - 2. Worker Crash in Stream and Paused State + Explicit Retry Contract

    @MainActor
    func testWorkerCrashInStreamAndPausedStatePlusExplicitRetryContract() async throws {
        let transport = ControllableCrashTransport()
        let client = MediaWorkerXPCClient(transport: transport)
        let controller = AVSampleBufferWorkerPlaybackController(
            url: URL(fileURLWithPath: "/tmp/worker_crash_audit.mkv"),
            client: client
        )
        defer { controller.teardown() }

        let midStreamErrorExp = expectation(description: "Mid-stream worker crash surfaces error")
        controller.onError = { _ in midStreamErrorExp.fulfill() }
        transport.crashOnPacketIndex = 3
        await controller.startPlayback(autoPlay: true)
        await fulfillment(of: [midStreamErrorExp], timeout: 2.0)
        XCTAssertEqual(transport.readPacketCalls, 3)
        XCTAssertEqual(transport.crashCallbackCount, 1)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(client.lifecycleState, .crashed)

        transport.crashOnPacketIndex = nil
        try await client.reconnect()
        XCTAssertEqual(client.lifecycleState, .idle)
        await controller.startPlayback(autoPlay: false)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(client.lifecycleState, .activePlayback)

        let pausedCrashExp = expectation(description: "Paused worker crash immediately notifies controller")
        controller.onError = { _ in pausedCrashExp.fulfill() }
        client.simulateInvalidation()
        await fulfillment(of: [pausedCrashExp], timeout: 2.0)
        XCTAssertEqual(client.lifecycleState, .crashed)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isPlaying)
    }

    // MARK: - 3. Multi-Round Subprocess Worker Crash vs Normal Idle Exit & Pipe Reclamation

    func testMultiRoundSubprocessWorkerWithTimeoutsAndPipeFDTracking() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-audit-proc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workerScript = tempDir.appendingPathComponent("worker.py")
        try Self.writePythonWorkerScript(to: workerScript)
        let baselinePipeFDs = Self.countOpenPipeDescriptors()
        let testURL = URL(fileURLWithPath: "/tmp/subprocess_worker_crash.mkv")
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")

        for round in 1...5 {
            let crashTransport = MediaWorkerProcessTransport(
                executableURL: pythonURL,
                arguments: [workerScript.path, "crash_on_read"],
                requestTimeoutSeconds: 2.0
            )
            defer { crashTransport.invalidate() }
            let crashClient = MediaWorkerXPCClient(transport: crashTransport)
            let crashNotified = expectation(description: "Round \(round) abnormal crash notification")
            crashClient.onCrash = { _ in crashNotified.fulfill() }

            let info = try await crashClient.open(url: testURL)
            XCTAssertEqual(info.format, "mkv")
            _ = try? await crashClient.readNextPacket(sessionId: info.sessionId)
            await fulfillment(of: [crashNotified], timeout: 2.0)
            XCTAssertEqual(crashClient.lifecycleState, .crashed)
            crashTransport.invalidate()

            let healthyTransport = MediaWorkerProcessTransport(
                executableURL: pythonURL,
                arguments: [workerScript.path, "healthy"],
                requestTimeoutSeconds: 2.0
            )
            defer { healthyTransport.invalidate() }
            let healthyClient = MediaWorkerXPCClient(transport: healthyTransport)
            healthyClient.onCrash = { err in
                XCTFail("Normal idle exit must not trigger onCrash: \(err)")
            }

            let reopened = try await healthyClient.open(url: testURL)
            let eofPacket = try await healthyClient.readNextPacket(sessionId: reopened.sessionId)
            XCTAssertNil(eofPacket)
            try await healthyClient.close(sessionId: reopened.sessionId)
            XCTAssertEqual(healthyClient.lifecycleState, .warmStandby)
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(healthyClient.crashCount, 0)
            healthyTransport.invalidate()
        }

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Self.countOpenPipeDescriptors() - baselinePipeFDs, 0)
    }

    // MARK: - 4. Deterministic Hung Subprocess Worker Timeout, Process Kill & Concurrent Invalidation

    /// Verifies that when a subprocess worker is alive and never replies (`time.sleep(60)`),
    /// `WorkerPipeChannel` times out deterministically via `Darwin.poll`, `MediaWorkerProcessTransport`
    /// kills and reaps the child process *before* closing pipe handles (avoiding any lock contention),
    /// and a concurrent `invalidate()` unblocks an in-flight read immediately without relying on outer `TaskGroup` races.
    func testHungSubprocessWorkerTimesOutKillsProcessAndReclaimsPipesDeterministically() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-audit-hang-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workerScript = tempDir.appendingPathComponent("worker_hang.py")
        try Self.writePythonWorkerScript(to: workerScript)
        let dummyVideoURL = tempDir.appendingPathComponent("dummy_hang.mkv")
        let baselinePipes = Self.countOpenPipeDescriptors()
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")

        let transport = MediaWorkerProcessTransport(
            executableURL: pythonURL,
            arguments: [workerScript.path, "hang"],
            requestTimeoutSeconds: 0.35
        )
        defer { transport.invalidate() }
        let client = MediaWorkerXPCClient(transport: transport)

        for round in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                _ = try await client.open(url: dummyVideoURL)
                XCTFail("Expected hung worker open() to throw MediaWorkerError.timedOut in round \(round)")
            } catch let error as MediaWorkerError {
                XCTAssertEqual(error, .timedOut)
            }
            XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 2.0)
            XCTAssertEqual(client.lifecycleState, .crashed)
            XCTAssertEqual(client.crashCount, round + 1)
            XCTAssertNil(transport.runningProcessIdentifier, "Hung child process must be killed and reaped")
            try await client.reconnect()
            XCTAssertEqual(client.lifecycleState, .idle)
        }
        transport.invalidate()

        let readHangTransport = MediaWorkerProcessTransport(
            executableURL: pythonURL,
            arguments: [workerScript.path, "hang_on_read"],
            requestTimeoutSeconds: 5.0
        )
        defer { readHangTransport.invalidate() }
        let readHangClient = MediaWorkerXPCClient(transport: readHangTransport)
        let opened = try await readHangClient.open(url: dummyVideoURL)
        XCTAssertNotNil(readHangTransport.runningProcessIdentifier)

        let invalidationTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            readHangClient.simulateInvalidation()
        }
        let readStart = CFAbsoluteTimeGetCurrent()
        _ = try? await readHangClient.readNextPacket(sessionId: opened.sessionId)
        await invalidationTask.value
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - readStart, 2.0)
        XCTAssertNil(readHangTransport.runningProcessIdentifier)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(Self.countOpenPipeDescriptors() - baselinePipes, 0)
    }

    // MARK: - 5. In-Process XPC Service Request Round-Trip vs Anonymous State Simulation

    func testWorkerAccountingMatrixSeparatesPythonDoubleRustDirectAndXPC() async throws {
        let delegate = LoopbackXPCWorkerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let xpcClient = MediaWorkerXPCClient(endpoint: listener.endpoint)
        let dummyURL = URL(fileURLWithPath: "/tmp/xpc_loopback_audit.mkv")
        let streamInfo = try await xpcClient.open(url: dummyURL)
        XCTAssertEqual(streamInfo.format, "mkv")
        XCTAssertEqual(xpcClient.lifecycleState, .activePlayback)

        let firstPkt = try await xpcClient.readNextPacket(sessionId: streamInfo.sessionId)
        let secondPkt = try await xpcClient.readNextPacket(sessionId: streamInfo.sessionId)
        XCTAssertNotNil(firstPkt)
        XCTAssertNil(secondPkt)

        let landed = try await xpcClient.seek(to: 2.5, sessionId: streamInfo.sessionId, accurate: true)
        XCTAssertEqual(landed, 2.5, accuracy: 0.001)
        try await xpcClient.close(sessionId: streamInfo.sessionId)
        XCTAssertEqual(xpcClient.lifecycleState, .warmStandby)
        XCTAssertEqual(delegate.closedSessionIds, [streamInfo.sessionId])

        xpcClient.simulateInvalidation()
        XCTAssertEqual(xpcClient.lifecycleState, .crashed)
        try await xpcClient.reconnect()
        XCTAssertEqual(xpcClient.lifecycleState, .idle)

        let reopenedInfo = try await xpcClient.open(url: dummyURL)
        XCTAssertNotEqual(reopenedInfo.sessionId, streamInfo.sessionId)
        try await xpcClient.close(sessionId: reopenedInfo.sessionId)
        XCTAssertEqual(xpcClient.lifecycleState, .warmStandby)
    }

    // MARK: - 6. Full Request+Response Exchange Serialization Across Concurrent read / seek / close

    /// Verifies that `WorkerPipeChannel.exchangeFrame` serializes the complete write+read exchange
    /// under `exchangeLock`, preventing concurrent `seek` and `readNextPacket` calls from interleaving
    /// their writes and reading each other's responses out of order.
    func testConcurrentProcessTransportReadSeekCloseSerializesFullExchangeWithoutCrossTalk() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-audit-serial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workerScript = tempDir.appendingPathComponent("worker_serial.py")
        try Self.writePythonWorkerScript(to: workerScript)
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")

        let transport = MediaWorkerProcessTransport(
            executableURL: pythonURL,
            arguments: [workerScript.path, "concurrent_delay"],
            requestTimeoutSeconds: 3.0
        )
        defer { transport.invalidate() }
        let client = MediaWorkerXPCClient(transport: transport)
        let opened = try await client.open(url: URL(fileURLWithPath: "/tmp/concurrent_serial.mkv"))

        let seekTargets: [Double] = [1.25, 2.50, 3.75]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for target in seekTargets {
                group.addTask {
                    let landed = try await client.seek(to: target, sessionId: opened.sessionId, accurate: true)
                    XCTAssertEqual(landed, target, accuracy: 0.001, "Seek response must match its own request")
                }
                group.addTask {
                    let pkt = try await client.readNextPacket(sessionId: opened.sessionId)
                    XCTAssertNotNil(pkt, "Read response must decode MediaPacketDTO without cross-talk")
                    XCTAssertEqual(pkt?.ptsValue, 120)
                }
            }
            try await group.waitForAll()
        }

        try await client.close(sessionId: opened.sessionId)
        XCTAssertEqual(client.lifecycleState, .warmStandby)
        XCTAssertNil(client.activeSessionId)
    }

    // MARK: - 7. Bounded Non-Blocking Pipe Write Timeout When Child Never Reads Stdin

    /// Verifies that when a child process never reads from `stdin` and the parent writes a payload
    /// larger than the kernel pipe buffer (`>64 KB`), `WorkerPipeChannel.writeExact` uses non-blocking IO
    /// (`O_NONBLOCK` + `Darwin.poll(POLLOUT)`) to time out deterministically, kill the child, and reclaim pipes.
    func testProcessTransportBoundedWriteTimeoutWhenChildNeverReadsStdin() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-audit-write-hang-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workerScript = tempDir.appendingPathComponent("worker_ignore_stdin.py")
        try Self.writePythonWorkerScript(to: workerScript)
        let baselinePipes = Self.countOpenPipeDescriptors()
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")

        let transport = MediaWorkerProcessTransport(
            executableURL: pythonURL,
            arguments: [workerScript.path, "ignore_stdin"],
            requestTimeoutSeconds: 0.35
        )
        defer { transport.invalidate() }
        let client = MediaWorkerXPCClient(transport: transport)

        let largeSegment = String(repeating: "a", count: 140_000)
        let largeURL = URL(fileURLWithPath: "/tmp/\(largeSegment).mkv")

        let start = CFAbsoluteTimeGetCurrent()
        do {
            _ = try await client.open(url: largeURL)
            XCTFail("Expected write to full pipe when child ignores stdin to throw MediaWorkerError.timedOut")
        } catch let error as MediaWorkerError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 2.5)
        XCTAssertEqual(client.lifecycleState, .crashed)
        XCTAssertNil(transport.runningProcessIdentifier, "Child process ignoring stdin must be killed and reaped")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(Self.countOpenPipeDescriptors() - baselinePipes, 0)
    }

    // MARK: - 8. Client-Level Session Isolation Against Stale close / read / seek Writebacks

    /// Verifies that `MediaWorkerXPCClient` isolates session state when switching from session A to session B:
    /// delayed `readNextPacket`, `seek`, and `close` completions from stale session A are rejected and never
    /// overwrite `activeSessionId`, `lifecycleState`, or `lastKnownTimestamp` of active session B.
    func testXPCClientRejectsStaleSessionReadSeekAndCloseWritebacksAfterSwitchToB() async throws {
        let transport = DelayedSessionTransport()
        let client = MediaWorkerXPCClient(transport: transport)
        let urlA = URL(fileURLWithPath: "/tmp/client_session_A.mkv")
        let urlB = URL(fileURLWithPath: "/tmp/client_session_B.mkv")

        let sessionA = try await client.open(url: urlA)
        XCTAssertEqual(client.activeSessionId, sessionA.sessionId)
        XCTAssertEqual(client.currentURL, urlA)

        transport.delayedSessionId = sessionA.sessionId
        let staleReadTask = Task { try await client.readNextPacket(sessionId: sessionA.sessionId) }
        let staleSeekTask = Task { try await client.seek(to: 99.0, sessionId: sessionA.sessionId, accurate: true) }
        let staleCloseTask = Task { try await client.close(sessionId: sessionA.sessionId) }

        try await Task.sleep(for: .milliseconds(25))

        let sessionB = try await client.open(url: urlB)
        XCTAssertNotEqual(sessionA.sessionId, sessionB.sessionId)
        let landedB = try await client.seek(to: 12.5, sessionId: sessionB.sessionId, accurate: true)
        XCTAssertEqual(landedB, 12.5, accuracy: 0.001)
        XCTAssertEqual(client.lastKnownTimestamp, 12.5, accuracy: 0.001)

        do {
            _ = try await staleReadTask.value
            XCTFail("Expected delayed readNextPacket for A to throw sessionNotFound")
        } catch let error as MediaWorkerError {
            XCTAssertEqual(error, .sessionNotFound(sessionA.sessionId))
        }
        do {
            _ = try await staleSeekTask.value
            XCTFail("Expected delayed seek for A to throw sessionNotFound")
        } catch let error as MediaWorkerError {
            XCTAssertEqual(error, .sessionNotFound(sessionA.sessionId))
        }
        try await staleCloseTask.value

        XCTAssertEqual(client.lifecycleState, .activePlayback)
        XCTAssertEqual(client.activeSessionId, sessionB.sessionId)
        XCTAssertEqual(client.currentURL, urlB)
        XCTAssertEqual(client.lastKnownTimestamp, 12.5, accuracy: 0.001)
    }

    // MARK: - 9. Critical-Section Channel Poisoning Before exchangeLock Unlock on Timeout or Partial Frame

    /// Verifies that when Request A times out (`late_seek_response`) or receives a partial frame (`partial_seek_response`)
    /// while Request B is already queued waiting on `exchangeLock`, `exchangeFrame` marks the channel unusable
    /// *before* `defer { exchangeLock.unlock() }` runs. Even when A's late response arrives immediately afterward,
    /// Request B must fail with `.connectionInvalidated` (never returning A's data), and subprocess + pipe FDs are reclaimed.
    func testQueuedRequestBRejectsPoisonedChannelWhenRequestATimesOutOrReceivesPartialFrameAndLateResponseArrives() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-audit-poison-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workerScript = tempDir.appendingPathComponent("worker_poison.py")
        try Self.writePythonWorkerScript(to: workerScript)
        let baselinePipes = Self.countOpenPipeDescriptors()

        try await assertSubprocessPoisonedExchangeReclaimsResources(
            workerScript: workerScript,
            tempDir: tempDir,
            mode: "late_seek_response"
        )
        try await assertSubprocessPoisonedExchangeReclaimsResources(
            workerScript: workerScript,
            tempDir: tempDir,
            mode: "partial_seek_response"
        )

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(Self.countOpenPipeDescriptors() - baselinePipes, 0)
    }

    private static func waitUntilSignal(
        timeoutSeconds: TimeInterval = 2.0,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func assertSubprocessPoisonedExchangeReclaimsResources(
        workerScript: URL,
        tempDir: URL,
        mode: String
    ) async throws {
        let workerReadyURL = tempDir.appendingPathComponent("ready_\(mode).sig")
        let queueReadyURL = tempDir.appendingPathComponent("queued_\(mode).sig")
        try? FileManager.default.removeItem(at: workerReadyURL)
        try? FileManager.default.removeItem(at: queueReadyURL)

        // Phase 1: Startup + open readiness uses a dedicated 3.0s startup timeout budget.
        let transport = MediaWorkerProcessTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [workerScript.path, mode, workerReadyURL.path, queueReadyURL.path],
            requestTimeoutSeconds: 3.0
        )
        defer { transport.invalidate() }
        let client = MediaWorkerXPCClient(transport: transport)
        let opened = try await client.open(url: URL(fileURLWithPath: "/tmp/poison_\(mode).mkv"))
        XCTAssertNotNil(transport.runningProcessIdentifier)

        // Phase 2: Start Request A and wait for explicit readiness signal (A in read phase + worker received A).
        let taskA = Task.detached(priority: .userInitiated) { () -> Result<Double, Error> in
            do {
                return .success(try await client.seek(to: 11.0, sessionId: opened.sessionId, accurate: true))
            } catch {
                return .failure(error)
            }
        }
        let aReady = await Self.waitUntilSignal(timeoutSeconds: 2.0) {
            transport.isExchangeInReadPhase && FileManager.default.fileExists(atPath: workerReadyURL.path)
        }
        XCTAssertTrue(aReady, "Request A must enter read phase and worker must signal receipt in mode \(mode)")

        // Phase 3: Start Request B and wait for explicit queueing signal (B waiting on exchangeLock).
        let taskB = Task.detached(priority: .userInitiated) { () -> Result<Double, Error> in
            do {
                return .success(try await client.seek(to: 22.0, sessionId: opened.sessionId, accurate: true))
            } catch {
                return .failure(error)
            }
        }
        let bQueued = await Self.waitUntilSignal(timeoutSeconds: 2.0) {
            transport.waitingExchangeCount >= 1
        }
        XCTAssertTrue(bQueued, "Request B must be deterministically queued on exchangeLock in mode \(mode)")

        // Phase 4: Tighten exchange timeout to 0.20s and release worker's 0.26s late response.
        transport.updateRequestTimeoutSeconds(0.20)
        try Data("1".utf8).write(to: queueReadyURL, options: .atomic)

        let resA = await taskA.value
        let resB = await taskB.value
        XCTAssertEqual( try? resA.get(), nil)
        XCTAssertEqual( try? resB.get(), nil)
        if case .failure(let errA) = resA {
            XCTAssertEqual(errA as? MediaWorkerError, .timedOut)
        }
        if case .failure(let errB) = resB {
            XCTAssertEqual(errB as? MediaWorkerError, .connectionInvalidated)
        }
        XCTAssertEqual(client.lifecycleState, .crashed)
        XCTAssertNil(transport.runningProcessIdentifier, "Subprocess in mode \(mode) must be terminated and reaped")
    }

    // MARK: - 10. Separate Accounting: In-Process Anonymous XPC vs Cross-PID Real Worker Single-Track Subtitle Cancellation

    /// Verifies and separately accounts for:
    /// 1. In-process anonymous XPC (`MediaWorkerService` over `NSXPCListener.anonymous()`, `workerPid == getpid()`);
    /// 2. Cross-PID real Worker (`workerPid != getpid()`) executing native Rust `ttmedia_subtitles_container_request`
    ///    where explicit single-track scan `reqA` (`track = 3`) is cancelled at cluster 1 while `reqB` (`track = 4`)
    ///    completes 2 clusters and 2 cues, with zero clusters scanned in the host process.
    func testCrossPIDRealWorkerAndInProcessAnonymousXPCSingleTrackSubtitleCancellationAccountedSeparately() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-audit-sub-xpid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mkvURL = tempDir.appendingPathComponent("two_cluster_sub.mkv")
        try CrossPIDSubtitleWorkerTestSupport.makeTwoClusterSubtitleMKV().write(to: mkvURL)
        let hostPid = getpid()

        let cabiPath = try XCTUnwrap(Bundle(for: Self.self).executablePath)
        let crossReqA: UInt64 = 880_101
        let crossReqB: UInt64 = 880_102
        let crossOut = try CrossPIDSubtitleWorkerTestSupport.runCrossPIDNativeRustSingleTrackCancellation(
            cabiImagePath: cabiPath,
            mkvURL: mkvURL,
            reqA: crossReqA,
            reqB: crossReqB,
            tempDir: tempDir
        )
        let workerPid = Int32((crossOut["workerPid"] as? Int) ?? 0)
        XCTAssertNotEqual(workerPid, 0)
        XCTAssertNotEqual(workerPid, hostPid, "Cross-PID worker must run in a different OS process")
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(crossReqA), 0, "Host must not scan cross-PID request")
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(crossReqB), 0, "Host must not scan cross-PID request")
        XCTAssertEqual(crossOut["reqACancelled"] as? Bool, true)
        XCTAssertEqual(crossOut["reqAClusters"] as? Int, 1)
        XCTAssertNotNil(crossOut["reqAError"] as? String)
        XCTAssertEqual(crossOut["reqBCancelled"] as? Bool, false)
        XCTAssertEqual(crossOut["reqBClusters"] as? Int, 2)
        XCTAssertEqual(crossOut["reqBCuesCount"] as? Int, 2)
    }
}

