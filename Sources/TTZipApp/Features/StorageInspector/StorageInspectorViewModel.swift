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
    public var rootTiles: [TreemapTile] { tiles }
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
    public internal(set) var cleanupReportsByGeneration: [UInt64: StorageCleanupReport] = [:]
    public internal(set) var cleanupReportsByDirectory: [String: StorageCleanupReport] = [:]

    /// Current scan generation counter; increments on every scan or cancellation to discard stale async results.
    public internal(set) var currentGeneration: UInt64 = 0
    var activeScanTask: Task<Void, Never>? = nil
    var activeCancelToken: StorageScanCancelToken? = nil

    /// Background cleanup execution state and cancellation tracking.
    public internal(set) var isCleaning: Bool = false
    public internal(set) var cleaningProgress: (completed: Int, total: Int)? = nil
    public internal(set) var currentCleanupGeneration: UInt64 = 0
    var activeCleanupTask: Task<StorageCleanupReport, Never>? = nil
    var activeCleanupCancelToken: StorageScanCancelToken? = nil

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
        let defaultDir = initialDirectory ?? RootFolderAccessManager.defaultInitialDirectoryURL()
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

    public var shouldStartScanOnAppear: Bool {
        guard !isCleaning else { return false }
        return state == .idle || (state == .cancelled && rootTiles.isEmpty)
    }

    public var showsNoReclaimableFoundBadge: Bool {
        guard reclaimableItems.isEmpty && unverifiedItems.isEmpty else { return false }
        switch state {
        case .completed, .empty:
            return true
        case .idle, .scanning, .cancelled, .permissionDenied, .failed:
            return false
        }
    }

    public func handleViewAppear() {
        if shouldStartScanOnAppear {
            startScan()
        }
    }

    public func handleExplicitClose() {
        cancelScan()
        cancelCleanup()
        isPresented = false
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

    func applyScanOutput(_ output: StorageScanOutput) {
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
}
