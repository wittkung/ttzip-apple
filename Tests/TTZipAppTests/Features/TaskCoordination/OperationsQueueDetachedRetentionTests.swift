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
final class OperationsQueueDetachedRetentionTests: XCTestCase {
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

    func testRealExternalURLCompressAndDeleteSourceDispatchToProtectedExecution() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_ext_url_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let srcFile = tmpRoot.appendingPathComponent("url_dispatched_source.txt").resolvingSymlinksInPath()
        try Data("URL_DISPATCHED_SOURCE_BYTES".utf8).write(to: srcFile)
        let encodedPath = try XCTUnwrap(srcFile.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        let url = try XCTUnwrap(URL(string: "ttzip://action?type=compress_and_delete_source&paths=\(encodedPath)"))
        let envelope = try XCTUnwrap(AppIntentParser.parse(url: url))

        let appState = AppViewState()
        AppIntentDispatcher.shared.bind(state: appState)
        AppIntentDispatcher.shared.dispatch(envelope)
        XCTAssertTrue(appState.navigationState.isCompressWorkspaceActive)
        XCTAssertTrue(appState.compressSession.deleteSourceAfterCompress)

        let doneExp = expectation(description: "real URL dispatched compression finished")
        appState.compressSession.selectedFormat = .zip
        appState.compressSession.openFinderAfterCompress = false
        appState.compressSession.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .completed && receipt.accepted {
                doneExp.fulfill()
            }
        }
        appState.compressSession.startCompression()
        let taskId = try XCTUnwrap(appState.compressSession.activeSessionTaskId)
        await fulfillment(of: [doneExp], timeout: 10.0)

        let summary = try XCTUnwrap(appState.compressSession.completedSummary)
        let inspection = try await TTZipEngineFacade.shared.inspectArchive(archivePath: summary.archivePath, password: nil)
        XCTAssertTrue(inspection.entries.contains(where: { $0.path.hasSuffix("url_dispatched_source.txt") }))
        XCTAssertEqual(try Data(contentsOf: srcFile), Data("URL_DISPATCHED_SOURCE_BYTES".utf8))
        XCTAssertNotNil(summary.sourcePreservationNotice)
        XCTAssertEqual(ArchiveOperationsQueueCenter.shared.completedSummary(for: taskId), summary)
        XCTAssertTrue(ArchiveOperationsQueueCenter.shared.hasPendingResponsibility(for: taskId))
    }

    func testDetachedAndCancelRequestedFailedOperationsRetainErrorAcrossClearFinishedTasks() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_fail_retain_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let srcFile = tmpRoot.appendingPathComponent("source.txt")
        try Data("FAIL_RETENTION_SOURCE".utf8).write(to: srcFile)

        let entered1 = expectation(description: "detached worker entered")
        let allowFail1 = expectation(description: "allow detached worker failure")
        let detachedErr = ArchiveError.engineFailure(code: -501, message: "Detached worker I/O failure (-501)")
        var detachedSession: CompressFormSession? = CompressFormSession(initialInputPaths: [srcFile.path])
        detachedSession?.targetDirectory = tmpRoot.path
        detachedSession?.outputName = "DetachedFail"
        detachedSession?.selectedFormat = .zip
        detachedSession?.openFinderAfterCompress = false
        detachedSession?.quickCompressExecutor = { _, _, _, _, _, _, _, _, _, _ in
            entered1.fulfill()
            await XCTWaiter().fulfillment(of: [allowFail1], timeout: 5.0)
            throw detachedErr
        }
        detachedSession?.startCompression()
        let detachedTaskId = try XCTUnwrap(detachedSession?.activeSessionTaskId)
        await fulfillment(of: [entered1], timeout: 5.0)
        detachedSession = nil
        allowFail1.fulfill()
        await OperationsQueueCoordinatorTests.waitForTerminalSettlement(id: detachedTaskId, in: center)

        XCTAssertEqual(center.operation(for: detachedTaskId)?.state, .failed)
        XCTAssertEqual(center.operation(for: detachedTaskId)?.errorMessage, detachedErr.localizedDescription)
        XCTAssertNil(center.outcome(for: detachedTaskId))
        XCTAssertNil(center.outputPath(for: detachedTaskId))
        XCTAssertFalse(center.isExecutionBound(id: detachedTaskId))
        XCTAssertEqual(center.bindingReleaseCount(for: detachedTaskId), 1)
        center.clearFinishedTasks()
        XCTAssertEqual(center.operation(for: detachedTaskId)?.state, .failed)
        XCTAssertEqual(center.operation(for: detachedTaskId)?.errorMessage, detachedErr.localizedDescription)

        let entered2 = expectation(description: "cancel-requested worker entered")
        let allowFail2 = expectation(description: "allow cancel-requested worker failure")
        let cancelRaceErr = ArchiveError.engineFailure(code: -502, message: "Engine write failure after cancel (-502)")
        let session2 = CompressFormSession(initialInputPaths: [srcFile.path])
        session2.targetDirectory = tmpRoot.path
        session2.outputName = "CancelRaceFail"
        session2.selectedFormat = .zip
        session2.openFinderAfterCompress = false
        session2.quickCompressExecutor = { _, _, _, _, _, _, _, _, _, _ in
            entered2.fulfill()
            await XCTWaiter().fulfillment(of: [allowFail2], timeout: 5.0)
            throw cancelRaceErr
        }
        session2.startCompression()
        let cancelRaceTaskId = try XCTUnwrap(session2.activeSessionTaskId)
        await fulfillment(of: [entered2], timeout: 5.0)
        session2.cancelCompression()
        XCTAssertEqual(center.operation(for: cancelRaceTaskId)?.state, .running)
        XCTAssertEqual(center.operation(for: cancelRaceTaskId)?.isCancellationRequested, true)
        allowFail2.fulfill()
        await OperationsQueueCoordinatorTests.waitForTerminalSettlement(id: cancelRaceTaskId, in: center)

        XCTAssertEqual(center.operation(for: cancelRaceTaskId)?.state, .failed)
        XCTAssertEqual(center.operation(for: cancelRaceTaskId)?.errorMessage, cancelRaceErr.localizedDescription)
        center.clearFinishedTasks()
        XCTAssertEqual(center.operation(for: cancelRaceTaskId)?.state, .failed)
        XCTAssertEqual(center.operation(for: cancelRaceTaskId)?.errorMessage, cancelRaceErr.localizedDescription)
        XCTAssertFalse(center.isExecutionBound(id: cancelRaceTaskId))
        XCTAssertEqual(center.bindingReleaseCount(for: cancelRaceTaskId), 1)
        XCTAssertNil(ArchiveTaskCoordinator.shared.handle(for: cancelRaceTaskId))
    }

    func testFailedTaskIsolationIdempotenceAndDiskInvarianceOnAcknowledge() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_fail_iso_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let srcSentinel = tmpRoot.appendingPathComponent("source_sentinel.txt")
        let residualSentinel = tmpRoot.appendingPathComponent(".ttzip_residual_sentinel")
        try Data("SOURCE_SENTINEL_BYTES".utf8).write(to: srcSentinel)
        try Data("RESIDUAL_SENTINEL_BYTES".utf8).write(to: residualSentinel)

        let enteredA = expectation(description: "Task A entered")
        let finishA = expectation(description: "Allow Task A fail")
        let errA = ArchiveError.engineFailure(code: -601, message: "Task A distinct failure (-601)")
        let errB = ArchiveError.engineFailure(code: -602, message: "Task B distinct failure (-602)")

        let session = CompressFormSession(initialInputPaths: [srcSentinel.path])
        session.targetDirectory = tmpRoot.path
        session.outputName = "FailTaskA"
        session.selectedFormat = .zip
        session.openFinderAfterCompress = false
        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            if outputPath.hasSuffix("FailTaskA.zip") {
                enteredA.fulfill()
                await XCTWaiter().fulfillment(of: [finishA], timeout: 5.0)
                throw errA
            }
            throw errB
        }

        session.startCompression()
        let taskIdA = try XCTUnwrap(session.activeSessionTaskId)
        await fulfillment(of: [enteredA], timeout: 5.0)

        session.detachActiveTaskToBackground()
        session.outputName = "FailTaskB"
        session.startCompression()
        let taskIdB = try XCTUnwrap(session.activeSessionTaskId)
        await OperationsQueueCoordinatorTests.waitForTerminalSettlement(id: taskIdB, in: center)

        finishA.fulfill()
        await OperationsQueueCoordinatorTests.waitForTerminalSettlement(id: taskIdA, in: center)

        XCTAssertEqual(center.operation(for: taskIdA)?.state, .failed)
        XCTAssertEqual(center.operation(for: taskIdA)?.errorMessage, errA.localizedDescription)
        XCTAssertEqual(center.operation(for: taskIdB)?.state, .failed)
        XCTAssertEqual(center.operation(for: taskIdB)?.errorMessage, errB.localizedDescription)
        XCTAssertNotEqual(center.operation(for: taskIdA)?.errorMessage, center.operation(for: taskIdB)?.errorMessage)

        center.markCompleted(id: taskIdA)
        center.markFailed(id: taskIdA, message: "Mutated error message")
        center.markCancelled(id: taskIdA)
        XCTAssertEqual(center.operation(for: taskIdA)?.state, .failed)
        XCTAssertEqual(center.operation(for: taskIdA)?.errorMessage, errA.localizedDescription)
        XCTAssertEqual(center.bindingReleaseCount(for: taskIdA), 1)

        center.clearFinishedTasks()
        XCTAssertNotNil(center.operation(for: taskIdA))
        XCTAssertNotNil(center.operation(for: taskIdB))
        center.acknowledgeResult(id: taskIdA)
        center.clearFinishedTasks()
        XCTAssertNil(center.operation(for: taskIdA))
        XCTAssertNotNil(center.operation(for: taskIdB))
        XCTAssertEqual(try Data(contentsOf: srcSentinel), Data("SOURCE_SENTINEL_BYTES".utf8))
        XCTAssertEqual(try Data(contentsOf: residualSentinel), Data("RESIDUAL_SENTINEL_BYTES".utf8))
    }

    func testClearFinishedTasksRetentionMatrixIncludingNilMessageFailed() throws {
        let center = ArchiveOperationsQueueCenter.shared
        let cleanCompletedId = UUID()
        let cleanCancelledId = UUID()
        let warnCompletedId = UUID()
        let preserveCompletedId = UUID()
        let nilMsgFailedId = UUID()

        for id in [cleanCompletedId, cleanCancelledId, warnCompletedId, preserveCompletedId, nilMsgFailedId] {
            center.enqueue(operation: QueuedArchiveOperation(
                id: id, name: "Op_\(id.uuidString.prefix(4)).zip", operationType: .compress, state: .running
            ))
        }

        center.markCompleted(id: cleanCompletedId)
        center.markCancelled(id: cleanCancelledId)
        center.markCompleted(id: warnCompletedId, warningMessage: "Cleanup warning")
        center.markCompleted(id: preserveCompletedId, sourcePreservationNotice: "Source preserved")
        center.markFailed(id: nilMsgFailedId, message: nil)

        XCTAssertFalse(center.hasPendingResponsibility(for: cleanCompletedId))
        XCTAssertFalse(center.hasPendingResponsibility(for: cleanCancelledId))
        XCTAssertTrue(center.hasPendingResponsibility(for: warnCompletedId))
        XCTAssertTrue(center.hasPendingResponsibility(for: preserveCompletedId))
        XCTAssertTrue(center.hasPendingResponsibility(for: nilMsgFailedId))

        center.clearFinishedTasks()
        XCTAssertNil(center.operation(for: cleanCompletedId))
        XCTAssertNil(center.operation(for: cleanCancelledId))
        XCTAssertNotNil(center.operation(for: warnCompletedId))
        XCTAssertNotNil(center.operation(for: preserveCompletedId))
        XCTAssertEqual(center.operation(for: nilMsgFailedId)?.state, .failed)
        XCTAssertNil(center.operation(for: nilMsgFailedId)?.errorMessage)

        center.acknowledgeResult(id: nilMsgFailedId)
        XCTAssertFalse(center.hasPendingResponsibility(for: nilMsgFailedId))
        center.clearFinishedTasks()
        XCTAssertNil(center.operation(for: nilMsgFailedId))
        XCTAssertNotNil(center.operation(for: warnCompletedId))
        XCTAssertNotNil(center.operation(for: preserveCompletedId))
    }

    func testCreateTransactionIncompleteWithPrimaryCancelledSettlesAsFailedNeverCancelled() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        let report = ArchiveCreateTransactionFailureReport(
            primaryStatusCode: 2,
            wasPrimaryCancelled: true,
            isCancellationRequested: true,
            stageDir: "/tmp/.ttzip_create_txn_u1",
            stageDirPreserved: true,
            unconfirmedReleaseCount: 1,
            cleanupFailures: [
                ArchiveStageCleanupFailureItem(
                    role: .stagedArtifact,
                    disposition: .descriptorReleaseUnconfirmed,
                    path: nil,
                    originalStagedPath: "/tmp/.ttzip_create_txn_u1/out.7z",
                    osErrorCode: Int32(EINTR),
                    message: "close(2) returned EINTR"
                )
            ],
            finishDiagnostics: [
                ArchiveStageFileFinishDiagnostic(
                    role: .stagedArtifact,
                    diagnosticPath: "/tmp/.ttzip_create_txn_u1/out.7z",
                    expectedDev: 1,
                    expectedIno: 2,
                    primaryStatusCode: 2,
                    closeOsError: Int32(EINTR),
                    closeDetail: "Interrupted system call",
                    releaseStatus: .releaseUnconfirmed
                )
            ],
            summaryMessage: "Transaction incomplete after cancel"
        )

        let submission = center.submit(name: "CancelWithUnconfirmedClose.7z", type: .compress) { _ -> Void in
            throw ArchiveError.createTransactionIncomplete(report)
        }
        let taskId = submission.id
        await OperationsQueueCoordinatorTests.waitForTerminalSettlement(id: taskId, in: center)

        let op = try XCTUnwrap(center.operation(for: taskId))
        XCTAssertEqual(op.state, .failed, "CreateTransactionIncomplete must settle as .failed, NEVER .cancelled")
        XCTAssertTrue(op.isCancellationRequested, "Cancel intent must be monotonically preserved on the failed record")
        XCTAssertEqual(op.createFailureReport, report)
        XCTAssertTrue(op.hasPendingResponsibility)
        XCTAssertTrue(center.hasPendingResponsibility(for: taskId))
        XCTAssertNotNil(op.warningMessage)

        center.clearFinishedTasks()
        XCTAssertNotNil(center.operation(for: taskId))
        center.acknowledgeResult(id: taskId)
        XCTAssertFalse(center.hasPendingResponsibility(for: taskId))
        center.clearFinishedTasks()
        XCTAssertNil(center.operation(for: taskId))
    }

    func testU1CompressFormSessionCreateTransactionIncompleteRoutesToQueueFailedReport() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_u1_session_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let srcFile = tmpRoot.appendingPathComponent("u1_src.txt")
        try Data("U1_SOURCE".utf8).write(to: srcFile)

        let session = CompressFormSession(initialInputPaths: [srcFile.path])
        session.targetDirectory = tmpRoot.path
        session.outputName = "u1_incomplete"
        session.openFinderAfterCompress = false
        let report = ArchiveCreateTransactionFailureReport(
            primaryStatusCode: -23,
            wasPrimaryCancelled: true,
            isCancellationRequested: true,
            stageDir: tmpRoot.appendingPathComponent(".ttzip_create_txn_s1").path,
            stageDirPreserved: true,
            unconfirmedReleaseCount: 1,
            summaryMessage: "Unconfirmed close release on cancel"
        )
        session.quickCompressExecutor = { _, _, _, _, _, _, _, _, _, _ in
            throw ArchiveError.createTransactionIncomplete(report)
        }
        session.startCompression()
        let taskId = try XCTUnwrap(session.activeSessionTaskId)
        await OperationsQueueCoordinatorTests.waitForTerminalSettlement(id: taskId, in: center)
        let op = try XCTUnwrap(center.operation(for: taskId))
        XCTAssertEqual(op.state, .failed)
        XCTAssertEqual(op.createFailureReport, report)
        center.acknowledgeResult(id: taskId)
        center.clearFinishedTasks()
    }
}
