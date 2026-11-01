// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import TTZipAppCommon
@testable import TTZipApp
@testable import TTZipAppModels
@testable import TTZipAppServices
@testable import TTZipAppViewModels
@testable import TTZipAppViews
import TTZipCore
import TTZipUI

private final class ScannerCancellationReceiptBox: @unchecked Sendable {
    private let enteredSemaphore = DispatchSemaphore(value: 0)
    private let entryReleaseGate = DispatchSemaphore(value: 0)
    private let terminatedSemaphore = DispatchSemaphore(value: 0)
    private let taskCompletedSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didSignalEntered = false
    private var didReleaseGate = false
    private var terminationReceipt: (wasCancelled: Bool, visitedCount: Int)?

    func markEnteredAndWaitReleaseGate(timeoutSeconds: Double) {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !didSignalEntered else { return false }
            didSignalEntered = true
            return true
        }
        if shouldSignal {
            enteredSemaphore.signal()
            _ = entryReleaseGate.wait(timeout: .now() + timeoutSeconds)
        }
    }

    func releaseEntryGate() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !didReleaseGate else { return false }
            didReleaseGate = true
            return true
        }
        if shouldSignal {
            entryReleaseGate.signal()
        }
    }

    func recordTermination(wasCancelled: Bool, visitedCount: Int) {
        lock.withLock {
            terminationReceipt = (wasCancelled, visitedCount)
        }
        terminatedSemaphore.signal()
    }

    func recordTaskCompleted() {
        taskCompletedSemaphore.signal()
    }

    func waitEntered(timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.enteredSemaphore.wait(timeout: .now() + timeoutSeconds) == .success)
            }
        }
    }

    func waitTerminated(timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.terminatedSemaphore.wait(timeout: .now() + timeoutSeconds) == .success)
            }
        }
    }

    func waitTaskCompleted(timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.taskCompletedSemaphore.wait(timeout: .now() + timeoutSeconds) == .success)
            }
        }
    }

    func currentReceipt() -> (wasCancelled: Bool, visitedCount: Int)? {
        lock.withLock { terminationReceipt }
    }
}

final class UnifiedExplorerSearchReviewTests: XCTestCase {

    func testScannerCancellationPropagatesToDetachedPOSIXWorkerAndStopsEarly() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("ttzip-s1-cancel-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        for idx in 0..<250 {
            let fileURL = tempRoot.appendingPathComponent(String(format: "entry_%04d.txt", idx))
            try Data("item".utf8).write(to: fileURL)
        }

        let receiptBox = ScannerCancellationReceiptBox()

        let scanner = DefaultDirectoryRecursiveScanner(
            entryVisitHook: { _, visitedCount in
                if visitedCount >= 5 {
                    receiptBox.markEnteredAndWaitReleaseGate(timeoutSeconds: 2.0)
                    try Task.checkCancellation()
                }
            },
            scanTerminationHook: { wasCancelled, visitedCount in
                receiptBox.recordTermination(wasCancelled: wasCancelled, visitedCount: visitedCount)
            }
        )

        let scanTask = Task {
            defer { receiptBox.recordTaskCompleted() }
            return try await scanner.searchDirectoryRecursively(
                rootURL: tempRoot,
                query: "entry",
                maxResults: 60,
                maxVisitedEntries: 8_000,
                maxDepth: 12
            )
        }
        defer {
            receiptBox.releaseEntryGate()
            scanTask.cancel()
        }

        let didEnter = await receiptBox.waitEntered(timeoutSeconds: 2.0)
        guard didEnter else {
            receiptBox.releaseEntryGate()
            scanTask.cancel()
            XCTFail("Scanner failed to enter POSIX directory loop within bounded timeout")
            return
        }

        scanTask.cancel()
        receiptBox.releaseEntryGate()

        let didTerminate = await receiptBox.waitTerminated(timeoutSeconds: 2.0)
        let didCompleteTask = await receiptBox.waitTaskCompleted(timeoutSeconds: 2.0)
        guard didTerminate, didCompleteTask else {
            XCTFail("Detached scanner worker did not terminate within bounded timeout (didTerminate=\(didTerminate), didCompleteTask=\(didCompleteTask))")
            return
        }

        do {
            _ = try await scanTask.value
            XCTFail("Expected CancellationError from cancelled recursive scan")
        } catch is CancellationError {
            // Expected
        }

        let unwrappedReceipt = try XCTUnwrap(receiptBox.currentReceipt())
        XCTAssertTrue(unwrappedReceipt.wasCancelled, "Detached worker must observe Task cancellation")
        XCTAssertLessThan(unwrappedReceipt.visitedCount, 50, "Scanner must stop early instead of scanning all 250 entries")
    }

    @MainActor
    func testTruncatedScanBudgetAndDepthReportPartialCoverageInsteadOfExhaustiveZeroMatch() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("ttzip-s1-trunc-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // 1. Depth truncation: place the ONLY match at depth 3 while maxDepth == 1
        let deepDir = tempRoot
            .appendingPathComponent("level1", isDirectory: true)
            .appendingPathComponent("level2", isDirectory: true)
            .appendingPathComponent("level3", isDirectory: true)
        try fm.createDirectory(at: deepDir, withIntermediateDirectories: true)
        let deepTarget = deepDir.appendingPathComponent("hidden_beyond_depth_needle.txt")
        try Data("needle".utf8).write(to: deepTarget)

        let scanner = DefaultDirectoryRecursiveScanner()
        let depthOutcome = try await scanner.searchDirectoryRecursively(
            rootURL: tempRoot,
            query: "hidden_beyond_depth_needle",
            maxResults: 60,
            maxVisitedEntries: 8_000,
            maxDepth: 1
        )
        XCTAssertTrue(depthOutcome.items.isEmpty)
        XCTAssertTrue(depthOutcome.isTruncated)
        XCTAssertTrue(depthOutcome.truncationReasons.contains(.maxDepthReached))

        // 2. Entry budget truncation: create 10 nested subdirs each with 5 files (total > 50 entries)
        // and place the ONLY matching file inside a deeper directory beyond the 8-entry visit budget.
        for i in 0..<10 {
            let subDir = tempRoot.appendingPathComponent(String(format: "branch_%02d", i), isDirectory: true)
            try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
            for j in 0..<5 {
                let filler = subDir.appendingPathComponent(String(format: "filler_%02d_%02d.txt", i, j))
                try Data("filler".utf8).write(to: filler)
            }
        }
        let beyondBudgetDir = tempRoot
            .appendingPathComponent("branch_09", isDirectory: true)
            .appendingPathComponent("deep_tail", isDirectory: true)
        try fm.createDirectory(at: beyondBudgetDir, withIntermediateDirectories: true)
        let lateTarget = beyondBudgetDir.appendingPathComponent("zzz_beyond_budget_needle.txt")
        try Data("needle".utf8).write(to: lateTarget)

        let budgetOutcome = try await scanner.searchDirectoryRecursively(
            rootURL: tempRoot,
            query: "zzz_beyond_budget_needle",
            maxResults: 60,
            maxVisitedEntries: 8,
            maxDepth: 12
        )
        XCTAssertTrue(budgetOutcome.items.isEmpty)
        XCTAssertTrue(budgetOutcome.isTruncated)
        XCTAssertTrue(budgetOutcome.truncationReasons.contains(.maxVisitedEntriesReached))
        XCTAssertEqual(budgetOutcome.visitedEntryCount, 8)

        // 3. Verify Coordinator & UI placeholder surface partial-scope warning instead of exhaustive "No matches found"
        let controlledScanner = ControlledRecursiveScanner()
        await controlledScanner.setOutcome(budgetOutcome, forRoot: tempRoot.path)
        let coordinator = UnifiedExplorerSearchCoordinator(
            windowID: UUID(),
            semanticEngine: ControlledSemanticEngine(),
            directoryScanner: controlledScanner,
            systemSearchProvider: ControlledSystemSearchProvider(),
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )
        coordinator.updateSearch(query: "zzz_beyond_budget_needle", scope: .physicalDirectory(tempRoot))
        await coordinator.waitForActiveSearch()

        XCTAssertEqual(coordinator.currentDirectoryGroup.phase, .empty)
        XCTAssertTrue(coordinator.currentDirectoryGroup.coverage.isTruncated)
        XCTAssertTrue(
            coordinator.currentDirectoryGroup.coverage.truncationReasons.contains(.maxVisitedEntriesReached)
        )
        let footnote = UnifiedExplorerSearchResultsView.coverageFootnote(
            for: coordinator.currentDirectoryGroup.coverage
        )
        XCTAssertTrue(
            footnote.contains("当前仅搜索部分范围") || footnote.contains("Only partial scope searched"),
            "Unexpected footnote: \(footnote)"
        )
        let placeholder = SearchNoMatchesPlaceholderView(
            query: "zzz_beyond_budget_needle",
            scopeDisplayPath: coordinator.currentDirectoryGroup.title,
            isTruncatedScope: coordinator.currentDirectoryGroup.coverage.isTruncated,
            visitedEntryCount: coordinator.currentDirectoryGroup.coverage.visitedEntryCount
        )
        XCTAssertTrue(
            placeholder.subtitleText.contains("当前仅搜索部分范围")
                || placeholder.subtitleText.contains("Only a partial scope was searched"),
            "Unexpected subtitle: \(placeholder.subtitleText)"
        )
    }

    @MainActor
    func testOffscreenHostedDiskDirectoryBrowserViewEndToEndSearchAndReveal() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("ttzip-s1-hosted-\(UUID().uuidString)", isDirectory: true)
        let subA = tempRoot.appendingPathComponent("folderA", isDirectory: true)
        let subB = subA.appendingPathComponent("folderB", isDirectory: true)
        try fm.createDirectory(at: subB, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let targetFile = subB.appendingPathComponent("hosted_target_doc.txt")
        try Data("hosted content".utf8).write(to: targetFile)

        let vm = AppViewState()
        vm.navigationState.currentDirectory = tempRoot

        let systemProvider = ControlledSystemSearchProvider()
        await systemProvider.setResults(
            [
                GlobalSearchResultItem(
                    id: "spotlight:hosted:external",
                    title: "hosted_target_external.md",
                    subtitle: "/Users/shared",
                    hitType: .archiveEntry,
                    diskPath: "/Users/shared/hosted_target_external.md",
                    isDirectory: false,
                    byteSize: 256,
                    score: 0.70
                )
            ],
            forQuery: "hosted_target"
        )

        let coordinator = UnifiedExplorerSearchCoordinator(
            windowID: vm.windowID,
            semanticEngine: ControlledSemanticEngine(),
            directoryScanner: DefaultDirectoryRecursiveScanner(),
            systemSearchProvider: systemProvider,
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )

        var observedColumns: [URL] = []
        var observedSelectedPaths: [Int: String] = [:]
        var observedSelectedItem: DiskItemInfo?

        var browserView = DiskDirectoryBrowserView(
            viewModel: vm,
            rootDirectory: tempRoot,
            isActive: true
        )
        browserView.injectedSearchCoordinator = coordinator
        browserView.onMillerColumnStateChanged = { cols, sel, item in
            observedColumns = cols
            observedSelectedPaths = sel
            observedSelectedItem = item
        }

        let hostingView = NSHostingView(rootView: browserView.environment(vm))
        hostingView.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
        hostingView.layoutSubtreeIfNeeded()

        let didLoadInitialRoot = await waitForHostedCondition(hostingView: hostingView, timeoutSeconds: 2.0) {
            observedColumns.map(\.standardizedFileURL.path) == [tempRoot.standardizedFileURL.path]
        }
        XCTAssertTrue(didLoadInitialRoot, "Initial root column must be observed in hosted FinderMillerColumnsView")

        // 1. State transition for a no-match query in hosted view
        vm.explorerState.searchQuery = "hosted_nonexistent_zzz"
        let didObserveNoMatchQuery = await waitForHostedCondition(hostingView: hostingView, timeoutSeconds: 2.0) {
            coordinator.activeQuery == "hosted_nonexistent_zzz"
        }
        XCTAssertTrue(didObserveNoMatchQuery)
        await coordinator.waitForActiveSearch()
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(coordinator.currentDirectoryGroup.phase, .empty)
        XCTAssertEqual(coordinator.fullDiskGroup.phase, .empty)
        XCTAssertFalse(coordinator.currentDirectoryGroup.allowsCreationInEmptyState)
        XCTAssertFalse(coordinator.fullDiskGroup.allowsCreationInEmptyState)

        // 2. State transition for a dual-group matching query in hosted view
        vm.explorerState.searchQuery = "hosted_target"
        let didObserveTargetQuery = await waitForHostedCondition(hostingView: hostingView, timeoutSeconds: 2.0) {
            coordinator.activeQuery == "hosted_target"
        }
        XCTAssertTrue(didObserveTargetQuery)
        await coordinator.waitForActiveSearch()
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(coordinator.currentDirectoryGroup.phase, .completed)
        XCTAssertEqual(coordinator.currentDirectoryGroup.items.map(\.title), ["hosted_target_doc.txt"])
        XCTAssertEqual(coordinator.fullDiskGroup.phase, .completed)
        XCTAssertEqual(coordinator.fullDiskGroup.items.map(\.title), ["hosted_target_external.md"])

        // 3. Activate current-directory descendant hit -> clears searchQuery and posts reveal notification to Miller columns
        let hit = try XCTUnwrap(coordinator.currentDirectoryGroup.items.first)
        coordinator.activateResult(hit, in: vm)
        let didRevealInMillerColumns = await waitForHostedCondition(hostingView: hostingView, timeoutSeconds: 2.0) {
            vm.explorerState.searchQuery.isEmpty
                && observedColumns.count == 3
                && observedSelectedItem?.path == targetFile.standardizedFileURL.path
        }
        XCTAssertTrue(didRevealInMillerColumns, "Miller columns must expand and select revealed descendant item")

        XCTAssertEqual(observedColumns.map { $0.standardizedFileURL.path }, [
            tempRoot.standardizedFileURL.path,
            subA.standardizedFileURL.path,
            subB.standardizedFileURL.path
        ])
        XCTAssertEqual(observedSelectedPaths[0], subA.standardizedFileURL.path)
        XCTAssertEqual(observedSelectedPaths[1], subB.standardizedFileURL.path)
        XCTAssertEqual(observedSelectedPaths[2], targetFile.standardizedFileURL.path)
        XCTAssertEqual(observedSelectedItem?.path, targetFile.standardizedFileURL.path)
    }

    @MainActor
    private func pumpMainRunLoopSlice(hostingView: NSHostingView<some View>) {
        hostingView.layoutSubtreeIfNeeded()
        _ = CFRunLoopRunInMode(.defaultMode, 0.002, true)
        hostingView.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func waitForHostedCondition(
        hostingView: NSHostingView<some View>,
        timeoutSeconds: Double,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            pumpMainRunLoopSlice(hostingView: hostingView)
            if condition() {
                return true
            }
            await Task.yield()
        }
        pumpMainRunLoopSlice(hostingView: hostingView)
        return condition()
    }
}
