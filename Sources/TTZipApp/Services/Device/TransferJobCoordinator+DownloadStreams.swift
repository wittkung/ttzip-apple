// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import TTZipAppCore
import TTZipCore

extension TransferJobCoordinator {
    struct DownloadStreamRequest: Sendable {
        let jobId: String
        let rustJobId: String
        let deviceId: String
        let remotePath: String
        let storageId: UInt32
        let objectHandle: UInt32
        let stagedCommitPath: String
        let totalBytes: UInt64
        let daemonPort: UInt16
        let customReader: RemoteChunkReader?
        let engine: AppCoreEngine
    }

    func streamAdbDownload(_ request: DownloadStreamRequest) throws -> (UInt64, String) {
        var hasher = SHA256()
        var cumulative: UInt64 = 0
        _ = try AdbSmartSocketClient.pullFile(
            serial: request.deviceId,
            remotePath: request.remotePath,
            daemonPort: request.daemonPort
        ) { chunk in
            if Task.isCancelled {
                throw CancellationError()
            }
            hasher.update(data: chunk)
            cumulative = try request.engine.writeTransferChunk(jobIdStr: request.rustJobId, chunkData: chunk)
        }
        if request.totalBytes == 0 && cumulative > 0 {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "Remote file reported 0 bytes but contains unread payload; download rejected to protect target"
            )
        }
        self.updateProgress(jobId: request.jobId, transferredBytes: cumulative, totalBytes: request.totalBytes)
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (cumulative, hex)
    }

    func streamMtpDownload(_ request: DownloadStreamRequest) throws -> (UInt64, String) {
        var hasher = SHA256()
        let rawBridgeURL = URL(fileURLWithPath: "\(request.stagedCommitPath).mtp_bridge")
        defer { try? FileManager.default.removeItem(at: rawBridgeURL) }

        let outcome = try MtpNativeClient.pullFileToStagedURL(
            serial: request.deviceId,
            storageId: request.storageId,
            objectHandle: request.objectHandle,
            remotePath: request.remotePath,
            stagedLocalURL: rawBridgeURL
        ) { _, _ in
            if Task.isCancelled {
                throw CancellationError()
            }
        }

        let readHandle = try FileHandle(forReadingFrom: rawBridgeURL)
        defer { try? readHandle.close() }
        var cumulative: UInt64 = 0
        while true {
            if Task.isCancelled {
                throw CancellationError()
            }
            let chunk = (try readHandle.read(upToCount: 65_536)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            cumulative = try request.engine.writeTransferChunk(jobIdStr: request.rustJobId, chunkData: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard cumulative == outcome.bytesTransferred, hex == outcome.sha256Hex else {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "MTP bridge staged download digest mismatch against transfer chunk stream"
            )
        }
        if request.totalBytes == 0 && cumulative > 0 {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "Remote MTP object reported 0 bytes but contains unread payload; download rejected to protect target"
            )
        }
        self.updateProgress(jobId: request.jobId, transferredBytes: cumulative, totalBytes: request.totalBytes)
        return (cumulative, hex)
    }

    func streamLocalDownload(_ request: DownloadStreamRequest) async throws -> (UInt64, String) {
        var hasher = SHA256()
        let fileHandle = try openDownloadSource(request)
        defer { try? fileHandle?.close() }
        if request.totalBytes == 0 {
            try verifyEmptyDownload(request, handle: fileHandle)
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (0, hex)
        }

        let chunkSize: UInt64 = 65_536
        var transferred: UInt64 = 0
        while !Task.isCancelled && transferred < request.totalBytes {
            let remaining = request.totalBytes - transferred
            let currentChunkLen = Int(min(chunkSize, remaining))
            let chunk = try readDownloadChunk(request, handle: fileHandle, offset: transferred, count: currentChunkLen)
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
            transferred = try request.engine.writeTransferChunk(jobIdStr: request.rustJobId, chunkData: chunk)
            self.updateProgress(jobId: request.jobId, transferredBytes: transferred, totalBytes: request.totalBytes)
            await Task.yield()
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (transferred, hex)
    }

    private func openDownloadSource(_ request: DownloadStreamRequest) throws -> FileHandle? {
        if request.deviceId.hasPrefix("adb://") || request.deviceId.hasPrefix("mtp://") { return nil }
        let path = request.remotePath.hasPrefix("file://") ? String(request.remotePath.dropFirst(7)) : request.remotePath
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw AdbSmartSocketError.syncProtocolError(
                reason: TTZipLocalizationManager.shared.string(for: L10n.AndroidInterconnect.errorTransferDeviceDisconnected)
            )
        }
        return handle
    }

    private func readDownloadChunk(_ request: DownloadStreamRequest, handle: FileHandle?, offset: UInt64, count: Int) throws -> Data {
        if let handle { return (try handle.read(upToCount: count)) ?? Data() }
        if let reader = request.customReader { return try reader(request.deviceId, request.remotePath, offset, count) }
        return Data()
    }

    private func verifyEmptyDownload(_ request: DownloadStreamRequest, handle: FileHandle?) throws {
        let probe = try readDownloadChunk(request, handle: handle, offset: 0, count: 1)
        if !probe.isEmpty {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "Remote file reported 0 bytes but contains payload; transfer rejected to protect target"
            )
        }
    }

}
