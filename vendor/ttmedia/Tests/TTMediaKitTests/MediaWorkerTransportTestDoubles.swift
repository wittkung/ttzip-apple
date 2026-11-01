// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import TTMediaDemux
@testable import TTMediaKit

// MARK: - Transport & XPC Test Doubles

internal final class DelayedSessionTransport: MediaWorkerTransport, @unchecked Sendable {
    private let lock = NSLock()
    var delayedSessionId: String?
    var isConnected: Bool { true }

    func setCrashHandler(_ handler: (@Sendable (MediaWorkerError) -> Void)?) {}

    func openMedia(
        path: String,
        targetTracks: [Int]?
    ) async throws -> (sessionId: String, metadata: [String: Any]) {
        (
            UUID().uuidString,
            ["format": "mkv", "duration": 120.0, "videoTracks": [], "audioTracks": []]
        )
    }

    func readNextPacket(sessionId: String) async throws -> Data? {
        if lock.withLock({ delayedSessionId == sessionId }) {
            try await Task.sleep(for: .milliseconds(90))
        }
        let dto = try MediaPacketDTO(
            streamIndex: 0,
            mediaType: .video,
            ptsValue: 88_000,
            ptsTimescale: 1000,
            dtsValue: 88_000,
            dtsTimescale: 1000,
            durationValue: 40,
            durationTimescale: 1000,
            payloadData: Data([0x00, 0x00, 0x00, 0x01]),
            isKeyframe: true,
            doNotDisplay: false
        )
        return try JSONEncoder().encode(dto)
    }

    func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double {
        if lock.withLock({ delayedSessionId == sessionId }) {
            try await Task.sleep(for: .milliseconds(90))
        }
        return timestamp
    }

    func closeMedia(sessionId: String) async throws {
        if lock.withLock({ delayedSessionId == sessionId }) {
            try await Task.sleep(for: .milliseconds(90))
        }
    }

    func setSleepState(state: Int) async throws {}
    func invalidate() {}
    func reconnect() async throws {}
}

internal final class LoopbackXPCWorkerDelegate: NSObject, NSXPCListenerDelegate, TTMediaWorkerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var readCountsBySession: [String: Int] = [:]
    private(set) var closedSessionIds: [String] = []

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface.makeMediaWorkerInterface()
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func openMedia(
        at path: String,
        targetTracks: [NSNumber]?,
        reply: @escaping @Sendable (Bool, String?, [String: Any]?) -> Void
    ) {
        let sid = UUID().uuidString
        lock.withLock { readCountsBySession[sid] = 0 }
        reply(true, sid, ["format": "mkv", "duration": 42.0, "videoTracks": [], "audioTracks": []])
    }

    func readNextPacket(
        forSession sessionId: String,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        let count = lock.withLock { () -> Int in
            let current = readCountsBySession[sessionId, default: 0]
            readCountsBySession[sessionId] = current + 1
            return current
        }
        guard count == 0 else {
            reply(nil, nil)
            return
        }
        let dto = try? MediaPacketDTO(
            streamIndex: 0,
            mediaType: .video,
            ptsValue: 0,
            ptsTimescale: 1000,
            dtsValue: 0,
            dtsTimescale: 1000,
            durationValue: 40,
            durationTimescale: 1000,
            payloadData: Data([0x00, 0x00, 0x00, 0x01]),
            isKeyframe: true,
            doNotDisplay: false
        )
        reply(dto.flatMap { try? JSONEncoder().encode($0) }, nil)
    }

    func seek(
        to timestamp: Double,
        sessionId: String,
        accurate: Bool,
        reply: @escaping @Sendable (Bool, Double, String?) -> Void
    ) {
        reply(true, timestamp, nil)
    }

    func closeMedia(
        forSession sessionId: String,
        reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        lock.withLock { closedSessionIds.append(sessionId) }
        reply(true, nil)
    }

    func setSleepState(state: Int, reply: @escaping @Sendable (Bool) -> Void) {
        reply(true)
    }
}

internal final class ControllableCrashTransport: MediaWorkerTransport, @unchecked Sendable {
    private static let sampleH264AvcC = Data([
        0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1, 0x00, 0x0D,
        0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x01, 0x40, 0x16,
        0xE8, 0x06, 0xD0, 0xA1, 0x35, 0x01, 0x00, 0x04,
        0x68, 0xCE, 0x3C, 0x80
    ])
    private static let sampleH264Frame = Data([0x00, 0x00, 0x00, 0x02, 0x65, 0x01])

    private let lock = NSLock()
    private var crashHandler: (@Sendable (MediaWorkerError) -> Void)?
    private var packetCounter = 0
    private var connected = true
    private(set) var readPacketCalls = 0
    private(set) var crashCallbackCount = 0
    var crashOnPacketIndex: Int?
    var isConnected: Bool { lock.withLock { connected } }

    func setCrashHandler(_ handler: (@Sendable (MediaWorkerError) -> Void)?) {
        lock.withLock { crashHandler = handler }
    }

    func openMedia(
        path: String,
        targetTracks: [Int]?
    ) async throws -> (sessionId: String, metadata: [String: Any]) {
        try lock.withLock {
            guard connected else { throw MediaWorkerError.connectionInvalidated }
            packetCounter = 0
            readPacketCalls = 0
            return (
                UUID().uuidString,
                [
                    "format": "matroska",
                    "durationSeconds": 30.0,
                    "selectedVideoTrackNumber": 1,
                    "metadataCapability": "v1_structured_contract_v1",
                    "videoTracks": [
                        [
                            "trackIndex": 1,
                            "codec": "h264",
                            "rawCodecId": "V_MPEG4/ISO/AVC",
                            "width": 320,
                            "height": 240,
                            "extradata": Self.sampleH264AvcC,
                            "isSelectedForPackets": true
                        ]
                    ],
                    "audioTracks": []
                ]
            )
        }
    }

    func readNextPacket(sessionId: String) async throws -> Data? {
        let (index, shouldCrash): (Int, Bool) = lock.withLock {
            packetCounter += 1
            readPacketCalls += 1
            if let limit = crashOnPacketIndex, packetCounter >= limit {
                connected = false
                crashCallbackCount += 1
                return (packetCounter, true)
            }
            return (packetCounter, false)
        }
        if shouldCrash {
            lock.withLock { crashHandler }?(.connectionInvalidated)
            throw MediaWorkerError.connectionInvalidated
        }
        guard index <= 2 else { return nil }
        let dto = try MediaPacketDTO(
            streamIndex: 1,
            mediaType: .video,
            ptsValue: Int64(index * 40),
            ptsTimescale: 1000,
            dtsValue: Int64(index * 40),
            dtsTimescale: 1000,
            durationValue: 40,
            durationTimescale: 1000,
            payloadData: Self.sampleH264Frame,
            isKeyframe: true,
            doNotDisplay: false
        )
        return try JSONEncoder().encode(dto)
    }

    func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double {
        try lock.withLock {
            guard connected else { throw MediaWorkerError.connectionInvalidated }
            return timestamp
        }
    }

    func closeMedia(sessionId: String) async throws {}
    func setSleepState(state: Int) async throws {}

    func invalidate() {
        lock.withLock { connected = false }
    }

    func reconnect() async throws {
        lock.withLock {
            connected = true
            packetCounter = 0
        }
    }
}

internal enum CrossPIDSubtitleWorkerTestSupport {
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

    static func makeTwoClusterSubtitleMKV() -> Data {
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
                UInt8(timecodeMs & 0xff)
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
            + trackEntry(number: 3, lang: "zho", name: "Primary")
            + trackEntry(number: 4, lang: "eng", name: "Secondary")
        let segmentPayload = ebmlElement(id: [0x16, 0x54, 0xae, 0x6b], payload: tracksPayload)
            + clusterElement(timecodeMs: 1_000, cue3: "Early-3", cue4: "Early-4")
            + clusterElement(timecodeMs: 600_000, cue3: "Late-3", cue4: "Late-4")
        return Data(ebmlHeader + ebmlElement(id: [0x18, 0x53, 0x80, 0x67], payload: segmentPayload))
    }

    static func runCrossPIDNativeRustSingleTrackCancellation(
        cabiImagePath: String,
        mkvURL: URL,
        reqA: UInt64,
        reqB: UInt64,
        tempDir: URL
    ) throws -> [String: Any] {
        let scriptURL = tempDir.appendingPathComponent("cross_pid_rust_subtitle_worker.py")
        let script = """
        import ctypes, json, os, sys, threading, time

        lib = ctypes.CDLL(sys.argv[1])
        mkv_path = sys.argv[2].encode("utf-8")
        req_a = int(sys.argv[3])
        req_b = int(sys.argv[4])

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

        lib.ttmedia_subtitles_set_request_cluster_delay_ms(req_a, 240)
        lib.ttmedia_subtitles_set_request_cluster_delay_ms(req_b, 40)

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
        time.sleep(0.08)
        lib.ttmedia_subtitles_cancel_request(req_a)
        ta.join(timeout=3.0)
        tb.join(timeout=3.0)

        out = {
            "workerPid": os.getpid(),
            "reqACancelled": bool(lib.ttmedia_subtitles_is_request_cancelled(req_a)),
            "reqAClusters": int(lib.ttmedia_subtitles_last_scanned_clusters(req_a)),
            "reqAError": results.get("a", {}).get("error"),
            "reqBCancelled": bool(lib.ttmedia_subtitles_is_request_cancelled(req_b)),
            "reqBClusters": int(lib.ttmedia_subtitles_last_scanned_clusters(req_b)),
            "reqBCuesCount": len(results.get("b", {}).get("cues", [])),
        }
        sys.stdout.write(json.dumps(out))
        sys.stdout.flush()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [scriptURL.path, cabiImagePath, mkvURL.path, "\(reqA)", "\(reqB)"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        try proc.run()
        try? outPipe.fileHandleForWriting.close()
        let data = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        try? outPipe.fileHandleForReading.close()
        var status: Int32 = 0
        if proc.processIdentifier > 0 {
            _ = Darwin.waitpid(proc.processIdentifier, &status, 0)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
