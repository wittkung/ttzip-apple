// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import TTZipUI
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class CompressWorkspaceTabTests: XCTestCase {

    func testCompressWorkspaceTabLifecycle() async throws {
        let nav = NavigationState()
        XCTAssertEqual(nav.directoryTabs.count, 1)
        XCTAssertFalse(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTabIndex, 0)
        
        // 1. Open compress workspace tab
        nav.openCompressWorkspaceTab()
        XCTAssertEqual(nav.directoryTabs.count, 2)
        XCTAssertTrue(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTabIndex, 1)
        
        let compressTab = nav.directoryTabs[1]
        XCTAssertTrue(compressTab.isCompressWorkspace)
        XCTAssertEqual(compressTab.url.absoluteString, "ttzip://compress-workspace")
        XCTAssertFalse(compressTab.title.isEmpty)
        
        // 2. Select first tab (regular directory)
        nav.selectTab(at: 0)
        XCTAssertEqual(nav.activeTabIndex, 0)
        XCTAssertFalse(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTab, .home)
        
        // 3. Select back to compress tab
        nav.selectTab(at: 1)
        XCTAssertEqual(nav.activeTabIndex, 1)
        XCTAssertTrue(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTab, .compressWorkspace)
        
        // 4. Close compress tab
        nav.closeCompressWorkspaceTab()
        XCTAssertEqual(nav.directoryTabs.count, 1)
        XCTAssertFalse(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTabIndex, 0)
        XCTAssertEqual(nav.activeTab, .home)
    }

    func testCompressWorkspaceTabReentrance() async throws {
        let nav = NavigationState()
        
        // Calling open multiple times must focus existing tab rather than duplicate
        nav.openCompressWorkspaceTab()
        XCTAssertEqual(nav.directoryTabs.count, 2)
        XCTAssertEqual(nav.activeTabIndex, 1)
        
        nav.selectTab(at: 0)
        XCTAssertEqual(nav.activeTabIndex, 0)
        
        nav.openCompressWorkspaceTab()
        XCTAssertEqual(nav.directoryTabs.count, 2)
        XCTAssertEqual(nav.activeTabIndex, 1)
        XCTAssertTrue(nav.isCompressWorkspaceActive)
    }

    func testCompressWorkspaceCloseTabByIndex() async throws {
        let nav = NavigationState()
        nav.openCompressWorkspaceTab()
        XCTAssertEqual(nav.directoryTabs.count, 2)
        
        // Closing tab at index 1
        nav.closeTab(at: 1)
        XCTAssertEqual(nav.directoryTabs.count, 1)
        XCTAssertFalse(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTabIndex, 0)
    }

    func testCompressWorkspaceTabCycling() async throws {
        let nav = NavigationState()
        nav.openCompressWorkspaceTab()
        XCTAssertEqual(nav.activeTabIndex, 1)
        
        // Cycling to previous
        nav.selectPreviousTab()
        XCTAssertEqual(nav.activeTabIndex, 0)
        XCTAssertFalse(nav.isCompressWorkspaceActive)
        
        // Cycling to next
        nav.selectNextTab()
        XCTAssertEqual(nav.activeTabIndex, 1)
        XCTAssertTrue(nav.isCompressWorkspaceActive)
    }

    func testCompressFormSessionInitialState() async throws {
        let session = CompressFormSession()
        XCTAssertTrue(session.itemsList.isEmpty)
        XCTAssertEqual(session.selectedFormat, .sevenZip)
        XCTAssertEqual(session.compressionLevel, .normal)
        XCTAssertFalse(session.outputName.isEmpty)
        XCTAssertFalse(session.isProcessing)
    }

    // MARK: - E1: Task Ownership Across Cancel and Immediate Retry

    func testCancelledTaskLateProgressDoesNotMutateRunningRetrySession() async throws {
        let (session, tempDir) = try makeConfiguredSession(prefix: "CompressLateProgress")
        let recorder = BoundaryReceiptRecorder(session: session)
        let enterGateA = CompressionStepGate(description: "Task A entered")
        let finishGateA = CompressionStepGate(description: "Task A finish")
        let enterGateB = CompressionStepGate(description: "Task B entered")
        let invocationCounter = LockedCounter()
        defer {
            enterGateA.release()
            finishGateA.release()
            enterGateB.release()
            AppErrorReporter.shared.dismiss()
        }

        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, progress, _ in
            if invocationCounter.increment() == 1 {
                await enterGateA.enterAndWait()
                progress?(ArchiveProgress(
                    state: .processing, bytesProcessed: 999, totalBytes: 1024,
                    currentFileName: "stale-from-A.txt", throughputMBs: 1.0
                ))
                await finishGateA.enterAndWait()
                return Self.makeResult(outputPath: outputPath, compressedBytes: 512)
            }
            progress?(ArchiveProgress(
                state: .processing, bytesProcessed: 512, totalBytes: 1024,
                currentFileName: "active-from-B.txt", throughputMBs: 25.0
            ))
            await enterGateB.enterAndWait()
            return Self.makeResult(outputPath: outputPath, compressedBytes: 256)
        }

        var trackedTaskIds: [UUID] = []
        do {
            let (taskIdA, taskIdB) = try await startACancelAndStartRunningB(
                session: session, recorder: recorder, enterGateA: enterGateA, enterGateB: enterGateB,
                trackedTaskIds: &trackedTaskIds
            )
            let staleProgressArrived = recorder.expectReceipt(description: "Stale A progress evaluated") {
                $0.taskId == taskIdA && $0.kind == .progress && $0.currentFileName == "stale-from-A.txt"
            }
            enterGateA.release()
            await fulfillment(of: [staleProgressArrived], timeout: 2.0)

            let staleReceipt = recorder.firstReceipt {
                $0.taskId == taskIdA && $0.kind == .progress && $0.currentFileName == "stale-from-A.txt"
            }
            XCTAssertEqual(staleReceipt?.accepted, false, "Stale Task A progress must be rejected at acceptance boundary")
            assertRunningStateBelongsToB(session: session, taskIdB: taskIdB)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        enterGateA.release()
        finishGateA.release()
        enterGateB.release()
        await waitForTerminalBoundaryReceipts(recorder: recorder, taskIds: trackedTaskIds)
        assertTerminalCompletionBelongsToB(session: session, tempDir: tempDir)
    }

    func testCancelledTaskLateSuccessDoesNotMutateRunningRetrySession() async throws {
        let (session, tempDir) = try makeConfiguredSession(prefix: "CompressLateSuccess")
        let recorder = BoundaryReceiptRecorder(session: session)
        let enterGateA = CompressionStepGate(description: "Task A entered")
        let enterGateB = CompressionStepGate(description: "Task B entered")
        let invocationCounter = LockedCounter()
        defer {
            enterGateA.release()
            enterGateB.release()
            AppErrorReporter.shared.dismiss()
        }

        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, progress, _ in
            if invocationCounter.increment() == 1 {
                await enterGateA.enterAndWait()
                return Self.makeResult(
                    outputPath: (tempDir.path as NSString).appendingPathComponent("ArchiveA.7z"),
                    compressedBytes: 777
                )
            }
            progress?(ArchiveProgress(
                state: .processing, bytesProcessed: 512, totalBytes: 1024,
                currentFileName: "active-from-B.txt", throughputMBs: 25.0
            ))
            await enterGateB.enterAndWait()
            return Self.makeResult(outputPath: outputPath, compressedBytes: 256)
        }

        var trackedTaskIds: [UUID] = []
        do {
            let (taskIdA, taskIdB) = try await startACancelAndStartRunningB(
                session: session, recorder: recorder, enterGateA: enterGateA, enterGateB: enterGateB,
                trackedTaskIds: &trackedTaskIds
            )
            let terminalA = recorder.expectTerminalBoundaryReceipt(for: taskIdA)
            enterGateA.release()
            await fulfillment(of: [terminalA], timeout: 2.0)

            let staleReceipt = recorder.firstReceipt { $0.taskId == taskIdA && $0.kind == .completed }
            XCTAssertEqual(staleReceipt?.accepted, false, "Stale Task A completion must be rejected at acceptance boundary")
            XCTAssertEqual(
                ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == taskIdA })?.state,
                .completed,
                "Historical Task A real completion must still be settled by the operation owner"
            )
            assertRunningStateBelongsToB(session: session, taskIdB: taskIdB)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        enterGateA.release()
        enterGateB.release()
        await waitForTerminalBoundaryReceipts(recorder: recorder, taskIds: trackedTaskIds)
        assertTerminalCompletionBelongsToB(session: session, tempDir: tempDir)
    }

    func testCancelledTaskLateFailureDoesNotMutateRunningRetrySession() async throws {
        let (session, tempDir) = try makeConfiguredSession(prefix: "CompressLateFailure")
        let recorder = BoundaryReceiptRecorder(session: session)
        let enterGateA = CompressionStepGate(description: "Task A entered")
        let enterGateB = CompressionStepGate(description: "Task B entered")
        let invocationCounter = LockedCounter()
        AppErrorReporter.shared.dismiss()
        defer {
            enterGateA.release()
            enterGateB.release()
            AppErrorReporter.shared.dismiss()
        }

        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, progress, _ in
            if invocationCounter.increment() == 1 {
                await enterGateA.enterAndWait()
                throw ArchiveError.engineFailure(code: -12, message: "Disk full from stale A")
            }
            progress?(ArchiveProgress(
                state: .processing, bytesProcessed: 512, totalBytes: 1024,
                currentFileName: "active-from-B.txt", throughputMBs: 25.0
            ))
            await enterGateB.enterAndWait()
            return Self.makeResult(outputPath: outputPath, compressedBytes: 256)
        }

        var trackedTaskIds: [UUID] = []
        do {
            let (taskIdA, taskIdB) = try await startACancelAndStartRunningB(
                session: session, recorder: recorder, enterGateA: enterGateA, enterGateB: enterGateB,
                trackedTaskIds: &trackedTaskIds
            )
            let terminalA = recorder.expectTerminalBoundaryReceipt(for: taskIdA)
            enterGateA.release()
            await fulfillment(of: [terminalA], timeout: 2.0)

            let staleReceipt = recorder.firstReceipt { $0.taskId == taskIdA && $0.kind == .failed }
            XCTAssertEqual(staleReceipt?.accepted, false, "Stale Task A failure must be rejected at acceptance boundary")
            XCTAssertEqual(
                ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == taskIdA })?.state,
                .failed,
                "Historical Task A real failure must still be settled by the operation owner"
            )
            XCTAssertFalse(AppErrorReporter.shared.isPresentingError, "Stale Task A failure must not present error alert")
            assertRunningStateBelongsToB(session: session, taskIdB: taskIdB)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        enterGateA.release()
        enterGateB.release()
        await waitForTerminalBoundaryReceipts(recorder: recorder, taskIds: trackedTaskIds)
        assertTerminalCompletionBelongsToB(session: session, tempDir: tempDir)
    }

    func testCoordinatorTokenCancellationArbitratesLateExecutorSuccessAndSuppressesSideEffects() async throws {
        let (session, tempDir) = try makeConfiguredSession(prefix: "CompressCoordinatorTokenCancelSuccess")
        let inputURL = tempDir.appendingPathComponent("payload.txt")
        let recorder = BoundaryReceiptRecorder(session: session)
        let successGate = CompressionStepGate(description: "Task A entered before coordinator cancel")
        var revealedOutputs: [(String, String)] = []
        session.deleteSourceAfterCompress = true
        session.openFinderAfterCompress = true
        session.revealCompletedArchive = { out, dir in revealedOutputs.append((out, dir)) }
        AppErrorReporter.shared.dismiss()
        defer {
            successGate.release()
            AppErrorReporter.shared.dismiss()
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
        }

        var trackedTaskIds: [UUID] = []
        do {
            session.outputName = "TokenCancelledSuccess"
            session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, token in
                await successGate.enterAndWait()
                XCTAssertEqual(token?.isCancelled(), true)
                return Self.makeResult(outputPath: outputPath, compressedBytes: 333)
            }
            session.startCompression()
            let taskIdA = try XCTUnwrap(session.activeSessionTaskId)
            trackedTaskIds.append(taskIdA)
            await fulfillment(of: [successGate.entered], timeout: 2.0)

            ArchiveOperationsQueueCenter.shared.cancel(id: taskIdA)
            XCTAssertEqual(session.activeSessionTaskId, taskIdA, "Direct coordinator cancel does not clear session task ID before boundary")

            let terminalA = recorder.expectTerminalBoundaryReceipt(for: taskIdA)
            successGate.release()
            await fulfillment(of: [terminalA], timeout: 2.0)

            let receiptA = recorder.firstReceipt { $0.taskId == taskIdA && $0.kind == .completed }
            XCTAssertEqual(receiptA?.accepted, true)
            XCTAssertFalse(session.isProcessing)
            XCTAssertFalse(session.isProgressModalPresented)
            XCTAssertNil(session.activeSessionTaskId)
            // Real archive completion after a cancel request must remain .completed (U1 rule: cancel request is not failure evidence)
            XCTAssertEqual(session.currentProgress.state, .completed)
            XCTAssertTrue(session.isSummarySheetPresented, "Committed archive after cancel request must present summary")
            XCTAssertNotNil(session.completedSummary, "Committed archive after cancel request must preserve completedSummary")
            XCTAssertNotNil(session.completedSummary?.sourcePreservationNotice)
            XCTAssertTrue(FileManager.default.fileExists(atPath: inputURL.path), "D-03a must preserve source file")
            XCTAssertTrue(revealedOutputs.isEmpty, "Late completion after cancel request must not auto-pop Finder")
            XCTAssertEqual(ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == taskIdA })?.state, .completed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        successGate.release()
        await waitForTerminalBoundaryReceipts(recorder: recorder, taskIds: trackedTaskIds)
    }

    func testCoordinatorTokenCancellationClassifiesSubsequentOrdinaryErrorAsCancelled() async throws {
        let (session, _) = try makeConfiguredSession(prefix: "CompressCoordinatorTokenCancelError")
        let recorder = BoundaryReceiptRecorder(session: session)
        let errorGate = CompressionStepGate(description: "Task entered before coordinator cancel")
        AppErrorReporter.shared.dismiss()
        defer {
            errorGate.release()
            AppErrorReporter.shared.dismiss()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
        }

        var trackedTaskIds: [UUID] = []
        do {
            session.outputName = "TokenCancelledError"
            session.quickCompressExecutor = { _, _, _, _, _, _, _, _, _, token in
                await errorGate.enterAndWait()
                XCTAssertEqual(token?.isCancelled(), true)
                throw ArchiveError.engineFailure(code: -12, message: "Interrupted write after token cancel")
            }
            session.startCompression()
            let taskId = try XCTUnwrap(session.activeSessionTaskId)
            trackedTaskIds.append(taskId)
            await fulfillment(of: [errorGate.entered], timeout: 2.0)

            ArchiveTaskCoordinator.shared.cancelTask(id: taskId)
            XCTAssertEqual(session.activeSessionTaskId, taskId)

            let terminal = recorder.expectTerminalBoundaryReceipt(for: taskId)
            errorGate.release()
            await fulfillment(of: [terminal], timeout: 2.0)

            let receipt = recorder.firstReceipt { $0.taskId == taskId && $0.kind == .failed }
            XCTAssertEqual(receipt?.accepted, true)
            XCTAssertFalse(session.isProcessing)
            XCTAssertFalse(session.isProgressModalPresented)
            XCTAssertNil(session.activeSessionTaskId)
            // Non-cancellation engine/cleanup errors must not be masked as .cancelled merely because the token was cancelled
            XCTAssertEqual(
                session.currentProgress.state,
                .failed(error: ArchiveError.engineFailure(code: -12, message: "Interrupted write after token cancel").localizedDescription)
            )
            XCTAssertTrue(AppErrorReporter.shared.isPresentingError, "Real engine/cleanup error after token cancel must be reported")
            XCTAssertNotNil(AppErrorReporter.shared.activeError)
            XCTAssertEqual(ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == taskId })?.state, .failed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        errorGate.release()
        await waitForTerminalBoundaryReceipts(recorder: recorder, taskIds: trackedTaskIds)
    }

    func testNormalCompressionCompletionAndCancellationPositiveControls() async throws {
        let (session, tempDir) = try makeConfiguredSession(prefix: "CompressPositiveControls")
        let recorder = BoundaryReceiptRecorder(session: session)
        let cancelGate = CompressionStepGate(description: "Cancelled task entered")
        defer {
            cancelGate.release()
            AppErrorReporter.shared.dismiss()
        }

        // Positive Control 1: Normal completion
        session.outputName = "NormalOut"
        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            Self.makeResult(outputPath: outputPath, compressedBytes: 128)
        }
        session.startCompression()
        let normalTaskId = try XCTUnwrap(session.activeSessionTaskId)
        let normalDone = recorder.expectTerminalBoundaryReceipt(for: normalTaskId)
        await fulfillment(of: [normalDone], timeout: 2.0)

        XCTAssertFalse(session.isProcessing)
        XCTAssertFalse(session.isProgressModalPresented)
        XCTAssertTrue(session.isSummarySheetPresented)
        XCTAssertEqual(session.completedSummary?.archivePath, tempDir.appendingPathComponent("NormalOut.7z").path)

        // Positive Control 2: Single-task cancellation holds ownership until worker exits with ArchiveError.cancelled
        session.quickCompressExecutor = { _, _, _, _, _, _, _, _, _, _ in
            await cancelGate.enterAndWait()
            throw ArchiveError.cancelled
        }
        session.outputName = "CancelledOut"
        session.startCompression()
        let cancelledTaskId = try XCTUnwrap(session.activeSessionTaskId)
        let cancelledTerminal = recorder.expectTerminalBoundaryReceipt(for: cancelledTaskId)
        await fulfillment(of: [cancelGate.entered], timeout: 2.0)

        session.cancelCompression()
        XCTAssertTrue(session.isProcessing, "Cancel request must not release busy state before worker finishes")
        XCTAssertTrue(session.isCancellationRequested)
        XCTAssertEqual(session.activeSessionTaskId, cancelledTaskId)
        XCTAssertEqual(session.currentProgress.state, .processing)

        cancelGate.release()
        await fulfillment(of: [cancelledTerminal], timeout: 2.0)

        let cancelReceipt = recorder.firstReceipt { $0.taskId == cancelledTaskId && $0.kind == .failed }
        XCTAssertEqual(cancelReceipt?.accepted, true)
        XCTAssertFalse(session.isProcessing)
        XCTAssertFalse(session.isProgressModalPresented)
        XCTAssertFalse(session.isSummarySheetPresented)
        XCTAssertNil(session.completedSummary)
        XCTAssertEqual(session.currentProgress.state, .cancelled)
    }

    // MARK: - E1 Test Support

    private func makeConfiguredSession(prefix: String) throws -> (CompressFormSession, URL) {
        let tempDir = try makeTemporaryDirectory(prefix: prefix)
        let inputURL = tempDir.appendingPathComponent("payload.txt")
        try Data(repeating: 0x41, count: 1024).write(to: inputURL)
        let session = CompressFormSession(initialInputPaths: [inputURL.path])
        session.targetDirectory = tempDir.path
        session.openFinderAfterCompress = false
        session.deleteSourceAfterCompress = false
        return (session, tempDir)
    }

    private func startACancelAndStartRunningB(
        session: CompressFormSession,
        recorder: BoundaryReceiptRecorder,
        enterGateA: CompressionStepGate,
        enterGateB: CompressionStepGate,
        trackedTaskIds: inout [UUID]
    ) async throws -> (UUID, UUID) {
        session.outputName = "ArchiveA"
        session.startCompression()
        let taskIdA = try XCTUnwrap(session.activeSessionTaskId)
        trackedTaskIds.append(taskIdA)
        await fulfillment(of: [enterGateA.entered], timeout: 2.0)
        XCTAssertTrue(session.isProcessing)
        XCTAssertTrue(session.isProgressModalPresented)

        session.cancelCompression()
        XCTAssertTrue(session.isProcessing)
        XCTAssertTrue(session.isCancellationRequested)
        XCTAssertEqual(session.activeSessionTaskId, taskIdA)

        // Detach Task A to background so a new operation B can be configured on the form while A settles in QueueCenter
        session.detachActiveTaskToBackground()
        XCTAssertFalse(session.isProcessing)
        XCTAssertFalse(session.isProgressModalPresented)
        XCTAssertNil(session.activeSessionTaskId)

        session.outputName = "ArchiveB"
        session.startCompression()
        let taskIdB = try XCTUnwrap(session.activeSessionTaskId)
        trackedTaskIds.append(taskIdB)
        XCTAssertNotEqual(taskIdA, taskIdB)
        let progressBArrived = recorder.expectReceipt(description: "Task B progress accepted") {
            $0.taskId == taskIdB && $0.kind == .progress && $0.currentFileName == "active-from-B.txt"
        }
        await fulfillment(of: [enterGateB.entered, progressBArrived], timeout: 2.0)
        assertRunningStateBelongsToB(session: session, taskIdB: taskIdB)
        return (taskIdA, taskIdB)
    }

    private func waitForTerminalBoundaryReceipts(recorder: BoundaryReceiptRecorder, taskIds: [UUID]) async {
        guard !taskIds.isEmpty else { return }
        let expectations = taskIds.map { recorder.expectTerminalBoundaryReceipt(for: $0) }
        await fulfillment(of: expectations, timeout: 2.0)
        ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
        ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
    }

    private func assertRunningStateBelongsToB(session: CompressFormSession, taskIdB: UUID) {
        XCTAssertEqual(session.activeSessionTaskId, taskIdB, "Stale Task A must not clear or replace B's task ID")
        XCTAssertTrue(session.isProcessing, "Stale Task A must not clear B's isProcessing flag")
        XCTAssertTrue(session.isProgressModalPresented, "Stale Task A must not dismiss B's progress modal")
        XCTAssertEqual(session.currentProgress.state, .processing, "Stale Task A must not overwrite B's progress state")
        XCTAssertEqual(session.currentProgress.bytesProcessed, 512, "Stale Task A must not overwrite B's progress bytes")
        XCTAssertEqual(session.currentProgress.currentFileName, "active-from-B.txt")
        XCTAssertFalse(session.isSummarySheetPresented, "Stale Task A must not present summary sheet during B")
        XCTAssertNil(session.completedSummary, "Stale Task A must not write completedSummary")
    }

    private func assertTerminalCompletionBelongsToB(session: CompressFormSession, tempDir: URL) {
        let expectedOutputB = tempDir.appendingPathComponent("ArchiveB.7z").path
        XCTAssertFalse(session.isProcessing)
        XCTAssertFalse(session.isProgressModalPresented)
        XCTAssertNil(session.activeSessionTaskId)
        XCTAssertTrue(session.isSummarySheetPresented)
        XCTAssertEqual(session.completedSummary?.archivePath, expectedOutputB)
        XCTAssertEqual(session.completedSummary?.compressedBytes, 256)
    }

    nonisolated private static func makeResult(outputPath: String, compressedBytes: Int64) -> ArchiveOperationResult {
        ArchiveOperationResult(
            outputPath: outputPath,
            originalBytes: 1024,
            compressedBytes: compressedBytes,
            durationSeconds: 0.1,
            throughputMBs: 20.0
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

@MainActor
private final class BoundaryReceiptRecorder {
    private(set) var receipts: [CompressFormSession.CompressionTaskBoundaryReceipt] = []
    private var waiters: [(UUID, (CompressFormSession.CompressionTaskBoundaryReceipt) -> Bool, XCTestExpectation)] = []

    init(session: CompressFormSession) {
        session.onBoundaryEventEvaluated = { [weak self] receipt in
            self?.record(receipt)
        }
    }

    func expectReceipt(
        description: String,
        matching predicate: @escaping (CompressFormSession.CompressionTaskBoundaryReceipt) -> Bool
    ) -> XCTestExpectation {
        let exp = XCTestExpectation(description: description)
        if receipts.contains(where: predicate) {
            exp.fulfill()
            return exp
        }
        waiters.append((UUID(), predicate, exp))
        return exp
    }

    /// Observes that `acceptCompressionTaskEvent` has finished evaluating a `.completed` or `.failed` event for `taskId`.
    func expectTerminalBoundaryReceipt(for taskId: UUID) -> XCTestExpectation {
        expectReceipt(description: "Terminal boundary receipt for \(taskId)") {
            $0.taskId == taskId && ($0.kind == .completed || $0.kind == .failed)
        }
    }

    func firstReceipt(
        matching predicate: (CompressFormSession.CompressionTaskBoundaryReceipt) -> Bool
    ) -> CompressFormSession.CompressionTaskBoundaryReceipt? {
        receipts.first(where: predicate)
    }

    private func record(_ receipt: CompressFormSession.CompressionTaskBoundaryReceipt) {
        receipts.append(receipt)
        var remaining: [(UUID, (CompressFormSession.CompressionTaskBoundaryReceipt) -> Bool, XCTestExpectation)] = []
        for entry in waiters {
            if entry.1(receipt) {
                entry.2.fulfill()
            } else {
                remaining.append(entry)
            }
        }
        waiters = remaining
    }
}

private final class CompressionStepGate: @unchecked Sendable {
    let entered: XCTestExpectation
    private let lock = NSLock()
    private var isOpen = false
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(description: String) {
        self.entered = XCTestExpectation(description: description)
    }

    func enterAndWait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let shouldFulfill = !hasEntered
            hasEntered = true
            if isOpen {
                lock.unlock()
                if shouldFulfill {
                    entered.fulfill()
                }
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
            if shouldFulfill {
                entered.fulfill()
            }
        }
    }

    func release() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}
