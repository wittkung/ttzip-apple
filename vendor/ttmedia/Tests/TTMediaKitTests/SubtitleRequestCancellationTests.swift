// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreMedia
import Darwin
import Foundation
import TTMediaDemux
import XCTest
@testable import TTMediaKit

final class SubtitleRequestCancellationTests: XCTestCase {
    @MainActor
    func testRequestScopedCancellationIsolatesPrewarmPrimarySecondaryAndPreStart() async throws {
        let mkvURL = try Self.writeSyntheticTwoClusterMKV()
        defer { try? FileManager.default.removeItem(at: mkvURL) }

        try await assertPrewarmCancelDoesNotCancelPrimaryOrSecondary(mkvURL: mkvURL)
        try await assertPrimaryAndSecondaryCancelIndependentlyAndIgnoreDelayedCancel(mkvURL: mkvURL)
        await assertPreStartCancellationIsNotLost(mkvURL: mkvURL)
    }

    @MainActor
    func testCancellationSurvivesOver64SubsequentCancellationsAndReclaimsLongRunningRecords() async throws {
        let mkvURL = try Self.writeSyntheticTwoClusterMKV()
        defer { try? FileManager.default.removeItem(at: mkvURL) }

        try await assertInFlightAndPreStartCancellationSurviveOver64SubsequentCancellations(mkvURL: mkvURL)
        try await assertLongRunningRequestsAndSessionsReclaimDeterministically(mkvURL: mkvURL)
    }

    @MainActor
    func testSessionStopAndXPCInterfaceRoundTripAndOutOfProcessWorkerCancellationStopNativeScan() async throws {
        let mkvURL = try Self.writeSyntheticTwoClusterMKV()
        defer { try? FileManager.default.removeItem(at: mkvURL) }

        // Evidence A (DirectTransport in-process): closing old session stops its scan at cluster 1 without affecting new session.
        try await assertClosingOldSessionDoesNotCancelNewSession(mkvURL: mkvURL)
        // Evidence B (NSXPCListener.anonymous() in-process XPC interface round-trip): verifies XPC protocol wiring in-process.
        try await assertInProcessAnonymousXPCInterfaceRoundTripCancellation(mkvURL: mkvURL)
        // Evidence C (Separate-PID Worker process, workerPid != getpid()): verifies active single-track scan A stops at
        // cluster 1 while concurrent single-track scan B completes at cluster 2 in a different OS process over IPC.
        try await assertSeparatePIDWorkerSingleTrackCancellationAndIPCStatus(mkvURL: mkvURL)
    }

    @MainActor
    private func assertInFlightAndPreStartCancellationSurviveOver64SubsequentCancellations(mkvURL: URL) async throws {
        let transport = MediaWorkerDirectTransport()
        let openResult = try await transport.openMedia(path: mkvURL.path, targetTracks: nil)

        let reqA = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: openResult.sessionId)
        let reqB = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: openResult.sessionId)
        ttmedia_subtitles_set_request_cluster_delay_ms(reqA, 220)
        ttmedia_subtitles_set_request_cluster_delay_ms(reqB, 90)

        async let taskA = try? transport.subtitleData(sessionId: openResult.sessionId, track: 3, requestID: reqA)
        async let taskB = transport.subtitleData(sessionId: openResult.sessionId, track: 4, requestID: reqB)

        try? await Task.sleep(for: .milliseconds(55))
        await transport.cancelSubtitleRequest(sessionId: openResult.sessionId, requestID: reqA)

        // Cancel 128 distinct requests (> 64) before reqA reaches its next cluster checkpoint.
        for offset in 0..<128 {
            let sid = "noise-session-\(offset)"
            let noiseID = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: sid)
            SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sid, requestID: noiseID)
            SubtitleSessionRequestRegistry.shared.finishRequest(sessionId: sid, requestID: noiseID)
        }

        _ = await taskA
        let dataB = try await taskB
        try? await transport.closeMedia(sessionId: openResult.sessionId)

        XCTAssertTrue(ttmedia_subtitles_is_request_cancelled(reqA))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(reqA), 1)
        XCTAssertFalse(ttmedia_subtitles_is_request_cancelled(reqB))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(reqB), 2)
        XCTAssertEqual(try MediaSubtitleResponse.decode(dataB).cues?.count, 2)

        try await assertRegisteredPreStartSurvivesOver4096Cancellations(
            mkvURL: mkvURL,
            sessionId: openResult.sessionId
        )
        try await assertActiveRequestCapacityRejectionAt4096(mkvURL: mkvURL)
    }

    @MainActor
    private func assertRegisteredPreStartSurvivesOver4096Cancellations(
        mkvURL: URL,
        sessionId: String
    ) async throws {
        let reqPre = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: sessionId)
        XCTAssertTrue(SubtitleSessionRequestRegistry.shared.tryRegisterRequest(sessionId: sessionId, requestID: reqPre))
        SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sessionId, requestID: reqPre)
        XCTAssertEqual(SubtitleSessionRequestRegistry.shared.activeRequestCount, 1)
        XCTAssertEqual(SubtitleSessionRequestRegistry.shared.preStartTombstoneCount, 0)
        XCTAssertEqual(ttmedia_subtitles_active_request_count(), 1)
        XCTAssertEqual(ttmedia_subtitles_pre_start_tombstone_count(), 0)

        for noiseID in UInt64(800_000)..<UInt64(804_500) {
            SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: nil, requestID: noiseID)
        }
        XCTAssertEqual(
            SubtitleSessionRequestRegistry.shared.preStartTombstoneCount,
            SubtitleSessionRequestRegistry.maxPreStartTombstones
        )
        XCTAssertEqual(
            ttmedia_subtitles_pre_start_tombstone_count(),
            SubtitleSessionRequestRegistry.maxPreStartTombstones
        )

        var didRejectLateStart = false
        do {
            _ = try await SubtitleContainerDirectExecutor.execute(
                subtitlePath: mkvURL.path,
                sessionId: sessionId,
                track: 3,
                requestID: reqPre
            )
        } catch is CancellationError {
            didRejectLateStart = true
        }
        XCTAssertTrue(didRejectLateStart, "Late start of registered cancelled request R must throw CancellationError")
        XCTAssertTrue(ttmedia_subtitles_is_request_cancelled(reqPre))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(reqPre), 0)
        XCTAssertEqual(SubtitleSessionRequestRegistry.shared.activeRequestCount, 0)
        XCTAssertEqual(ttmedia_subtitles_active_request_count(), 0)

        for noiseID in UInt64(800_000)..<UInt64(804_500) {
            SubtitleSessionRequestRegistry.shared.finishRequest(sessionId: "tombstone-cleanup", requestID: noiseID)
        }
        XCTAssertEqual(SubtitleSessionRequestRegistry.shared.preStartTombstoneCount, 0)
        XCTAssertEqual(ttmedia_subtitles_pre_start_tombstone_count(), 0)
    }

    @MainActor
    private func assertActiveRequestCapacityRejectionAt4096(mkvURL: URL) async throws {
        let capSession = "capacity-session-\(UUID().uuidString)"
        let capBase: UInt64 = 900_000
        let maxActive = UInt64(SubtitleSessionRequestRegistry.maxActiveRequests)
        for offset in 0..<maxActive {
            XCTAssertTrue(
                SubtitleSessionRequestRegistry.shared.tryRegisterRequest(
                    sessionId: capSession,
                    requestID: capBase + offset
                )
            )
        }
        SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: capSession, requestID: capBase)
        XCTAssertEqual(SubtitleSessionRequestRegistry.shared.activeRequestCount, Int(maxActive))
        XCTAssertEqual(ttmedia_subtitles_active_request_count(), Int(maxActive))
        XCTAssertFalse(
            SubtitleSessionRequestRegistry.shared.tryRegisterRequest(
                sessionId: capSession,
                requestID: capBase + maxActive
            )
        )
        var didRejectCapacity = false
        do {
            _ = try await SubtitleContainerDirectExecutor.execute(
                subtitlePath: mkvURL.path,
                sessionId: capSession,
                track: 3,
                requestID: capBase + maxActive
            )
        } catch {
            didRejectCapacity = true
        }
        XCTAssertTrue(didRejectCapacity, "4097th active request must be explicitly rejected without evicting existing entries")
        XCTAssertTrue(SubtitleSessionRequestRegistry.shared.isCancelled(sessionId: capSession, requestID: capBase))

        for offset in 0..<maxActive {
            SubtitleSessionRequestRegistry.shared.finishRequest(sessionId: capSession, requestID: capBase + offset)
        }
        XCTAssertEqual(SubtitleSessionRequestRegistry.shared.activeRequestCount, 0)
        XCTAssertEqual(SubtitleSessionRequestRegistry.shared.trackedSessionCount, 0)
        XCTAssertEqual(ttmedia_subtitles_active_request_count(), 0)
    }

    @MainActor
    private func assertLongRunningRequestsAndSessionsReclaimDeterministically(mkvURL: URL) async throws {
        for delayID in UInt64(700_000)..<UInt64(700_300) {
            ttmedia_subtitles_set_request_cluster_delay_ms(delayID, 5)
        }
        XCTAssertEqual(ttmedia_subtitles_pending_delay_count(), 256)
        for delayID in UInt64(700_000)..<UInt64(700_300) {
            ttmedia_subtitles_reclaim_request(delayID)
        }
        XCTAssertEqual(ttmedia_subtitles_pending_delay_count(), 0)

        for idx in 0..<300 {
            let sid = "reclaim-session-\(idx)-\(UUID().uuidString)"
            let req1 = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: sid)
            let req2 = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: sid)
            if idx % 3 == 0 {
                SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sid, requestID: req1)
                _ = try? await SubtitleContainerDirectExecutor.execute(
                    subtitlePath: mkvURL.path,
                    sessionId: sid,
                    track: 3,
                    requestID: req1
                )
                let data = try await SubtitleContainerDirectExecutor.execute(
                    subtitlePath: mkvURL.path,
                    sessionId: sid,
                    track: 4,
                    requestID: req2
                )
                XCTAssertEqual(try MediaSubtitleResponse.decode(data).cues?.count, 2)
            } else if idx % 3 == 1 {
                SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: sid)
                _ = try? await SubtitleContainerDirectExecutor.execute(
                    subtitlePath: mkvURL.path,
                    sessionId: sid,
                    track: 3,
                    requestID: req1
                )
                _ = try? await SubtitleContainerDirectExecutor.execute(
                    subtitlePath: mkvURL.path,
                    sessionId: sid,
                    track: 4,
                    requestID: req2
                )
            } else {
                _ = try await SubtitleContainerDirectExecutor.execute(
                    subtitlePath: mkvURL.path,
                    sessionId: sid,
                    track: 3,
                    requestID: req1
                )
                _ = try await SubtitleContainerDirectExecutor.execute(
                    subtitlePath: mkvURL.path,
                    sessionId: sid,
                    track: 4,
                    requestID: req2
                )
            }
        }
        XCTAssertEqual(SubtitleSessionRequestRegistry.shared.activeRequestCount, 0)
        XCTAssertEqual(SubtitleSessionRequestRegistry.shared.trackedSessionCount, 0)
        XCTAssertEqual(SubtitleSessionRequestRegistry.shared.preStartTombstoneCount, 0)
        XCTAssertLessThanOrEqual(
            SubtitleSessionRequestRegistry.shared.cancelledSessionCount,
            SubtitleSessionRequestRegistry.maxCancelledSessions
        )
        XCTAssertEqual(ttmedia_subtitles_active_request_count(), 0)
        XCTAssertEqual(ttmedia_subtitles_pre_start_tombstone_count(), 0)
        XCTAssertEqual(ttmedia_subtitles_pending_delay_count(), 0)
        XCTAssertLessThanOrEqual(ttmedia_subtitles_completed_record_count(), 256)
        XCTAssertEqual(
            ttmedia_subtitles_retained_record_count(),
            ttmedia_subtitles_completed_record_count()
        )
    }

    @MainActor
    private func assertPrewarmCancelDoesNotCancelPrimaryOrSecondary(mkvURL: URL) async throws {
        let transport = MediaWorkerDirectTransport()
        let openResult = try await transport.openMedia(path: mkvURL.path, targetTracks: nil)

        let prewarmReq = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: openResult.sessionId)
        let primaryReq = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: openResult.sessionId)
        let secondaryReq = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: openResult.sessionId)
        for id in [prewarmReq, primaryReq, secondaryReq] {
            ttmedia_subtitles_set_request_cluster_delay_ms(id, 130)
        }
        let prewarmTrack = try XCTUnwrap(
            VideoPlaybackSession.encodePrewarmContainerRequest(targetTrackID: nil as UInt64?, maxTracks: 2, budgetMs: 4000)
        )
        async let prewarmTask = try? transport.subtitleData(sessionId: openResult.sessionId, track: prewarmTrack, requestID: prewarmReq)
        async let primaryTask = transport.subtitleData(sessionId: openResult.sessionId, track: 3, requestID: primaryReq)
        async let secondaryTask = transport.subtitleData(sessionId: openResult.sessionId, track: 4, requestID: secondaryReq)

        try? await Task.sleep(for: .milliseconds(55))
        await transport.cancelSubtitleRequest(sessionId: openResult.sessionId, requestID: prewarmReq)
        _ = await prewarmTask
        let primaryData = try await primaryTask
        let secondaryData = try await secondaryTask
        try? await transport.closeMedia(sessionId: openResult.sessionId)

        XCTAssertTrue(ttmedia_subtitles_is_request_cancelled(prewarmReq))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(prewarmReq), 1)
        XCTAssertFalse(ttmedia_subtitles_is_request_cancelled(primaryReq))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(primaryReq), 2)
        XCTAssertFalse(ttmedia_subtitles_is_request_cancelled(secondaryReq))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(secondaryReq), 2)
        XCTAssertEqual(try MediaSubtitleResponse.decode(primaryData).cues?.count, 2)
        XCTAssertEqual(try MediaSubtitleResponse.decode(secondaryData).cues?.count, 2)
    }

    @MainActor
    private func assertPrimaryAndSecondaryCancelIndependentlyAndIgnoreDelayedCancel(mkvURL: URL) async throws {
        let session = Self.makeDirectContainerSession(mkvURL: mkvURL, clusterDelayMs: 130)
        defer { session.stop() }

        session.selectSubtitle("embedded:3", showFeedback: false)
        let primaryReq1 = try XCTUnwrap(session.activePrimaryRequestID)
        let primaryTask1 = try XCTUnwrap(session.subtitleLoadTask)
        session.selectSecondarySubtitle("embedded:4")
        let secondaryReq1 = try XCTUnwrap(session.activeSecondaryRequestID)
        let secondaryTask1 = try XCTUnwrap(session.secondarySubtitleLoadTask)
        try? await Task.sleep(for: .milliseconds(55))
        session.selectSecondarySubtitle("off")
        await secondaryTask1.value
        await primaryTask1.value

        XCTAssertTrue(ttmedia_subtitles_is_request_cancelled(secondaryReq1))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(secondaryReq1), 1)
        XCTAssertFalse(ttmedia_subtitles_is_request_cancelled(primaryReq1))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(primaryReq1), 2)
        session.currentTime = CMTime(seconds: 600.5, preferredTimescale: 600)
        XCTAssertEqual(session.activeSubtitleText, "后段字幕")

        session.subtitleCache.removeAll()
        session.selectSubtitle("embedded:3", showFeedback: false)
        let primaryReq2 = try XCTUnwrap(session.activePrimaryRequestID)
        let primaryTask2 = try XCTUnwrap(session.subtitleLoadTask)
        session.selectSecondarySubtitle("embedded:4")
        let secondaryReq2 = try XCTUnwrap(session.activeSecondaryRequestID)
        let secondaryTask2 = try XCTUnwrap(session.secondarySubtitleLoadTask)
        try? await Task.sleep(for: .milliseconds(55))
        session.selectSubtitle("off", showFeedback: false)
        session.cancelSubtitleRequestID(primaryReq1)
        await primaryTask2.value
        await secondaryTask2.value

        XCTAssertTrue(ttmedia_subtitles_is_request_cancelled(primaryReq2))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(primaryReq2), 1)
        XCTAssertFalse(ttmedia_subtitles_is_request_cancelled(secondaryReq2))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(secondaryReq2), 2)
        XCTAssertEqual(session.activeSecondarySubtitleText, "Late cue")
    }

    @MainActor
    private func assertPreStartCancellationIsNotLost(mkvURL: URL) async {
        let session = Self.makeDirectContainerSession(mkvURL: mkvURL, clusterDelayMs: 120)
        defer { session.stop() }

        session.selectSubtitle("embedded:3", showFeedback: false)
        guard let preStartReq = session.activePrimaryRequestID else {
            XCTFail("Expected activePrimaryRequestID to be allocated synchronously")
            return
        }
        let cancelledTask = session.subtitleLoadTask
        session.selectSubtitle("off", showFeedback: false)
        _ = try? await SubtitleContainerDirectExecutor.execute(
            subtitlePath: mkvURL.path,
            sessionId: session.sessionID.uuidString,
            track: 3,
            requestID: preStartReq
        )
        await cancelledTask?.value
        XCTAssertTrue(ttmedia_subtitles_is_request_cancelled(preStartReq))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(preStartReq), 0)
    }

    @MainActor
    private func assertClosingOldSessionDoesNotCancelNewSession(mkvURL: URL) async throws {
        let oldSession = Self.makeDirectContainerSession(mkvURL: mkvURL, clusterDelayMs: 140)
        let newSession = Self.makeDirectContainerSession(mkvURL: mkvURL, clusterDelayMs: 140)
        defer { newSession.stop() }

        oldSession.selectSubtitle("embedded:3", showFeedback: false)
        newSession.selectSubtitle("embedded:3", showFeedback: false)
        let oldReqID = try XCTUnwrap(oldSession.activePrimaryRequestID)
        let oldTask = try XCTUnwrap(oldSession.subtitleLoadTask)
        let newReqID = try XCTUnwrap(newSession.activePrimaryRequestID)
        let newTask = try XCTUnwrap(newSession.subtitleLoadTask)

        try? await Task.sleep(for: .milliseconds(55))
        oldSession.stop()
        await oldTask.value
        await newTask.value

        XCTAssertTrue(ttmedia_subtitles_is_request_cancelled(oldReqID))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(oldReqID), 1)
        XCTAssertNil(oldSession.subtitleCache["embedded:3"])
        XCTAssertFalse(ttmedia_subtitles_is_request_cancelled(newReqID))
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(newReqID), 2)
        newSession.currentTime = CMTime(seconds: 600.5, preferredTimescale: 600)
        XCTAssertEqual(newSession.activeSubtitleText, "后段字幕")
    }

    @MainActor
    private func assertInProcessAnonymousXPCInterfaceRoundTripCancellation(mkvURL: URL) async throws {
        let harness = AnonymousXPCWorkerHarness()
        defer { harness.tearDown() }

        let xpcTransport = MediaWorkerXPCTransport(endpoint: harness.endpoint, useFileHandleCapability: true)
        let xpcClient = MediaWorkerXPCClient(transport: xpcTransport)
        _ = try await xpcClient.open(url: mkvURL)
        let sessionID = try XCTUnwrap(xpcClient.activeSessionId)

        let cancelledXpcReq = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: sessionID)
        let activeXpcReq = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: sessionID)
        _ = try await xpcClient.configureSubtitleRequestDelay(requestID: cancelledXpcReq, delayMs: 140)
        _ = try await xpcClient.configureSubtitleRequestDelay(requestID: activeXpcReq, delayMs: 140)

        async let cancelledCall = try? xpcClient.subtitleData(track: 3, requestID: cancelledXpcReq)
        async let survivingCall = xpcClient.subtitleData(track: 4, requestID: activeXpcReq)

        try? await Task.sleep(for: .milliseconds(60))
        await xpcTransport.cancelSubtitleRequest(sessionId: sessionID, requestID: cancelledXpcReq)

        _ = await cancelledCall
        let survivingData = try await survivingCall

        let statusCancelled = try await xpcClient.subtitleRequestStatus(requestID: cancelledXpcReq)
        let statusSurviving = try await xpcClient.subtitleRequestStatus(requestID: activeXpcReq)
        XCTAssertEqual(statusCancelled.workerPid, getpid(), "Anonymous listener runs in-process")
        XCTAssertTrue(harness.service.hasCancelledRequest(cancelledXpcReq))
        XCTAssertTrue(statusCancelled.isCancelled)
        XCTAssertEqual(statusCancelled.clustersScanned, 1)
        XCTAssertFalse(statusSurviving.isCancelled)
        XCTAssertEqual(statusSurviving.clustersScanned, 2)
        let survivingCues = try XCTUnwrap(try MediaSubtitleResponse.decode(survivingData).cues)
        XCTAssertEqual(survivingCues.map(\.text), ["Early cue", "Late cue"])
        try await xpcClient.close(sessionId: sessionID)
    }

    @MainActor
    private func assertSeparatePIDWorkerSingleTrackCancellationAndIPCStatus(mkvURL: URL) async throws {
        let cabiPath = try XCTUnwrap(Bundle(for: Self.self).executablePath)
        let scriptURL = mkvURL.deletingLastPathComponent().appendingPathComponent("ipc_subtitle_worker.py")
        try Self.separatePIDWorkerIPCScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let reqA: UInt64 = 980_101
        let reqB: UInt64 = 980_102
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", scriptURL.path, cabiPath, mkvURL.path, "\(reqA)", "\(reqB)"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()

        let outHandle = outPipe.fileHandleForReading
        var readyLine = ""
        while !readyLine.contains("WORKER_READY") {
            let chunk = outHandle.availableData
            guard !chunk.isEmpty else { break }
            readyLine += String(decoding: chunk, as: UTF8.self)
        }
        XCTAssertTrue(readyLine.contains("WORKER_READY"), "Separate-PID worker failed to start: \(readyLine)")

        try? await Task.sleep(for: .milliseconds(75))
        inPipe.fileHandleForWriting.write(Data("CANCEL \(reqA)\n".utf8))
        try? inPipe.fileHandleForWriting.close()

        let remainingData = outHandle.readDataToEndOfFile()
        process.waitUntilExit()
        let fullOutput = readyLine + String(decoding: remainingData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "Worker exited with error: \(fullOutput)")

        guard let resultLine = fullOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("WORKER_RESULT ") }) else {
            XCTFail("Missing WORKER_RESULT line in output: \(fullOutput)")
            return
        }
        let fields = Dictionary(
            uniqueKeysWithValues: resultLine
                .dropFirst("WORKER_RESULT ".count)
                .split(separator: " ")
                .compactMap { part -> (String, String)? in
                    let kv = part.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { return nil }
                    return (String(kv[0]), String(kv[1]))
                }
        )
        let workerPid = Int32(fields["worker_pid"] ?? "0") ?? 0
        XCTAssertNotEqual(workerPid, 0)
        XCTAssertNotEqual(workerPid, getpid(), "Worker must run in a separate OS process PID")
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(reqA), 0, "Host process must not share Rust scan state with Worker")
        XCTAssertEqual(ttmedia_subtitles_last_scanned_clusters(reqB), 0, "Host process must not share Rust scan state with Worker")
        XCTAssertEqual(fields["reqA_clusters"], "1", "Cancelled single-track scan in Worker must stop at cluster 1")
        XCTAssertEqual(fields["reqA_cancelled"], "true")
        XCTAssertEqual(fields["reqB_clusters"], "2", "Concurrent single-track scan in Worker must complete 2 clusters")
        XCTAssertEqual(fields["reqB_cancelled"], "false")
        XCTAssertEqual(fields["reqB_cues"], "2")
    }

    private static let separatePIDWorkerIPCScript = """
    import ctypes, json, os, sys, threading

    lib = ctypes.CDLL(sys.argv[1])
    mkv_path = sys.argv[2].encode("utf-8")
    req_a = int(sys.argv[3])
    req_b = int(sys.argv[4])

    lib.ttmedia_subtitles_register_request.argtypes = [ctypes.c_uint64]
    lib.ttmedia_subtitles_register_request.restype = ctypes.c_bool
    lib.ttmedia_subtitles_set_request_cluster_delay_ms.argtypes = [ctypes.c_uint64, ctypes.c_uint32]
    lib.ttmedia_subtitles_set_request_cluster_delay_ms.restype = None
    lib.ttmedia_subtitles_container_request.argtypes = [ctypes.c_char_p, ctypes.c_int64, ctypes.c_uint64]
    lib.ttmedia_subtitles_container_request.restype = ctypes.c_void_p
    lib.ttmedia_subtitles_cancel_request.argtypes = [ctypes.c_uint64]
    lib.ttmedia_subtitles_cancel_request.restype = None
    lib.ttmedia_subtitles_last_scanned_clusters.argtypes = [ctypes.c_uint64]
    lib.ttmedia_subtitles_last_scanned_clusters.restype = ctypes.c_uint64
    lib.ttmedia_subtitles_is_request_cancelled.argtypes = [ctypes.c_uint64]
    lib.ttmedia_subtitles_is_request_cancelled.restype = ctypes.c_bool
    lib.ttmedia_subtitles_free.argtypes = [ctypes.c_void_p]
    lib.ttmedia_subtitles_free.restype = None

    assert lib.ttmedia_subtitles_register_request(req_a)
    assert lib.ttmedia_subtitles_register_request(req_b)
    lib.ttmedia_subtitles_set_request_cluster_delay_ms(req_a, 180)
    lib.ttmedia_subtitles_set_request_cluster_delay_ms(req_b, 180)

    results = {}
    def run_scan(key, track, rid):
        ptr = lib.ttmedia_subtitles_container_request(mkv_path, track, rid)
        if not ptr:
            results[key] = {"error": "null"}
            return
        try:
            raw = ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8")
            results[key] = json.loads(raw)
        finally:
            lib.ttmedia_subtitles_free(ptr)

    ta = threading.Thread(target=run_scan, args=("a", 3, req_a))
    tb = threading.Thread(target=run_scan, args=("b", 4, req_b))
    ta.start()
    tb.start()

    sys.stdout.write(f"WORKER_READY pid={os.getpid()}\\n")
    sys.stdout.flush()

    for line in sys.stdin:
        parts = line.strip().split()
        if len(parts) == 2 and parts[0] == "CANCEL":
            lib.ttmedia_subtitles_cancel_request(int(parts[1]))
            break

    ta.join(timeout=3.0)
    tb.join(timeout=3.0)
    cues_b = len(results.get("b", {}).get("cues") or [])
    a_cl = int(lib.ttmedia_subtitles_last_scanned_clusters(req_a))
    a_can = "true" if lib.ttmedia_subtitles_is_request_cancelled(req_a) else "false"
    b_cl = int(lib.ttmedia_subtitles_last_scanned_clusters(req_b))
    b_can = "true" if lib.ttmedia_subtitles_is_request_cancelled(req_b) else "false"
    sys.stdout.write(
        f"WORKER_RESULT worker_pid={os.getpid()} reqA_clusters={a_cl} reqA_cancelled={a_can} "
        f"reqB_clusters={b_cl} reqB_cancelled={b_can} reqB_cues={cues_b}\\n"
    )
    sys.stdout.flush()
    """

    @MainActor
    private static func makeDirectContainerSession(mkvURL: URL, clusterDelayMs: UInt32) -> VideoPlaybackSession {
        let session = VideoPlaybackSession(url: mkvURL)
        session.embeddedSubtitles = [
            EmbeddedSubtitleTrack(id: 3, title: "中文", language: "zh", codec: "S_TEXT/UTF8", supported: true),
            EmbeddedSubtitleTrack(id: 4, title: "English", language: "en", codec: "S_TEXT/UTF8", supported: true),
        ]
        let sid = session.sessionID.uuidString
        session.embeddedSubtitleRequestLoader = { track, requestID in
            ttmedia_subtitles_set_request_cluster_delay_ms(requestID, clusterDelayMs)
            return try await Task.detached(priority: .userInitiated) {
                try await SubtitleContainerDirectExecutor.execute(
                    subtitlePath: mkvURL.path,
                    sessionId: sid,
                    track: track,
                    requestID: requestID
                )
            }.value
        }
        return session
    }

    private static func ebmlElement(id: [UInt8], payload: [UInt8]) -> [UInt8] {
        var out = id
        if payload.count < 127 {
            out.append(0x80 | UInt8(payload.count))
        } else {
            let len = UInt16(payload.count) | 0x4000
            out.append(UInt8((len >> 8) & 0xff))
            out.append(UInt8(len & 0xff))
        }
        out.append(contentsOf: payload)
        return out
    }

    private static func writeSyntheticTwoClusterMKV() throws -> URL {
        func videoTrackEntry() -> [UInt8] {
            let videoSettings = ebmlElement(id: [0xb0], payload: [0x07, 0x80])
                + ebmlElement(id: [0xba], payload: [0x04, 0x38])
            var entry = ebmlElement(id: [0xd7], payload: [1])
            entry += ebmlElement(id: [0x83], payload: [1])
            entry += ebmlElement(id: [0x86], payload: Array("V_MPEG4/ISO/AVC".utf8))
            entry += ebmlElement(id: [0xe0], payload: videoSettings)
            return ebmlElement(id: [0xae], payload: entry)
        }
        func trackEntry(number: UInt8, lang: String, name: String) -> [UInt8] {
            var entry = ebmlElement(id: [0xd7], payload: [number])
            entry += ebmlElement(id: [0x83], payload: [17])
            entry += ebmlElement(id: [0x86], payload: Array("S_TEXT/UTF8".utf8))
            entry += ebmlElement(id: [0x22, 0xb5, 0x9c], payload: Array(lang.utf8))
            entry += ebmlElement(id: [0x53, 0x6e], payload: Array(name.utf8))
            return ebmlElement(id: [0xae], payload: entry)
        }
        func clusterElement(timecodeMs: UInt32, cue3: String, cue4: String) -> [UInt8] {
            let tcBytes: [UInt8] = [
                UInt8((timecodeMs >> 24) & 0xff),
                UInt8((timecodeMs >> 16) & 0xff),
                UInt8((timecodeMs >> 8) & 0xff),
                UInt8(timecodeMs & 0xff),
            ]
            var cluster = ebmlElement(id: [0xe7], payload: tcBytes)
            for (trackNum, text) in [(UInt8(3), cue3), (UInt8(4), cue4)] {
                let block = [UInt8(0x80 | trackNum), 0x00, 0x00, 0x00] + Array(text.utf8)
                let group = ebmlElement(id: [0xa1], payload: block) + ebmlElement(id: [0x9b], payload: [0x03, 0xe8])
                cluster += ebmlElement(id: [0xa0], payload: group)
            }
            return ebmlElement(id: [0x1f, 0x43, 0xb6, 0x75], payload: cluster)
        }
        let ebmlHeader = ebmlElement(
            id: [0x1a, 0x45, 0xdf, 0xa3],
            payload: ebmlElement(id: [0x42, 0x82], payload: Array("matroska".utf8))
        )
        let tracksPayload = videoTrackEntry()
            + trackEntry(number: 3, lang: "zho", name: "中文")
            + trackEntry(number: 4, lang: "eng", name: "English")
        let segmentPayload = ebmlElement(id: [0x16, 0x54, 0xae, 0x6b], payload: tracksPayload)
            + clusterElement(timecodeMs: 1_000, cue3: "前段字幕", cue4: "Early cue")
            + clusterElement(timecodeMs: 600_000, cue3: "后段字幕", cue4: "Late cue")
        let bytes = ebmlHeader + ebmlElement(id: [0x18, 0x53, 0x80, 0x67], payload: segmentPayload)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-cancel-\(UUID().uuidString).mkv")
        try Data(bytes).write(to: url)
        return url
    }
}

private final class AnonymousXPCWorkerHarness: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener: NSXPCListener
    let service = MediaWorkerService()
    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    override init() {
        self.listener = NSXPCListener.anonymous()
        super.init()
        self.listener.delegate = self
        self.listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface.makeMediaWorkerInterface()
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }

    func tearDown() {
        service.invalidate()
        listener.invalidate()
    }
}
