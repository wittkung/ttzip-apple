// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Darwin
import Foundation
import TTZipAppCore
import TTZipCore

extension TransferJobCoordinator {
    nonisolated func completeUploadedFile(_ request: UploadStreamRequest, uploadOutcome: StreamUploadInternalOutcome, resolvedLocalFinalDest: String?) async throws {
        if Task.isCancelled {
            let phase = await self.getJobCommitPhase(jobId: request.jobId)
            if phase == .committed {
                await self.finalizeJob(jobId: request.jobId, status: .completed)
                return
            }
            Self.cleanupUploadStaging(engine: request.engine, rustJobId: request.rustJobId, stagingPath: request.stagingPath)
            await self.finalizeJob(jobId: request.jobId, status: .failed, errorMessage: "Cancelled by user")
            return
        }

        if uploadOutcome.skipped {
            await self.markJobSkipped(jobId: request.jobId)
            await self.finalizeJob(jobId: request.jobId, status: .completed)
            return
        }

        guard uploadOutcome.transferred == request.totalBytes,
              uploadOutcome.actualStreamedSha256Hex == request.expectedSha256Hex,
              uploadOutcome.sourceStreamSha256Verified else {
            Self.cleanupUploadStaging(engine: request.engine, rustJobId: request.rustJobId, stagingPath: request.stagingPath)
            let msg = TTZipLocalizationManager.shared.string(
                for: L10n.AndroidInterconnect.errorTransferIncompleteBytes
            )
            await self.finalizeJob(jobId: request.jobId, status: .failed, errorMessage: msg)
            return
        }

        guard let (finalVerificationLevel, finalReadbackVerified) = try await self.commitLocalUploadIfNeeded(
            request, uploadOutcome: uploadOutcome, resolvedLocalFinalDest: resolvedLocalFinalDest
        ) else { return }

        await self.recordVerifiedDigest(
            jobId: request.jobId,
            sha256Hex: uploadOutcome.actualStreamedSha256Hex,
            verificationLevel: finalVerificationLevel,
            sourceStreamSha256Verified: uploadOutcome.sourceStreamSha256Verified,
            remoteSizeVerified: uploadOutcome.remoteSizeVerified,
            remoteReadbackSha256Verified: finalReadbackVerified
        )
        await self.finalizeJob(jobId: request.jobId, status: .completed)
    }

    nonisolated func commitLocalUploadIfNeeded(_ request: UploadStreamRequest, uploadOutcome: StreamUploadInternalOutcome, resolvedLocalFinalDest: String?) async throws -> (AndroidTransferVerificationLevel, Bool)? {
        if let staging = request.stagingPath, let finalDest = resolvedLocalFinalDest {
            let (stagedSize, stagedSha256Hex) = try Self.computeFileSha256Hex(atPath: staging)
            guard stagedSize == request.totalBytes,
                  stagedSha256Hex == uploadOutcome.actualStreamedSha256Hex,
                  stagedSha256Hex == request.expectedSha256Hex else {
                Self.cleanupUploadStaging(engine: request.engine, rustJobId: request.rustJobId, stagingPath: request.stagingPath)
                await self.finalizeJob(
                    jobId: request.jobId,
                    status: .failed,
                    errorMessage: "Pre-commit SHA-256 verification failed for local upload target"
                )
                return nil
            }
            try Self.atomicCommitLocalFile(
                from: staging,
                to: finalDest,
                allowOverwrite: request.conflictPolicy == .overwrite
            )
            await self.markJobCommitted(jobId: request.jobId)
            return (.remoteReadbackSha256Verified, true)
        }

        return (uploadOutcome.verificationLevel, uploadOutcome.remoteReadbackSha256Verified)
    }

    nonisolated func handleUploadFailure(jobId: String, engine: AppCoreEngine, rustJobId: String?, localStagingPartPath: String?, error: any Error) async {
        let phase = await self.getJobCommitPhase(jobId: jobId)
        if phase == .committed {
            await self.finalizeJob(jobId: jobId, status: .completed)
        } else if phase == .unknown {
            Self.cleanupUploadStaging(engine: engine, rustJobId: rustJobId, stagingPath: localStagingPartPath)
            await self.finalizeJob(
                jobId: jobId,
                status: .failed,
                errorMessage: "Commit status unknown: transfer outcome unverified; target preserved"
            )
        } else {
            Self.cleanupUploadStaging(engine: engine, rustJobId: rustJobId, stagingPath: localStagingPartPath)
            let errMsg = error is CancellationError ? "Cancelled by user" : error.localizedDescription
            await self.finalizeJob(jobId: jobId, status: .failed, errorMessage: errMsg)
        }
    }

    nonisolated func prepareUploadSource(jobId: String, localPath: String, totalBytes: UInt64, sourceUri: String, destUri: String, engine: AppCoreEngine) async throws -> (String, String)? {
        let (sourceDiskSize, sourceSha256Hex) = try Self.computeFileSha256Hex(atPath: localPath)
        guard sourceDiskSize == totalBytes else {
            await self.finalizeJob(
                jobId: jobId,
                status: .failed,
                errorMessage: "Source file size changed before upload started"
            )
            return nil
        }

        let submittedId = try engine.submitTransfer(
            priorityStr: "normal",
            sourceUri: sourceUri,
            destinationUri: destUri,
            totalBytes: totalBytes
        )
        return (submittedId, sourceSha256Hex)
    }


    nonisolated func prepareLocalUploadTarget(
        jobId: String, deviceId: String, remoteDir: String, fileName: String,
        policy: AndroidTransferConflictPolicy, maxCandidates: Int, customWriter: RemoteChunkWriter?,
        sanitizedToken: String
    ) async throws -> (finalPath: String?, stagingPath: String?)? {
        let isRemoteDevice = deviceId.hasPrefix("adb://") || deviceId.hasPrefix("mtp://")
        guard !isRemoteDevice && customWriter == nil else { return (nil, nil) }
        let requestedDest = (remoteDir as NSString).appendingPathComponent(fileName)
        let (finalDest, shouldSkip) = try Self.resolveLocalDestinationPath(
            requestedPath: requestedDest, conflictPolicy: policy, maxCandidates: maxCandidates
        )
        if shouldSkip {
            await self.markJobSkipped(jobId: jobId)
            await self.finalizeJob(jobId: jobId, status: .completed)
            return nil
        }
        return (finalDest, "\(finalDest).\(sanitizedToken).ttpart")
    }
}
