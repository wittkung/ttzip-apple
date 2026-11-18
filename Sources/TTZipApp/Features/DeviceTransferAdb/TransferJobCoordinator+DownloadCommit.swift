// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Darwin
import Foundation
import TTZipAppCore
import TTZipCore

extension TransferJobCoordinator {
    struct DownloadCommitContext: Sendable {
        let jobId: String
        let submittedId: String
        let stagedCommitPath: String
        let stagedPartPath: String
        let finalLocalPath: String
        let totalBytes: UInt64
        let resolvedPolicy: AndroidTransferConflictPolicy
        let engine: AppCoreEngine
    }

    nonisolated func completeDownloadedFile(_ context: DownloadCommitContext, transferred: UInt64, streamedSha256Hex: String) async throws {
        if Task.isCancelled {
            Self.cleanupDownloadStaging(
                engine: context.engine,
                rustJobId: context.submittedId,
                stagedPartPath: context.stagedPartPath,
                stagedCommitPath: context.stagedCommitPath
            )
            await self.finalizeJob(jobId: context.jobId, status: .failed, errorMessage: "Cancelled by user")
            return
        }

        guard transferred == context.totalBytes else {
            Self.cleanupDownloadStaging(
                engine: context.engine,
                rustJobId: context.submittedId,
                stagedPartPath: context.stagedPartPath,
                stagedCommitPath: context.stagedCommitPath
            )
            let msg = TTZipLocalizationManager.shared.string(
                for: L10n.AndroidInterconnect.errorTransferIncompleteBytes
            )
            await self.finalizeJob(jobId: context.jobId, status: .failed, errorMessage: msg)
            return
        }

        _ = try context.engine.finalizeTransfer(jobIdStr: context.submittedId)
        let (diskSize, diskSha256Hex) = try Self.computeFileSha256Hex(atPath: context.stagedCommitPath)
        guard diskSize == context.totalBytes, diskSha256Hex == streamedSha256Hex else {
            Self.cleanupDownloadStaging(
                engine: context.engine,
                rustJobId: context.submittedId,
                stagedPartPath: context.stagedPartPath,
                stagedCommitPath: context.stagedCommitPath
            )
            await self.finalizeJob(
                jobId: context.jobId,
                status: .failed,
                errorMessage: "Pre-commit SHA-256 verification failed for downloaded file"
            )
            return
        }

        try Self.atomicCommitLocalFile(
            from: context.stagedCommitPath,
            to: context.finalLocalPath,
            allowOverwrite: context.resolvedPolicy == .overwrite
        )
        await self.markJobCommitted(jobId: context.jobId)

        await self.recordVerifiedDigest(
            jobId: context.jobId,
            sha256Hex: diskSha256Hex,
            verificationLevel: .remoteReadbackSha256Verified,
            sourceStreamSha256Verified: false,
            remoteSizeVerified: true,
            remoteReadbackSha256Verified: true
        )
        await self.finalizeJob(jobId: context.jobId, status: .completed)
    }

    nonisolated func handleDownloadFailure(jobId: String, engine: AppCoreEngine, rustJobId: String?, stagedPartPath: String, stagedCommitPath: String, error: any Error) async {
        let phase = await self.getJobCommitPhase(jobId: jobId)
        if phase == .committed {
            await self.finalizeJob(jobId: jobId, status: .completed)
        } else {
            if let submittedId = rustJobId {
                Self.cleanupDownloadStaging(
                    engine: engine,
                    rustJobId: submittedId,
                    stagedPartPath: stagedPartPath,
                    stagedCommitPath: stagedCommitPath
                )
            } else if !stagedPartPath.isEmpty || !stagedCommitPath.isEmpty {
                try? FileManager.default.removeItem(atPath: stagedPartPath)
                try? FileManager.default.removeItem(atPath: stagedCommitPath)
            }
            let errMsg = error is CancellationError ? "Cancelled by user" : error.localizedDescription
            await self.finalizeJob(jobId: jobId, status: .failed, errorMessage: errMsg)
        }
    }

}
