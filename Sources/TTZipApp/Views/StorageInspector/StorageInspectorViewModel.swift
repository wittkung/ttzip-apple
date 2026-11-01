// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreGraphics
import Darwin
import TTZipCore
import TTZipUI

// MARK: - Trash Executor Abstraction (Injectable for Isolated Testing)

/// Pluggable trash handler allowing unit tests to verify cleanup safety without mutating the user's real macOS Trash.
public typealias StorageTrashHandler = @Sendable (URL) throws -> URL?

// MARK: - Storage Inspector View Model

@Observable
@MainActor
public final class StorageInspectorViewModel {
    public static let shared = StorageInspectorViewModel()

    public var selectedDirectory: URL
    public var state: StorageScannerState = .idle
    public var tiles: [TreemapTile] = []
    public var reclaimableItems: [ReclaimableStorageItem] = []
    public var unverifiedItems: [ReclaimableStorageItem] = []
    public var selectedCandidateIds: Set<String> = []
    public var selectedTile: TreemapTile? = nil
    public var isPresented: Bool = false
    public var statusAlertMessage: String? = nil

    public var totalScannedBytes: UInt64 = 0
    public var totalLogicalBytes: UInt64 = 0
    public var totalReclaimableBytes: UInt64 = 0
    public var lastScanSummary: StorageScanSummary? = nil
    public var lastCleanupReport: StorageCleanupReport? = nil
    /// Historical cleanup reports indexed by cleanup generation and by authorized root directory.
    public private(set) var cleanupReportsByGeneration: [UInt64: StorageCleanupReport] = [:]
    public private(set) var cleanupReportsByDirectory: [String: StorageCleanupReport] = [:]

    /// Current scan generation counter; increments on every scan or cancellation to discard stale async results.
    public private(set) var currentGeneration: UInt64 = 0
    private var activeScanTask: Task<Void, Never>? = nil
    private var activeCancelToken: StorageScanCancelToken? = nil

    /// Background cleanup execution state and cancellation tracking.
    public private(set) var isCleaning: Bool = false
    public private(set) var cleaningProgress: (completed: Int, total: Int)? = nil
    public private(set) var currentCleanupGeneration: UInt64 = 0
    private var activeCleanupTask: Task<StorageCleanupReport, Never>? = nil
    private var activeCleanupCancelToken: StorageScanCancelToken? = nil

    /// Injectable trash handler (defaults to `FileManager.default.trashItem(at:resultingItemURL:)`).
    public var trashHandler: StorageTrashHandler
    /// Optional artificial delay per entry (nanoseconds) for deterministic cancellation tests.
    public var testPerEntryDelayNanoseconds: UInt64 = 0
    /// Maximum visited entries per scan (configurable for truncation tests).
    public var maxVisitedEntries: Int = StorageDirectoryScanner.defaultMaxVisitedEntries
    /// Maximum visited entries per candidate subtree during pre-cleanup safety inspection.
    public var maxSubtreeInspectionEntries: Int = ForensicPathGuard.defaultSubtreeInspectionBudget

    public init(
        initialDirectory: URL? = nil,
        trashHandler: @escaping StorageTrashHandler = { url in
            var resulting: NSURL? = nil
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }
    ) {
        let defaultDir = initialDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        self.selectedDirectory = defaultDir.standardizedFileURL.resolvingSymlinksInPath()
        self.trashHandler = trashHandler
    }

    // MARK: - Selection Management

    public var selectedCandidates: [ReclaimableStorageItem] {
        reclaimableItems.filter { selectedCandidateIds.contains($0.id) && $0.isSelectableForCleanup }
    }

    public var selectedCandidatesEstimatedBytes: UInt64 {
        let deduplicated = Self.deduplicateOverlappingAncestors(selectedCandidates).kept
        return deduplicated.reduce(0) { $0 &+ $1.sizeBytes }
    }

    public func toggleCandidateSelection(_ item: ReclaimableStorageItem) {
        guard item.isSelectableForCleanup, !isCleaning else { return }
        if selectedCandidateIds.contains(item.id) {
            selectedCandidateIds.remove(item.id)
        } else {
            selectedCandidateIds.insert(item.id)
        }
    }

    public func selectAllVerifiedCandidates() {
        guard !isCleaning else { return }
        selectedCandidateIds = Set(reclaimableItems.filter(\.isSelectableForCleanup).map(\.id))
    }

    public func clearCandidateSelection() {
        guard !isCleaning else { return }
        selectedCandidateIds.removeAll()
    }

    // MARK: - Directory Navigation & Scan Lifecycle

    public func setDirectory(_ url: URL) {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        if standardized == selectedDirectory, case .scanning = state {
            return
        }
        cancelCleanup()
        if standardized != selectedDirectory {
            lastCleanupReport = nil
            statusAlertMessage = nil
        }
        selectedDirectory = standardized
        startScan()
    }

    public var canNavigateUp: Bool {
        let path = selectedDirectory.standardizedFileURL.path
        return path != "/" && !path.isEmpty
    }

    public func navigateToParentDirectory() {
        let parent = selectedDirectory.deletingLastPathComponent()
        guard parent.path != selectedDirectory.path else { return }
        setDirectory(parent)
    }

    public func cancelScan() {
        activeCancelToken?.cancel()
        activeCancelToken = nil
        activeScanTask?.cancel()
        activeScanTask = nil
        currentGeneration &+= 1
        if case .scanning = state {
            state = .cancelled
        }
    }

    public func cancelCleanup() {
        activeCleanupCancelToken?.cancel()
        activeCleanupCancelToken = nil
        activeCleanupTask?.cancel()
        activeCleanupTask = nil
        currentCleanupGeneration &+= 1
        isCleaning = false
        cleaningProgress = nil
    }

    public func startScan() {
        if isCleaning {
            cancelCleanup()
        }
        activeCancelToken?.cancel()
        activeScanTask?.cancel()
        currentGeneration &+= 1
        let expectedGen = currentGeneration

        let token = StorageScanCancelToken()
        activeCancelToken = token

        tiles.removeAll()
        reclaimableItems.removeAll()
        unverifiedItems.removeAll()
        selectedCandidateIds.removeAll()
        selectedTile = nil
        totalScannedBytes = 0
        totalLogicalBytes = 0
        totalReclaimableBytes = 0
        lastScanSummary = nil

        let targetDir = selectedDirectory
        let maxEntries = maxVisitedEntries
        let delayNs = testPerEntryDelayNanoseconds
        state = .scanning(currentPath: targetDir.lastPathComponent, scannedItems: 0, itemsPerSec: 0)

        let progressCallback: @Sendable (String, Int) -> Void = { [weak self] currentName, count in
            guard !token.isCancelled else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.currentGeneration == expectedGen,
                      !token.isCancelled,
                      case .scanning = self.state else { return }
                self.state = .scanning(currentPath: currentName, scannedItems: count, itemsPerSec: 0)
            }
        }

        activeScanTask = Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) { () -> StorageScanOutput in
                StorageDirectoryScanner.scanDirectory(
                    rootURL: targetDir,
                    cancelToken: token,
                    maxVisitedEntries: maxEntries,
                    perEntryDelayNanoseconds: delayNs,
                    onProgress: progressCallback
                )
            }.value

            guard let self else { return }
            guard self.currentGeneration == expectedGen, !token.isCancelled, !Task.isCancelled else {
                return
            }

            self.applyScanOutput(output)
        }
    }

    /// Synchronously runs a scan for `selectedDirectory` (used by deterministic unit tests).
    @discardableResult
    public func performSynchronousScan() -> StorageScanOutput {
        if isCleaning {
            cancelCleanup()
        }
        activeCancelToken?.cancel()
        activeScanTask?.cancel()
        currentGeneration &+= 1
        let token = StorageScanCancelToken()
        activeCancelToken = token

        let output = StorageDirectoryScanner.scanDirectory(
            rootURL: selectedDirectory,
            cancelToken: token,
            maxVisitedEntries: maxVisitedEntries,
            perEntryDelayNanoseconds: testPerEntryDelayNanoseconds
        )
        applyScanOutput(output)
        return output
    }

    private func applyScanOutput(_ output: StorageScanOutput) {
        self.lastScanSummary = output.summary
        self.reclaimableItems = output.verifiedCandidates
        self.unverifiedItems = output.unverifiedCandidates
        self.tiles = output.tiles
        self.totalScannedBytes = output.summary.allocatedBytes
        self.totalLogicalBytes = output.summary.logicalBytes
        self.totalReclaimableBytes = output.summary.reclaimableBytes
        self.selectedCandidateIds.removeAll()
        self.selectedTile = nil

        switch output.status {
        case .completed:
            self.state = .completed(
                totalBytes: output.summary.allocatedBytes,
                reclaimableBytes: output.summary.reclaimableBytes,
                durationSec: max(0.001, output.summary.durationSec)
            )
        case .empty:
            self.state = .empty(rootPath: output.summary.rootPath)
        case .cancelled:
            self.state = .cancelled
        case .permissionDenied(let path):
            self.state = .permissionDenied(path: path)
        case .failed(let message):
            self.state = .failed(message: message)
        }
    }

    // MARK: - Background Async Cleanup & Synchronous Cleanup Entry Points

    /// Starts an asynchronous background cleanup for all currently selected verified candidates.
    /// Returns `nil` if a cleanup is already in progress (`isCleaning == true`).
    @discardableResult
    public func startCleanupSelected(rescanAfter: Bool = true) -> Task<StorageCleanupReport, Never>? {
        startCleanup(for: selectedCandidates, rescanAfter: rescanAfter)
    }

    /// Starts an asynchronous background cleanup for a single candidate item.
    /// Returns `nil` if a cleanup is already in progress (`isCleaning == true`).
    @discardableResult
    public func startCleanupItem(
        _ item: ReclaimableStorageItem,
        rescanAfter: Bool = true
    ) -> Task<StorageCleanupReport, Never>? {
        startCleanup(for: [item], rescanAfter: rescanAfter)
    }

    /// Launches a background task to revalidate and move `requestedItems` to Trash off `@MainActor`.
    /// Rejects duplicate submissions while `isCleaning == true`.
    @discardableResult
    public func startCleanup(
        for requestedItems: [ReclaimableStorageItem],
        rescanAfter: Bool = false
    ) -> Task<StorageCleanupReport, Never>? {
        guard !isCleaning else { return nil }
        let authorizedRoot = selectedDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let expectedScanGen = currentGeneration
        currentCleanupGeneration &+= 1
        let expectedCleanupGen = currentCleanupGeneration

        guard !requestedItems.isEmpty else {
            let emptyReport = StorageCleanupReport(
                cleanupGeneration: expectedCleanupGen,
                scanGeneration: expectedScanGen,
                rootPath: authorizedRoot,
                records: [],
                trashedCount: 0,
                coveredByParentCount: 0,
                rejectedOrFailedCount: 0,
                cancelledCount: 0,
                reclaimedEstimatedBytes: 0
            )
            cleanupReportsByGeneration[expectedCleanupGen] = emptyReport
            cleanupReportsByDirectory[authorizedRoot] = emptyReport
            self.lastCleanupReport = emptyReport
            return Task { emptyReport }
        }

        let (keptItems, coveredPairs) = Self.deduplicateOverlappingAncestors(requestedItems)
        let cleanupToken = StorageScanCancelToken()
        activeCleanupCancelToken = cleanupToken

        isCleaning = true
        cleaningProgress = (completed: 0, total: keptItems.count)

        let handler = trashHandler
        let subtreeBudget = maxSubtreeInspectionEntries
        let progressCallback: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            guard !cleanupToken.isCancelled else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.currentCleanupGeneration == expectedCleanupGen,
                      self.currentGeneration == expectedScanGen,
                      self.isCleaning else { return }
                self.cleaningProgress = (completed: done, total: total)
            }
        }

        let task = Task<StorageCleanupReport, Never> { [weak self] in
            let (report, trashedItems) = await Task.detached(priority: .userInitiated) {
                Self.runCleanupBatchOffMainActor(
                    cleanupGeneration: expectedCleanupGen,
                    scanGeneration: expectedScanGen,
                    keptItems: keptItems,
                    coveredPairs: coveredPairs,
                    authorizedRoot: authorizedRoot,
                    trashHandler: handler,
                    cancelToken: cleanupToken,
                    maxSubtreeEntries: subtreeBudget,
                    onProgress: progressCallback
                )
            }.value

            guard let self else { return report }
            self.finishAsyncCleanup(
                report: report,
                trashedItems: trashedItems,
                authorizedRoot: authorizedRoot,
                expectedCleanupGen: expectedCleanupGen,
                expectedScanGen: expectedScanGen,
                wasCancelled: cleanupToken.isCancelled,
                rescanAfter: rescanAfter
            )
            return report
        }

        activeCleanupTask = task
        return task
    }

    private func finishAsyncCleanup(
        report: StorageCleanupReport,
        trashedItems: [ReclaimableStorageItem],
        authorizedRoot: String,
        expectedCleanupGen: UInt64,
        expectedScanGen: UInt64,
        wasCancelled: Bool,
        rescanAfter: Bool
    ) {
        self.cleanupReportsByGeneration[expectedCleanupGen] = report
        self.cleanupReportsByDirectory[authorizedRoot] = report

        let currentRoot = selectedDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard self.currentCleanupGeneration == expectedCleanupGen,
              self.currentGeneration == expectedScanGen,
              !wasCancelled,
              currentRoot == authorizedRoot else {
            if self.currentCleanupGeneration == expectedCleanupGen {
                self.isCleaning = false
                self.cleaningProgress = nil
                self.activeCleanupTask = nil
                self.activeCleanupCancelToken = nil
            }
            return
        }

        self.isCleaning = false
        self.cleaningProgress = nil
        self.activeCleanupTask = nil
        self.activeCleanupCancelToken = nil
        self.lastCleanupReport = report

        applyCleanupStateMutations(
            report: report,
            trashedItems: trashedItems,
            expectedCleanupGen: expectedCleanupGen,
            expectedScanGen: expectedScanGen,
            authorizedRoot: authorizedRoot,
            rescanAfter: rescanAfter
        )
    }

    /// Executes cleanup for a single candidate item with full pre-execution revalidation.
    @discardableResult
    public func trashItem(_ item: ReclaimableStorageItem, rescanAfter: Bool = false) -> StorageCleanupReport {
        executeCleanup(for: [item], rescanAfter: rescanAfter)
    }

    /// Moves all currently selected verified candidates to Trash.
    @discardableResult
    public func trashSelectedCandidates(rescanAfter: Bool = true) -> StorageCleanupReport {
        executeCleanup(for: selectedCandidates, rescanAfter: rescanAfter)
    }

    /// Compatibility entry point: moves selected candidates if any are selected, or all verified candidates
    /// when invoked from legacy callers. Never touches unverified candidates.
    @discardableResult
    public func trashAllReclaimable() -> StorageCleanupReport {
        let targets = selectedCandidates.isEmpty ? reclaimableItems.filter(\.isSelectableForCleanup) : selectedCandidates
        return executeCleanup(for: targets, rescanAfter: false)
    }

    /// Synchronous cleanup entry point for deterministic unit tests.
    @discardableResult
    public func executeCleanup(
        for requestedItems: [ReclaimableStorageItem],
        rescanAfter: Bool = false
    ) -> StorageCleanupReport {
        let authorizedRoot = selectedDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let expectedScanGen = currentGeneration
        currentCleanupGeneration &+= 1
        let expectedCleanupGen = currentCleanupGeneration

        guard !requestedItems.isEmpty else {
            let emptyReport = StorageCleanupReport(
                cleanupGeneration: expectedCleanupGen,
                scanGeneration: expectedScanGen,
                rootPath: authorizedRoot,
                records: [],
                trashedCount: 0,
                coveredByParentCount: 0,
                rejectedOrFailedCount: 0,
                cancelledCount: 0,
                reclaimedEstimatedBytes: 0
            )
            cleanupReportsByGeneration[expectedCleanupGen] = emptyReport
            cleanupReportsByDirectory[authorizedRoot] = emptyReport
            self.lastCleanupReport = emptyReport
            return emptyReport
        }

        let (keptItems, coveredPairs) = Self.deduplicateOverlappingAncestors(requestedItems)
        let (report, trashedItems) = Self.runCleanupBatchOffMainActor(
            cleanupGeneration: expectedCleanupGen,
            scanGeneration: expectedScanGen,
            keptItems: keptItems,
            coveredPairs: coveredPairs,
            authorizedRoot: authorizedRoot,
            trashHandler: trashHandler,
            cancelToken: StorageScanCancelToken(),
            maxSubtreeEntries: maxSubtreeInspectionEntries,
            onProgress: nil
        )
        cleanupReportsByGeneration[expectedCleanupGen] = report
        cleanupReportsByDirectory[authorizedRoot] = report
        self.lastCleanupReport = report
        applyCleanupStateMutations(
            report: report,
            trashedItems: trashedItems,
            expectedCleanupGen: expectedCleanupGen,
            expectedScanGen: expectedScanGen,
            authorizedRoot: authorizedRoot,
            rescanAfter: rescanAfter
        )
        return report
    }

    private nonisolated static func runCleanupBatchOffMainActor(
        cleanupGeneration: UInt64,
        scanGeneration: UInt64,
        keptItems: [ReclaimableStorageItem],
        coveredPairs: [(item: ReclaimableStorageItem, parentPath: String)],
        authorizedRoot: String,
        trashHandler: StorageTrashHandler,
        cancelToken: StorageScanCancelToken,
        maxSubtreeEntries: Int,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) -> (StorageCleanupReport, [ReclaimableStorageItem]) {
        var records: [StorageCleanupItemRecord] = []
        var trashedItems: [ReclaimableStorageItem] = []
        var trashedCount = 0
        var coveredCount = 0
        var rejectedOrFailedCount = 0
        var cancelledCount = 0
        var trashedBytes: UInt64 = 0

        for (coveredItem, parentPath) in coveredPairs {
            coveredCount += 1
            records.append(StorageCleanupItemRecord(
                name: coveredItem.name,
                path: coveredItem.path,
                estimatedBytes: coveredItem.sizeBytes,
                outcome: .coveredByParent(parentPath: parentPath)
            ))
        }

        for (idx, item) in keptItems.enumerated() {
            let singleOutcome = processSingleCleanupItem(
                item: item,
                authorizedRoot: authorizedRoot,
                trashHandler: trashHandler,
                cancelToken: cancelToken,
                maxSubtreeEntries: maxSubtreeEntries
            )
            switch singleOutcome {
            case .trashed:
                trashedCount += 1
                trashedBytes &+= item.sizeBytes
                trashedItems.append(item)
            case .coveredByParent:
                coveredCount += 1
            case .cancelled:
                cancelledCount += 1
            case .rejected, .failed:
                rejectedOrFailedCount += 1
            }
            records.append(StorageCleanupItemRecord(
                name: item.name,
                path: item.path,
                estimatedBytes: item.sizeBytes,
                outcome: singleOutcome
            ))
            onProgress?(idx + 1, keptItems.count)
        }

        let report = StorageCleanupReport(
            cleanupGeneration: cleanupGeneration,
            scanGeneration: scanGeneration,
            rootPath: authorizedRoot,
            records: records,
            trashedCount: trashedCount,
            coveredByParentCount: coveredCount,
            rejectedOrFailedCount: rejectedOrFailedCount,
            cancelledCount: cancelledCount,
            reclaimedEstimatedBytes: trashedBytes
        )
        return (report, trashedItems)
    }

    private nonisolated static func processSingleCleanupItem(
        item: ReclaimableStorageItem,
        authorizedRoot: String,
        trashHandler: StorageTrashHandler,
        cancelToken: StorageScanCancelToken,
        maxSubtreeEntries: Int
    ) -> StorageCleanupItemOutcome {
        if cancelToken.isCancelled {
            return .cancelled
        }
        let effectiveAuthRoot = item.scanRootPath.isEmpty ? authorizedRoot : item.scanRootPath
        if let rejection = ForensicPathGuard.revalidateBeforeTrash(
            item: item,
            authorizedScanRootPath: effectiveAuthRoot,
            cancelToken: cancelToken,
            maxSubtreeEntries: maxSubtreeEntries
        ) {
            if cancelToken.isCancelled {
                return .cancelled
            }
            return .rejected(rejection)
        }
        if cancelToken.isCancelled {
            return .cancelled
        }

        do {
            let resultingURL = try trashHandler(item.url)
            var postStat = Darwin.stat()
            if Darwin.lstat(item.path, &postStat) == 0,
               item.identity.inode == 0
                || (postStat.st_dev == item.identity.device && postStat.st_ino == item.identity.inode) {
                return .failed(message: "Original path still exists after trash operation")
            }
            return .trashed(trashedURL: resultingURL)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private func applyCleanupStateMutations(
        report: StorageCleanupReport,
        trashedItems: [ReclaimableStorageItem],
        expectedCleanupGen: UInt64,
        expectedScanGen: UInt64,
        authorizedRoot: String,
        rescanAfter: Bool
    ) {
        let currentRoot = selectedDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard self.currentCleanupGeneration == expectedCleanupGen,
              self.currentGeneration == expectedScanGen,
              currentRoot == authorizedRoot else {
            return
        }

        if !trashedItems.isEmpty {
            removeTrashedItemsFromActiveSnapshot(trashedItems, fallbackBytes: report.trashedEstimatedBytes)
        }

        if report.rejectedOrFailedCount > 0 {
            let firstFailure = report.records.first {
                if case .rejected = $0.outcome { return true }
                if case .failed = $0.outcome { return true }
                return false
            }
            let detail = firstFailure.map { "\($0.name): \($0.outcome.localizedStatus())" } ?? ""
            if report.trashedCount == 0 {
                statusAlertMessage = detail
            } else {
                let summary = StorageLocaleKey.cleanupSummaryPartialFormat.format(
                    report.trashedCount,
                    report.rejectedOrFailedCount
                )
                statusAlertMessage = detail.isEmpty ? summary : "\(summary)\n\(detail)"
            }
        }

        if rescanAfter && report.trashedCount > 0 {
            startScan()
        }
    }

    private func removeTrashedItemsFromActiveSnapshot(
        _ trashedItems: [ReclaimableStorageItem],
        fallbackBytes: UInt64
    ) {
        var removedCandidateIDs = Set<String>()
        var removedBytes: UInt64 = 0

        reclaimableItems.removeAll { candidate in
            let matchesTrashedIdentity = trashedItems.contains { trashed in
                trashed.identity == candidate.identity
                    || ForensicPathGuard.isStrictDescendant(childPath: candidate.path, ofRootPath: trashed.path)
            }
            guard matchesTrashedIdentity else { return false }
            if let liveIdentity = StorageEntryIdentity.capture(atPath: candidate.path),
               liveIdentity.inode == candidate.identity.inode,
               liveIdentity.device == candidate.identity.device {
                return false
            }
            removedCandidateIDs.insert(candidate.id)
            removedBytes &+= candidate.sizeBytes
            return true
        }

        let effectiveRemovedPaths = removedCandidateIDs.isEmpty
            ? Set(trashedItems.filter { StorageEntryIdentity.capture(atPath: $0.path) == nil }.map(\.path))
            : removedCandidateIDs
        selectedCandidateIds.subtract(effectiveRemovedPaths)
        tiles.removeAll { tile in
            !tile.relativePath.isEmpty && effectiveRemovedPaths.contains(tile.relativePath)
        }
        if let selected = selectedTile, !selected.relativePath.isEmpty, effectiveRemovedPaths.contains(selected.relativePath) {
            selectedTile = nil
        }

        let delta = removedBytes > 0 ? removedBytes : fallbackBytes
        totalReclaimableBytes = totalReclaimableBytes >= delta ? (totalReclaimableBytes - delta) : 0
        totalScannedBytes = totalScannedBytes >= delta ? (totalScannedBytes - delta) : 0
    }

    /// Deduplicates overlapping parent/child candidates so that only outermost ancestors are executed,
    /// returning both the kept ancestors and the covered descendants.
    public nonisolated static func deduplicateOverlappingAncestors(
        _ items: [ReclaimableStorageItem]
    ) -> (kept: [ReclaimableStorageItem], covered: [(item: ReclaimableStorageItem, parentPath: String)]) {
        let sorted = items.sorted { lhs, rhs in
            let lc = (lhs.path as NSString).pathComponents.count
            let rc = (rhs.path as NSString).pathComponents.count
            if lc != rc { return lc < rc }
            return lhs.path < rhs.path
        }

        var kept: [ReclaimableStorageItem] = []
        var covered: [(item: ReclaimableStorageItem, parentPath: String)] = []

        for candidate in sorted {
            if kept.contains(where: { $0.path == candidate.path }) {
                continue
            }
            if let ancestor = kept.first(where: {
                ForensicPathGuard.isStrictDescendant(childPath: candidate.path, ofRootPath: $0.path)
            }) {
                covered.append((item: candidate, parentPath: ancestor.path))
            } else {
                kept.append(candidate)
            }
        }

        return (kept, covered)
    }

    // MARK: - Public Classification & Layout APIs

    /// Evaluates an entry for semantic tile classification and reclaimable status.
    /// Requires the path to exist on disk and pass full positive evidence + subtree safety inspection;
    /// never marks non-existent or name-only entries as reclaimable.
    public nonisolated static func classifyEntry(
        name: String,
        isDir: Bool,
        url: URL
    ) -> (TileCategory, Bool, String) {
        var st = Darwin.stat()
        guard Darwin.lstat(url.path, &st) == 0 else {
            let (cat, reason) = ForensicPathGuard.classifyRegularFileOrDirectory(name: name, isDir: isDir, url: url)
            return (cat, false, reason)
        }
        let isLink = (st.st_mode & S_IFMT) == S_IFLNK
        let actualIsDir = (st.st_mode & S_IFMT) == S_IFDIR
        let eval = ForensicPathGuard.evaluateCandidate(
            name: name,
            isDir: actualIsDir,
            isSymlink: isLink,
            url: url
        )
        return (eval.category, eval.verification == .verified, eval.reason)
    }

    /// Computes a Bruls squarified treemap layout in unit `[0..1] × [0..1]` coordinates,
    /// preserving exact byte conservation and deterministic ordering.
    public nonisolated static func computeSquarifiedLayout(
        entries: [(name: String, path: String, bytes: UInt64, category: TileCategory, isReclaim: Bool)],
        totalBytes: UInt64
    ) -> [TreemapTile] {
        let withDirs = entries.map { entry in
            (
                name: entry.name,
                path: entry.path,
                bytes: entry.bytes,
                category: entry.category,
                isReclaim: entry.isReclaim,
                isDir: false
            )
        }
        return StorageDirectoryScanner.computeSquarifiedLayoutWithDirs(entries: withDirs, totalBytes: totalBytes)
    }
}
