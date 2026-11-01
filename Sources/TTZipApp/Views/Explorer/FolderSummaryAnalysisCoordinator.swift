// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import Observation
#if canImport(TTZipAppModels)
#endif
#if canImport(TTZipAppServices)
#endif

/// Single category entry in a folder's file-type breakdown.
package struct FolderDistributionEntry: Equatable, Sendable {
    package let category: String
    package let count: Int
    /// Logical file bytes. Nil when at least one size is unavailable or the sum overflows.
    package let sizeBytes: Int64?

    package init(category: String, count: Int, sizeBytes: Int64? = nil) {
        self.category = category
        self.count = count
        self.sizeBytes = sizeBytes
    }
}

/// Lightweight non-recursive metadata for a folder's own filesystem inode.
package struct FolderLightweightMetadata: Equatable, Sendable {
    package let modificationDate: Date?
    package let fileSystemName: String
    package let posixPermissions: String
    package let ownerName: String
    package let groupName: String

    package init(
        modificationDate: Date?,
        fileSystemName: String,
        posixPermissions: String,
        ownerName: String,
        groupName: String
    ) {
        self.modificationDate = modificationDate
        self.fileSystemName = fileSystemName
        self.posixPermissions = posixPermissions
        self.ownerName = ownerName
        self.groupName = groupName
    }

    package static func unanalyzedPlaceholder(modificationDate: Date? = nil) -> FolderLightweightMetadata {
        FolderLightweightMetadata(
            modificationDate: modificationDate,
            fileSystemName: "--",
            posixPermissions: "--",
            ownerName: "--",
            groupName: "--"
        )
    }
}

/// Recursive folder statistics produced by the background analysis task.
package struct FolderAnalysisSnapshot: Equatable, Sendable {
    package let totalSizeBytes: Int64
    package let subfolderCount: Int
    package let fileCount: Int
    package let distribution: [FolderDistributionEntry]

    package init(
        totalSizeBytes: Int64,
        subfolderCount: Int,
        fileCount: Int,
        distribution: [FolderDistributionEntry]
    ) {
        self.totalSizeBytes = totalSizeBytes
        self.subfolderCount = subfolderCount
        self.fileCount = fileCount
        self.distribution = distribution
    }
}

/// Strictly classified target identity for folder inspection.
package enum FolderAnalysisTargetIdentity: Equatable, Sendable {
    case localDirectory(URL)
    case rejectedVirtualOrRemote(rawPath: String, reason: String)

    package var isAnalyzableLocalTarget: Bool {
        if case .localDirectory = self {
            return true
        }
        return false
    }

    package var localDirectoryURL: URL? {
        if case .localDirectory(let url) = self {
            return url
        }
        return nil
    }
}

/// Explicit error domain for local directory analysis.
package enum FolderAnalysisError: Error, LocalizedError, Equatable, Sendable {
    case rejectedNonLocalTarget(String)
    case targetDoesNotExist(String)
    case targetAccessDenied(String)
    case targetNotDirectory(String)
    case scanFailed(String)

    package var errorDescription: String? {
        switch self {
        case .rejectedNonLocalTarget(let reason):
            return reason
        case .targetDoesNotExist(let path):
            return "Directory does not exist: \(path)"
        case .targetAccessDenied(let path):
            return "Permission denied when reading directory: \(path)"
        case .targetNotDirectory(let path):
            return "Target path is not a directory: \(path)"
        case .scanFailed(let message):
            return message
        }
    }
}

/// Lifecycle state for background folder analysis.
package enum FolderAnalysisPhase: Equatable, Sendable {
    case idleSummary
    case analyzing(generation: Int)
    case completed(FolderAnalysisSnapshot)
    case failed(String)
}

/// Thread-safe cancellation relay linking structured task cancellation to detached directory enumeration.
package final class FolderScanCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancelHandlers: [@Sendable () -> Void] = []

    package init(onCancel: (@Sendable () -> Void)? = nil) {
        if let onCancel {
            cancelHandlers.append(onCancel)
        }
    }

    package var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    package func registerOnCancel(_ handler: @escaping @Sendable () -> Void) {
        var shouldRunImmediately = false
        lock.lock()
        if cancelled {
            shouldRunImmediately = true
        } else {
            cancelHandlers.append(handler)
        }
        lock.unlock()

        if shouldRunImmediately {
            handler()
        }
    }

    package func cancel() {
        var handlersToRun: [@Sendable () -> Void] = []
        lock.lock()
        if !cancelled {
            cancelled = true
            handlersToRun = cancelHandlers
            cancelHandlers.removeAll()
        }
        lock.unlock()

        for handler in handlersToRun {
            handler()
        }
    }
}

/// Leaf coordinator owning automatic background analysis and stale-result isolation.
@MainActor
@Observable
package final class FolderSummaryAnalysisCoordinator {
    package typealias DirectoryStatsScanner = @Sendable (
        _ targetIdentity: FolderAnalysisTargetIdentity,
        _ cancellationBox: FolderScanCancellationBox
    ) async throws -> FolderAnalysisSnapshot

    package private(set) var currentItem: DiskItemInfo
    package private(set) var targetIdentity: FolderAnalysisTargetIdentity
    package private(set) var lightweightMetadata: FolderLightweightMetadata
    package private(set) var phase: FolderAnalysisPhase = .idleSummary
    package private(set) var generation: Int = 0
    package private(set) var isStopped: Bool = false

    // Observable verification counters for deterministic testing and view-host lifecycle proof.
    package private(set) var scanCallCount: Int = 0
    package private(set) var cancelSignalCount: Int = 0
    package private(set) var activeScanCount: Int = 0
    package private(set) var completedScanReleaseCount: Int = 0
    package private(set) var ignoredDuplicateRequestCount: Int = 0
    package private(set) var rejectedStaleCommitCount: Int = 0
    package private(set) var rejectedNonLocalRequestCount: Int = 0
    package private(set) var viewMountAndChangeCount: Int = 0
    package private(set) var viewDisappearCount: Int = 0
    package private(set) var lastMountedItemPath: String?

    @ObservationIgnored
    private let scanner: DirectoryStatsScanner
    @ObservationIgnored
    private var inFlightTask: Task<Void, Never>?
    @ObservationIgnored
    private var inFlightGeneration: Int?
    @ObservationIgnored
    private var activeCancellationBox: FolderScanCancellationBox?
    @ObservationIgnored
    private var signalledCancelGenerations: Set<Int> = []

    package init(
        item: DiskItemInfo,
        scanner: @escaping DirectoryStatsScanner = FolderSummaryAnalysisCoordinator.defaultScanner
    ) {
        self.currentItem = item
        self.scanner = scanner
        let resolvedIdentity = Self.classifyIdentity(for: item)
        self.targetIdentity = resolvedIdentity
        self.lightweightMetadata = Self.loadLightweightMetadata(for: item, identity: resolvedIdentity)
        self.phase = .idleSummary
    }

    // MARK: - Presentation Convenience Projections

    package var isCalculating: Bool {
        if case .analyzing = phase {
            return true
        }
        return false
    }

    package var hasAnalyzedStats: Bool {
        if case .completed = phase {
            return true
        }
        return false
    }

    package var analyzedSnapshot: FolderAnalysisSnapshot? {
        if case .completed(let snapshot) = phase {
            return snapshot
        }
        return nil
    }

    package var totalSizeBytes: Int64 {
        analyzedSnapshot?.totalSizeBytes ?? 0
    }

    package var subfolderCount: Int {
        analyzedSnapshot?.subfolderCount ?? 0
    }

    package var fileCount: Int {
        analyzedSnapshot?.fileCount ?? 0
    }

    package var fileTypeDistribution: [FolderDistributionEntry] {
        analyzedSnapshot?.distribution ?? []
    }

    package var failureMessage: String? {
        if case .failed(let message) = phase {
            return message
        }
        return nil
    }

    package var canAnalyzeSelectedTarget: Bool {
        targetIdentity.isAnalyzableLocalTarget
    }

    // MARK: - Selection, Invalidation & Lifecycle

    /// Invoked by `FolderMediaArtboardView` when mounted or when `item.path` updates.
    package func handleViewSelectionChange(_ newItem: DiskItemInfo) {
        let shouldStart = generation == 0 || isStopped
            || newItem.path != currentItem.path
            || newItem.isDirectory != currentItem.isDirectory
            || newItem.isArchive != currentItem.isArchive
        viewMountAndChangeCount += 1
        lastMountedItemPath = newItem.path
        selectItem(newItem)
        if shouldStart, canAnalyzeSelectedTarget, phase == .idleSummary {
            startAnalysis()
        }
    }

    /// Invoked by `FolderMediaArtboardView` on `.onDisappear`.
    package func handleViewDisappear() {
        viewDisappearCount += 1
        stop()
    }

    /// Switches or initializes the inspected folder to lightweight summary mode with zero recursive scanning.
    package func selectItem(_ newItem: DiskItemInfo, forceReset: Bool = false) {
        let wasStopped = isStopped
        isStopped = false
        let isSameTarget =
            newItem.path == currentItem.path
            && newItem.isDirectory == currentItem.isDirectory
            && newItem.isArchive == currentItem.isArchive
        let hasDanglingAnalyzingPhase = isCalculating && inFlightTask == nil
        if !forceReset && !wasStopped && isSameTarget && !hasDanglingAnalyzingPhase {
            return
        }

        cancelInFlightScanIfNeeded()
        generation &+= 1
        currentItem = newItem
        let resolvedIdentity = Self.classifyIdentity(for: newItem)
        targetIdentity = resolvedIdentity
        lightweightMetadata = Self.loadLightweightMetadata(for: newItem, identity: resolvedIdentity)
        phase = .idleSummary
    }

    /// Invalidates stale results and refreshes the visible directory in the background.
    package func invalidateAfterDirectoryMutation() {
        guard !isStopped else { return }
        cancelInFlightScanIfNeeded()
        generation &+= 1
        lightweightMetadata = Self.loadLightweightMetadata(for: currentItem, identity: targetIdentity)
        phase = .idleSummary
        if canAnalyzeSelectedTarget {
            startAnalysis()
        }
    }

    /// Cancels an in-flight analysis and returns to lightweight summary mode.
    package func cancelAnalysis() {
        guard inFlightTask != nil || isCalculating else { return }
        cancelInFlightScanIfNeeded()
        generation &+= 1
        phase = .idleSummary
    }

    /// Stops the coordinator when the view disappears, cancelling active work, converging state to summary, and blocking late commits.
    package func stop() {
        isStopped = true
        cancelInFlightScanIfNeeded()
        generation &+= 1
        phase = .idleSummary
    }

    // MARK: - Shared Background Analysis Entry

    /// Validates and launches one background scan, shared by automatic selection and retry.
    package func startAnalysis() {
        isStopped = false
        if case .analyzing(let activeGen) = phase, activeGen == generation, inFlightTask != nil {
            ignoredDuplicateRequestCount += 1
            return
        }

        switch targetIdentity {
        case .rejectedVirtualOrRemote(_, let reason):
            rejectedNonLocalRequestCount += 1
            phase = .failed(reason)
            return
        case .localDirectory:
            break
        }

        let requestGeneration = generation
        let requestPath = currentItem.path
        let requestIdentity = targetIdentity
        phase = .analyzing(generation: requestGeneration)
        scanCallCount += 1
        activeScanCount += 1

        let box = FolderScanCancellationBox()
        box.registerOnCancel { [weak self] in
            Task { @MainActor [weak self] in
                self?.recordCancelSignalIfNeeded(forGeneration: requestGeneration)
            }
        }
        activeCancellationBox = box
        inFlightGeneration = requestGeneration

        inFlightTask = Task { @MainActor [weak self] in
            await self?.runScanTask(
                requestGeneration: requestGeneration,
                requestPath: requestPath,
                requestIdentity: requestIdentity,
                cancellationBox: box
            )
        }
    }

    /// Async entry point that awaits completion of the launched or reused task.
    package func requestAnalysis() async {
        startAnalysis()
        if let task = inFlightTask {
            await task.value
        }
    }

    private func runScanTask(
        requestGeneration: Int,
        requestPath: String,
        requestIdentity: FolderAnalysisTargetIdentity,
        cancellationBox: FolderScanCancellationBox
    ) async {
        defer {
            activeScanCount = max(0, activeScanCount - 1)
            completedScanReleaseCount += 1
            if inFlightGeneration == requestGeneration {
                inFlightTask = nil
                inFlightGeneration = nil
                activeCancellationBox = nil
            }
        }

        let scanFn = self.scanner
        do {
            let snapshot = try await withTaskCancellationHandler(
                operation: {
                    try await scanFn(requestIdentity, cancellationBox)
                },
                onCancel: {
                    cancellationBox.cancel()
                }
            )

            guard !isStopped,
                !cancellationBox.isCancelled,
                !Task.isCancelled,
                generation == requestGeneration,
                currentItem.path == requestPath
            else {
                rejectedStaleCommitCount += 1
                return
            }

            phase = .completed(snapshot)
        } catch {
            if isStopped
                || cancellationBox.isCancelled
                || Task.isCancelled
                || generation != requestGeneration
                || currentItem.path != requestPath
                || error is CancellationError
            {
                rejectedStaleCommitCount += 1
                return
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(message)
        }
    }

    private func cancelInFlightScanIfNeeded() {
        if let activeGen = inFlightGeneration {
            recordCancelSignalIfNeeded(forGeneration: activeGen)
        }
        activeCancellationBox?.cancel()
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightGeneration = nil
        activeCancellationBox = nil
    }

    private func recordCancelSignalIfNeeded(forGeneration gen: Int) {
        guard !signalledCancelGenerations.contains(gen) else { return }
        signalledCancelGenerations.insert(gen)
        cancelSignalCount += 1
    }

    // MARK: - Strict Identity & Lightweight Metadata Resolution

    /// Resolves whether `item` is a real local directory or a virtual/remote/subpath identity that must be rejected.
    nonisolated package static func classifyIdentity(for item: DiskItemInfo) -> FolderAnalysisTargetIdentity {
        classifyPathIdentity(
            rawPath: item.path,
            isDirectory: item.isDirectory,
            isArchive: item.isArchive
        )
    }

    /// Resolves whether a raw path string represents a real local directory without mutating significant leading/trailing characters.
    nonisolated package static func classifyPathIdentity(
        rawPath: String,
        isDirectory: Bool = true,
        isArchive: Bool = false
    ) -> FolderAnalysisTargetIdentity {
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejectedVirtualOrRemote(rawPath: rawPath, reason: "Empty target path")
        }
        guard isDirectory, !isArchive else {
            return .rejectedVirtualOrRemote(
                rawPath: rawPath,
                reason: "Target is not a real local directory"
            )
        }

        let lowercased = rawPath.lowercased()
        if lowercased.contains("?subpath=") || lowercased.contains("&subpath=") {
            return .rejectedVirtualOrRemote(
                rawPath: rawPath,
                reason: "Archive virtual subpath cannot be analyzed as a local directory"
            )
        }
        if rawPath.hasPrefix("//") {
            return .rejectedVirtualOrRemote(
                rawPath: rawPath,
                reason: "Remote network authority path cannot be analyzed as a local directory"
            )
        }

        if lowercased.contains("://") {
            return classifyURLStringIdentity(rawPath)
        }

        guard rawPath.hasPrefix("/") || rawPath.hasPrefix("~") else {
            return .rejectedVirtualOrRemote(
                rawPath: rawPath,
                reason: "Relative or virtual path cannot be analyzed as a local directory"
            )
        }

        let expanded = rawPath.hasPrefix("~")
            ? NSString(string: rawPath).expandingTildeInPath
            : rawPath
        guard expanded.hasPrefix("/") else {
            return .rejectedVirtualOrRemote(
                rawPath: rawPath,
                reason: "Expanded path is not an absolute local filesystem path"
            )
        }

        let localURL = URL(fileURLWithPath: expanded, isDirectory: true)
        return .localDirectory(localURL)
    }

    nonisolated private static func classifyURLStringIdentity(
        _ rawPath: String
    ) -> FolderAnalysisTargetIdentity {
        guard let components = URLComponents(string: rawPath),
            let scheme = components.scheme?.lowercased()
        else {
            return .rejectedVirtualOrRemote(
                rawPath: rawPath,
                reason: "Malformed URL cannot be analyzed as a local directory"
            )
        }

        if components.queryItems?.contains(where: { $0.name.lowercased() == "subpath" }) == true {
            return .rejectedVirtualOrRemote(
                rawPath: rawPath,
                reason: "Archive virtual subpath cannot be analyzed as a local directory"
            )
        }

        guard scheme == "file" else {
            return .rejectedVirtualOrRemote(
                rawPath: rawPath,
                reason: "Non-local scheme '\(scheme)://' is not supported for local directory analysis"
            )
        }

        if let host = components.host, !host.isEmpty, host.lowercased() != "localhost" {
            return .rejectedVirtualOrRemote(
                rawPath: rawPath,
                reason: "Remote file authority '\(host)' is not a local directory"
            )
        }

        guard let url = components.url,
            AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(url),
            url.path.hasPrefix("/")
        else {
            return .rejectedVirtualOrRemote(
                rawPath: rawPath,
                reason: "Non-local file URL authority is not supported"
            )
        }

        let localURL = URL(fileURLWithPath: url.path, isDirectory: true)
        return .localDirectory(localURL)
    }

    /// Reads single-inode `stat` / `statfs` metadata without enumerating directory children.
    nonisolated package static func loadLightweightMetadata(
        for item: DiskItemInfo,
        identity: FolderAnalysisTargetIdentity
    ) -> FolderLightweightMetadata {
        guard case .localDirectory(let url) = identity else {
            return .unanalyzedPlaceholder(modificationDate: item.modificationDate)
        }

        let path = url.path
        var statBuf = stat()
        guard stat(path, &statBuf) == 0 else {
            return .unanalyzedPlaceholder(modificationDate: item.modificationDate)
        }

        let modDate = Date(timeIntervalSince1970: TimeInterval(statBuf.st_mtimespec.tv_sec))
        let permsText = String(format: "%04o", Int(statBuf.st_mode & 0o7777))

        let ownerName: String
        if let pw = getpwuid(statBuf.st_uid), let name = pw.pointee.pw_name {
            ownerName = String(cString: name)
        } else {
            ownerName = "--"
        }

        let groupName: String
        if let grp = getgrgid(statBuf.st_gid), let gname = grp.pointee.gr_name {
            groupName = String(cString: gname)
        } else {
            groupName = "--"
        }

        var sfs = statfs()
        let fsName: String
        if statfs(path, &sfs) == 0 {
            let rawFs = withUnsafePointer(to: &sfs.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                    String(cString: $0)
                }
            }
            fsName = rawFs.lowercased() == "apfs" ? "APFS" : (rawFs.isEmpty ? "--" : rawFs)
        } else {
            fsName = "--"
        }

        return FolderLightweightMetadata(
            modificationDate: item.modificationDate ?? modDate,
            fileSystemName: fsName,
            posixPermissions: permsText,
            ownerName: ownerName,
            groupName: groupName
        )
    }

    // MARK: - Default Validated Local Directory Scanner

    nonisolated package static let defaultScanner: DirectoryStatsScanner = { targetIdentity, cancellationBox in
        guard case .localDirectory(let targetURL) = targetIdentity else {
            throw FolderAnalysisError.rejectedNonLocalTarget(
                "Target is not a valid local directory"
            )
        }

        if cancellationBox.isCancelled || Task.isCancelled {
            throw CancellationError()
        }

        try validateLocalDirectoryReadable(at: targetURL)

        let (size, subfolders, files, dist) = await FolderMediaArtboardView.calculateFolderStats(
            at: targetURL.path,
            maxDepth: 16,
            cancellationBox: cancellationBox
        )

        if cancellationBox.isCancelled || Task.isCancelled {
            throw CancellationError()
        }

        let entries = dist.map {
            FolderDistributionEntry(category: $0.category, count: $0.count, sizeBytes: $0.sizeBytes)
        }
        return FolderAnalysisSnapshot(
            totalSizeBytes: size,
            subfolderCount: subfolders,
            fileCount: files,
            distribution: entries
        )
    }

    nonisolated private static func validateLocalDirectoryReadable(at targetURL: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
            throw FolderAnalysisError.targetDoesNotExist(targetURL.path)
        }
        guard isDir.boolValue else {
            throw FolderAnalysisError.targetNotDirectory(targetURL.path)
        }

        guard let dirStream = Darwin.opendir(targetURL.path) else {
            let err = errno
            if err == EACCES || err == EPERM {
                throw FolderAnalysisError.targetAccessDenied(targetURL.path)
            }
            if err == ENOENT {
                throw FolderAnalysisError.targetDoesNotExist(targetURL.path)
            }
            throw FolderAnalysisError.scanFailed(String(cString: strerror(err)))
        }
        Darwin.closedir(dirStream)
    }
}
