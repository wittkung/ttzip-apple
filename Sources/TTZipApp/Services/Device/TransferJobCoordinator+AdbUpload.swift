// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import TTZipAppCore
import TTZipCore

extension TransferJobCoordinator {
    func streamAdbUpload(_ request: UploadStreamRequest) throws -> StreamUploadInternalOutcome {
        guard let (baseDir, targetFileName, finalRemotePath) = try resolveAdbUploadDestination(request) else {
            return StreamUploadInternalOutcome(
                transferred: 0, skipped: true, actualStreamedSha256Hex: "", verificationLevel: .none,
                sourceStreamSha256Verified: false, remoteSizeVerified: false, remoteReadbackSha256Verified: false
            )
        }
        let stagedRemotePath = "\(baseDir)/.ttzip_part_\(request.sanitizedJobToken)_\(targetFileName)"
        do {
            let (cumulative, actualStreamedSha256Hex) = try pushVerifiedAdbStaging(request, stagedRemotePath: stagedRemotePath)
            try AdbSmartSocketClient.commitStagedRemoteFile(
                serial: request.deviceId,
                stagedRemotePath: stagedRemotePath,
                finalRemotePath: finalRemotePath,
                expectedBytes: request.totalBytes,
                conflictPolicy: request.conflictPolicy,
                daemonPort: request.daemonPort
            )
            self.markJobCommitted(jobId: request.jobId)
            self.updateProgress(jobId: request.jobId, transferredBytes: cumulative, totalBytes: request.totalBytes)
            return StreamUploadInternalOutcome(
                transferred: cumulative,
                skipped: false,
                actualStreamedSha256Hex: actualStreamedSha256Hex,
                verificationLevel: .sourceStreamAndRemoteSizeVerified,
                sourceStreamSha256Verified: true,
                remoteSizeVerified: true,
                remoteReadbackSha256Verified: false
            )
        } catch let err as AdbSmartSocketError {
            if case .commitStatusUnknown = err {
                self.markJobCommitUnknown(jobId: request.jobId)
                self.recordVerifiedDigest(
                    jobId: request.jobId,
                    sha256Hex: request.expectedSha256Hex,
                    verificationLevel: .none,
                    sourceStreamSha256Verified: true,
                    remoteSizeVerified: false,
                    remoteReadbackSha256Verified: false
                )
                throw err
            }
            AdbSmartSocketClient.removeRemoteFileBestEffort(
                serial: request.deviceId,
                remotePath: stagedRemotePath,
                daemonPort: request.daemonPort
            )
            throw err
        } catch {
            AdbSmartSocketClient.removeRemoteFileBestEffort(
                serial: request.deviceId,
                remotePath: stagedRemotePath,
                daemonPort: request.daemonPort
            )
            throw error
        }
    }

    private func resolveAdbUploadDestination(_ request: UploadStreamRequest) throws -> (String, String, String)? {
        let cleanDir = request.remoteDir.hasSuffix("/") ? String(request.remoteDir.dropLast()) : request.remoteDir
        let baseDir = cleanDir.isEmpty ? "" : cleanDir
        var targetFileName = request.fileName
        var finalRemotePath = "\(baseDir)/\(targetFileName)"

        // Strict conflict probe: never swallow STAT errors with try?.
        let existingStat = try AdbSmartSocketClient.statRemoteFile(
            serial: request.deviceId,
            remotePath: finalRemotePath,
            daemonPort: request.daemonPort
        )
        if existingStat.exists {
            switch request.conflictPolicy {
            case .skip:
                return nil
            case .keepBoth:
                let limit = max(1, request.maxKeepBothCandidates)
                let nsName = request.fileName as NSString
                let ext = nsName.pathExtension
                let stem = nsName.deletingPathExtension
                var foundCandidate = false
                for index in 1...limit {
                    let candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
                    let candidatePath = "\(baseDir)/\(candidate)"
                    let stat = try AdbSmartSocketClient.statRemoteFile(
                        serial: request.deviceId,
                        remotePath: candidatePath,
                        daemonPort: request.daemonPort
                    )
                    if !stat.exists {
                        targetFileName = candidate
                        finalRemotePath = candidatePath
                        foundCandidate = true
                        break
                    }
                }
                guard foundCandidate else {
                    throw AdbSmartSocketError.syncProtocolError(
                        reason: "ADB KeepBoth candidate names exhausted for '\(request.fileName)' (limit \(limit))"
                    )
                }
            case .overwrite:
                break
            }
        }

        return (baseDir, targetFileName, finalRemotePath)
    }

    private func pushVerifiedAdbStaging(_ request: UploadStreamRequest, stagedRemotePath: String) throws -> (UInt64, String) {
        var cumulative: UInt64 = 0
        let (sentBytes, actualStreamedSha256Hex) = try AdbSmartSocketClient.pushFileVerified(
            serial: request.deviceId,
            localURL: URL(fileURLWithPath: request.localPath),
            remotePath: stagedRemotePath,
            daemonPort: request.daemonPort
        ) { chunkBytes in
            if Task.isCancelled {
                throw CancellationError()
            }
            let progress = try request.engine.recordTransferChunk(jobIdStr: request.rustJobId, chunkBytes: UInt64(chunkBytes))
            cumulative = progress.transferredBytes
        }
        guard cumulative == request.totalBytes, sentBytes == request.totalBytes else {
            AdbSmartSocketClient.removeRemoteFileBestEffort(
                serial: request.deviceId,
                remotePath: stagedRemotePath,
                daemonPort: request.daemonPort
            )
            throw AdbSmartSocketError.syncProtocolError(
                reason: TTZipLocalizationManager.shared.string(
                    for: L10n.AndroidInterconnect.errorTransferIncompleteBytes
                )
            )
        }
        guard actualStreamedSha256Hex == request.expectedSha256Hex else {
            AdbSmartSocketClient.removeRemoteFileBestEffort(
                serial: request.deviceId,
                remotePath: stagedRemotePath,
                daemonPort: request.daemonPort
            )
            throw AdbSmartSocketError.syncProtocolError(
                reason: "ADB upload stream SHA-256 mismatch before commit (expected \(request.expectedSha256Hex), actual \(actualStreamedSha256Hex))"
            )
        }
        return (cumulative, actualStreamedSha256Hex)
    }

}
