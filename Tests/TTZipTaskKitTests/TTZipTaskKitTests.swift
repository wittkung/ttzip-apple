// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import TTZipOperationContract
import TTZipCore
@testable import TTZipTaskKit

@MainActor
private final class RecordingProgressSink: TaskProgressIndicatorSink {
    struct UpdateEvent: Equatable {
        let fraction: Double
        let activeCount: Int
    }

    private(set) var updates: [UpdateEvent] = []
    private(set) var clearCount: Int = 0

    func updateProgress(fraction: Double, activeCount: Int) {
        updates.append(UpdateEvent(fraction: fraction, activeCount: activeCount))
    }

    func clearProgress() {
        clearCount += 1
    }
}

@MainActor
final class TTZipTaskKitTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
        ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
    }

    override func tearDown() async throws {
        ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
        ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
        try await super.tearDown()
    }

    func testSampledProgressStreamSnapshotAtomicityAndCancellationCascade() async throws {
        let handle = TaskExecutionHandle()
        let sheet = ProgressAtomicSheet(totalBytes: 4_096, handle: handle)

        XCTAssertEqual(sheet.readSnapshot(), ProgressSnapshot(totalBytes: 4_096))
        XCTAssertFalse(sheet.readSnapshot().isIndeterminate)

        let stream = SampledProgressStream.makeStream(
            sheet: sheet,
            frequency: .custom(120.0)
        )

        let collectedTask = Task<[ProgressSnapshot], Never> {
            var snapshots: [ProgressSnapshot] = []
            for await snapshot in stream {
                snapshots.append(snapshot)
            }
            return snapshots
        }

        try await Task.sleep(nanoseconds: 25_000_000)
        sheet.updateProgress(processed: 2_048, instantBps: 10 * 1024 * 1024, itemName: "payload.bin")
        try await Task.sleep(nanoseconds: 25_000_000)
        sheet.markFinished()

        let snapshots = await collectedTask.value
        XCTAssertGreaterThanOrEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.first?.processedBytes, 0)
        let terminal = try XCTUnwrap(snapshots.last)
        XCTAssertTrue(terminal.isFinished)
        XCTAssertTrue(terminal.isTerminal)
        XCTAssertEqual(terminal.processedBytes, 4_096)
        XCTAssertEqual(terminal.totalBytes, 4_096)
        XCTAssertEqual(terminal.fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(terminal.currentItemName, "payload.bin")

        let cancelHandle = TaskExecutionHandle()
        let cancelSheet = ProgressAtomicSheet(totalBytes: 1_024, handle: cancelHandle)
        let cancelStream = SampledProgressStream.makeStream(
            sheet: cancelSheet,
            frequency: .sixtyHz
        )
        let consumer = Task {
            for await _ in cancelStream {}
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()
        await consumer.value
        XCTAssertTrue(cancelSheet.isCancelled)
        XCTAssertTrue(cancelHandle.isCancelled)
    }

    func testArchiveTaskCoordinatorRegisterPauseResumeCancelLifecycle() {
        let coordinator = ArchiveTaskCoordinator.shared
        let baselineCount = coordinator.activeCount
        let taskID = UUID()

        let handle = coordinator.registerTask(id: taskID)
        defer { coordinator.unregisterTask(id: taskID) }

        XCTAssertEqual(coordinator.activeCount, baselineCount + 1)
        XCTAssertTrue(coordinator.handle(for: taskID) === handle)
        XCTAssertFalse(handle.isPaused)
        XCTAssertFalse(handle.isCancelled)

        coordinator.pauseTask(id: taskID)
        XCTAssertTrue(handle.isPaused)

        coordinator.resumeTask(id: taskID)
        XCTAssertFalse(handle.isPaused)

        coordinator.cancelTask(id: taskID)
        XCTAssertTrue(handle.isCancelled)
        XCTAssertTrue(handle.uniffiToken.isCancelled())

        coordinator.unregisterTask(id: taskID)
        XCTAssertNil(coordinator.handle(for: taskID))
        XCTAssertEqual(coordinator.activeCount, baselineCount)
    }

    func testArchiveOperationsQueueCenterTransitionsAndResponsibilityRetention() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        let previousSink = center.progressIndicatorSink
        let sink = RecordingProgressSink()
        center.progressIndicatorSink = sink
        defer { center.progressIndicatorSink = previousSink }

        let warningID = UUID()
        center.enqueue(
            operation: QueuedArchiveOperation(
                id: warningID,
                name: "ArchiveWithWarning.zip",
                operationType: .compress,
                state: .queued,
                totalBytes: 1_000
            )
        )
        center.updateProgress(id: warningID, bytesProcessed: 400, totalBytes: 1_000, throughputMBs: 16.0)
        XCTAssertEqual(center.operation(for: warningID)?.state, .running)
        XCTAssertEqual(center.activeTasksCount, 1)
        XCTAssertEqual(sink.updates.last, .init(fraction: 0.4, activeCount: 1))

        center.pause(id: warningID)
        XCTAssertEqual(center.operation(for: warningID)?.state, .paused)
        XCTAssertEqual(center.activeTasksCount, 0)

        center.resume(id: warningID)
        XCTAssertEqual(center.operation(for: warningID)?.state, .running)
        XCTAssertEqual(center.activeTasksCount, 1)

        let warningOutcome = ExtractionOutcome(
            status: .completedWithFailures,
            extracted: 3,
            replaced: 0,
            keptBoth: 0,
            skipped: 0,
            failed: [FailedItem(relativePath: "locked.tmp", reason: .permissionDenied, errno: 13)]
        )
        let summary = CompressionCompletedSummary(
            taskId: warningID,
            archivePath: "/tmp/ArchiveWithWarning.zip",
            originalBytes: 1_000,
            compressedBytes: 620,
            elapsedSeconds: 0.05,
            throughputMBs: 20.0,
            format: .zip,
            isEncrypted: false,
            outcome: warningOutcome,
            cleanupWarningMessage: "cleanup residual"
        )
        center.markCompleted(id: warningID, summary: summary)
        XCTAssertEqual(center.operation(for: warningID)?.state, .completed)
        XCTAssertTrue(center.hasPendingResponsibility(for: warningID))
        XCTAssertGreaterThanOrEqual(sink.clearCount, 1)

        center.clearFinishedTasks()
        XCTAssertNotNil(center.operation(for: warningID))

        center.acknowledgeResult(id: warningID)
        XCTAssertFalse(center.hasPendingResponsibility(for: warningID))
        center.clearFinishedTasks()
        XCTAssertNil(center.operation(for: warningID))
    }

    func testBoundCancellationRemainsNonTerminalUntilWorkerSettles() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        let taskID = UUID()
        let handle = ArchiveTaskCoordinator.shared.registerTask(id: taskID)
        let workerObservedCancel = expectation(description: "worker observed cancellation")

        let worker = Task {
            while !Task.isCancelled && !handle.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            workerObservedCancel.fulfill()
        }

        center.enqueue(
            operation: QueuedArchiveOperation(
                id: taskID,
                name: "InFlightCancel.7z",
                operationType: .extract,
                state: .running,
                totalBytes: 2_048,
                bytesProcessed: 512,
                throughputMBs: 8.0
            )
        )
        center.bind(id: taskID, handle: handle, task: worker)

        center.cancel(id: taskID)
        XCTAssertEqual(center.operation(for: taskID)?.state, .running)
        XCTAssertEqual(center.operation(for: taskID)?.isCancellationRequested, true)
        XCTAssertTrue(center.isExecutionBound(id: taskID))

        center.clearFinishedTasks()
        XCTAssertNotNil(center.operation(for: taskID))

        await fulfillment(of: [workerObservedCancel], timeout: 2.0)
        center.markCancelled(id: taskID)
        XCTAssertEqual(center.operation(for: taskID)?.state, .cancelled)
        XCTAssertFalse(center.isExecutionBound(id: taskID))
        XCTAssertEqual(center.bindingReleaseCount(for: taskID), 1)

        center.clearFinishedTasks()
        XCTAssertNil(center.operation(for: taskID))
    }
}
