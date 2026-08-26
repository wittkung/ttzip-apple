// SPDX-License-Identifier: BSD-3-Clause OR Apache-2.0
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import Observation
import TTZipCore

/// Application-wide background operations queue and telemetry coordinator.
@Observable
@MainActor
public final class ArchiveOperationsQueueCenter {
    public static let shared = ArchiveOperationsQueueCenter()

    public private(set) var tasks: [QueuedArchiveOperation] = []
    public private(set) var activeTasksCount: Int = 0
    public private(set) var overallProgress: Double = 0.0
    public private(set) var overallThroughputMBs: Double = 0.0

    private init() {}

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
        tasks[idx].state = .running
        recalculateTelemetry()
    }

    /// Marks an operation as completed.
    public func markCompleted(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = .completed
        tasks[idx].bytesProcessed = tasks[idx].totalBytes
        tasks[idx].throughputMBs = 0.0
        recalculateTelemetry()
    }

    /// Marks an operation as failed with an optional error description.
    public func markFailed(id: UUID, message: String?) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = .failed
        tasks[idx].errorMessage = message
        tasks[idx].throughputMBs = 0.0
        recalculateTelemetry()
    }

    /// Pauses an active operation and dispatches cooperative pause to task coordinator.
    public func pause(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].state == .running else { return }
        tasks[idx].state = .paused
        tasks[idx].throughputMBs = 0.0
        ArchiveTaskCoordinator.shared.pauseTask(id: id)
        recalculateTelemetry()
    }

    /// Resumes a paused operation.
    public func resume(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].state == .paused || tasks[idx].state == .queued else { return }
        tasks[idx].state = .running
        ArchiveTaskCoordinator.shared.resumeTask(id: id)
        recalculateTelemetry()
    }

    /// Cancels an operation and dispatches cooperative cancellation down to the engine.
    public func cancel(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].state != .completed && tasks[idx].state != .cancelled && tasks[idx].state != .failed else { return }
        tasks[idx].state = .cancelled
        tasks[idx].throughputMBs = 0.0
        ArchiveTaskCoordinator.shared.cancelTask(id: id)
        recalculateTelemetry()
    }

    /// Clears completed, failed, or cancelled tasks from the queue history.
    public func clearFinishedTasks() {
        tasks.removeAll { $0.state == .completed || $0.state == .failed || $0.state == .cancelled }
        recalculateTelemetry()
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
