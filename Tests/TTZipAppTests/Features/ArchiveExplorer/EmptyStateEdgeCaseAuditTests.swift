// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import SwiftUI
import Observation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

@MainActor
final class EmptyStateEdgeCaseAuditTests: XCTestCase {
    
    // MARK: - EmptyFolderPlaceholderView Invariants
    
    func testEmptyFolderPlaceholderViewInstantiation() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_empty_dir_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        var folderTriggeredURL: URL? = nil
        var fileTriggeredURL: URL? = nil
        
        let placeholder = EmptyFolderPlaceholderView(
            dirURL: tempURL,
            onTriggerNewFolder: { url in folderTriggeredURL = url },
            onTriggerNewFile: { url in fileTriggeredURL = url }
        )
        
        XCTAssertEqual(placeholder.dirURL, tempURL)
        
        placeholder.onTriggerNewFolder(tempURL)
        XCTAssertEqual(folderTriggeredURL, tempURL)
        
        placeholder.onTriggerNewFile(tempURL)
        XCTAssertEqual(fileTriggeredURL, tempURL)
        
        let createdFolder = tempURL.appendingPathComponent("NewSubfolder")
        try FileManager.default.createDirectory(at: createdFolder, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdFolder.path))
        
        let createdFile = tempURL.appendingPathComponent("NewFile.txt")
        try Data("TTZip".utf8).write(to: createdFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdFile.path))
    }
    
    // MARK: - SingleMillerColumnView Empty State Invariants
    
    func testSingleMillerColumnViewEmptyDirectoryRendering() {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_miller_\(UUID().uuidString)")
        
        var refreshed = false
        var selectedAll = false
        var updatedWidth: CGFloat = 0
        
        let emptyColumn = SingleMillerColumnView(
            index: 0,
            dirURL: tempURL,
            selectedPath: nil,
            currentSort: .nameAsc,
            items: [],
            currentWidth: 260,
            canGoParent: false,
            isColumnActive: true,
            multiSelectedPaths: [],
            onPrependParent: {},
            onChangeSort: { _ in },
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onSelectItem: { _, _, _, _, _ in },
            onTriggerNewFolder: { _ in },
            onTriggerNewFile: { _ in },
            onRefresh: { refreshed = true },
            onSelectAll: { selectedAll = true },
            onWidthChanged: { w in updatedWidth = w }
        )
        
        XCTAssertEqual(emptyColumn.index, 0)
        XCTAssertEqual(emptyColumn.dirURL, tempURL)
        XCTAssertEqual(emptyColumn.items?.count, 0)
        XCTAssertEqual(emptyColumn.currentWidth, 260)
        XCTAssertEqual(emptyColumn.currentSort, .nameAsc)
        XCTAssertFalse(emptyColumn.canGoParent)
        XCTAssertTrue(emptyColumn.isColumnActive)
        XCTAssertTrue(emptyColumn.multiSelectedPaths.isEmpty)
        XCTAssertNil(emptyColumn.selectedPath)
        
        emptyColumn.onRefresh()
        XCTAssertTrue(refreshed)
        emptyColumn.onSelectAll()
        XCTAssertTrue(selectedAll)
        emptyColumn.onWidthChanged(300)
        XCTAssertEqual(updatedWidth, 300)
        
        let loadingColumn = SingleMillerColumnView(
            index: 1,
            dirURL: tempURL,
            selectedPath: "some/path",
            currentSort: .dateDesc,
            items: nil,
            currentWidth: 280,
            canGoParent: true,
            isColumnActive: false,
            multiSelectedPaths: ["selected/a"],
            onPrependParent: {},
            onChangeSort: { _ in },
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onSelectItem: { _, _, _, _, _ in },
            onTriggerNewFolder: { _ in },
            onTriggerNewFile: { _ in },
            onRefresh: {},
            onSelectAll: {},
            onWidthChanged: { _ in }
        )
        
        XCTAssertNil(loadingColumn.items)
        XCTAssertEqual(loadingColumn.index, 1)
        XCTAssertEqual(loadingColumn.dirURL, tempURL)
        XCTAssertEqual(loadingColumn.currentSort, .dateDesc)
        XCTAssertEqual(loadingColumn.selectedPath, "some/path")
        XCTAssertEqual(loadingColumn.currentWidth, 280)
        XCTAssertTrue(loadingColumn.canGoParent)
        XCTAssertFalse(loadingColumn.isColumnActive)
        XCTAssertEqual(loadingColumn.multiSelectedPaths, ["selected/a"])
    }
    
    // MARK: - ExplorerItemInspectorView Nil and Empty Selection Invariants
    
    func testInspectorColumnViewNilItemZenPlaceholder() {
        let nilInspector = ExplorerItemInspectorView(
            item: nil,
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onPreviewFile: { _ in }
        )
        
        XCTAssertNil(nilInspector.item)
        XCTAssertFalse(nilInspector.isVirtualItem)
        XCTAssertNil(nilInspector.effectivePreviewURL)
        XCTAssertNil(nilInspector.effectiveModificationDate)
    }
    
    func testInspectorColumnViewWithEmptyFolder() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_empty_folder_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let itemInfo = DiskItemInfo(url: tempDir)
        XCTAssertTrue(itemInfo.isDirectory)
        
        let folderInspector = ExplorerItemInspectorView(
            item: itemInfo,
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onPreviewFile: { _ in }
        )
        
        XCTAssertNotNil(folderInspector.item)
        XCTAssertEqual(folderInspector.item?.path, tempDir.path)
        XCTAssertTrue(folderInspector.item?.isDirectory == true)
        XCTAssertFalse(folderInspector.isVirtualItem)
        XCTAssertEqual(folderInspector.effectivePreviewURL?.path, tempDir.resolvingSymlinksInPath().path)
        XCTAssertNotNil(folderInspector.effectiveModificationDate)
    }
    
    func testInspectorColumnViewWithRegularFile() throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_file_\(UUID().uuidString).txt")
        try Data("Hello TTZip".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let itemInfo = DiskItemInfo(url: tempFile)
        XCTAssertFalse(itemInfo.isDirectory)
        
        let fileInspector = ExplorerItemInspectorView(
            item: itemInfo,
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onPreviewFile: { _ in }
        )
        
        XCTAssertNotNil(fileInspector.item)
        XCTAssertEqual(fileInspector.item?.path, tempFile.path)
        XCTAssertFalse(fileInspector.item?.isDirectory == true)
        XCTAssertFalse(fileInspector.isVirtualItem)
        XCTAssertEqual(fileInspector.effectivePreviewURL?.path, tempFile.resolvingSymlinksInPath().path)
        XCTAssertNotNil(fileInspector.effectiveModificationDate)
    }
    
    // MARK: - FolderMediaArtboardView Empty and Populated Folder Statistics
    
    func testFolderMediaArtboardViewEmptyDirectoryCalculation() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_artboard_empty_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let itemInfo = DiskItemInfo(url: tempDir)
        let artboard = FolderMediaArtboardView(item: itemInfo, onCompressPath: { _ in })
        
        XCTAssertEqual(artboard.item.path, tempDir.path)
        XCTAssertTrue(artboard.item.isDirectory)
        XCTAssertNotNil(artboard.item.modificationDate)
        
        let (emptySize, emptySubfolders, emptyFiles, emptyDist) = await FolderMediaArtboardView.calculateFolderStats(at: tempDir.path)
        
        XCTAssertEqual(emptyFiles, 0)
        XCTAssertEqual(emptySubfolders, 0)
        XCTAssertEqual(emptySize, 0)
        XCTAssertTrue(emptyDist.isEmpty)
        
        let subDir = tempDir.appendingPathComponent("nested_sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let sampleFile = tempDir.appendingPathComponent("data.bin")
        try Data(repeating: 0x42, count: 512).write(to: sampleFile)
        
        let (populatedSize, populatedSubfolders, populatedFiles, populatedDist) = await FolderMediaArtboardView.calculateFolderStats(at: tempDir.path)
        
        XCTAssertEqual(populatedSubfolders, 1, "Must detect exactly 1 nested directory")
        XCTAssertEqual(populatedFiles, 1, "Must detect exactly 1 file")
        XCTAssertGreaterThanOrEqual(populatedSize, 512, "Total size must account for file contents")
        XCTAssertTrue(populatedDist.contains { $0.category == "bin" && $0.count == 1 }, "Distribution must contain bin category")
    }

    func testFolderDistributionUsesTheSameFilesForCountAndLogicalSize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("distribution_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<3 {
            try Data(repeating: 1, count: 1).write(to: directory.appendingPathComponent("small\(index).txt"))
        }
        try Data(repeating: 2, count: 10).write(to: directory.appendingPathComponent("large.bin"))
        try Data().write(to: directory.appendingPathComponent("zero.empty"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.alias"),
            withDestinationURL: directory
        )

        let result = await FolderMediaArtboardView.calculateFolderStats(at: directory.path)
        XCTAssertEqual(result.fileCount, 6)
        XCTAssertEqual(result.totalSize, 13)
        let entries = result.distribution.map {
            FolderDistributionEntry(category: $0.category, count: $0.count, sizeBytes: $0.sizeBytes)
        }
        XCTAssertEqual(entries.reduce(0) { $0 + $1.count }, result.fileCount)
        XCTAssertEqual(entries.compactMap(\.sizeBytes).reduce(0, +), result.totalSize)
        XCTAssertNil(entries.first(where: { $0.category == "alias" })?.sizeBytes)
        XCTAssertEqual(FolderDistributionMetric.count.sorted(entries).map(\.category), ["txt", "alias", "bin", "empty"])
        XCTAssertEqual(FolderDistributionMetric.size.sorted(entries).map(\.category), ["bin", "txt", "empty", "alias"])
        XCTAssertEqual(FolderDistributionMetric.count.total(entries), 6)
        XCTAssertEqual(FolderDistributionMetric.size.total(entries), 13)
        if let bin = entries.first(where: { $0.category == "bin" }) {
            XCTAssertEqual(FolderDistributionMetric.count.share(of: bin, total: 6) ?? -1, 1.0 / 6.0, accuracy: 1e-12)
            XCTAssertEqual(FolderDistributionMetric.size.share(of: bin, total: 13) ?? -1, 10.0 / 13.0, accuracy: 1e-12)
        } else {
            XCTFail("Missing bin category")
        }

        let uncertain = entries + [FolderDistributionEntry(category: "unknown", count: 1)]
        XCTAssertEqual(FolderDistributionMetric.size.sorted(uncertain).suffix(2).map(\.category), ["alias", "unknown"])
        XCTAssertEqual(FolderDistributionMetric.count.sorted(uncertain).map(\.category), ["txt", "alias", "bin", "empty", "unknown"])
        XCTAssertNil(FolderDistributionMetric.size.share(of: FolderDistributionEntry(category: "unknown", count: 1), total: 13))
    }

    // MARK: - U04 Coordinator Lifecycle, Concurrency, and Path Identity Invariants

    func testSuspendedScanOnFolderADoesNotOverwriteSwitchedFolderBAndDeduplicatesClicks() async throws {
        let fm = FileManager.default
        let rootTemp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u04_race_\(UUID().uuidString)")
        let dirA = rootTemp.appendingPathComponent("FolderA")
        let dirB = rootTemp.appendingPathComponent("FolderB")
        try fm.createDirectory(at: dirA, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: rootTemp) }

        let barrier = DeterministicScanBarrier()
        let coordinator = FolderSummaryAnalysisCoordinator(
            item: DiskItemInfo(url: dirA),
            scanner: { _, _ in
                await barrier.enterAndWaitForRelease()
                return FolderAnalysisSnapshot(
                    totalSizeBytes: 888_888,
                    subfolderCount: 9,
                    fileCount: 42,
                    distribution: [FolderDistributionEntry(category: "swift", count: 42)]
                )
            }
        )

        coordinator.startAnalysis()
        let entered = await barrier.waitUntilEntered()

        // Duplicate clicks while analyzing must be ignored without spawning concurrent scans.
        coordinator.startAnalysis()
        coordinator.startAnalysis()
        let scanCountDuringFlight = coordinator.scanCallCount
        let duplicateCount = coordinator.ignoredDuplicateRequestCount

        // Switch to Folder B while Folder A is suspended at the barrier.
        coordinator.selectItem(DiskItemInfo(url: dirB))
        let cancelSignalsAfterSwitch = coordinator.cancelSignalCount
        let phaseAfterSwitch = coordinator.phase

        // Unconditionally release barrier and drain before asserting.
        await barrier.release()
        let drained = await waitForActiveScansToDrain(on: coordinator)

        XCTAssertTrue(entered)
        XCTAssertEqual(scanCountDuringFlight, 1)
        XCTAssertEqual(duplicateCount, 2)
        XCTAssertEqual(cancelSignalsAfterSwitch, 1)
        XCTAssertEqual(phaseAfterSwitch, .idleSummary)
        XCTAssertTrue(drained)
        XCTAssertEqual(coordinator.currentItem.path, dirB.path)
        XCTAssertEqual(coordinator.phase, .idleSummary)
        XCTAssertNil(coordinator.analyzedSnapshot)
        XCTAssertEqual(coordinator.rejectedStaleCommitCount, 1)
        XCTAssertEqual(coordinator.activeScanCount, 0)
        XCTAssertEqual(coordinator.completedScanReleaseCount, 1)
    }

    func testTrailingSpaceDirectoryIdentityPreservesExactPathAndRejectsNonLocalTargets() async throws {
        let fm = FileManager.default
        let rootTemp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u04_space_\(UUID().uuidString)")
        let dirNoSpace = rootTemp.appendingPathComponent("FolderA", isDirectory: true)
        let dirWithTrailingSpace = rootTemp.appendingPathComponent("FolderA ", isDirectory: true)
        try fm.createDirectory(
            at: dirNoSpace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try fm.createDirectory(
            at: dirWithTrailingSpace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: rootTemp) }

        try Data(repeating: 0x31, count: 128).write(to: dirNoSpace.appendingPathComponent("one.txt"))
        try Data(repeating: 0x32, count: 256).write(to: dirWithTrailingSpace.appendingPathComponent("twoA.txt"))
        try Data(repeating: 0x33, count: 256).write(to: dirWithTrailingSpace.appendingPathComponent("twoB.txt"))

        let observedPaths = LockedPathRecorder()
        let recordingScanner: FolderSummaryAnalysisCoordinator.DirectoryStatsScanner = { identity, box in
            if let path = identity.localDirectoryURL?.path {
                observedPaths.append(path)
            }
            return try await FolderSummaryAnalysisCoordinator.defaultScanner(identity, box)
        }

        let itemNoSpace = DiskItemInfo(url: dirNoSpace, isDirectory: true, name: "FolderA")
        let itemTrailingSpace = DiskItemInfo(url: dirWithTrailingSpace, isDirectory: true, name: "FolderA ")
        XCTAssertTrue(itemTrailingSpace.path.hasSuffix("FolderA "))

        let coordNoSpace = FolderSummaryAnalysisCoordinator(item: itemNoSpace, scanner: recordingScanner)
        let coordTrailingSpace = FolderSummaryAnalysisCoordinator(item: itemTrailingSpace, scanner: recordingScanner)

        XCTAssertEqual(coordNoSpace.targetIdentity.localDirectoryURL?.path, dirNoSpace.path)
        XCTAssertEqual(coordTrailingSpace.targetIdentity.localDirectoryURL?.path, dirWithTrailingSpace.path)
        XCTAssertEqual(coordNoSpace.lightweightMetadata.posixPermissions, "0755")
        XCTAssertEqual(coordTrailingSpace.lightweightMetadata.posixPermissions, "0700")

        await coordNoSpace.requestAnalysis()
        await coordTrailingSpace.requestAnalysis()

        XCTAssertEqual(coordNoSpace.fileCount, 1)
        XCTAssertEqual(coordNoSpace.totalSizeBytes, 128)
        XCTAssertEqual(coordTrailingSpace.fileCount, 2)
        XCTAssertEqual(coordTrailingSpace.totalSizeBytes, 512)
        XCTAssertEqual(observedPaths.values, [dirNoSpace.path, dirWithTrailingSpace.path])

        try await assertNonLocalAndMissingDirectoryControls(
            scanner: recordingScanner,
            priorCount: 2,
            recorder: observedPaths
        )
    }

    private func assertNonLocalAndMissingDirectoryControls(
        scanner: @escaping FolderSummaryAnalysisCoordinator.DirectoryStatsScanner,
        priorCount: Int,
        recorder: LockedPathRecorder
    ) async throws {
        let rejectedPaths = [
            "   \n\t  ",
            "file://fileserver.local/shared/Photos",
            "mtp://device-01/DCIM/Camera",
            "ttzip://session-1/inner/folder",
            "file:///Users/tester/Archive.zip?subpath=docs/sub",
            "/Users/tester/Archive.zip?subpath=docs/sub"
        ]
        for rawPath in rejectedPaths {
            let item = DiskItemInfo(
                path: rawPath,
                name: "VirtualOrRemote",
                displayName: "VirtualOrRemote",
                isDirectory: true,
                isArchive: false,
                sizeText: "--",
                rawSizeBytes: 0,
                modificationDate: nil,
                kindText: "Folder"
            )
            let coordinator = FolderSummaryAnalysisCoordinator(item: item, scanner: scanner)
            XCTAssertFalse(coordinator.canAnalyzeSelectedTarget, "Must reject \(rawPath)")
            await coordinator.requestAnalysis()
            XCTAssertEqual(coordinator.scanCallCount, 0)
            XCTAssertEqual(coordinator.rejectedNonLocalRequestCount, 1)
        }
        XCTAssertEqual(recorder.values.count, priorCount)

        let missingPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u04_missing_\(UUID().uuidString)").path
        let missingItem = DiskItemInfo(
            path: missingPath,
            name: "Missing",
            displayName: "Missing",
            isDirectory: true,
            isArchive: false,
            sizeText: "--",
            rawSizeBytes: 0,
            modificationDate: nil,
            kindText: "Folder"
        )
        let missingCoordinator = FolderSummaryAnalysisCoordinator(item: missingItem, scanner: scanner)
        await missingCoordinator.requestAnalysis()
        XCTAssertEqual(missingCoordinator.scanCallCount, 1)
        XCTAssertFalse(missingCoordinator.hasAnalyzedStats)
        XCTAssertNotNil(missingCoordinator.failureMessage)
    }

    func testDeterministicScanBarrierBoundedFailureWhenScannerNeverEnters() async {
        let barrier = DeterministicScanBarrier()
        let startNs = DispatchTime.now().uptimeNanoseconds
        let entered = await barrier.waitUntilEntered(timeoutNanoseconds: 40_000_000)
        await barrier.release()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0

        XCTAssertFalse(entered, "waitUntilEntered must return false when scanner never enters")
        XCTAssertLessThan(elapsedMs, 500.0, "Timeout path must return promptly without hanging on uncancelled continuation")
    }

    func testAutomaticAnalysisDeduplicatesSelectionAndRefreshesAfterDirectoryMutation() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u04_auto_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = DiskItemInfo(url: root)
        let coordinator = FolderSummaryAnalysisCoordinator(item: item)
        coordinator.handleViewSelectionChange(item)
        let initialDrained = await waitForActiveScansToDrain(on: coordinator)
        XCTAssertTrue(initialDrained)
        XCTAssertTrue(coordinator.hasAnalyzedStats)
        XCTAssertEqual(coordinator.scanCallCount, 1)
        coordinator.handleViewSelectionChange(item)
        XCTAssertEqual(coordinator.scanCallCount, 1, "Repeated selection must reuse completed analysis")
        coordinator.invalidateAfterDirectoryMutation()
        let refreshed = await waitForActiveScansToDrain(on: coordinator)
        XCTAssertTrue(refreshed)
        XCTAssertTrue(coordinator.hasAnalyzedStats)
        XCTAssertEqual(coordinator.scanCallCount, 2, "Directory mutations refresh automatically")
        coordinator.stop()
        coordinator.invalidateAfterDirectoryMutation()
        XCTAssertEqual(coordinator.scanCallCount, 2, "Invisible inspectors must not restart scanning")
    }

    func testCancelledAutomaticAnalysisStaysPausedUntilDirectoryRefresh() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u04_paused_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = DeterministicScanBarrier()
        let item = DiskItemInfo(url: root)
        let coordinator = FolderSummaryAnalysisCoordinator(item: item, scanner: { _, _ in
            await barrier.enterAndWaitForRelease()
            return FolderAnalysisSnapshot(totalSizeBytes: 12, subfolderCount: 0, fileCount: 1, distribution: [])
        })
        coordinator.handleViewSelectionChange(item)
        let entered = await barrier.waitUntilEntered()
        coordinator.cancelAnalysis()
        coordinator.handleViewSelectionChange(item)
        let callsWhilePaused = coordinator.scanCallCount
        await barrier.release()
        let cancelledDrained = await waitForActiveScansToDrain(on: coordinator)
        XCTAssertTrue(entered)
        XCTAssertTrue(cancelledDrained)
        XCTAssertEqual(callsWhilePaused, 1, "An ordinary selection callback must respect user cancellation")
        XCTAssertEqual(coordinator.phase, .idleSummary)
        coordinator.invalidateAfterDirectoryMutation()
        let refreshed = await waitForActiveScansToDrain(on: coordinator)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(coordinator.scanCallCount, 2)
        XCTAssertTrue(coordinator.hasAnalyzedStats)
    }

    private func waitForActiveScansToDrain(
        on coordinator: FolderSummaryAnalysisCoordinator,
        timeoutNanoseconds: UInt64 = 1_500_000_000
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while coordinator.activeScanCount > 0 {
            if DispatchTime.now().uptimeNanoseconds > deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}

package final class LockedScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    package init() {}

    package func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    package func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    package var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

package final class LockedPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    package init() {}

    package func append(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }

    package var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

package actor DeterministicScanBarrier {
    private var hasEntered = false
    private var isReleased = false
    private var enteredWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var releaseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    package init() {}

    package func enterAndWaitForRelease() async {
        hasEntered = true
        let waiters = Array(enteredWaiters.values)
        enteredWaiters.removeAll()
        for cont in waiters {
            cont.resume(returning: true)
        }

        if isReleased {
            return
        }
        let releaseID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if isReleased || Task.isCancelled {
                    cont.resume()
                } else {
                    releaseWaiters[releaseID] = cont
                }
            }
        } onCancel: {
            Task {
                await self.cancelReleaseWaiter(id: releaseID)
            }
        }
    }

    package func waitUntilEntered(timeoutNanoseconds: UInt64 = 1_500_000_000) async -> Bool {
        if hasEntered {
            return true
        }
        let waiterID = UUID()
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            self.expireEnteredWaiter(id: waiterID)
        }
        defer {
            timeoutTask.cancel()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if hasEntered {
                    cont.resume(returning: true)
                } else if Task.isCancelled {
                    cont.resume(returning: false)
                } else {
                    enteredWaiters[waiterID] = cont
                }
            }
        } onCancel: {
            Task {
                await self.expireEnteredWaiter(id: waiterID)
            }
        }
    }

    private func expireEnteredWaiter(id: UUID) {
        if let cont = enteredWaiters.removeValue(forKey: id) {
            cont.resume(returning: false)
        }
    }

    private func cancelReleaseWaiter(id: UUID) {
        if let cont = releaseWaiters.removeValue(forKey: id) {
            cont.resume()
        }
    }

    package func release() {
        isReleased = true
        let pendingEntered = Array(enteredWaiters.values)
        enteredWaiters.removeAll()
        for cont in pendingEntered {
            cont.resume(returning: hasEntered)
        }
        let pendingRelease = Array(releaseWaiters.values)
        releaseWaiters.removeAll()
        for cont in pendingRelease {
            cont.resume()
        }
    }
}
