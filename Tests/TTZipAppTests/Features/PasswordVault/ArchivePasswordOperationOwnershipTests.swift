// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import TTZipUI
@testable import TTZipCore
@testable import TTZipApp

// MM41 Part B — page ownership of a password operation across foreground navigation.
//
// Contract (products/ttzip/docs/twin/archive/mm41b-password-operation-ownership.md):
//   * navigating away abandons a **browse** password operation and closes the prompt that
//     belonged to the abandoned page;
//   * a late browse result is discarded entirely — it is never written into the new page and
//     never written back into the old page in the background;
//   * the page identity is captured with the operation, and a result is accepted only while the
//     operation is still current **and** the captured session is still the active one;
//   * extraction operations (`quickExtract` / `extractEntries`) are authorized background work:
//     navigation must not cancel them, not even while they are in flight.
//
// Waiting discipline (every wait in this file is bounded):
//   * the controlled driver is held in flight by `ArchiveHostAsyncBarrier`; the test waits for
//     the "entered" event with an explicit budget (`waitUntilSuspended(timeout:)`), so a driver
//     that never enters is *observed* instead of awaited forever;
//   * the outcome of the submission is collected through `ArchiveHostCompletionReceipt`, whose
//     wait is bounded as well — this file never awaits `Task.value` directly, so a submission
//     that never completes cannot hang the test;
//   * the gate is released unconditionally, also when a wait expired, so a failing case never
//     leaves the controlled driver suspended behind the test;
//   * there is no wall-clock sleeping anywhere.
//
// Artifact discipline: the extraction cases drive the real host call chain, but the engine is
// replaced by the controlled driver double `MockArchivePasswordDriver`. The driver writes a
// *controlled* output file and the test asserts its content — that proves the host drove the
// engine contract with the right arguments and applied the result. It does **not** prove real
// archive extraction.
//
// Wiring requirement: this file MUST be compiled into the same `swift_test` target as
// `ArchivePasswordOperationTests.swift` and `ArchiveHostAcceptanceTestSupport.swift`
// (currently `AppCoreGateTests`), because it reuses the controlled
// driver double, the bounded barrier, the bounded receipt and the shared archive fixtures.

@MainActor
final class ArchivePasswordOperationOwnershipTests: ArchiveHostAcceptanceTestCase {

    // MARK: - Waiting budgets

    /// Budget for observing that the controlled driver entered its gated call.
    private let enteredBudget: Duration = .seconds(2)

    /// Budget for observing the outcome of a submission.
    private let completionBudget: Duration = .seconds(2)

    /// Short budget used by the failure-path self-checks.
    private let failureBudget: Duration = .milliseconds(300)

    // MARK: - Helpers

    /// Controlled driver whose browse probe is held in flight until the barrier is released.
    ///
    /// `suspendsProbe: false` builds a driver that never enters the gate — the failure-path
    /// self-check needs exactly that.
    private func makeBrowseDriver(
        barrier: ArchiveHostAsyncBarrier,
        suspendsProbe: Bool = true,
        probeFailure: Error? = nil
    ) -> MockArchivePasswordDriver {
        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            InspectResult(
                archivePath: path,
                format: "zip",
                entries: [
                    ArchiveEntry(
                        path: self.probeEntryPath,
                        uncompressedSize: 128,
                        isDirectory: false,
                        modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                        isEncrypted: true,
                        compressedSize: 128,
                        crc32: 0x1234_5678
                    )
                ],
                totalUncompressedBytes: 128,
                totalCompressedBytes: 128,
                unlockedPassword: nil
            )
        }
        driver.verifyPayloadHandler = { _, _, _ in
            if suspendsProbe {
                await barrier.suspendUntilReleased()
            }
            if let probeFailure { throw probeFailure }
            return Data("decrypted".utf8)
        }
        return driver
    }

    /// The archive path of the tab session with the given identity, if any.
    private func tabArchivePath(in state: AppViewState, tabID: UUID) -> String? {
        state.navigationState.tabSessions.first(where: { $0.id == tabID })?.archivePath
    }

    /// Starts a password submission whose outcome is collected by a bounded receipt.
    ///
    /// The task is never awaited directly: the receipt owns the outcome, so a submission that
    /// never completes cannot hang the test.
    private func startSubmission(
        state: AppViewState,
        receipt: ArchiveHostCompletionReceipt<ArchivePasswordSubmissionResult>,
        candidate: String
    ) {
        Task { @MainActor in
            await receipt.store(await state.submitArchivePassword(candidate))
        }
    }

    // MARK: - P1 — a late browse result must not reach the page the user navigated to

    func testLateBrowseResultAfterNavigationIsDiscardedAndNeverWrittenBack() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-browse")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        let driver = makeBrowseDriver(barrier: barrier)
        let state = AppViewState(fileViewer: MockFileViewerHarness(), passwordDriver: driver)
        let originSessionID = state.navigationState.activeSessionID

        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)

        let receipt = ArchiveHostCompletionReceipt<ArchivePasswordSubmissionResult>()
        startSubmission(state: state, receipt: receipt, candidate: correctPassword)
        let entered = await barrier.waitUntilSuspended(timeout: enteredBudget)
        XCTAssertTrue(entered, "The controlled driver must enter the gated probe")

        // The user leaves the page that raised the prompt.
        state.navigationState.openNewTab(url: try makeDestinationDirectory())
        let activeSessionIDAfterNavigation = state.navigationState.activeSessionID
        XCTAssertNotEqual(activeSessionIDAfterNavigation, originSessionID)

        await barrier.release()
        let outcome = await receipt.waitForValue(timeout: completionBudget)

        XCTAssertEqual(outcome, .cancelledOrStale, "An abandoned browse operation must not resume")
        XCTAssertNil(
            tabArchivePath(in: state, tabID: activeSessionIDAfterNavigation),
            "The newly active tab must not become the archive of the abandoned operation"
        )
        XCTAssertNil(
            tabArchivePath(in: state, tabID: originSessionID),
            "The abandoned operation must not be written back into the page it left"
        )
        XCTAssertNil(state.explorerState.currentArchivePath, "The window must not host the abandoned archive")
    }

    // MARK: - P2 — the prompt of the abandoned page is closed

    func testNavigationClosesTheBrowsePromptOfTheAbandonedPageOnly() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-prompt")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        let driver = makeBrowseDriver(barrier: barrier)
        let state = AppViewState(fileViewer: MockFileViewerHarness(), passwordDriver: driver)

        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)
        XCTAssertTrue(state.showPasswordPrompt, "The prompt must be presented before the navigation")

        state.navigationState.openNewTab(url: try makeDestinationDirectory())

        XCTAssertFalse(state.showPasswordPrompt, "The prompt of the abandoned page must be closed")
        XCTAssertNil(state.pendingPasswordContext, "The abandoned browse context must be cleared")
        XCTAssertNil(state.overlayState.pendingEncryptedPath, "The overlay must not point at the abandoned archive")
        XCTAssertNil(
            state.explorerState.currentArchivePath,
            "Closing the abandoned prompt must not rewrite the explorer state of the new page"
        )
    }

    // MARK: - P4 — positive control: without navigation the result commits to the captured session

    func testBrowseResultWithoutNavigationCommitsToTheCapturedSession() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-control")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        let driver = makeBrowseDriver(barrier: barrier)
        let state = AppViewState(fileViewer: MockFileViewerHarness(), passwordDriver: driver)
        let originSessionID = state.navigationState.activeSessionID

        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)

        // The positive control drives the same bounded flow as the navigation cases: the
        // submission starts, the entered event is awaited with a budget, the gate is released
        // and the outcome is collected through the bounded receipt.
        let receipt = ArchiveHostCompletionReceipt<ArchivePasswordSubmissionResult>()
        startSubmission(state: state, receipt: receipt, candidate: correctPassword)
        let entered = await barrier.waitUntilSuspended(timeout: enteredBudget)
        XCTAssertTrue(entered, "The controlled driver must enter the gated probe")
        await barrier.release()
        let outcome = await receipt.waitForValue(timeout: completionBudget)

        XCTAssertEqual(outcome, .verifiedAndResumed, "A browse operation without navigation must resume")
        XCTAssertEqual(
            tabArchivePath(in: state, tabID: originSessionID),
            archivePath,
            "The result must commit into the session that captured the prompt"
        )
        XCTAssertEqual(state.explorerState.currentArchivePath, archivePath)
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: archivePath), correctPassword)
    }

    // MARK: - P5 — ABA: returning to the originating tab must not revive the abandoned prompt

    func testReturningToTheOriginatingTabDoesNotReviveTheAbandonedPrompt() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-aba")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        let driver = makeBrowseDriver(barrier: barrier)
        let state = AppViewState(fileViewer: MockFileViewerHarness(), passwordDriver: driver)
        let originSessionID = state.navigationState.activeSessionID

        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)

        let receipt = ArchiveHostCompletionReceipt<ArchivePasswordSubmissionResult>()
        startSubmission(state: state, receipt: receipt, candidate: correctPassword)
        let entered = await barrier.waitUntilSuspended(timeout: enteredBudget)
        XCTAssertTrue(entered, "The controlled driver must enter the gated probe")

        state.navigationState.openNewTab(url: try makeDestinationDirectory())
        state.navigationState.switchToTab(id: originSessionID)
        XCTAssertEqual(state.navigationState.activeSessionID, originSessionID, "The test must end on the captured session")

        await barrier.release()
        let outcome = await receipt.waitForValue(timeout: completionBudget)

        XCTAssertEqual(outcome, .cancelledOrStale, "T1 -> T2 -> T1 must not revive the abandoned prompt")
        XCTAssertNil(tabArchivePath(in: state, tabID: originSessionID), "No archive may be committed after the round trip")
        XCTAssertNil(state.explorerState.currentArchivePath)
    }

    // MARK: - V1 — navigation while the browse verification is in flight

    func testNavigationDuringBrowseVerificationDiscardsTheLateSuccess() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-inflight-success")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        // Prepare throwing fixtures before the controlled operation can suspend.
        let navigationDestination = try makeDestinationDirectory()

        let barrier = ArchiveHostAsyncBarrier()
        let driver = makeBrowseDriver(barrier: barrier)
        let state = AppViewState(fileViewer: MockFileViewerHarness(), passwordDriver: driver)
        let originSessionID = state.navigationState.activeSessionID

        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)

        let receipt = ArchiveHostCompletionReceipt<ArchivePasswordSubmissionResult>()
        startSubmission(state: state, receipt: receipt, candidate: correctPassword)
        let entered = await barrier.waitUntilSuspended(timeout: enteredBudget)
        XCTAssertTrue(entered, "The controlled driver must enter the gated probe")

        state.navigationState.openNewTab(url: navigationDestination)
        await barrier.release()
        let outcome = await receipt.waitForValue(timeout: completionBudget)

        XCTAssertEqual(outcome, .cancelledOrStale, "The late success of an abandoned operation must be discarded")
        XCTAssertNil(tabArchivePath(in: state, tabID: state.navigationState.activeSessionID))
        XCTAssertNil(tabArchivePath(in: state, tabID: originSessionID))
        XCTAssertNil(state.explorerState.currentArchivePath)
    }

    // MARK: - V2 — navigation while the browse verification is in flight and the late result is an error

    func testNavigationDuringBrowseVerificationDiscardsTheLateErrorAndKeepsANewContext() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-inflight-error")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        // Prepare throwing fixtures before the controlled operation can suspend.
        let navigationDestination = try makeDestinationDirectory()
        let newArchivePath = try makeArchiveFixture(named: "ownership-inflight-error-new").path

        let barrier = ArchiveHostAsyncBarrier()
        let driver = makeBrowseDriver(
            barrier: barrier,
            probeFailure: ArchiveError.wrongPassword(archivePath: archivePath)
        )
        let state = AppViewState(fileViewer: MockFileViewerHarness(), passwordDriver: driver)

        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)

        let receipt = ArchiveHostCompletionReceipt<ArchivePasswordSubmissionResult>()
        startSubmission(state: state, receipt: receipt, candidate: correctPassword)
        let entered = await barrier.waitUntilSuspended(timeout: enteredBudget)
        XCTAssertTrue(entered, "The controlled driver must enter the gated probe")

        state.navigationState.openNewTab(url: navigationDestination)
        // A new context is staged while the old verification is still in flight.
        state.stagePasswordPromptContext(archivePath: newArchivePath, kind: .browse)
        let newOperationID = state.pendingPasswordContext?.operationID

        await barrier.release()
        let outcome = await receipt.waitForValue(timeout: completionBudget)

        XCTAssertEqual(outcome, .cancelledOrStale, "The late error of an abandoned operation must be discarded")
        XCTAssertEqual(
            state.pendingPasswordContext?.operationID,
            newOperationID,
            "The old asynchronous completion must never clear the new context"
        )
        XCTAssertEqual(state.pendingPasswordContext?.archivePath, newArchivePath)
    }

    // MARK: - X1 — an authorized quick extraction is not cancelled by navigation

    func testAuthorizedQuickExtractionInFlightSurvivesNavigation() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-quick-extract")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)
        let destination = try makeDestinationDirectory()
        let controlledOutputName = "controlled-quick-extract.txt"

        // Prepare throwing fixtures before the controlled operation can suspend.
        let navigationDestination = try makeDestinationDirectory()

        let barrier = ArchiveHostAsyncBarrier()
        let viewer = MockFileViewerHarness()
        let driver = MockArchivePasswordDriver()
        driver.quickExtractHandler = { path, destinationDir, password, _ in
            await barrier.suspendUntilReleased()
            // The controlled engine writes an inspectable output so the test can assert the
            // content the host asked for — not a real extraction.
            let outputDirectory = URL(fileURLWithPath: destinationDir)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try "controlled quick extract for \(path) with \(password ?? "-")"
                .write(to: outputDirectory.appendingPathComponent(controlledOutputName), atomically: true, encoding: .utf8)
            return ExtractResult(
                archivePath: path,
                destinationDir: destinationDir,
                durationSeconds: 0.01,
                unlockedPassword: password,
                isVaultUnlocked: false
            )
        }

        let state = AppViewState(fileViewer: viewer, passwordDriver: driver)
        state.stagePasswordPromptContext(
            archivePath: archivePath,
            kind: .quickExtract(
                targetDir: destination.path,
                isSmartExtract: false,
                trashSourceAfterExtract: false,
                collisionHandling: .policy(.keepBoth)
            )
        )

        let receipt = ArchiveHostCompletionReceipt<ArchivePasswordSubmissionResult>()
        startSubmission(state: state, receipt: receipt, candidate: correctPassword)
        let entered = await barrier.waitUntilSuspended(timeout: enteredBudget)
        XCTAssertTrue(entered, "The controlled engine must enter the gated quick extract")

        // The user navigates while the authorized extraction is in flight.
        state.navigationState.openNewTab(url: navigationDestination)
        await barrier.release()
        let outcome = await receipt.waitForValue(timeout: completionBudget)

        XCTAssertEqual(outcome, .verifiedAndResumed, "An authorized extraction must not be cancelled by navigation")

        // The host must have driven the engine contract with the captured arguments.
        let quickExtractCalls = driver.calls.filter { call in
            if case .quickExtract = call.kind { return true }
            return false
        }
        XCTAssertEqual(quickExtractCalls.count, 1, "The host must drive exactly one quick extract")
        let captured = quickExtractCalls.first.map { call -> (String, String, String?) in
            guard case .quickExtract(let path, let destDir, let password, _) = call.kind else {
                return ("", "", nil)
            }
            return (path, destDir, password)
        }
        XCTAssertEqual(captured?.0, archivePath, "The engine must receive the archive of the operation")
        XCTAssertEqual(captured?.1, destination.appendingPathComponent("ownership-quick-extract").path)
        XCTAssertEqual(captured?.2, correctPassword, "The engine must receive the submitted candidate")

        // The controlled output proves the result was applied to the requested destination.
        let expectedOutput = destination
            .appendingPathComponent("ownership-quick-extract")
            .appendingPathComponent(controlledOutputName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedOutput.path),
            "The controlled extraction output must exist"
        )
        let outputText = try String(contentsOf: expectedOutput, encoding: .utf8)
        XCTAssertTrue(
            outputText.contains(archivePath) && outputText.contains(correctPassword),
            "The controlled output must carry the arguments the host passed, got: \(outputText)"
        )
        XCTAssertTrue(
            state.taskState.statusMessage.contains("Extraction complete"),
            "The extraction result must still be applied, got: \(state.taskState.statusMessage)"
        )
        XCTAssertEqual(viewer.revealedPaths.count, 1, "The extraction must still reveal its output")
    }

    // MARK: - X2 — an authorized entry extraction is not cancelled by navigation

    func testAuthorizedEntryExtractionInFlightSurvivesNavigation() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-entry-extract")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)
        let destination = try makeDestinationDirectory()
        let controlledOutputName = "controlled-entry-extract.txt"

        // Prepare throwing fixtures before the controlled operation can suspend.
        let navigationDestination = try makeDestinationDirectory()

        let barrier = ArchiveHostAsyncBarrier()
        let viewer = MockFileViewerHarness()
        let driver = MockArchivePasswordDriver()
        driver.extractEntriesHandler = { (path: String, entryPaths: [String], destinationDir: String, password: String?) in
            await barrier.suspendUntilReleased()
            let outputDirectory = URL(fileURLWithPath: destinationDir)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try "controlled entry extract for \(entryPaths.joined(separator: ",")) with \(password ?? "-")"
                .write(to: outputDirectory.appendingPathComponent(controlledOutputName), atomically: true, encoding: .utf8)
            return ExtractionOutcome(
                status: .completed,
                extracted: UInt64(entryPaths.count),
                replaced: 0,
                keptBoth: 0,
                skipped: 0,
                failed: []
            )
        }

        let state = AppViewState(fileViewer: viewer, passwordDriver: driver)
        state.stagePasswordPromptContext(
            archivePath: archivePath,
            kind: .extractEntries(
                entryPaths: [probeEntryPath],
                destinationDir: destination.path,
                collisionHandling: .policy(.keepBoth)
            )
        )

        let receipt = ArchiveHostCompletionReceipt<ArchivePasswordSubmissionResult>()
        startSubmission(state: state, receipt: receipt, candidate: correctPassword)
        let entered = await barrier.waitUntilSuspended(timeout: enteredBudget)
        XCTAssertTrue(entered, "The controlled engine must enter the gated entry extraction")

        // The user navigates while the authorized extraction is in flight.
        state.navigationState.openNewTab(url: navigationDestination)
        await barrier.release()
        let outcome = await receipt.waitForValue(timeout: completionBudget)

        XCTAssertEqual(outcome, .verifiedAndResumed, "An authorized extraction must not be cancelled by navigation")

        let entryExtractCalls = driver.calls.filter { call in
            if case .extractEntries = call.kind { return true }
            return false
        }
        XCTAssertEqual(entryExtractCalls.count, 1, "The host must drive exactly one entry extraction")
        let captured = entryExtractCalls.first.map { call -> (String, [String], String, String?) in
            guard case .extractEntries(let path, let entryPaths, let destDir, let password) = call.kind else {
                return ("", [], "", nil)
            }
            return (path, entryPaths, destDir, password)
        }
        XCTAssertEqual(captured?.0, archivePath)
        XCTAssertEqual(captured?.1, [probeEntryPath])
        XCTAssertEqual(captured?.2, destination.path)
        XCTAssertEqual(captured?.3, correctPassword)

        let expectedOutput = destination.appendingPathComponent(controlledOutputName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedOutput.path),
            "The controlled extraction output must exist"
        )
        let outputText = try String(contentsOf: expectedOutput, encoding: .utf8)
        XCTAssertTrue(
            outputText.contains(probeEntryPath) && outputText.contains(correctPassword),
            "The controlled output must carry the arguments the host passed, got: \(outputText)"
        )
        XCTAssertTrue(
            state.taskState.statusMessage.contains("Extracted entry"),
            "The extraction result must still be applied, got: \(state.taskState.statusMessage)"
        )
        XCTAssertEqual(viewer.revealedPaths.count, 1, "The extraction must still reveal its output")
    }

    // MARK: - Failure-path self-checks — the bounded waits must fail within their budget

    /// Self-check: when the controlled driver never enters the gate, the bounded "entered" wait
    /// must report the missing event within its budget instead of waiting forever.
    func testBoundedEnteredWaitReportsTheMissingEventWithinItsBudget() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-no-enter")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        // The driver never suspends, so the "entered" event never arrives.
        let driver = makeBrowseDriver(barrier: barrier, suspendsProbe: false)
        let state = AppViewState(fileViewer: MockFileViewerHarness(), passwordDriver: driver)

        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)

        let receipt = ArchiveHostCompletionReceipt<ArchivePasswordSubmissionResult>()
        startSubmission(state: state, receipt: receipt, candidate: correctPassword)

        let entered = await barrier.waitUntilSuspended(timeout: failureBudget)
        XCTAssertFalse(entered, "The bounded wait must report that the entered event never arrived")

        // The gate is released unconditionally, also when the entered event never arrived.
        await barrier.release()
        let outcome = await receipt.waitForValue(timeout: completionBudget)
        XCTAssertEqual(
            outcome,
            .verifiedAndResumed,
            "Without a navigation the operation still completes — the missing entered event is a harness fact, not a product failure"
        )
    }

    /// Self-check: when the submission never completes, the bounded completion wait must report
    /// the missing outcome within its budget, and the cleanup must not wait for it again.
    func testBoundedCompletionWaitReportsTheMissingOutcomeWithinItsBudget() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-no-completion")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        let driver = makeBrowseDriver(barrier: barrier)
        let state = AppViewState(fileViewer: MockFileViewerHarness(), passwordDriver: driver)

        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)

        let receipt = ArchiveHostCompletionReceipt<ArchivePasswordSubmissionResult>()
        startSubmission(state: state, receipt: receipt, candidate: correctPassword)
        let entered = await barrier.waitUntilSuspended(timeout: enteredBudget)
        XCTAssertTrue(entered, "The controlled driver must enter the gated probe")

        // The gate is deliberately not released before the completion wait: the outcome cannot
        // arrive within the budget.
        let outcome = await receipt.waitForValue(timeout: failureBudget)
        XCTAssertNil(outcome, "The bounded wait must report that the outcome never arrived")
        let recordedOutcome = await receipt.recorded()
        XCTAssertNil(recordedOutcome, "No outcome may be recorded while the gate is closed")

        // The missing outcome above was observed while the gate was closed. Cleanup must not
        // turn that observation into success, but must finish before shared test state resets.
        await barrier.release()
        let cleanupOutcome = await receipt.waitForValue(timeout: completionBudget)
        XCTAssertEqual(cleanupOutcome, .verifiedAndResumed, "The released controlled operation must finish within the cleanup budget")
    }
}
