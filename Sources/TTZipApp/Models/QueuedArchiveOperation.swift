// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

public enum ArchiveTaskExecutionState: String, Sendable, Codable, CaseIterable {
    case queued = "queued"
    case running = "running"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

/// Complete operation-level summary of a finished archive compression task.
public struct CompressionCompletedSummary: Sendable, Equatable, Hashable {
    public let taskId: UUID?
    public let archivePath: String
    public let originalBytes: Int64
    public let compressedBytes: Int64
    public let elapsedSeconds: Double
    public let throughputMBs: Double
    public let format: ArchiveCompressionFormat
    public let isEncrypted: Bool
    public let outcome: ExtractionOutcome?
    public let cleanupWarningMessage: String?
    public let sourcePreservationNotice: String?

    public init(
        taskId: UUID? = nil,
        archivePath: String,
        originalBytes: Int64,
        compressedBytes: Int64,
        elapsedSeconds: Double,
        throughputMBs: Double,
        format: ArchiveCompressionFormat,
        isEncrypted: Bool,
        outcome: ExtractionOutcome? = nil,
        cleanupWarningMessage: String? = nil,
        sourcePreservationNotice: String? = nil
    ) {
        self.taskId = taskId
        self.archivePath = archivePath
        self.originalBytes = originalBytes
        self.compressedBytes = compressedBytes
        self.elapsedSeconds = elapsedSeconds
        self.throughputMBs = throughputMBs
        self.format = format
        self.isEncrypted = isEncrypted
        self.outcome = outcome
        self.cleanupWarningMessage = cleanupWarningMessage
        self.sourcePreservationNotice = sourcePreservationNotice
    }
}

public struct QueuedArchiveOperation: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var operationType: ArchiveOperationType
    public var state: ArchiveTaskExecutionState
    public var totalBytes: Int64
    public var bytesProcessed: Int64
    public var throughputMBs: Double
    public var outputPath: String?
    public var outcome: ExtractionOutcome?
    public var completedSummary: CompressionCompletedSummary?
    public var createFailureReport: ArchiveCreateTransactionFailureReport?
    public var errorMessage: String?
    public var warningMessage: String?
    public var cleanupWarningMessage: String?
    public var sourcePreservationNotice: String?
    public var isCancellationRequested: Bool
    public var isResponsibilityAcknowledged: Bool

    public var fractionCompleted: Double {
        totalBytes > 0 ? Double(bytesProcessed) / Double(totalBytes) : 0.0
    }

    /// Indicates whether this settled operation carries an unacknowledged failure record,
    /// post-commit cleanup warnings, structured failed items, or source preservation notices
    /// that must not be silently discarded by `clearFinishedTasks()`.
    public var hasPendingResponsibility: Bool {
        guard !isResponsibilityAcknowledged else { return false }
        if state == .failed {
            return true
        }
        let hasStructuredFailures = outcome?.status == .completedWithFailures
            || !(outcome?.failed.isEmpty ?? true)
            || createFailureReport != nil
        return cleanupWarningMessage != nil
            || sourcePreservationNotice != nil
            || hasStructuredFailures
    }

    public init(
        id: UUID = UUID(),
        name: String,
        operationType: ArchiveOperationType,
        state: ArchiveTaskExecutionState = .queued,
        totalBytes: Int64 = 0,
        bytesProcessed: Int64 = 0,
        throughputMBs: Double = 0.0,
        outputPath: String? = nil,
        outcome: ExtractionOutcome? = nil,
        completedSummary: CompressionCompletedSummary? = nil,
        createFailureReport: ArchiveCreateTransactionFailureReport? = nil,
        errorMessage: String? = nil,
        warningMessage: String? = nil,
        cleanupWarningMessage: String? = nil,
        sourcePreservationNotice: String? = nil,
        isCancellationRequested: Bool = false,
        isResponsibilityAcknowledged: Bool = false
    ) {
        self.id = id
        self.name = name
        self.operationType = operationType
        self.state = state
        self.totalBytes = totalBytes
        self.bytesProcessed = bytesProcessed
        self.throughputMBs = throughputMBs
        self.outputPath = outputPath
        self.outcome = outcome
        self.completedSummary = completedSummary
        self.createFailureReport = createFailureReport
        self.errorMessage = errorMessage
        self.warningMessage = warningMessage
        self.cleanupWarningMessage = cleanupWarningMessage
        self.sourcePreservationNotice = sourcePreservationNotice
        self.isCancellationRequested = isCancellationRequested
        self.isResponsibilityAcknowledged = isResponsibilityAcknowledged
    }
}
