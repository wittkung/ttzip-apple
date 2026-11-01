// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Darwin
import Foundation
import TTZipAppCore
import TTZipCore

extension AndroidTransferStatus {
    /// Indicates whether the status represents an active operational state.
    public var isActive: Bool {
        self == .transferring || self == .cancelling
    }

    /// Indicates whether the status represents a final terminal state.
    public var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

/// Thread-safe entity model representing an ongoing or completed transfer or direct pipeline job.
public struct AndroidTransferJob: Identifiable, Sendable, Hashable, Codable {
    /// UUID uniquely identifying the transfer task.
    public let jobId: String
    /// Identifier of the Android device bound to this transfer job.
    public let deviceId: String
    /// Transfer direction and pipeline mode.
    public let direction: AndroidTransferDirection
    /// Local or remote source path.
    public let sourcePath: String
    /// Local or remote destination path.
    public let destinationPath: String
    /// Total byte count of files to transfer.
    public let totalBytes: UInt64
    /// Number of bytes transferred or decompressed so far.
    public var transferredBytes: UInt64
    /// Smoothed rolling throughput in bytes per second.
    public var currentSpeedBps: UInt64
    /// Current lifecycle execution status.
    public var status: AndroidTransferStatus
    /// Optional failure description if status is .failed.
    public var errorMessage: String?
    /// Optional MTP storage partition identifier (`0` uses primary storage).
    public var storageId: UInt32
    /// Optional MTP object handle (`0` resolves by VFS path).
    public var objectHandle: UInt32
    /// Target conflict resolution policy.
    public var conflictPolicy: AndroidTransferConflictPolicy
    /// Maximum candidate filenames probed under `.keepBoth` before failing explicitly.
    public var maxKeepBothCandidates: Int
    /// Lowercase hex SHA-256 digest verified before commit, when available.
    public var verifiedSha256Hex: String?
    /// Explicit verification tier achieved before commit.
    public var verificationLevel: AndroidTransferVerificationLevel
    /// Whether the transmitted source stream matched the expected source SHA-256 before commit.
    public var sourceStreamSha256Verified: Bool
    /// Whether the remote device confirmed the final byte count via `STAT` or `GetObjectInfo`.
    public var remoteSizeVerified: Bool
    /// Whether the remote payload was read back end-to-end and verified by SHA-256.
    public var remoteReadbackSha256Verified: Bool
    /// Whether the transfer was skipped due to .skip conflict policy.
    public var isSkipped: Bool
    /// Discrete atomic commit phase.
    public var commitPhase: AndroidTransferCommitPhase

    /// Conformance to Identifiable using jobId.
    public var id: String {
        jobId
    }

    /// Normalized completion progress ratio between 0.0 and 1.0.
    public var progressRatio: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(max(Double(transferredBytes) / Double(totalBytes), 0.0), 1.0)
    }

    /// Estimated remaining duration in seconds based on smoothed currentSpeedBps.
    public var estimatedRemainingSeconds: TimeInterval? {
        guard currentSpeedBps > 0, totalBytes > transferredBytes else { return nil }
        let remainingBytes = totalBytes - transferredBytes
        return TimeInterval(remainingBytes) / TimeInterval(currentSpeedBps)
    }

    /// Memberwise initializer for AndroidTransferJob.
    public init(
        jobId: String = UUID().uuidString,
        deviceId: String = "",
        direction: AndroidTransferDirection,
        sourcePath: String,
        destinationPath: String,
        totalBytes: UInt64,
        transferredBytes: UInt64 = 0,
        currentSpeedBps: UInt64 = 0,
        status: AndroidTransferStatus = .queued,
        errorMessage: String? = nil,
        storageId: UInt32 = 0,
        objectHandle: UInt32 = 0,
        conflictPolicy: AndroidTransferConflictPolicy = .overwrite,
        maxKeepBothCandidates: Int = 10_000,
        verifiedSha256Hex: String? = nil,
        verificationLevel: AndroidTransferVerificationLevel = .none,
        sourceStreamSha256Verified: Bool = false,
        remoteSizeVerified: Bool = false,
        remoteReadbackSha256Verified: Bool = false,
        isSkipped: Bool = false,
        commitPhase: AndroidTransferCommitPhase = .uncommitted
    ) {
        self.jobId = jobId
        self.deviceId = deviceId
        self.direction = direction
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.currentSpeedBps = currentSpeedBps
        self.status = status
        self.errorMessage = errorMessage
        self.storageId = storageId
        self.objectHandle = objectHandle
        self.conflictPolicy = conflictPolicy
        self.maxKeepBothCandidates = max(1, maxKeepBothCandidates)
        self.verifiedSha256Hex = verifiedSha256Hex
        self.verificationLevel = verificationLevel
        self.sourceStreamSha256Verified = sourceStreamSha256Verified
        self.remoteSizeVerified = remoteSizeVerified
        self.remoteReadbackSha256Verified = remoteReadbackSha256Verified
        self.isSkipped = isSkipped
        self.commitPhase = commitPhase
    }
}

/// Internal bookkeeping state for an individual tracked transfer task.
struct JobInternalContext {
    var job: AndroidTransferJob
    var lastSampleTimestamp: TimeInterval
    var lastSampleTransferredBytes: UInt64
    var cancellationTask: Task<Void, Never>?
    var commitPhase: AndroidTransferCommitPhase = .uncommitted
}

/// Swift 6 Actor coordinating concurrent Android transfer jobs, live speed smoothing, and cancellation.
public actor TransferJobCoordinator {
    public typealias RemoteChunkReader = @Sendable (
        _ deviceId: String,
        _ remotePath: String,
        _ offset: UInt64,
        _ length: Int
    ) throws -> Data

    public typealias RemoteChunkWriter = @Sendable (
        _ deviceId: String,
        _ remoteDir: String,
        _ fileName: String,
        _ offset: UInt64,
        _ chunk: Data,
        _ isFinal: Bool
    ) throws -> Void

    /// Shared singleton instance for host-wide transfer coordination.
    public static let shared = TransferJobCoordinator()

    /// Maximum number of concurrently transferring jobs (default 2).
    public let maxConcurrentJobs: Int

    /// Smoothing alpha factor for Exponential Moving Average (EMA) rate calculations.
    private let emaAlpha: Double = 0.25

    /// Active tracked job registry keyed by jobId.
    var jobContexts: [String: JobInternalContext] = [:]

    /// Active state stream subscriber continuations keyed by subscription UUID.
    private var continuations: [UUID: AsyncStream<[AndroidTransferJob]>.Continuation] = [:]

    /// Configurable ADB daemon TCP port (defaults to 5037).
    private var adbDaemonPort: UInt16 = AdbSmartSocketClient.defaultDaemonPort

    /// Optional custom remote chunk reader for deterministic protocol testing.
    private var remoteChunkReader: RemoteChunkReader?

    /// Optional custom remote chunk writer for deterministic protocol testing.
    private var remoteChunkWriter: RemoteChunkWriter?

    /// Creates a new `TransferJobCoordinator` actor instance with configurable concurrency limit.
    /// - Parameter maxConcurrentJobs: Maximum allowed simultaneous active jobs (minimum 1).
    public init(maxConcurrentJobs: Int = 2) {
        self.maxConcurrentJobs = max(1, maxConcurrentJobs)
        if MtpNativeClient.currentBridgeProvider() == nil {
            MtpNativeClient.registerBridgeProvider(UniFFIMtpTransferBridgeProvider.shared)
        }
    }

    /// Configures the ADB daemon port and optional custom chunk reader/writer hooks.
    public func configureTransport(
        adbDaemonPort: UInt16 = AdbSmartSocketClient.defaultDaemonPort,
        remoteReader: RemoteChunkReader? = nil,
        remoteWriter: RemoteChunkWriter? = nil
    ) {
        self.adbDaemonPort = adbDaemonPort
        self.remoteChunkReader = remoteReader
        self.remoteChunkWriter = remoteWriter
    }

    func transportConfiguration() -> (UInt16, RemoteChunkReader?, RemoteChunkWriter?) {
        (adbDaemonPort, remoteChunkReader, remoteChunkWriter)
    }

    func attachCancellationTask(jobId: String, task: Task<Void, Never>) {
        if var ctx = jobContexts[jobId] {
            ctx.cancellationTask = task
            jobContexts[jobId] = ctx
        }
    }

    func recordVerifiedDigest(
        jobId: String,
        sha256Hex: String,
        verificationLevel: AndroidTransferVerificationLevel,
        sourceStreamSha256Verified: Bool,
        remoteSizeVerified: Bool,
        remoteReadbackSha256Verified: Bool
    ) {
        guard var context = jobContexts[jobId] else { return }
        context.job.verifiedSha256Hex = sha256Hex
        context.job.verificationLevel = verificationLevel
        context.job.sourceStreamSha256Verified = sourceStreamSha256Verified
        context.job.remoteSizeVerified = remoteSizeVerified
        context.job.remoteReadbackSha256Verified = remoteReadbackSha256Verified
        jobContexts[jobId] = context
    }

    /// Enqueues a new transfer or streaming extraction job.
    /// - Parameter job: The initial transfer job model to enqueue.
    /// - Returns: The registered transfer job.
    @discardableResult
    public func enqueueJob(_ job: AndroidTransferJob) -> AndroidTransferJob {
        let now = Date().timeIntervalSince1970
        let context = JobInternalContext(
            job: job,
            lastSampleTimestamp: now,
            lastSampleTransferredBytes: job.transferredBytes,
            cancellationTask: nil
        )
        jobContexts[job.jobId] = context
        scheduleNextJobs()
        broadcastUpdate()
        return job
    }

    /// Updates incremental transfer progress and recalculates smoothed throughput via EMA.
    /// - Parameters:
    ///   - jobId: Unique identifier of the target job.
    ///   - transferredBytes: Total cumulative bytes transferred up to this moment.
    ///   - totalBytes: Optional updated total byte count if size became known dynamically.
    public func updateProgress(jobId: String, transferredBytes: UInt64, totalBytes: UInt64? = nil) {
        guard var context = jobContexts[jobId] else { return }

        let now = Date().timeIntervalSince1970
        let timeDelta = max(0.001, now - context.lastSampleTimestamp)
        let bytesDelta = transferredBytes >= context.lastSampleTransferredBytes
            ? transferredBytes - context.lastSampleTransferredBytes
            : 0

        let instantSpeedBps = Double(bytesDelta) / timeDelta

        // Apply Exponential Moving Average (EMA) smoothing to eliminate speed oscillation
        let currentEma = Double(context.job.currentSpeedBps)
        let smoothedSpeed: Double
        if currentEma <= 0.0 {
            smoothedSpeed = instantSpeedBps
        } else {
            smoothedSpeed = (emaAlpha * instantSpeedBps) + ((1.0 - emaAlpha) * currentEma)
        }

        context.job.transferredBytes = transferredBytes
        if let total = totalBytes {
            context.job = AndroidTransferJob(
                jobId: context.job.jobId,
                deviceId: context.job.deviceId,
                direction: context.job.direction,
                sourcePath: context.job.sourcePath,
                destinationPath: context.job.destinationPath,
                totalBytes: total,
                transferredBytes: transferredBytes,
                currentSpeedBps: UInt64(smoothedSpeed.rounded()),
                status: context.job.status,
                errorMessage: context.job.errorMessage,
                storageId: context.job.storageId,
                objectHandle: context.job.objectHandle,
                conflictPolicy: context.job.conflictPolicy,
                maxKeepBothCandidates: context.job.maxKeepBothCandidates,
                verifiedSha256Hex: context.job.verifiedSha256Hex,
                verificationLevel: context.job.verificationLevel,
                sourceStreamSha256Verified: context.job.sourceStreamSha256Verified,
                remoteSizeVerified: context.job.remoteSizeVerified,
                remoteReadbackSha256Verified: context.job.remoteReadbackSha256Verified,
                isSkipped: context.job.isSkipped,
                commitPhase: context.commitPhase
            )
        } else {
            context.job.currentSpeedBps = UInt64(smoothedSpeed.rounded())
        }

        context.lastSampleTimestamp = now
        context.lastSampleTransferredBytes = transferredBytes
        jobContexts[jobId] = context

        broadcastUpdate()
    }

    /// Explicitly marks a job as skipped under .skip conflict policy without recording transferred bytes.
    public func markJobSkipped(jobId: String) {
        guard var context = jobContexts[jobId] else { return }
        context.job.isSkipped = true
        context.job.transferredBytes = 0
        context.job.currentSpeedBps = 0
        jobContexts[jobId] = context
        broadcastUpdate()
    }

    /// Sets the commit phase for a job, preventing post-commit cancellation races.
    public func markJobCommitted(jobId: String) {
        guard var context = jobContexts[jobId] else { return }
        context.commitPhase = .committed
        context.job.commitPhase = .committed
        jobContexts[jobId] = context
        broadcastUpdate()
    }

    /// Sets the commit phase to unknown when communication dropped during commit.
    public func markJobCommitUnknown(jobId: String) {
        guard var context = jobContexts[jobId] else { return }
        context.commitPhase = .unknown
        context.job.commitPhase = .unknown
        jobContexts[jobId] = context
        broadcastUpdate()
    }

    /// Queries the current commit phase of a job.
    public func getJobCommitPhase(jobId: String) -> AndroidTransferCommitPhase {
        jobContexts[jobId]?.commitPhase ?? .uncommitted
    }

    /// Transitions an existing job into a terminal completed or failed state.
    /// - Parameters:
    ///   - jobId: Unique identifier of the job.
    ///   - status: Completed or Failed status.
    ///   - errorMessage: Optional error description if failed.
    public func finalizeJob(jobId: String, status: AndroidTransferStatus, errorMessage: String? = nil) {
        guard var context = jobContexts[jobId] else { return }

        // Barrier: once committed or completed, never overwrite with failure or cancellation
        if (context.job.status == .completed || context.commitPhase == .committed) && status != .completed {
            return
        }

        context.job.status = status
        context.job.currentSpeedBps = 0
        context.job.errorMessage = errorMessage
        context.job.commitPhase = context.commitPhase
        if status == .completed {
            context.commitPhase = .committed
            context.job.commitPhase = .committed
            if !context.job.isSkipped {
                context.job.transferredBytes = context.job.totalBytes
            }
        } else if status == .failed {
            if context.commitPhase == .unknown {
                // Preserve source stream verification evidence while disclaiming remote verification
                context.job.verificationLevel = .none
                context.job.remoteSizeVerified = false
                context.job.remoteReadbackSha256Verified = false
            } else {
                context.job.verifiedSha256Hex = nil
                context.job.verificationLevel = .none
                context.job.sourceStreamSha256Verified = false
                context.job.remoteSizeVerified = false
                context.job.remoteReadbackSha256Verified = false
            }
        }
        context.cancellationTask?.cancel()
        context.cancellationTask = nil
        jobContexts[jobId] = context

        scheduleNextJobs()
        broadcastUpdate()
    }

    /// Requests cooperative cancellation of an active or queued transfer job.
    /// - Parameter jobId: Unique identifier of the job to cancel.
    /// - Returns: True if the job was located and marked for cancellation, false otherwise.
    @discardableResult
    public func cancelJob(jobId: String) -> Bool {
        guard var context = jobContexts[jobId] else { return false }

        if context.job.status.isTerminal || context.commitPhase == .committed {
            return false
        }

        context.job.currentSpeedBps = 0
        context.cancellationTask?.cancel()

        if context.job.status == .queued {
            context.cancellationTask = nil
            jobContexts[jobId] = context
            finalizeJob(jobId: jobId, status: .failed, errorMessage: "Cancelled by user")
            return true
        }

        context.job.status = .cancelling
        jobContexts[jobId] = context
        broadcastUpdate()
        return true
    }

    /// Retrieves an immutable snapshot array of all currently tracked transfer jobs.
    /// - Returns: Array of AndroidTransferJob instances.
    public func getJobs() -> [AndroidTransferJob] {
        jobContexts.values.map(\.job).sorted { $0.jobId < $1.jobId }
    }

    /// Retrieves a specific transfer job by its unique identifier.
    /// - Parameter jobId: The unique job identifier.
    /// - Returns: The matching AndroidTransferJob if present, nil otherwise.
    public func getJob(jobId: String) -> AndroidTransferJob? {
        jobContexts[jobId]?.job
    }

    /// Clears completed or failed jobs from the coordinator registry.
    public func clearFinishedJobs() {
        jobContexts = jobContexts.filter { !$0.value.job.status.isTerminal }
        broadcastUpdate()
    }

    /// Asynchronous stream broadcasting all active and updated transfer jobs to UI subscribers.
    public var jobUpdates: AsyncStream<[AndroidTransferJob]> {
        let (stream, continuation) = AsyncStream<[AndroidTransferJob]>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.yield(getJobs())
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeContinuation(id: id)
            }
        }
        return stream
    }

    /// Internal helper scheduling pending queued jobs up to maxConcurrentJobs.
    private func scheduleNextJobs() {
        let activeCount = jobContexts.values.filter { $0.job.status == .transferring }.count
        var availableSlots = max(0, maxConcurrentJobs - activeCount)

        for (id, var context) in jobContexts where context.job.status == .queued && availableSlots > 0 {
            context.job.status = .transferring
            jobContexts[id] = context
            availableSlots -= 1
        }
    }

    /// Removes a terminated stream continuation observer.
    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    /// Broadcasts the current jobs snapshot array to all registered stream observers.
    private func broadcastUpdate() {
        let snapshot = getJobs()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    // MARK: - Staging, Conflict & Digest Helpers

    nonisolated static func formatDeviceUri(deviceId: String, path: String) -> String {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        if deviceId.hasPrefix("adb://") || deviceId.hasPrefix("mtp://") {
            return "\(deviceId)\(normalizedPath)"
        }
        if deviceId.hasPrefix("adb:") {
            let serial = String(deviceId.dropFirst(4))
            return "adb://\(serial)\(normalizedPath)"
        }
        if deviceId.hasPrefix("mtp:") || deviceId.hasPrefix("usb:") {
            let serial = String(deviceId.dropFirst(4))
            return "mtp://\(serial)\(normalizedPath)"
        }
        return "adb://\(deviceId)\(normalizedPath)"
    }

    nonisolated static func sanitizeJobToken(_ jobId: String) -> String {
        let filtered = jobId.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
        let token = String(String.UnicodeScalarView(filtered))
        return token.isEmpty ? UUID().uuidString : token
    }

    nonisolated static func resolveLocalDestinationPath(
        requestedPath: String,
        conflictPolicy: AndroidTransferConflictPolicy,
        maxCandidates: Int = 10_000
    ) throws -> (resolvedPath: String, shouldSkip: Bool) {
        let parentDir = (requestedPath as NSString).deletingLastPathComponent
        if !parentDir.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: parentDir, isDirectory: &isDir), !isDir.boolValue {
                throw AdbSmartSocketError.syncProtocolError(
                    reason: "Local destination parent path is not a directory: \(parentDir)"
                )
            }
        }
        var st = Darwin.stat()
        let pathExists: (String) -> Bool = { p in
            FileManager.default.fileExists(atPath: p) || Darwin.lstat(p, &st) == 0
        }
        guard pathExists(requestedPath) else {
            return (requestedPath, false)
        }
        switch conflictPolicy {
        case .overwrite:
            return (requestedPath, false)
        case .skip:
            return (requestedPath, true)
        case .keepBoth:
            let limit = max(1, maxCandidates)
            let nsPath = requestedPath as NSString
            let dir = nsPath.deletingLastPathComponent
            let ext = nsPath.pathExtension
            let stem = (nsPath.lastPathComponent as NSString).deletingPathExtension
            for index in 1...limit {
                let candidateName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
                let candidatePath = (dir as NSString).appendingPathComponent(candidateName)
                if !pathExists(candidatePath) {
                    return (candidatePath, false)
                }
            }
            throw AdbSmartSocketError.syncProtocolError(
                reason: "KeepBoth candidate names exhausted for '\(nsPath.lastPathComponent)' (limit \(limit))"
            )
        }
    }

    nonisolated static func computeFileSha256Hex(atPath path: String) throws -> (size: UInt64, sha256Hex: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw AdbSmartSocketError.syncProtocolError(reason: "Unable to open file for SHA-256 verification: \(path)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalSize: UInt64 = 0
        while true {
            let chunk = (try handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            totalSize += UInt64(chunk.count)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (totalSize, hex)
    }

    nonisolated static func atomicCommitLocalFile(
        from stagedPath: String,
        to finalPath: String,
        allowOverwrite: Bool = true
    ) throws {
        let parentDir = (finalPath as NSString).deletingLastPathComponent
        if !parentDir.isEmpty && !FileManager.default.fileExists(atPath: parentDir) {
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }
        if !allowOverwrite {
            if Darwin.link(stagedPath, finalPath) == 0 {
                _ = Darwin.unlink(stagedPath)
                return
            }
            let errCode = errno
            _ = Darwin.unlink(stagedPath)
            if errCode == EEXIST {
                throw AdbSmartSocketError.syncProtocolError(
                    reason: "Target file '\(finalPath)' already exists under non-overwrite conflict policy"
                )
            }
            throw AdbSmartSocketError.syncProtocolError(
                reason: "Atomic non-overwrite link failed from '\(stagedPath)' to '\(finalPath)' (errno=\(errCode))"
            )
        }
        if Darwin.rename(stagedPath, finalPath) != 0 {
            let errCode = errno
            throw AdbSmartSocketError.syncProtocolError(
                reason: "Atomic POSIX rename failed from '\(stagedPath)' to '\(finalPath)' (errno=\(errCode))"
            )
        }
    }

    nonisolated static func cleanupDownloadStaging(
        engine: AppCoreEngine,
        rustJobId: String,
        stagedPartPath: String,
        stagedCommitPath: String
    ) {
        try? engine.cancelTransfer(jobIdStr: rustJobId)
        try? FileManager.default.removeItem(atPath: stagedPartPath)
        try? FileManager.default.removeItem(atPath: stagedCommitPath)
    }

    nonisolated static func cleanupUploadStaging(
        engine: AppCoreEngine,
        rustJobId: String?,
        stagingPath: String?
    ) {
        if let id = rustJobId {
            try? engine.cancelTransfer(jobIdStr: id)
        }
        if let path = stagingPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    public func executeDirectExtraction(
        jobId: String,
        archivePath: String,
        destinationDeviceId: String,
        destinationDir: String
    ) {
        let task = Task.detached { [weak self] in
            guard let self = self else { return }
            let engine = AppCoreEngine.shared
            let destUri = Self.formatDeviceUri(deviceId: destinationDeviceId, path: destinationDir)
            let totalBytes = (await self.getJob(jobId: jobId)?.totalBytes) ?? 0

            do {
                let rustJobId = try engine.submitTransfer(
                    priorityStr: "normal",
                    sourceUri: "file://\(archivePath)",
                    destinationUri: destUri,
                    totalBytes: totalBytes
                )

                let chunkSize: UInt64 = 65_536
                var transferred: UInt64 = 0

                if totalBytes == 0 {
                    await self.finalizeJob(jobId: jobId, status: .completed)
                    return
                }

                let fileHandle = FileHandle(forReadingAtPath: archivePath)
                defer {
                    try? fileHandle?.close()
                }

                while !Task.isCancelled && transferred < totalBytes {
                    let remaining = totalBytes - transferred
                    let currentChunkLen = Int(min(chunkSize, remaining))

                    if let handle = fileHandle,
                       let chunk = try handle.read(upToCount: currentChunkLen),
                       !chunk.isEmpty {
                        let progress = try engine.recordTransferChunk(jobIdStr: rustJobId, chunkBytes: UInt64(chunk.count))
                        transferred = progress.transferredBytes
                    } else {
                        break
                    }

                    await self.updateProgress(
                        jobId: jobId,
                        transferredBytes: transferred,
                        totalBytes: totalBytes
                    )
                    await Task.yield()
                }

                if Task.isCancelled {
                    try? engine.cancelTransfer(jobIdStr: rustJobId)
                    await self.finalizeJob(jobId: jobId, status: .failed, errorMessage: "Cancelled by user")
                    return
                }

                await self.finalizeJob(jobId: jobId, status: .completed)
            } catch {
                await self.finalizeJob(jobId: jobId, status: .failed, errorMessage: error.localizedDescription)
            }
        }
        attachCancellationTask(jobId: jobId, task: task)
    }
}
