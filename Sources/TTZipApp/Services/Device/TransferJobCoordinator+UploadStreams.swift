// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import TTZipAppCore
import TTZipCore

extension TransferJobCoordinator {
    struct UploadStreamRequest: Sendable {
        let jobId: String
        let rustJobId: String
        let deviceId: String
        let localPath: String
        let remoteDir: String
        let fileName: String
        let storageId: UInt32
        let conflictPolicy: AndroidTransferConflictPolicy
        let maxKeepBothCandidates: Int
        let sanitizedJobToken: String
        let expectedSha256Hex: String
        let totalBytes: UInt64
        let daemonPort: UInt16
        let customWriter: RemoteChunkWriter?
        let stagingPath: String?
        let engine: AppCoreEngine
    }

    struct StreamUploadInternalOutcome {
        let transferred: UInt64
        let skipped: Bool
        let actualStreamedSha256Hex: String
        let verificationLevel: AndroidTransferVerificationLevel
        let sourceStreamSha256Verified: Bool
        let remoteSizeVerified: Bool
        let remoteReadbackSha256Verified: Bool
    }

    func streamMtpUpload(_ request: UploadStreamRequest) throws -> StreamUploadInternalOutcome {
        let outcome = try MtpNativeClient.pushFileVerified(
            serial: request.deviceId,
            storageId: request.storageId,
            parentDir: request.remoteDir,
            fileName: request.fileName,
            localURL: URL(fileURLWithPath: request.localPath),
            expectedSha256Hex: request.expectedSha256Hex,
            conflictPolicy: request.conflictPolicy,
            maxKeepBothCandidates: request.maxKeepBothCandidates
        ) { sent, _ in
            if Task.isCancelled {
                throw CancellationError()
            }
            _ = sent
        }
        if outcome.skipped {
            return StreamUploadInternalOutcome(
                transferred: 0,
                skipped: true,
                actualStreamedSha256Hex: "",
                verificationLevel: .none,
                sourceStreamSha256Verified: false,
                remoteSizeVerified: false,
                remoteReadbackSha256Verified: false
            )
        }
        guard outcome.sourceStreamSha256Verified,
              outcome.remoteSizeVerified,
              outcome.sha256Hex == request.expectedSha256Hex else {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "MTP upload stream SHA-256 or remote object size verification failed before commit"
            )
        }
        if outcome.bytesTransferred > 0 {
            _ = try? request.engine.recordTransferChunk(jobIdStr: request.rustJobId, chunkBytes: outcome.bytesTransferred)
            self.updateProgress(jobId: request.jobId, transferredBytes: outcome.bytesTransferred, totalBytes: request.totalBytes)
        }
        self.markJobCommitted(jobId: request.jobId)
        let level: AndroidTransferVerificationLevel = outcome.remoteReadbackSha256Verified
            ? .remoteReadbackSha256Verified
            : .sourceStreamAndRemoteSizeVerified
        return StreamUploadInternalOutcome(
            transferred: outcome.bytesTransferred,
            skipped: false,
            actualStreamedSha256Hex: outcome.sha256Hex,
            verificationLevel: level,
            sourceStreamSha256Verified: outcome.sourceStreamSha256Verified,
            remoteSizeVerified: outcome.remoteSizeVerified,
            remoteReadbackSha256Verified: outcome.remoteReadbackSha256Verified
        )
    }

    func streamLocalUpload(_ request: UploadStreamRequest) async throws -> StreamUploadInternalOutcome {
        guard let readHandle = FileHandle(forReadingAtPath: request.localPath) else {
            throw AdbSmartSocketError.syncProtocolError(
                reason: TTZipLocalizationManager.shared.string(
                    for: L10n.AndroidInterconnect.errorTransferDeviceDisconnected
                )
            )
        }
        defer { try? readHandle.close() }

        var writeHandle: FileHandle?
        if let stagingPath = request.stagingPath {
            try FileManager.default.createDirectory(atPath: request.remoteDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stagingPath, contents: nil)
            writeHandle = FileHandle(forWritingAtPath: stagingPath)
        }
        defer { try? writeHandle?.close() }

        if request.totalBytes == 0 {
            let emptyHex = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
            guard emptyHex == request.expectedSha256Hex else {
                throw AdbSmartSocketError.syncProtocolError(reason: "Upload stream SHA-256 mismatch against source file")
            }
            return StreamUploadInternalOutcome(
                transferred: 0,
                skipped: false,
                actualStreamedSha256Hex: emptyHex,
                verificationLevel: .sourceStreamAndRemoteSizeVerified,
                sourceStreamSha256Verified: true,
                remoteSizeVerified: true,
                remoteReadbackSha256Verified: false
            )
        }

        return try await streamLocalUploadChunks(request, readHandle: readHandle, writeHandle: writeHandle)
    }

    private func streamLocalUploadChunks(_ request: UploadStreamRequest, readHandle: FileHandle, writeHandle: FileHandle?) async throws -> StreamUploadInternalOutcome {
        var hasher = SHA256()
        let chunkSize: UInt64 = 65_536
        var transferred: UInt64 = 0
        while !Task.isCancelled && transferred < request.totalBytes {
            let remaining = request.totalBytes - transferred
            let currentChunkLen = Int(min(chunkSize, remaining))
            guard let chunk = try readHandle.read(upToCount: currentChunkLen), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
            let nextTransferred = transferred + UInt64(chunk.count)
            if let writer = request.customWriter {
                try writer(request.deviceId, request.remoteDir, request.fileName, transferred, chunk, nextTransferred >= request.totalBytes)
            } else if let wh = writeHandle {
                try wh.write(contentsOf: chunk)
            }
            let progress = try request.engine.recordTransferChunk(jobIdStr: request.rustJobId, chunkBytes: UInt64(chunk.count))
            transferred = progress.transferredBytes
            self.updateProgress(jobId: request.jobId, transferredBytes: transferred, totalBytes: request.totalBytes)
            await Task.yield()
        }
        try? writeHandle?.synchronize()
        let streamedHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if transferred == request.totalBytes && streamedHex != request.expectedSha256Hex {
            throw AdbSmartSocketError.syncProtocolError(reason: "Upload stream SHA-256 mismatch against source file")
        }
        return StreamUploadInternalOutcome(
            transferred: transferred,
            skipped: false,
            actualStreamedSha256Hex: streamedHex,
            verificationLevel: .sourceStreamAndRemoteSizeVerified,
            sourceStreamSha256Verified: transferred == request.totalBytes && streamedHex == request.expectedSha256Hex,
            remoteSizeVerified: transferred == request.totalBytes,
            remoteReadbackSha256Verified: false
        )
    }

}
