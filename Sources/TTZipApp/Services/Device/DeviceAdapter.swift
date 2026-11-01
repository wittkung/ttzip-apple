// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Darwin
import Foundation
import TTZipAppCore
import TTZipCore

extension AppCoreEngine {
    /// Shared singleton instance for unified native desktop application engine operations.
    public static let shared: AppCoreEngine = {
        let configPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ttzip_app_core")
        try? FileManager.default.createDirectory(atPath: configPath, withIntermediateDirectories: true)
        if let engine = try? AppCoreEngine(configDir: configPath) {
            return engine
        }
        fatalError("Failed to initialize AppCoreEngine singleton")
    }()
}

/// Typed errors emitted by the ADB Smart Socket pairing, connection, and SYNC protocol client.
public enum AdbSmartSocketError: LocalizedError, Sendable, Equatable {
    case invalidPinLength
    case invalidEndpoint
    case daemonUnreachable(host: String, port: UInt16)
    case pairingRejected(reason: String)
    case connectionRejected(reason: String)
    case deviceUnauthorized(serial: String)
    case deviceOffline(serial: String)
    case connectPortUnresolved(host: String)
    case commitStatusUnknown(reason: String)
    case syncProtocolError(reason: String)

    public var errorDescription: String? {
        let l10n = TTZipLocalizationManager.shared
        switch self {
        case .invalidPinLength:
            return l10n.string(for: L10n.AndroidInterconnect.errorInvalidPinLength)
        case .invalidEndpoint:
            return l10n.string(for: L10n.AndroidInterconnect.errorInvalidEndpoint)
        case .daemonUnreachable:
            return l10n.string(for: L10n.AndroidInterconnect.errorDaemonUnreachable)
        case .pairingRejected(let reason):
            return l10n.format(L10n.AndroidInterconnect.errorPinRejectedFormat, reason)
        case .connectionRejected(let reason):
            return l10n.format(L10n.AndroidInterconnect.errorConnectRejectedFormat, reason)
        case .deviceUnauthorized:
            return l10n.string(for: L10n.AndroidInterconnect.errorDeviceUnauthorized)
        case .deviceOffline:
            return l10n.string(for: L10n.AndroidInterconnect.errorDeviceOffline)
        case .connectPortUnresolved:
            return l10n.string(for: L10n.AndroidInterconnect.errorConnectPortUnresolved)
        case .syncProtocolError(let reason), .commitStatusUnknown(let reason):
            return reason
        }
    }
}

/// Parsed record from `host:devices-l` returned by the local ADB server.
public struct AdbDaemonDeviceRecord: Sendable, Equatable {
    public let serial: String
    public let state: String
    public let model: String?
    public let product: String?

    public init(serial: String, state: String, model: String? = nil, product: String? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
    }
}

/// Authentic AOSP Smart Socket (`127.0.0.1:5037`) and `SYNC` client for wireless pairing,
/// session verification, and streaming file transfers.
public enum AdbSmartSocketClient {
    public static let defaultDaemonHost = "127.0.0.1"
    public static let defaultDaemonPort: UInt16 = 5037

    /// Default primary partition assigned to connected Android devices when storage metadata has not yet been queried.
    public static func defaultPartitions(for connectionType: AndroidConnectionType) -> [AndroidStoragePartition] {
        let root = connectionType == .usbMtp ? "/" : "/storage/emulated/0"
        return [
            AndroidStoragePartition(
                partitionId: "primary",
                displayName: "Internal Shared Storage",
                totalBytes: 0,
                availableBytes: 0,
                rootPath: root,
                isRemovable: false
            )
        ]
    }

    /// Sends a single Smart Socket `host:` command and returns the response payload after `OKAY`.
    public static func sendHostCommand(
        _ command: String,
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort,
        timeoutMs: Int32 = 5_000
    ) throws -> String {
        let fd = try openSocket(host: daemonHost, port: daemonPort, timeoutMs: timeoutMs)
        defer { Darwin.close(fd) }

        try writeSmartCommand(fd: fd, command: command)
        let status = try readExactString(fd: fd, length: 4)
        let payload = try readLengthPrefixedPayload(fd: fd)

        if status == "OKAY" {
            return payload
        }
        throw AdbSmartSocketError.pairingRejected(
            reason: payload.isEmpty ? "ADB daemon returned \(status)" : payload
        )
    }

    /// Queries `host:devices-l` from the local ADB daemon and parses all attached/wireless records.
    public static func listDevices(
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort,
        timeoutMs: Int32 = 3_000
    ) throws -> [AdbDaemonDeviceRecord] {
        let payload = try sendHostCommand(
            "host:devices-l",
            daemonHost: daemonHost,
            daemonPort: daemonPort,
            timeoutMs: timeoutMs
        )
        return parseDevicesList(payload)
    }

    /// Probes both ADB daemon reachability and whether at least one authorized `device` session is active.
    public static func probeAuthorizedDevices(
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort
    ) -> (daemonReachable: Bool, authorizedDevices: [AdbDaemonDeviceRecord]) {
        guard let records = try? listDevices(daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: 1_500) else {
            return (false, [])
        }
        let authorized = records.filter { $0.state == "device" }
        return (true, authorized)
    }

    /// Executes real Android 11+ wireless pairing (`host:pair:<pin>:<host>:<pairingPort>`) followed by
    /// session verification (`host:devices-l` and `host:connect`), rejecting wrong/expired PINs or unauthorized sessions.
    public static func pairAndConnectWireless(
        pin: String,
        host: String,
        pairingPort: UInt16,
        connectPort: UInt16? = nil,
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort,
        timeoutMs: Int32 = 5_000
    ) throws -> AndroidDevice {
        try validatePairingInputs(pin: pin, host: host, port: pairingPort)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

        let pairPayload = try sendHostCommand(
            "host:pair:\(pin):\(trimmedHost):\(pairingPort)",
            daemonHost: daemonHost,
            daemonPort: daemonPort,
            timeoutMs: timeoutMs
        )
        try verifyPairResponsePayload(pairPayload)

        return try resolveConnectedSession(
            host: trimmedHost,
            pairingPort: pairingPort,
            connectPort: connectPort,
            daemonHost: daemonHost,
            daemonPort: daemonPort,
            timeoutMs: timeoutMs
        )
    }

    private static func validatePairingInputs(pin: String, host: String, port: UInt16) throws {
        let isSixDigits = pin.count == 6 && pin.allSatisfy { $0.isASCII && $0.isNumber }
        guard isSixDigits else {
            throw AdbSmartSocketError.invalidPinLength
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, port > 0 else {
            throw AdbSmartSocketError.invalidEndpoint
        }
    }

    private static func verifyPairResponsePayload(_ payload: String) throws {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("failed") || lower.contains("error") || !lower.contains("successfully paired to") {
            throw AdbSmartSocketError.pairingRejected(
                reason: trimmed.isEmpty ? "Empty pairing response from ADB daemon" : trimmed
            )
        }
    }

    /// Connects to an already-paired wireless Android device on its Wireless Debugging transport port.
    public static func connectWireless(
        host: String,
        connectionPort: UInt16 = 5555,
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort,
        timeoutMs: Int32 = 5_000
    ) throws -> AndroidDevice {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, connectionPort > 0 else {
            throw AdbSmartSocketError.invalidEndpoint
        }
        return try resolveConnectedSession(
            host: trimmedHost,
            pairingPort: 0,
            connectPort: connectionPort,
            daemonHost: daemonHost,
            daemonPort: daemonPort,
            timeoutMs: timeoutMs
        )
    }

    private static func resolveConnectedSession(
        host: String,
        pairingPort: UInt16,
        connectPort: UInt16?,
        daemonHost: String,
        daemonPort: UInt16,
        timeoutMs: Int32
    ) throws -> AndroidDevice {
        guard let targetPort = connectPort else {
            // Do NOT fall back to pairingPort: Android 11+ closes the ephemeral SPAKE2 pairing port
            // immediately after `host:pair` succeeds. Check whether the local ADB daemon auto-connected
            // via mDNS (`_adb-tls-connect._tcp`); otherwise require an explicit connectPort.
            if let initialRecords = try? listDevices(daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs),
               let matched = findMatchingRecord(in: initialRecords, host: host, preferredPort: nil),
               matched.serial != "\(host):\(pairingPort)" {
                return try buildVerifiedDevice(from: matched, host: host)
            }
            throw AdbSmartSocketError.connectPortUnresolved(host: host)
        }

        if pairingPort > 0 && targetPort == pairingPort {
            throw AdbSmartSocketError.connectPortUnresolved(host: host)
        }

        let connectPayload = try sendHostCommand(
            "host:connect:\(host):\(targetPort)",
            daemonHost: daemonHost,
            daemonPort: daemonPort,
            timeoutMs: timeoutMs
        )
        try verifyConnectResponsePayload(connectPayload, serial: "\(host):\(targetPort)")

        let updatedRecords = try listDevices(daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs)
        if let matched = findMatchingRecord(in: updatedRecords, host: host, preferredPort: targetPort) {
            return try buildVerifiedDevice(from: matched, host: host)
        }
        throw AdbSmartSocketError.connectPortUnresolved(host: host)
    }

    private static func verifyConnectResponsePayload(_ payload: String, serial: String) throws {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("failed to authenticate") || lower.contains("unauthorized") {
            throw AdbSmartSocketError.deviceUnauthorized(serial: serial)
        }
        if lower.contains("failed to") || lower.contains("unable to") || lower.contains("cannot connect") {
            throw AdbSmartSocketError.connectionRejected(reason: trimmed)
        }
        if !lower.contains("connected to") && !lower.contains("already connected to") {
            throw AdbSmartSocketError.connectionRejected(
                reason: trimmed.isEmpty ? "Unexpected empty connect payload" : trimmed
            )
        }
    }

    private static func findMatchingRecord(
        in records: [AdbDaemonDeviceRecord],
        host: String,
        preferredPort: UInt16?
    ) -> AdbDaemonDeviceRecord? {
        if let port = preferredPort,
           let exact = records.first(where: { $0.serial == "\(host):\(port)" }) {
            return exact
        }
        return records.first { $0.serial == host || $0.serial.hasPrefix("\(host):") }
    }

    private static func buildVerifiedDevice(
        from record: AdbDaemonDeviceRecord,
        host: String
    ) throws -> AndroidDevice {
        switch record.state {
        case "device":
            return AndroidDevice(
                deviceId: record.serial,
                displayName: record.model ?? host,
                vendorId: 0,
                productId: 0,
                serialNumber: record.serial,
                connectionType: .wirelessAdb,
                status: .connected,
                storagePartitions: defaultPartitions(for: .wirelessAdb)
            )
        case "unauthorized":
            throw AdbSmartSocketError.deviceUnauthorized(serial: record.serial)
        default:
            throw AdbSmartSocketError.deviceOffline(serial: record.serial)
        }
    }

    /// Parses `host:devices-l` text lines into structured `AdbDaemonDeviceRecord` values.
    public static func parseDevicesList(_ payload: String) -> [AdbDaemonDeviceRecord] {
        var records: [AdbDaemonDeviceRecord] = []
        for rawLine in payload.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("*") || line.hasPrefix("List of devices") {
                continue
            }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 2 else { continue }
            var model: String?
            var product: String?
            for token in tokens.dropFirst(2) {
                if token.hasPrefix("model:") {
                    model = String(token.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
                } else if token.hasPrefix("product:") {
                    product = String(token.dropFirst("product:".count))
                }
            }
            records.append(AdbDaemonDeviceRecord(serial: tokens[0], state: tokens[1], model: model, product: product))
        }
        return records
    }

    // MARK: - ADB SYNC File Pull & Push

    /// Pulls a file over ADB `SYNC` (`RECV`) and streams each verified `DATA` frame to `onChunk`.
    public static func pullFile(
        serial: String,
        remotePath: String,
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort,
        timeoutMs: Int32 = 10_000,
        onChunk: (Data) throws -> Void
    ) throws -> UInt64 {
        let fd = try openSyncSession(serial: serial, daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs)
        defer {
            _ = try? writeAll(fd: fd, bytes: Array("QUIT\0\0\0\0".utf8))
            Darwin.close(fd)
        }

        try sendSyncRequest(fd: fd, tag: "RECV", payload: Array(remotePath.utf8))
        var totalBytes: UInt64 = 0
        while true {
            let header = try readExact(fd: fd, length: 8)
            let tag = String(decoding: header[0..<4], as: UTF8.self)
            let length = Int(readUInt32LE(header, offset: 4))
            switch tag {
            case "DATA":
                if length > 0 {
                    let chunk = try readExact(fd: fd, length: length)
                    try onChunk(chunk)
                    totalBytes += UInt64(chunk.count)
                }
            case "DONE":
                return totalBytes
            case "FAIL":
                let reason = length > 0 ? (try? readExactString(fd: fd, length: length)) ?? "SYNC RECV failed" : "SYNC RECV failed"
                throw AdbSmartSocketError.syncProtocolError(reason: reason)
            default:
                throw AdbSmartSocketError.syncProtocolError(reason: "Unexpected ADB SYNC RECV frame tag '\(tag)'")
            }
        }
    }

    /// Pushes a local file over ADB `SYNC` (`SEND`) in 64 KiB `DATA` frames and verifies `OKAY`.
    public static func pushFile(
        serial: String,
        localURL: URL,
        remotePath: String,
        posixMode: UInt32 = 0o644,
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort,
        timeoutMs: Int32 = 10_000,
        onChunkSent: (Int) throws -> Void
    ) throws -> UInt64 {
        let result = try pushFileVerified(
            serial: serial,
            localURL: localURL,
            remotePath: remotePath,
            posixMode: posixMode,
            daemonHost: daemonHost,
            daemonPort: daemonPort,
            timeoutMs: timeoutMs,
            onChunkSent: onChunkSent
        )
        return result.bytesSent
    }

    /// Pushes a local file over ADB `SYNC` (`SEND`) in 64 KiB `DATA` frames, computing the SHA-256 of the actual
    /// transmitted stream and rejecting sizes exceeding the 32-bit `STAT` verification ceiling before writing.
    public static func pushFileVerified(
        serial: String,
        localURL: URL,
        remotePath: String,
        posixMode: UInt32 = 0o644,
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort,
        timeoutMs: Int32 = 10_000,
        onChunkSent: (Int) throws -> Void
    ) throws -> (bytesSent: UInt64, actualStreamedSha256Hex: String) {
        if let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value,
           fileSize > UInt64(UInt32.max) {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "File size \(fileSize) exceeds 32-bit ADB SYNC STAT v1 verification limit (\(UInt32.max) bytes)"
            )
        }

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }

        let fd = try openSyncSession(serial: serial, daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs)
        defer {
            _ = try? writeAll(fd: fd, bytes: Array("QUIT\0\0\0\0".utf8))
            Darwin.close(fd)
        }

        let spec = "\(remotePath),\(posixMode | 0o100000)"
        try sendSyncRequest(fd: fd, tag: "SEND", payload: Array(spec.utf8))

        var totalSent: UInt64 = 0
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            if totalSent + UInt64(chunk.count) > UInt64(UInt32.max) {
                throw AdbSmartSocketError.syncProtocolError(
                    reason: "Streamed payload exceeds 32-bit ADB SYNC STAT v1 verification limit (\(UInt32.max) bytes)"
                )
            }
            try sendSyncRequest(fd: fd, tag: "DATA", payload: Array(chunk))
            hasher.update(data: chunk)
            totalSent += UInt64(chunk.count)
            try onChunkSent(chunk.count)
        }

        let mtime = UInt32(Date().timeIntervalSince1970)
        try writeSyncHeader(fd: fd, tag: "DONE", value: mtime)

        try receiveUploadAcknowledgement(fd: fd)
        let digestHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (totalSent, digestHex)
    }

    private static func receiveUploadAcknowledgement(fd: Int32) throws {
        let respHeader = try readExact(fd: fd, length: 8)
        let respTag = String(decoding: respHeader[0..<4], as: UTF8.self)
        let respLen = Int(readUInt32LE(respHeader, offset: 4))
        if respTag == "OKAY" { return }
        let reason = respLen > 0 ? (try? readExactString(fd: fd, length: respLen)) ?? "SYNC SEND rejected" : "SYNC SEND rejected (\(respTag))"
        throw AdbSmartSocketError.syncProtocolError(reason: reason)
    }

    /// Queries remote file metadata over ADB `SYNC` (`STAT`).
    /// Returns `(exists: false, 0, 0, 0)` when `mode == 0`.
    public static func statRemoteFile(
        serial: String,
        remotePath: String,
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort,
        timeoutMs: Int32 = 5_000
    ) throws -> (exists: Bool, mode: UInt32, size: UInt32, mtime: UInt32) {
        let fd = try openSyncSession(serial: serial, daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs)
        defer {
            _ = try? writeAll(fd: fd, bytes: Array("QUIT\0\0\0\0".utf8))
            Darwin.close(fd)
        }

        try sendSyncRequest(fd: fd, tag: "STAT", payload: Array(remotePath.utf8))
        let response = try readExact(fd: fd, length: 16)
        let tag = String(decoding: response[0..<4], as: UTF8.self)
        guard tag == "STAT" else {
            throw AdbSmartSocketError.syncProtocolError(reason: "Unexpected ADB SYNC STAT response tag '\(tag)'")
        }
        let mode = readUInt32LE(response, offset: 4)
        let size = readUInt32LE(response, offset: 8)
        let mtime = readUInt32LE(response, offset: 12)
        return (mode != 0, mode, size, mtime)
    }

    /// Executes a non-interactive shell command on the target ADB device via `host:transport:<serial>` + `shell:`.
    @discardableResult
    public static func executeShellCommand(
        serial: String,
        command: String,
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort,
        timeoutMs: Int32 = 5_000
    ) throws -> String {
        let cleanSerial = serial.hasPrefix("adb://") ? String(serial.dropFirst("adb://".count)) : serial
        let fd = try openSocket(host: daemonHost, port: daemonPort, timeoutMs: timeoutMs)
        defer { Darwin.close(fd) }

        try writeSmartCommand(fd: fd, command: "host:transport:\(cleanSerial)")
        let transportStatus = try readExactString(fd: fd, length: 4)
        guard transportStatus == "OKAY" else {
            let err = (try? readLengthPrefixedPayload(fd: fd)) ?? "transport selection failed"
            throw AdbSmartSocketError.syncProtocolError(reason: err)
        }

        try writeSmartCommand(fd: fd, command: "shell:\(command)")
        let shellStatus = try readExactString(fd: fd, length: 4)
        guard shellStatus == "OKAY" else {
            let err = (try? readLengthPrefixedPayload(fd: fd)) ?? "shell command rejected"
            throw AdbSmartSocketError.syncProtocolError(reason: err)
        }

        var output = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.recv(fd, base, 4096, 0)
            }
            if n <= 0 { break }
            output.append(contentsOf: buf[0..<n])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Best-effort removes a remote temporary/staging file on cancellation or upload failure.
    public static func removeRemoteFileBestEffort(
        serial: String,
        remotePath: String,
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort,
        timeoutMs: Int32 = 3_000
    ) {
        let escaped = shellSingleQuote(remotePath)
        _ = try? executeShellCommand(
            serial: serial,
            command: "rm -f \(escaped)",
            daemonHost: daemonHost,
            daemonPort: daemonPort,
            timeoutMs: timeoutMs
        )
    }

    static func shellSingleQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Low-Level POSIX Socket Framing

    private static func openSyncSession(
        serial: String,
        daemonHost: String,
        daemonPort: UInt16,
        timeoutMs: Int32
    ) throws -> Int32 {
        let cleanSerial = serial.hasPrefix("adb://") ? String(serial.dropFirst("adb://".count)) : serial
        let fd = try openSocket(host: daemonHost, port: daemonPort, timeoutMs: timeoutMs)
        do {
            try writeSmartCommand(fd: fd, command: "host:transport:\(cleanSerial)")
            let transportStatus = try readExactString(fd: fd, length: 4)
            guard transportStatus == "OKAY" else {
                let err = (try? readLengthPrefixedPayload(fd: fd)) ?? "transport selection failed"
                throw AdbSmartSocketError.syncProtocolError(reason: err)
            }
            try writeSmartCommand(fd: fd, command: "sync:")
            let syncStatus = try readExactString(fd: fd, length: 4)
            guard syncStatus == "OKAY" else {
                let err = (try? readLengthPrefixedPayload(fd: fd)) ?? "sync handshake failed"
                throw AdbSmartSocketError.syncProtocolError(reason: err)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func openSocket(host: String, port: UInt16, timeoutMs: Int32) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw AdbSmartSocketError.daemonUnreachable(host: host, port: port)
        }

        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(
            tv_sec: __darwin_time_t(max(1, timeoutMs / 1000)),
            tv_usec: __darwin_suseconds_t((timeoutMs % 1000) * 1000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            throw AdbSmartSocketError.invalidEndpoint
        }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw AdbSmartSocketError.daemonUnreachable(host: host, port: port)
        }
        return fd
    }

    private static func writeSmartCommand(fd: Int32, command: String) throws {
        let framed = String(format: "%04x%@", command.utf8.count, command)
        try writeAll(fd: fd, bytes: Array(framed.utf8))
    }

    private static func sendSyncRequest(fd: Int32, tag: String, payload: [UInt8]) throws {
        try writeSyncHeader(fd: fd, tag: tag, value: UInt32(payload.count))
        if !payload.isEmpty {
            try writeAll(fd: fd, bytes: payload)
        }
    }

    private static func writeSyncHeader(fd: Int32, tag: String, value: UInt32) throws {
        var header = Array(tag.utf8.prefix(4))
        let le = value.littleEndian
        withUnsafeBytes(of: le) { header.append(contentsOf: $0) }
        try writeAll(fd: fd, bytes: header)
    }

    private static func writeAll(fd: Int32, bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
            }
            if written <= 0 {
                throw AdbSmartSocketError.syncProtocolError(reason: "Socket write failed or closed")
            }
            offset += written
        }
    }

    private static func readExact(fd: Int32, length: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: length)
        var offset = 0
        while offset < length {
            let n = buffer.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.recv(fd, base.advanced(by: offset), length - offset, 0)
            }
            if n <= 0 {
                throw AdbSmartSocketError.syncProtocolError(reason: "Unexpected EOF from ADB socket")
            }
            offset += n
        }
        return Data(buffer)
    }

    private static func readExactString(fd: Int32, length: Int) throws -> String {
        let data = try readExact(fd: fd, length: length)
        return String(decoding: data, as: UTF8.self)
    }

    private static func readLengthPrefixedPayload(fd: Int32) throws -> String {
        guard let hexStr = try? readExactString(fd: fd, length: 4) else {
            return ""
        }
        guard let byteCount = Int(hexStr, radix: 16), byteCount > 0 else {
            return ""
        }
        return try readExactString(fd: fd, length: byteCount)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1]) << 8
        let b2 = UInt32(data[data.startIndex + offset + 2]) << 16
        let b3 = UInt32(data[data.startIndex + offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
