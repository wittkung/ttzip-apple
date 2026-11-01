// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import Observation
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Application-wide background operations queue and telemetry coordinator.
@Observable
@MainActor
public final class ArchiveOperationsQueueCenter {
    public static let shared = ArchiveOperationsQueueCenter()

    public private(set) var tasks: [QueuedArchiveOperation] = []
    public private(set) var activeTasksCount: Int = 0
    public private(set) var overallProgress: Double = 0.0
    public private(set) var overallThroughputMBs: Double = 0.0

    /// Associated execution handles driving the underlying UniFFI CancellationTokens and Swift tasks.
    private var attachedHandles: [UUID: TaskExecutionHandle] = [:]
    private var releasedBindingCounts: [UUID: Int] = [:]

    private init() {}

    package func bindingReleaseCount(for id: UUID) -> Int {
        releasedBindingCounts[id, default: 0]
    }

    package func isExecutionBound(id: UUID) -> Bool {
        attachedHandles[id] != nil
    }

    /// Queries the full operation record by task ID.
    public func operation(for id: UUID) -> QueuedArchiveOperation? {
        tasks.first(where: { $0.id == id })
    }

    /// Queries the complete compression summary retained for a finished task ID.
    public func completedSummary(for id: UUID) -> CompressionCompletedSummary? {
        operation(for: id)?.completedSummary
    }

    /// Queries the structured outcome retained for a finished task ID.
    public func outcome(for id: UUID) -> ExtractionOutcome? {
        operation(for: id)?.outcome
    }

    /// Queries the archive output path retained for a finished task ID.
    public func outputPath(for id: UUID) -> String? {
        operation(for: id)?.outputPath
    }

    /// Queries whether the operation still carries an unacknowledged failure record, cleanup warnings,
    /// structured failed items, or source preservation notices.
    public func hasPendingResponsibility(for id: UUID) -> Bool {
        operation(for: id)?.hasPendingResponsibility ?? false
    }

    /// Explicitly marks the in-memory pending responsibility / failure or warning notice for `id` as acknowledged
    /// so that a subsequent `clearFinishedTasks()` call is permitted to remove the queue history entry.
    /// Does not delete disk files, claim disk residuals were removed, or alter historical outcome facts.
    public func acknowledgeResult(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard Self.isTerminalState(tasks[idx].state) else { return }
        tasks[idx].isResponsibilityAcknowledged = true
    }

    package func acknowledgeAllPendingResults() {
        for idx in tasks.indices where Self.isTerminalState(tasks[idx].state) {
            tasks[idx].isResponsibilityAcknowledged = true
        }
    }

    private static func isTerminalState(_ state: ArchiveTaskExecutionState) -> Bool {
        state == .completed || state == .failed || state == .cancelled
    }

    package static func composeWarningMessage(
        cleanupWarning: String?,
        sourcePreservationNotice: String?
    ) -> String? {
        switch (cleanupWarning, sourcePreservationNotice) {
        case let (.some(cleanup), .some(preservation)):
            return "\(cleanup) · \(preservation)"
        case let (.some(cleanup), .none):
            return cleanup
        case let (.none, .some(preservation)):
            return preservation
        case (.none, .none):
            return nil
        }
    }

    /// Binds an existing execution handle to a queued operation.
    public func bind(
        id: UUID,
        handle: TaskExecutionHandle
    ) {
        attachedHandles[id] = handle
    }

    /// Binds an existing execution handle and Swift Task to a queued operation.
    public func bind<T: Sendable, E: Error>(
        id: UUID,
        handle: TaskExecutionHandle,
        task: Task<T, E>
    ) {
        attachedHandles[id] = handle
        handle.attach(task: task)
    }

    /// Submits an operation into the queue center, automatically binding lifecycle, handle, and cancellation tokens.
    @discardableResult
    public func submit<T: Sendable>(
        id: UUID = UUID(),
        name: String,
        type: ArchiveOperationType,
        totalBytes: Int64 = 0,
        operation: @escaping @Sendable (_ handle: TaskExecutionHandle) async throws -> T
    ) -> (id: UUID, task: Task<T, Error>) {
        let handle = ArchiveTaskCoordinator.shared.registerTask(id: id)
        let record = QueuedArchiveOperation(
            id: id,
            name: name,
            operationType: type,
            state: .queued,
            totalBytes: totalBytes
        )
        self.enqueue(operation: record)

        let wrappedTask = Task<T, Error> { [weak self] in
            await MainActor.run {
                self?.markRunning(id: id)
            }
            do {
                let result = try await operation(handle)
                await MainActor.run {
                    self?.markCompleted(id: id)
                }
                return result
            } catch let ArchiveError.createTransactionIncomplete(report) {
                await MainActor.run {
                    self?.markFailed(
                        id: id,
                        message: report.summaryMessage,
                        warningMessage: report.hasCleanupOrRecoveryIssues ? report.summaryMessage : nil,
                        createFailureReport: report
                    )
                }
                throw ArchiveError.createTransactionIncomplete(report)
            } catch is CancellationError {
                await MainActor.run {
                    self?.markCancelled(id: id)
                }
                throw CancellationError()
            } catch let archiveError as ArchiveError where archiveError == .cancelled {
                await MainActor.run {
                    self?.markCancelled(id: id)
                }
                throw archiveError
            } catch {
                await MainActor.run {
                    self?.markFailed(id: id, message: error.localizedDescription)
                }
                throw error
            }
        }

        self.bind(id: id, handle: handle, task: wrappedTask)
        return (id, wrappedTask)
    }

    /// Registers and enqueues a new background operation.
    public func enqueue(operation: QueuedArchiveOperation) {
        if let existingIdx = tasks.firstIndex(where: { $0.id == operation.id }) {
            tasks[existingIdx] = operation
        } else {
            tasks.append(operation)
        }
        recalculateTelemetry()
    }

    /// Updates live progress metrics for an operation.
    public func updateProgress(
        id: UUID,
        bytesProcessed: Int64,
        totalBytes: Int64,
        throughputMBs: Double
    ) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard !Self.isTerminalState(tasks[idx].state) else { return }
        tasks[idx].bytesProcessed = bytesProcessed
        if totalBytes > 0 {
            tasks[idx].totalBytes = totalBytes
        }
        tasks[idx].throughputMBs = throughputMBs
        if tasks[idx].state == .queued {
            tasks[idx].state = .running
        }
        recalculateTelemetry()
    }

    /// Marks an operation as actively running.
    public func markRunning(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard !Self.isTerminalState(tasks[idx].state) else { return }
        tasks[idx].state = .running
        recalculateTelemetry()
    }

    /// Marks an operation as completed, recording its complete operation summary, structured outcome,
    /// non-fatal post-commit cleanup warnings, and source preservation notices.
    public func markCompleted(
        id: UUID,
        summary: CompressionCompletedSummary? = nil,
        warningMessage: String? = nil,
        sourcePreservationNotice: String? = nil
    ) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard !Self.isTerminalState(tasks[idx].state) else { return }
        tasks[idx].state = .completed
        tasks[idx].bytesProcessed = tasks[idx].totalBytes
        tasks[idx].throughputMBs = 0.0
        tasks[idx].completedSummary = summary
        tasks[idx].outputPath = summary?.archivePath
        tasks[idx].outcome = summary?.outcome
        let resolvedCleanupWarning = warningMessage ?? summary?.cleanupWarningMessage
        let resolvedPreservationNotice = sourcePreservationNotice ?? summary?.sourcePreservationNotice
        tasks[idx].cleanupWarningMessage = resolvedCleanupWarning
        tasks[idx].sourcePreservationNotice = resolvedPreservationNotice
        tasks[idx].warningMessage = Self.composeWarningMessage(
            cleanupWarning: resolvedCleanupWarning,
            sourcePreservationNotice: resolvedPreservationNotice
        )
        tasks[idx].isResponsibilityAcknowledged = false
        releaseBindingIfPresent(id: id)
        recalculateTelemetry()
    }

    /// Marks an operation as failed with an optional error description, cleanup warning, and structured creation transaction failure report.
    /// Unacknowledged failed records remain protected from `clearFinishedTasks()` until `acknowledgeResult(id:)`.
    public func markFailed(
        id: UUID,
        message: String?,
        warningMessage: String? = nil,
        createFailureReport: ArchiveCreateTransactionFailureReport? = nil
    ) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard !Self.isTerminalState(tasks[idx].state) else { return }
        tasks[idx].state = .failed
        tasks[idx].errorMessage = message ?? createFailureReport?.summaryMessage
        tasks[idx].createFailureReport = createFailureReport
        if let createFailureReport {
            if createFailureReport.isCancellationRequested {
                tasks[idx].isCancellationRequested = true
            }
            if warningMessage == nil && createFailureReport.hasCleanupOrRecoveryIssues {
                tasks[idx].cleanupWarningMessage = createFailureReport.summaryMessage
                tasks[idx].warningMessage = createFailureReport.summaryMessage
            }
        }
        if let warningMessage {
            tasks[idx].cleanupWarningMessage = warningMessage
            tasks[idx].warningMessage = warningMessage
        }
        tasks[idx].isResponsibilityAcknowledged = false
        tasks[idx].throughputMBs = 0.0
        releaseBindingIfPresent(id: id)
        recalculateTelemetry()
    }

    /// Marks a bound operation as terminally cancelled after its execution worker exits.
    public func markCancelled(id: UUID, warningMessage: String? = nil) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard !Self.isTerminalState(tasks[idx].state) else { return }
        tasks[idx].state = .cancelled
        tasks[idx].isCancellationRequested = true
        if let warningMessage {
            tasks[idx].cleanupWarningMessage = warningMessage
            tasks[idx].warningMessage = warningMessage
        }
        tasks[idx].throughputMBs = 0.0
        releaseBindingIfPresent(id: id)
        recalculateTelemetry()
    }

    /// Pauses an active operation and dispatches cooperative pause to task coordinator.
    public func pause(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].state == .running else { return }
        tasks[idx].state = .paused
        tasks[idx].throughputMBs = 0.0
        attachedHandles[id]?.pause()
        ArchiveTaskCoordinator.shared.pauseTask(id: id)
        recalculateTelemetry()
    }

    /// Resumes a paused operation.
    public func resume(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].state == .paused || tasks[idx].state == .queued else { return }
        tasks[idx].state = .running
        attachedHandles[id]?.resume()
        ArchiveTaskCoordinator.shared.resumeTask(id: id)
        recalculateTelemetry()
    }

    /// Requests cooperative cancellation for an operation.
    /// Bound active executions remain in their non-terminal state with `isCancellationRequested = true`
    /// until the worker actually terminates and settles via `markCancelled`, `markCompleted`, or `markFailed`.
    public func cancel(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard !Self.isTerminalState(tasks[idx].state) else { return }
        tasks[idx].isCancellationRequested = true
        tasks[idx].throughputMBs = 0.0

        if let handle = attachedHandles[id] {
            handle.cancel()
            ArchiveTaskCoordinator.shared.cancelTask(id: id)
        } else {
            tasks[idx].state = .cancelled
            ArchiveTaskCoordinator.shared.cancelTask(id: id)
        }

        recalculateTelemetry()
    }

    @inline(__always)
    public func pauseTask(id: UUID) { pause(id: id) }

    @inline(__always)
    public func resumeTask(id: UUID) { resume(id: id) }

    @inline(__always)
    public func cancelTask(id: UUID) { cancel(id: id) }

    /// Clears settled terminal tasks from the queue history without removing or unbinding in-flight cancelling tasks
    /// and without discarding finished operations that still carry unacknowledged responsibilities or warnings.
    public func clearFinishedTasks() {
        let finishedIDs = tasks
            .filter {
                Self.isTerminalState($0.state)
                    && attachedHandles[$0.id] == nil
                    && !$0.hasPendingResponsibility
            }
            .map { $0.id }
        for id in finishedIDs {
            releaseBindingIfPresent(id: id)
            releasedBindingCounts.removeValue(forKey: id)
        }
        let finishedSet = Set(finishedIDs)
        tasks.removeAll { finishedSet.contains($0.id) }
        recalculateTelemetry()
    }

    /// Releases the attached execution handle and task coordinator registration at most once per task ID.
    private func releaseBindingIfPresent(id: UUID) {
        if attachedHandles.removeValue(forKey: id) != nil {
            releasedBindingCounts[id, default: 0] += 1
            ArchiveTaskCoordinator.shared.unregisterTask(id: id)
        }
    }

    /// Recalculates aggregate progress, throughput, and updates Dock indicator with monotonic batch progression.
    private func recalculateTelemetry() {
        let runningTasks = tasks.filter { $0.state == .running }
        self.activeTasksCount = runningTasks.count

        if runningTasks.isEmpty {
            self.overallProgress = 0.0
            self.overallThroughputMBs = 0.0
            DockProgressManager.shared.clearProgress()
        } else {
            // Monotonic batch progression: include completed tasks so progress doesn't regress
            let batchTasks = tasks.filter { $0.state == .running || $0.state == .paused || $0.state == .queued || $0.state == .completed }
            let total = batchTasks.reduce(Int64(0)) { $0 + max(1, $1.totalBytes) }
            let processed = batchTasks.reduce(Int64(0)) { $0 + $1.bytesProcessed }
            let fraction = total > 0 ? min(1.0, max(0.0, Double(processed) / Double(total))) : 0.0
            self.overallProgress = fraction
            self.overallThroughputMBs = runningTasks.reduce(0.0) { $0 + $1.throughputMBs }
            DockProgressManager.shared.updateProgress(fraction: fraction, activeCount: runningTasks.count)
        }
    }
}
