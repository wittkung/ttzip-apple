// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class CompressFormSessionCancellationSettlementTests: XCTestCase {

    @MainActor
    func testU1CancelDoesNotMaskRealEngineOrCleanupErrorAndDetachedSessionSettlesInQueue() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_u1_err_detach_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let srcFile = tmpRoot.appendingPathComponent("u1_err.txt")
        try Data("U1_ERR".utf8).write(to: srcFile)

        let failedExp = expectation(description: "failed boundary")
        let session = CompressFormSession()
        session.loadInputPaths([srcFile.path])
        session.targetDirectory = tmpRoot.path
        session.outputName = "u1_real_err"
        session.selectedFormat = .zip
        session.openFinderAfterCompress = false
        session.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .failed {
                failedExp.fulfill()
            }
        }
        session.quickCompressExecutor = { _, _, _, _, _, _, _, _, _, token in
            token?.cancel()
            throw ArchiveError.engineFailure(code: -12, message: "Failed to clean up staging transaction after cancel")
        }

        session.startCompression()
        let errTaskId = try XCTUnwrap(session.activeSessionTaskId)
        await fulfillment(of: [failedExp], timeout: 5.0)

        let errQueueRecord = try XCTUnwrap(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == errTaskId })
        )
        XCTAssertEqual(
            errQueueRecord.state,
            .failed,
            "Real I/O or cleanup error after cancel token set must be recorded as .failed, not masked as .cancelled"
        )

        let workerEntered = expectation(description: "detached worker entered")
        let allowDetachedFinish = expectation(description: "allow detached finish")
        var detachedSession: CompressFormSession? = CompressFormSession()
        detachedSession?.loadInputPaths([srcFile.path])
        detachedSession?.targetDirectory = tmpRoot.path
        detachedSession?.outputName = "u1_detached_win"
        detachedSession?.selectedFormat = .zip
        detachedSession?.openFinderAfterCompress = false
        detachedSession?.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            workerEntered.fulfill()
            await XCTWaiter().fulfillment(of: [allowDetachedFinish], timeout: 5.0)
            try Data("DETACHED_OK".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath,
                originalBytes: 6,
                compressedBytes: 11,
                durationSeconds: 0.01,
                throughputMBs: 8.0
            )
        }

        detachedSession?.startCompression()
        let detachedTaskId = try XCTUnwrap(detachedSession?.activeSessionTaskId)
        weak let weakDetachedSession = detachedSession
        await fulfillment(of: [workerEntered], timeout: 5.0)

        detachedSession = nil
        allowDetachedFinish.fulfill()
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNil(weakDetachedSession, "Detached CompressFormSession must not be leaked by retain cycles")
        let detachedRecord = try XCTUnwrap(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == detachedTaskId })
        )
        XCTAssertEqual(
            detachedRecord.state,
            .completed,
            "Operation owner (ArchiveOperationsQueueCenter) must settle terminal completion even if CompressFormSession was deallocated"
        )
        XCTAssertEqual(ArchiveOperationsQueueCenter.shared.bindingReleaseCount(for: detachedTaskId), 1)
    }

    @MainActor
    func testU1CancelRequestDoesNotPrematurelyReleaseResponsibilityOrOverwriteCommittedSuccess() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_u1_cancel_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let srcFile = tmpRoot.appendingPathComponent("u1_input.txt")
        try Data("U1_INPUT".utf8).write(to: srcFile)

        let workerEntered = expectation(description: "worker entered")
        let allowWorkerReturn = expectation(description: "allow worker return")
        let boundaryCompleted = expectation(description: "boundary completed")

        let session = CompressFormSession()
        session.loadInputPaths([srcFile.path])
        session.targetDirectory = tmpRoot.path
        session.outputName = "u1_committed"
        session.selectedFormat = .zip
        session.openFinderAfterCompress = false
        session.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .completed || receipt.kind == .failed {
                boundaryCompleted.fulfill()
            }
        }
        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            workerEntered.fulfill()
            await XCTWaiter().fulfillment(of: [allowWorkerReturn], timeout: 5.0)
            try Data("COMMITTED_AFTER_CANCEL_REQ".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath,
                originalBytes: 8,
                compressedBytes: 26,
                durationSeconds: 0.02,
                throughputMBs: 5.0
            )
        }

        session.startCompression()
        await fulfillment(of: [workerEntered], timeout: 5.0)
        let taskId = try XCTUnwrap(session.activeSessionTaskId)

        session.cancelCompression()
        session.cancelCompression()

        XCTAssertTrue(session.isProcessing, "Session must stay busy until worker actually finishes")
        XCTAssertTrue(session.isCancellationRequested)
        XCTAssertEqual(session.activeSessionTaskId, taskId, "activeSessionTaskId must stay bound until terminal event")
        XCTAssertNotNil(ArchiveTaskCoordinator.shared.handle(for: taskId), "Coordinator registration must remain until worker finishes")

        ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
        XCTAssertNotNil(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == taskId }),
            "In-flight cancelling task must not be removed by clearFinishedTasks before worker finishes"
        )

        allowWorkerReturn.fulfill()
        await fulfillment(of: [boundaryCompleted], timeout: 5.0)

        XCTAssertEqual(session.currentProgress.state, .completed)
        XCTAssertNotNil(session.completedSummary)
        XCTAssertEqual(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == taskId })?.state,
            .completed
        )
        XCTAssertEqual(ArchiveOperationsQueueCenter.shared.bindingReleaseCount(for: taskId), 1)
    }

    @MainActor
    func testD03aRealFilteredDirectoryCompressionPreservesExcludedAndIncludedSources() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_d03a_real_filter_\(UUID().uuidString)", isDirectory: true)
        let sourceDir = tmpRoot.appendingPathComponent("project_folder", isDirectory: true)
        let nestedDir = sourceDir.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let includedRootFile = sourceDir.appendingPathComponent("included_report.txt")
        let includedNestedFile = nestedDir.appendingPathComponent("nested_keep.txt")
        let excludedDsStore = sourceDir.appendingPathComponent(".DS_Store")
        let excludedAppleDouble = nestedDir.appendingPathComponent("._nested_keep.txt")
        try Data("INCLUDED_REPORT_CONTENT_2026".utf8).write(to: includedRootFile)
        try Data("NESTED_KEEP_CONTENT".utf8).write(to: includedNestedFile)
        try Data("FINDER_DS_STORE_METADATA_BYTES".utf8).write(to: excludedDsStore)
        try Data("APPLE_DOUBLE_RESOURCE_FORK_BYTES".utf8).write(to: excludedAppleDouble)

        let completedExp = expectation(description: "real filtered directory compression completed")
        let session = CompressFormSession(initialInputPaths: [sourceDir.path])
        session.targetDirectory = tmpRoot.path
        session.outputName = "real_filtered_archive"
        session.selectedFormat = .zip
        session.skipMacJunk = true
        session.deleteSourceAfterCompress = true
        session.openFinderAfterCompress = false
        session.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .completed && receipt.accepted {
                completedExp.fulfill()
            }
        }

        session.startCompression()
        let taskId = try XCTUnwrap(session.activeSessionTaskId)
        await fulfillment(of: [completedExp], timeout: 10.0)

        let summary = try XCTUnwrap(session.completedSummary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.archivePath))
        let inspection = try await TTZipEngineFacade.shared.inspectArchive(archivePath: summary.archivePath, password: nil)
        let entryPaths = inspection.entries.map(\.path)
        XCTAssertTrue(entryPaths.contains(where: { $0.hasSuffix("included_report.txt") }))
        XCTAssertTrue(entryPaths.contains(where: { $0.hasSuffix("subdir/nested_keep.txt") }))
        XCTAssertFalse(entryPaths.contains(where: { $0.contains(".DS_Store") }), "skipMacJunk must exclude .DS_Store from real archive")
        XCTAssertFalse(entryPaths.contains(where: { $0.contains("._nested_keep.txt") }), "skipMacJunk must exclude AppleDouble file from real archive")

        XCTAssertEqual(try Data(contentsOf: includedRootFile), Data("INCLUDED_REPORT_CONTENT_2026".utf8))
        XCTAssertEqual(try Data(contentsOf: includedNestedFile), Data("NESTED_KEEP_CONTENT".utf8))
        XCTAssertEqual(try Data(contentsOf: excludedDsStore), Data("FINDER_DS_STORE_METADATA_BYTES".utf8))
        XCTAssertEqual(try Data(contentsOf: excludedAppleDouble), Data("APPLE_DOUBLE_RESOURCE_FORK_BYTES".utf8))
        XCTAssertNotNil(summary.sourcePreservationNotice)
        XCTAssertEqual(ArchiveOperationsQueueCenter.shared.completedSummary(for: taskId), summary)
        XCTAssertTrue(ArchiveOperationsQueueCenter.shared.hasPendingResponsibility(for: taskId))
    }

    @MainActor
    func testCreateTransactionFailureSheetAndCleanupItemsInspection() async throws {
        let residual = FailedItem(relativePath: "/tmp/.ttzip_create_bak_55", reason: .permissionDenied, errno: 13)
        let sheet = CompressionSummarySheetView(archivePath: "/tmp/a.zip", originalSizeBytes: 100, compressedSizeBytes: 50, elapsedSeconds: 0.1, throughputMBs: 10.0, format: .zip, isEncrypted: false, cleanupWarningMessage: "warn", failedCleanupItems: [residual], onCloseAndExplore: {})
        XCTAssertTrue(sheet.renderedNotices.contains(where: { $0.contains("/tmp/.ttzip_create_bak_55") && $0.contains("permissionDenied") }))
        let failExp = expectation(description: "create transaction incomplete failure sheet")
        let report = ArchiveCreateTransactionFailureReport(primaryStatusCode: -23, wasPrimaryCancelled: true, isCancellationRequested: true, stageDir: "/tmp/.ttzip_create_txn_sheet", stageDirPreserved: true, unconfirmedReleaseCount: 1, summaryMessage: "Stage preserved after cancel")
        let session = CompressFormSession()
        session.itemsList = [CompressFileItem(path: "/tmp/in.txt")]
        session.onBoundaryEventEvaluated = { if $0.kind == .failed && $0.accepted { failExp.fulfill() } }
        session.quickCompressExecutor = { _, _, _, _, _, _, _, _, _, _ in throw ArchiveError.createTransactionIncomplete(report) }
        session.startCompression()
        let failTaskId = try XCTUnwrap(session.activeSessionTaskId)
        await fulfillment(of: [failExp], timeout: 5.0)
        XCTAssertTrue(session.isCreateFailureSheetPresented)
        XCTAssertEqual(session.failedCreateTransactionReport, report)
        ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
        XCTAssertTrue(ArchiveOperationsQueueCenter.shared.hasPendingResponsibility(for: failTaskId))
        session.acknowledgeFailedCreateTransaction()
        XCTAssertFalse(session.isCreateFailureSheetPresented)
        XCTAssertFalse(ArchiveOperationsQueueCenter.shared.hasPendingResponsibility(for: failTaskId))
        ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
    }
}
