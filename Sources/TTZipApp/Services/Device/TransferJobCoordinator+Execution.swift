// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Darwin
import Foundation
import TTZipAppCore
import TTZipCore

extension TransferJobCoordinator {
    // MARK: - Pipeline Execution

    /// Executes a file download task asynchronously with job-scoped `.ttpart` staging, pre-commit SHA-256 verification,
    /// and atomic POSIX commit.
    public func executeDownload(
        jobId: String,
        deviceId: String,
        remotePath: String,
        localPath: String,
        storageId: UInt32? = nil,
        objectHandle: UInt32? = nil,
        conflictPolicy: AndroidTransferConflictPolicy? = nil
    ) {
        let task = Task.detached { [weak self] in
            guard let self = self else { return }
            let engine = AppCoreEngine.shared
            let snapshot = await self.getJob(jobId: jobId)
            let totalBytes = snapshot?.totalBytes ?? 0
            let resolvedStorageId = storageId ?? snapshot?.storageId ?? 0
            let resolvedObjectHandle = objectHandle ?? snapshot?.objectHandle ?? 0
            let resolvedPolicy = conflictPolicy ?? snapshot?.conflictPolicy ?? .overwrite
            let maxCandidates = snapshot?.maxKeepBothCandidates ?? 10_000

            let sanitizedToken = Self.sanitizeJobToken(jobId)
            var stagedCommitPath = ""
            var stagedPartPath = ""
            var rustJobId: String?

            do {
                let (finalLocalPath, shouldSkip) = try Self.resolveLocalDestinationPath(
                    requestedPath: localPath,
                    conflictPolicy: resolvedPolicy,
                    maxCandidates: maxCandidates
                )
                if shouldSkip {
                    await self.markJobSkipped(jobId: jobId)
                    await self.finalizeJob(jobId: jobId, status: .completed)
                    return
                }

                stagedCommitPath = "\(finalLocalPath).\(sanitizedToken).stage"
                stagedPartPath = "\(stagedCommitPath).ttpart"
                let sourceUri = Self.formatDeviceUri(deviceId: deviceId, path: remotePath)
                let stagedDestUri = "file://\(stagedCommitPath)"
                let (daemonPort, customReader, _) = await self.transportConfiguration()

                let submittedId = try engine.submitTransfer(
                    priorityStr: "normal",
                    sourceUri: sourceUri,
                    destinationUri: stagedDestUri,
                    totalBytes: totalBytes
                )
                rustJobId = submittedId
                let (transferred, streamedSha256Hex) = try await self.streamDownloadPayload(
                    jobId: jobId,
                    rustJobId: submittedId,
                    deviceId: deviceId,
                    remotePath: remotePath,
                    storageId: resolvedStorageId,
                    objectHandle: resolvedObjectHandle,
                    stagedCommitPath: stagedCommitPath,
                    totalBytes: totalBytes,
                    daemonPort: daemonPort,
                    customReader: customReader,
                    engine: engine
                )

                try await self.completeDownloadedFile(
                    DownloadCommitContext(
                        jobId: jobId, submittedId: submittedId, stagedCommitPath: stagedCommitPath,
                        stagedPartPath: stagedPartPath, finalLocalPath: finalLocalPath,
                        totalBytes: totalBytes, resolvedPolicy: resolvedPolicy, engine: engine
                    ), transferred: transferred, streamedSha256Hex: streamedSha256Hex
                )
            } catch {
                await self.handleDownloadFailure(
                    jobId: jobId, engine: engine, rustJobId: rustJobId,
                    stagedPartPath: stagedPartPath, stagedCommitPath: stagedCommitPath, error: error
                )
            }
        }
        attachCancellationTask(jobId: jobId, task: task)
    }

    private func streamDownloadPayload(
        jobId: String,
        rustJobId: String,
        deviceId: String,
        remotePath: String,
        storageId: UInt32,
        objectHandle: UInt32,
        stagedCommitPath: String,
        totalBytes: UInt64,
        daemonPort: UInt16,
        customReader: RemoteChunkReader?,
        engine: AppCoreEngine
    ) async throws -> (UInt64, String) {
        let request = DownloadStreamRequest(
            jobId: jobId,
            rustJobId: rustJobId,
            deviceId: deviceId,
            remotePath: remotePath,
            storageId: storageId,
            objectHandle: objectHandle,
            stagedCommitPath: stagedCommitPath,
            totalBytes: totalBytes,
            daemonPort: daemonPort,
            customReader: customReader,
            engine: engine
        )
        if customReader == nil {
            if deviceId.hasPrefix("adb://") { return try streamAdbDownload(request) }
            if deviceId.hasPrefix("mtp://") { return try streamMtpDownload(request) }
        }
        return try await streamLocalDownload(request)
    }

    /// Executes a file upload task asynchronously with pre-commit stream SHA-256 verification and job-scoped staging.
    public func executeUpload(
        jobId: String,
        deviceId: String,
        localPath: String,
        remoteDir: String,
        storageId: UInt32? = nil,
        conflictPolicy: AndroidTransferConflictPolicy? = nil
    ) {
        let task = Task.detached { [weak self] in
            guard let self = self else { return }
            let engine = AppCoreEngine.shared
            let snapshot = await self.getJob(jobId: jobId)
            let totalBytes = snapshot?.totalBytes ?? 0
            let resolvedStorageId = storageId ?? snapshot?.storageId ?? 0
            let resolvedPolicy = conflictPolicy ?? snapshot?.conflictPolicy ?? .overwrite
            let maxCandidates = snapshot?.maxKeepBothCandidates ?? 10_000

            let sourceUri = "file://\(localPath)"
            let destUri = Self.formatDeviceUri(deviceId: deviceId, path: remoteDir)
            let (daemonPort, _, customWriter) = await self.transportConfiguration()
            let sanitizedToken = Self.sanitizeJobToken(jobId)
            var rustJobId: String?
            var localStagingPartPath: String?

            do {
                guard let (submittedId, sourceSha256Hex) = try await self.prepareUploadSource(
                    jobId: jobId, localPath: localPath, totalBytes: totalBytes,
                    sourceUri: sourceUri, destUri: destUri, engine: engine
                ) else { return }
                rustJobId = submittedId

                let originalFileName = (localPath as NSString).lastPathComponent
                guard let localTarget = try await self.prepareLocalUploadTarget(
                    jobId: jobId, deviceId: deviceId, remoteDir: remoteDir, fileName: originalFileName,
                    policy: resolvedPolicy, maxCandidates: maxCandidates, customWriter: customWriter,
                    sanitizedToken: sanitizedToken
                ) else { return }
                let resolvedLocalFinalDest = localTarget.finalPath
                localStagingPartPath = localTarget.stagingPath

                let request = UploadStreamRequest(
                    jobId: jobId,
                    rustJobId: submittedId,
                    deviceId: deviceId,
                    localPath: localPath,
                    remoteDir: remoteDir,
                    fileName: originalFileName,
                    storageId: resolvedStorageId,
                    conflictPolicy: resolvedPolicy,
                    maxKeepBothCandidates: maxCandidates,
                    sanitizedJobToken: sanitizedToken,
                    expectedSha256Hex: sourceSha256Hex,
                    totalBytes: totalBytes,
                    daemonPort: daemonPort,
                    customWriter: customWriter,
                    stagingPath: localStagingPartPath,
                    engine: engine
                )
                let uploadOutcome = try await self.streamUploadPayload(request)

                try await self.completeUploadedFile(
                    request, uploadOutcome: uploadOutcome, resolvedLocalFinalDest: resolvedLocalFinalDest
                )
            } catch {
                await self.handleUploadFailure(
                    jobId: jobId, engine: engine, rustJobId: rustJobId,
                    localStagingPartPath: localStagingPartPath, error: error
                )
            }
        }
        attachCancellationTask(jobId: jobId, task: task)
    }

    private func streamUploadPayload(_ request: UploadStreamRequest) async throws -> StreamUploadInternalOutcome {
        if request.customWriter == nil {
            if request.deviceId.hasPrefix("mtp://") { return try streamMtpUpload(request) }
            if request.deviceId.hasPrefix("adb://") { return try streamAdbUpload(request) }
        }
        return try await streamLocalUpload(request)
    }
}
