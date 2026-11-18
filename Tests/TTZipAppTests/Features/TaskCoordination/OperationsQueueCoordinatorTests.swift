// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import SwiftUI
import os
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

@MainActor
final class OperationsQueueCoordinatorTests: XCTestCase {
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

    static func waitForTerminalSettlement(id: UUID, in center: ArchiveOperationsQueueCenter) async {
        while true {
            if let op = center.operation(for: id),
               (op.state == .completed || op.state == .failed || op.state == .cancelled),
               !center.isExecutionBound(id: id) {
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let resumeOnce: @Sendable () -> Void = {
                    let shouldResume = resumed.withLock { state -> Bool in
                        guard !state else { return false }
                        state = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume()
                    }
                }
                let settledNow = withObservationTracking {
                    guard let op = center.operation(for: id) else { return false }
                    return (op.state == .completed || op.state == .failed || op.state == .cancelled)
                        && !center.isExecutionBound(id: id)
                } onChange: {
                    resumeOnce()
                }
                if settledNow {
                    resumeOnce()
                }
            }
        }
    }

    func testOperationsQueueLifecycleAndTelemetry() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        
        let op1Id = UUID()
        let op1 = QueuedArchiveOperation(
            id: op1Id,
            name: "Archive 1.zip",
            operationType: .compress,
            state: .queued,
            totalBytes: 1000,
            bytesProcessed: 0,
            throughputMBs: 0.0
        )
        
        center.enqueue(operation: op1)
        XCTAssertEqual(center.tasks.count, 1)
        XCTAssertEqual(center.activeTasksCount, 0)
        XCTAssertEqual(center.overallProgress, 0.0)
        
        center.updateProgress(id: op1Id, bytesProcessed: 500, totalBytes: 1000, throughputMBs: 25.5)
        XCTAssertEqual(center.activeTasksCount, 1)
        XCTAssertEqual(center.overallProgress, 0.5, accuracy: 0.01)
        XCTAssertEqual(center.overallThroughputMBs, 25.5, accuracy: 0.01)
        
        // Enqueue second task
        let op2Id = UUID()
        let op2 = QueuedArchiveOperation(
            id: op2Id,
            name: "Extract 2.7z",
            operationType: .extract,
            state: .running,
            totalBytes: 1000,
            bytesProcessed: 500,
            throughputMBs: 15.0
        )
        center.enqueue(operation: op2)
        XCTAssertEqual(center.activeTasksCount, 2)
        XCTAssertEqual(center.overallProgress, 0.5, accuracy: 0.01)
        XCTAssertEqual(center.overallThroughputMBs, 40.5, accuracy: 0.01)
        
        // Pause op1
        center.pause(id: op1Id)
        XCTAssertEqual(center.tasks.first(where: { $0.id == op1Id })?.state, .paused)
        XCTAssertEqual(center.activeTasksCount, 1)
        
        // Resume op1
        center.resume(id: op1Id)
        XCTAssertEqual(center.tasks.first(where: { $0.id == op1Id })?.state, .running)
        XCTAssertEqual(center.activeTasksCount, 2)
        
        // Complete op1
        center.markCompleted(id: op1Id)
        XCTAssertEqual(center.tasks.first(where: { $0.id == op1Id })?.state, .completed)
        XCTAssertEqual(center.activeTasksCount, 1)
        
        // Cancel op2
        center.cancel(id: op2Id)
        XCTAssertEqual(center.tasks.first(where: { $0.id == op2Id })?.state, .cancelled)
        XCTAssertEqual(center.activeTasksCount, 0)
        XCTAssertEqual(center.overallProgress, 0.0)
        
        // Clear finished
        center.clearFinishedTasks()
        XCTAssertEqual(center.tasks.count, 0)
    }

    func testOperationsQueueRealCancellationBinding() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        let taskId = UUID()
        let handle = ArchiveTaskCoordinator.shared.registerTask(id: taskId)

        let exp = expectation(description: "Task cancelled")
        let innerTask = Task {
            while !Task.isCancelled && !handle.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            exp.fulfill()
        }

        let op = QueuedArchiveOperation(
            id: taskId,
            name: "Bound Task.zip",
            operationType: .compress,
            state: .running,
            totalBytes: 5000,
            bytesProcessed: 100,
            throughputMBs: 10.0
        )
        center.enqueue(operation: op)
        center.bind(id: taskId, handle: handle, task: innerTask)

        XCTAssertFalse(handle.isCancelled)
        XCTAssertFalse(handle.uniffiToken.isCancelled())

        // Trigger cancel via QueueCenter UI entrypoint while task is bound and running
        center.cancel(id: taskId)

        // While the worker is still running, cancellation request is recorded without premature terminal state or unbinding
        XCTAssertEqual(center.tasks.first(where: { $0.id == taskId })?.state, .running)
        XCTAssertEqual(center.tasks.first(where: { $0.id == taskId })?.isCancellationRequested, true)

        // Verify handle and underlying UniFFI token were physically cancelled
        XCTAssertTrue(handle.isCancelled)
        XCTAssertTrue(handle.uniffiToken.isCancelled())

        // clearFinishedTasks must NOT remove an in-flight cancelling task before its worker finishes
        center.clearFinishedTasks()
        XCTAssertNotNil(center.tasks.first(where: { $0.id == taskId }))

        // Verify attached Swift task received cancellation and finishes
        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertTrue(innerTask.isCancelled)

        // Once the worker terminates, settle terminal cancellation and verify single binding release
        center.markCancelled(id: taskId)
        XCTAssertEqual(center.tasks.first(where: { $0.id == taskId })?.state, .cancelled)
        XCTAssertEqual(center.bindingReleaseCount(for: taskId), 1)

        center.clearFinishedTasks()
        XCTAssertNil(center.tasks.first(where: { $0.id == taskId }))
    }

    func testOperationsQueueSubmitExecutionAndCancellation() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        let tokenCheckExp = expectation(description: "Token check fulfilled")

        let (opId, wrappedTask) = center.submit(
            name: "AsyncSubmit.zip",
            type: .compress,
            totalBytes: 2000
        ) { handle in
            while !handle.isCancelled && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            tokenCheckExp.fulfill()
            throw CancellationError()
        }

        // Wait brief moment for task to enter running loop
        try await Task.sleep(nanoseconds: 20_000_000)

        // Cancel via QueueCenter
        center.cancel(id: opId)

        await fulfillment(of: [tokenCheckExp], timeout: 2.0)
        
        do {
            _ = try await wrappedTask.value
            XCTFail("Expected cancellation error")
        } catch is CancellationError {
            // Success
        }

        XCTAssertEqual(center.tasks.first(where: { $0.id == opId })?.state, .cancelled)
        center.clearFinishedTasks()
    }

    func testDetachedSessionRetainsCompleteResultAndClearFinishedProtectsUnacknowledgedResponsibilities() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_queue_retention_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let savedLanguage = AppLocalizationState.shared.currentLanguage
        defer {
            AppLocalizationState.shared.setLanguage(savedLanguage)
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let srcFile = tmpRoot.appendingPathComponent("source.txt")
        try Data("RETENTION_SOURCE".utf8).write(to: srcFile)
        let expectedArchivePath = tmpRoot.appendingPathComponent("detached_warn.zip").path
        let failedCleanupItem = FailedItem(
            relativePath: tmpRoot.appendingPathComponent(".ttzip_stage_residual").path,
            reason: .permissionDenied,
            errno: 13
        )
        let warningOutcome = ExtractionOutcome(
            status: .completedWithFailures,
            extracted: 1,
            replaced: 0,
            keptBoth: 0,
            skipped: 0,
            failed: [failedCleanupItem]
        )

        // 1. Verify localized cleanup warning under Simplified Chinese
        AppLocalizationState.shared.setLanguage(.zhHans)
        let localizedWarning = try XCTUnwrap(
            CompressionCompletedSummary.makeCleanupWarningMessage(outcome: warningOutcome)
        )
        XCTAssertFalse(
            localizedWarning.contains("post-commit cleanup warning(s)"),
            "Cleanup warning must use localized string table instead of hardcoded English"
        )

        // 2. Start compression on a session that is deallocated before worker returns
        let workerEntered = expectation(description: "worker entered")
        let allowFinish = expectation(description: "allow worker finish")
        var session: CompressFormSession? = CompressFormSession()
        session?.loadInputPaths([srcFile.path])
        session?.targetDirectory = tmpRoot.path
        session?.outputName = "detached_warn"
        session?.selectedFormat = .zip
        session?.openFinderAfterCompress = false
        session?.deleteSourceAfterCompress = true
        session?.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            workerEntered.fulfill()
            await XCTWaiter().fulfillment(of: [allowFinish], timeout: 5.0)
            try Data("COMMITTED_ARCHIVE".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath,
                originalBytes: 16,
                compressedBytes: 17,
                durationSeconds: 0.02,
                throughputMBs: 12.0,
                outcome: warningOutcome
            )
        }

        session?.startCompression()
        let taskId = try XCTUnwrap(session?.activeSessionTaskId)
        await fulfillment(of: [workerEntered], timeout: 5.0)

        // Deallocate form session before completion
        session = nil
        allowFinish.fulfill()
        await Self.waitForTerminalSettlement(id: taskId, in: center)

        let record = try XCTUnwrap(center.tasks.first(where: { $0.id == taskId }))
        let recordMirrorChildren = Dictionary(
            uniqueKeysWithValues: Mirror(reflecting: record).children.compactMap { child -> (String, Any)? in
                guard let label = child.label else { return nil }
                return (label, child.value)
            }
        )
        let retainedOutputPath = recordMirrorChildren["outputPath"] as? String
        let retainedOutcome = recordMirrorChildren["outcome"] as? ExtractionOutcome
        XCTAssertEqual(
            retainedOutputPath,
            expectedArchivePath,
            "Queue operation record must retain archive outputPath after form session is deallocated"
        )
        XCTAssertEqual(
            retainedOutcome?.failed,
            [failedCleanupItem],
            "Queue operation record must retain structured ExtractionOutcome failed items after form deallocation"
        )

        // 3. clearFinishedTasks() must NOT silently drop an unacknowledged warning / source preservation record
        center.clearFinishedTasks()
        XCTAssertNotNil(
            center.tasks.first(where: { $0.id == taskId }),
            "clearFinishedTasks() must not discard finished task with unacknowledged cleanup warning or source preservation notice"
        )
        XCTAssertEqual(center.outputPath(for: taskId), expectedArchivePath)
        XCTAssertEqual(center.outcome(for: taskId)?.failed, [failedCleanupItem])
        XCTAssertEqual(center.completedSummary(for: taskId)?.taskId, taskId)
        XCTAssertNotNil(center.completedSummary(for: taskId)?.sourcePreservationNotice)
        XCTAssertNotNil(center.completedSummary(for: taskId)?.cleanupWarningMessage)
        XCTAssertTrue(center.hasPendingResponsibility(for: taskId))
        XCTAssertFalse(center.isExecutionBound(id: taskId))
        XCTAssertEqual(center.bindingReleaseCount(for: taskId), 1)
        XCTAssertNil(ArchiveTaskCoordinator.shared.handle(for: taskId))

        // 4. Explicit acknowledgment allows clearFinishedTasks() to remove the in-memory record without deleting disk files
        center.acknowledgeResult(id: taskId)
        XCTAssertFalse(center.hasPendingResponsibility(for: taskId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedArchivePath))
        center.clearFinishedTasks()
        XCTAssertNil(center.operation(for: taskId))
    }

    func testDetachedBackgroundTaskAndNewForegroundTaskRetainSeparateResultsAndIdempotentSettlement() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_detach_ab_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let srcFile = tmpRoot.appendingPathComponent("ab_source.txt")
        try Data("AB_SOURCE_PAYLOAD".utf8).write(to: srcFile)
        let failedItemA = FailedItem(
            relativePath: tmpRoot.appendingPathComponent(".ttzip_txn_a").path,
            reason: .permissionDenied,
            errno: 13
        )
        let outcomeA = ExtractionOutcome(
            status: .completedWithFailures, extracted: 1, replaced: 0, keptBoth: 0, skipped: 0, failed: [failedItemA]
        )

        let enteredA = expectation(description: "Task A entered")
        let finishA = expectation(description: "Allow Task A finish")
        let completedB = expectation(description: "Task B completed on form")
        let rejectedLateA = expectation(description: "Late Task A evaluated at boundary")

        let session = CompressFormSession(initialInputPaths: [srcFile.path])
        session.targetDirectory = tmpRoot.path
        session.outputName = "TaskA_Warn"
        session.selectedFormat = .zip
        session.openFinderAfterCompress = false
        session.deleteSourceAfterCompress = true
        var taskIdA: UUID?
        var taskIdB: UUID?
        session.onBoundaryEventEvaluated = { receipt in
            if receipt.taskId == taskIdB && receipt.kind == .completed && receipt.accepted {
                completedB.fulfill()
            } else if receipt.taskId == taskIdA && receipt.kind == .completed && !receipt.accepted {
                rejectedLateA.fulfill()
            }
        }
        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            if outputPath.hasSuffix("TaskA_Warn.zip") {
                enteredA.fulfill()
                await XCTWaiter().fulfillment(of: [finishA], timeout: 5.0)
                try Data("ARCHIVE_A".utf8).write(to: URL(fileURLWithPath: outputPath))
                return ArchiveOperationResult(
                    outputPath: outputPath, originalBytes: 17, compressedBytes: 9,
                    durationSeconds: 0.02, throughputMBs: 10.0, outcome: outcomeA
                )
            }
            try Data("ARCHIVE_B".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath, originalBytes: 17, compressedBytes: 9,
                durationSeconds: 0.01, throughputMBs: 20.0, outcome: nil
            )
        }

        session.startCompression()
        let idA = try XCTUnwrap(session.activeSessionTaskId)
        taskIdA = idA
        await fulfillment(of: [enteredA], timeout: 5.0)

        // Detach Task A and start clean Task B on the same session; B finishes before A
        session.detachActiveTaskToBackground()
        session.outputName = "TaskB_Clean"
        session.deleteSourceAfterCompress = false
        session.startCompression()
        let idB = try XCTUnwrap(session.activeSessionTaskId)
        taskIdB = idB
        await fulfillment(of: [completedB], timeout: 5.0)

        finishA.fulfill()
        await fulfillment(of: [rejectedLateA], timeout: 5.0)

        let expectedPathA = tmpRoot.appendingPathComponent("TaskA_Warn.zip").path
        let expectedPathB = tmpRoot.appendingPathComponent("TaskB_Clean.zip").path
        XCTAssertEqual(session.completedSummary?.taskId, idB)
        XCTAssertEqual(session.completedSummary?.archivePath, expectedPathB)
        XCTAssertEqual(center.outputPath(for: idA), expectedPathA)
        XCTAssertEqual(center.outcome(for: idA)?.failed, [failedItemA])
        XCTAssertTrue(center.hasPendingResponsibility(for: idA))
        XCTAssertEqual(center.outputPath(for: idB), expectedPathB)
        XCTAssertNil(center.outcome(for: idB))
        XCTAssertFalse(center.hasPendingResponsibility(for: idB))

        // Duplicate terminal calls on settled Task A must be no-ops
        center.markFailed(id: idA, message: "Should not overwrite settled completion")
        center.markCancelled(id: idA)
        XCTAssertEqual(center.operation(for: idA)?.state, .completed)
        XCTAssertEqual(center.bindingReleaseCount(for: idA), 1)

        // clearFinishedTasks removes clean Task B while preserving unacknowledged Task A
        center.clearFinishedTasks()
        XCTAssertNil(center.operation(for: idB))
        XCTAssertNotNil(center.operation(for: idA))
    }

    func testCleanupWarningLocalizationAcrossAllLanguagesAndSummarySheetOffscreenHosting() throws {
        let savedLanguage = AppLocalizationState.shared.currentLanguage
        defer { AppLocalizationState.shared.setLanguage(savedLanguage) }

        let outcome = ExtractionOutcome(
            status: .completedWithFailures,
            extracted: 3,
            replaced: 0,
            keptBoth: 0,
            skipped: 0,
            failed: [
                FailedItem(relativePath: "/tmp/r1", reason: .permissionDenied, errno: 13),
                FailedItem(relativePath: "/tmp/r2", reason: .permissionDenied, errno: 66)
            ]
        )
        let languages: [AppLanguage] = [.en, .zhHans, .zhHant, .ja, .de, .fr, .es]
        for lang in languages {
            AppLocalizationState.shared.setLanguage(lang)
            let warning = try XCTUnwrap(CompressionCompletedSummary.makeCleanupWarningMessage(outcome: outcome))
            let preservation = try XCTUnwrap(CompressionCompletedSummary.makeSourcePreservationNotice(shouldDeleteSource: true))
            XCTAssertTrue(warning.contains("2"), "Warning in \(lang.bcp47) must include failed item count 2")
            XCTAssertFalse(preservation.isEmpty)
            if lang != .en {
                XCTAssertFalse(
                    warning.contains("post-commit cleanup warning(s)"),
                    "Non-English locale \(lang.bcp47) must not fall back to hardcoded English"
                )
            }
        }

        // Verify all 4 notice states in CompressionSummarySheetView + offscreen NSHostingView layout
        let cases: [(String?, String?, Int)] = [
            (nil, nil, 0),
            (nil, "Preservation only", 1),
            ("Cleanup warning only", nil, 1),
            ("Cleanup warning", "Preservation notice", 2)
        ]
        for (cleanup, preservation, expectedCount) in cases {
            let sheet = CompressionSummarySheetView(
                archivePath: "/tmp/out.zip",
                originalSizeBytes: 1024,
                compressedSizeBytes: 512,
                elapsedSeconds: 0.2,
                throughputMBs: 25.0,
                format: .zip,
                isEncrypted: false,
                cleanupWarningMessage: cleanup,
                sourcePreservationNotice: preservation,
                onCloseAndExplore: {}
            )
            XCTAssertEqual(sheet.hasNotices, expectedCount > 0)
            XCTAssertEqual(sheet.renderedNotices.count, expectedCount)
            let hosting = NSHostingView(rootView: sheet)
            hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        }
    }
}
