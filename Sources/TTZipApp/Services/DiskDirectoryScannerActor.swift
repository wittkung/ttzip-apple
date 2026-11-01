// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os
import TTZipCore
import TTZipUI
import TTZipPreviewKit

extension DiskSortOption: @unchecked Sendable {}

/// Stage-by-stage timing breakdown for directory navigation and scanning.
public struct DirectoryNavigationStageMetrics: Sendable, Equatable {
    public let directoryPath: String
    public let scopeID: String
    public let generation: UInt64
    public let selectionToScanStartMs: Double
    public let permissionCheckMs: Double
    public let scanMs: Double
    public let sortMs: Double
    public let totalMs: Double
    public let itemCount: Int
    public let isCacheHit: Bool

    public init(
        directoryPath: String,
        scopeID: String,
        generation: UInt64,
        selectionToScanStartMs: Double,
        permissionCheckMs: Double,
        scanMs: Double,
        sortMs: Double,
        totalMs: Double,
        itemCount: Int,
        isCacheHit: Bool
    ) {
        self.directoryPath = directoryPath
        self.scopeID = scopeID
        self.generation = generation
        self.selectionToScanStartMs = selectionToScanStartMs
        self.permissionCheckMs = permissionCheckMs
        self.scanMs = scanMs
        self.sortMs = sortMs
        self.totalMs = totalMs
        self.itemCount = itemCount
        self.isCacheHit = isCacheHit
    }
}

/// Dedicated service executing high-throughput non-blocking disk directory scans.
/// Delegated directly to the Rust engine for concurrent POSIX scanning and pre-sorted summaries,
/// with automatic security-scoped volume authorization, generational cancellation, and resilient FileManager fallback.
public actor DiskDirectoryScanner {
    public static let shared = DiskDirectoryScanner()

    private struct CachedDirectoryEntry {
        let items: [DiskItemInfo]
        let sortOption: DiskSortOption
        let modificationDate: Date?
        let isReadable: Bool
    }

    private var activeGenerations: [String: UInt64] = [:]
    private var inFlightTasks: [String: Task<[DiskItemInfo], Error>] = [:]
    private var directoryCache: [String: CachedDirectoryEntry] = [:]
    private var selectionStartUptimes: [String: TimeInterval] = [:]
    private var latestMetricsByScope: [String: DirectoryNavigationStageMetrics] = [:]

    private init() {}

    /// Records the timestamp when a user selects a directory in a given scope/window.
    public func recordSelectionStart(forScope scopeID: String, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        selectionStartUptimes[scopeID] = uptime
    }

    /// Returns the most recent stage latency metrics recorded for `scopeID`.
    public func latestMetrics(forScope scopeID: String) -> DirectoryNavigationStageMetrics? {
        latestMetricsByScope[scopeID]
    }

    /// Returns the current generation counter for `scopeID`.
    public func currentGeneration(forScope scopeID: String) -> UInt64 {
        activeGenerations[scopeID] ?? 0
    }

    /// Cancels any in-flight scan for `scopeID` and advances its generation counter.
    public func cancelScope(_ scopeID: String) {
        let nextGen = (activeGenerations[scopeID] ?? 0) &+ 1
        activeGenerations[scopeID] = nextGen
        inFlightTasks[scopeID]?.cancel()
        inFlightTasks.removeValue(forKey: scopeID)
    }

    /// Invalidates cached scan snapshots for a specific directory URL across all sort options.
    public func invalidateCache(for dirURL: URL) {
        let standardized = dirURL.standardizedFileURL.path
        let prefix = standardized + "::"
        for key in Array(directoryCache.keys) where key.hasPrefix(prefix) {
            directoryCache.removeValue(forKey: key)
        }
    }

    /// Clears all cached directory scan snapshots.
    public func invalidateAllCache() {
        directoryCache.removeAll()
    }

    private func beginGeneration(forScope scopeID: String) -> (generation: UInt64, selectionUptime: TimeInterval?) {
        let nextGen = (activeGenerations[scopeID] ?? 0) &+ 1
        activeGenerations[scopeID] = nextGen
        if let existingTask = inFlightTasks.removeValue(forKey: scopeID) {
            existingTask.cancel()
        }
        let selUptime = selectionStartUptimes.removeValue(forKey: scopeID)
        return (nextGen, selUptime)
    }

    private func registerInFlightTask(_ task: Task<[DiskItemInfo], Error>, forScope scopeID: String, generation: UInt64) {
        guard activeGenerations[scopeID] == generation else {
            task.cancel()
            return
        }
        inFlightTasks[scopeID] = task
    }

    private func finishGeneration(
        forScope scopeID: String,
        generation: UInt64,
        cacheKey: String?,
        cacheEntry: CachedDirectoryEntry?,
        metrics: DirectoryNavigationStageMetrics?
    ) -> Bool {
        guard activeGenerations[scopeID] == generation else {
            return false
        }
        inFlightTasks.removeValue(forKey: scopeID)
        if let cacheKey, let cacheEntry {
            if directoryCache.count >= 128 {
                directoryCache.removeAll(keepingCapacity: true)
            }
            directoryCache[cacheKey] = cacheEntry
        }
        if let metrics {
            latestMetricsByScope[scopeID] = metrics
        }
        return true
    }

    private func cachedEntry(forKey key: String) -> CachedDirectoryEntry? {
        directoryCache[key]
    }

    private func removeCachedEntry(forKey key: String) {
        directoryCache.removeValue(forKey: key)
    }
}

public typealias DiskDirectoryScannerActor = DiskDirectoryScanner

extension DiskDirectoryScanner {

    /// Scans the target directory via the high-performance Rust engine with fallback protection.
    public func scanDirectory(at dirURL: URL) async throws -> [DiskItemInfo] {
        try await scanDirectory(
            at: dirURL,
            sortOption: .nameAsc,
            scopeID: nil,
            bypassCache: true,
            customScanOperation: nil
        )
    }

    /// Scans and sorts the target directory off the main thread and outside the actor serial lock,
    /// supporting per-scope generational cancellation and mtime/permission-validated caching.
    public func scanDirectory(
        at dirURL: URL,
        sortOption: DiskSortOption = .nameAsc,
        scopeID: String? = nil,
        bypassCache: Bool = false,
        customScanOperation: (@Sendable (URL) async throws -> [DiskItemInfo])? = nil
    ) async throws -> [DiskItemInfo] {
        try Task.checkCancellation()

        let effectiveScope = scopeID ?? "transient_\(UUID().uuidString)"
        let (generation, selectionUptime) = beginGeneration(forScope: effectiveScope)
        let startUptime = ProcessInfo.processInfo.systemUptime
        let selectionDeltaMs = selectionUptime.map { max(0, (startUptime - $0) * 1000.0) } ?? 0.0
        let standardizedPath = dirURL.standardizedFileURL.path
        let cacheKey = "\(standardizedPath)::\(sortOption.rawValue)"

        if !bypassCache, customScanOperation == nil,
           let hitItems = try await resolveValidatedCachedItems(
               dirURL: dirURL,
               standardizedPath: standardizedPath,
               cacheKey: cacheKey,
               scopeID: effectiveScope,
               generation: generation,
               selectionUptime: selectionUptime,
               startUptime: startUptime,
               selectionDeltaMs: selectionDeltaMs
           ) {
            return hitItems
        }

        let workerTask = Self.spawnWorkerScanTask(
            dirURL: dirURL,
            sortOption: sortOption,
            customScanOperation: customScanOperation
        )

        registerInFlightTask(
            Task { (try await workerTask.value).items },
            forScope: effectiveScope,
            generation: generation
        )

        return try await withTaskCancellationHandler {
            let output = try await workerTask.value
            let totalMs = max(0, (ProcessInfo.processInfo.systemUptime - (selectionUptime ?? startUptime)) * 1000.0)
            let isStillCurrent = finishGeneration(
                forScope: effectiveScope,
                generation: generation,
                cacheKey: customScanOperation == nil ? cacheKey : nil,
                cacheEntry: customScanOperation == nil
                    ? CachedDirectoryEntry(items: output.items, sortOption: sortOption, modificationDate: output.modDate, isReadable: true)
                    : nil,
                metrics: DirectoryNavigationStageMetrics(
                    directoryPath: standardizedPath,
                    scopeID: effectiveScope,
                    generation: generation,
                    selectionToScanStartMs: selectionDeltaMs,
                    permissionCheckMs: output.permMs,
                    scanMs: output.scanMs,
                    sortMs: output.sortMs,
                    totalMs: totalMs,
                    itemCount: output.items.count,
                    isCacheHit: false
                )
            )
            guard isStillCurrent, !Task.isCancelled else {
                throw CancellationError()
            }
            return output.items
        } onCancel: {
            workerTask.cancel()
        }
    }

    private func resolveValidatedCachedItems(
        dirURL: URL,
        standardizedPath: String,
        cacheKey: String,
        scopeID: String,
        generation: UInt64,
        selectionUptime: TimeInterval?,
        startUptime: TimeInterval,
        selectionDeltaMs: Double
    ) async throws -> [DiskItemInfo]? {
        guard let cached = cachedEntry(forKey: cacheKey) else { return nil }
        let expectedModDate = cached.modificationDate
        let validation = await Task.detached(priority: .userInitiated) {
            Self.validateCacheMetadata(at: dirURL, expectedModificationDate: expectedModDate)
        }.value
        if Task.isCancelled || currentGeneration(forScope: scopeID) != generation {
            throw CancellationError()
        }
        guard validation.isValid else {
            removeCachedEntry(forKey: cacheKey)
            return nil
        }
        let totalMs = max(0, (ProcessInfo.processInfo.systemUptime - (selectionUptime ?? startUptime)) * 1000.0)
        let metrics = DirectoryNavigationStageMetrics(
            directoryPath: standardizedPath,
            scopeID: scopeID,
            generation: generation,
            selectionToScanStartMs: selectionDeltaMs,
            permissionCheckMs: validation.checkMs,
            scanMs: 0.0,
            sortMs: 0.0,
            totalMs: totalMs,
            itemCount: cached.items.count,
            isCacheHit: true
        )
        _ = finishGeneration(
            forScope: scopeID,
            generation: generation,
            cacheKey: nil,
            cacheEntry: nil,
            metrics: metrics
        )
        return cached.items
    }

    private struct WorkerScanOutput: Sendable {
        let items: [DiskItemInfo]
        let modDate: Date?
        let permMs: Double
        let scanMs: Double
        let sortMs: Double
    }

    private nonisolated static func spawnWorkerScanTask(
        dirURL: URL,
        sortOption: DiskSortOption,
        customScanOperation: (@Sendable (URL) async throws -> [DiskItemInfo])?
    ) -> Task<WorkerScanOutput, Error> {
        let sortOptionRaw = sortOption.rawValue
        return Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            let permStart = ProcessInfo.processInfo.systemUptime
            let isVolume = dirURL.path.hasPrefix("/Volumes/")
            let targetURL = await RootFolderAccessManager.shared.canonicalDirectoryURL(for: dirURL)
            let isInternal = (try? targetURL.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) ?? false
            let isExternalVolume = isVolume && !isInternal

            try Task.checkCancellation()

            let hasAccess = await RootFolderAccessManager.shared.ensureAccess(for: dirURL, promptIfMissing: isExternalVolume)
            let lease = await RootFolderAccessManager.shared.acquireLease(for: dirURL)
            defer { lease?.release() }
            let permMs = max(0, (ProcessInfo.processInfo.systemUptime - permStart) * 1000.0)

            try Task.checkCancellation()

            let scanStart = ProcessInfo.processInfo.systemUptime
            let rawItems: [DiskItemInfo]
            if let customScanOperation {
                rawItems = try await customScanOperation(dirURL)
            } else {
                rawItems = try Self.performScanSync(
                    at: dirURL,
                    hasAccess: hasAccess || lease != nil,
                    isExternalVolume: isExternalVolume
                )
            }
            let scanMs = max(0, (ProcessInfo.processInfo.systemUptime - scanStart) * 1000.0)

            try Task.checkCancellation()

            let sortStart = ProcessInfo.processInfo.systemUptime
            let resolvedSort = DiskSortOption(rawValue: sortOptionRaw) ?? .nameAsc
            let sortedItems = Self.sortIfNeeded(rawItems, by: resolvedSort)
            let sortMs = max(0, (ProcessInfo.processInfo.systemUptime - sortStart) * 1000.0)

            try Task.checkCancellation()

            let modDate = (try? dirURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return WorkerScanOutput(items: sortedItems, modDate: modDate, permMs: permMs, scanMs: scanMs, sortMs: sortMs)
        }
    }

    private nonisolated static func validateCacheMetadata(
        at dirURL: URL,
        expectedModificationDate: Date?
    ) -> (isValid: Bool, checkMs: Double) {
        let start = ProcessInfo.processInfo.systemUptime
        let path = dirURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue,
              FileManager.default.isReadableFile(atPath: path) else {
            let ms = max(0, (ProcessInfo.processInfo.systemUptime - start) * 1000.0)
            return (false, ms)
        }
        var freshURL = dirURL
        freshURL.removeAllCachedResourceValues()
        let currentModDate = try? freshURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let ms = max(0, (ProcessInfo.processInfo.systemUptime - start) * 1000.0)
        guard let expectedModificationDate, let currentModDate else {
            return (false, ms)
        }
        return (expectedModificationDate == currentModDate, ms)
    }

    private nonisolated static func sortIfNeeded(
        _ items: [DiskItemInfo],
        by sortOption: DiskSortOption
    ) -> [DiskItemInfo] {
        guard items.count > 1 else { return items }
        if sortOption == .nameAsc && isAlreadySortedByNameAsc(items) {
            return items
        }
        return DiskItemSorter.sort(items, by: sortOption)
    }

    private nonisolated static func isAlreadySortedByNameAsc(_ items: [DiskItemInfo]) -> Bool {
        for i in 0..<(items.count - 1) {
            let lhs = items[i]
            let rhs = items[i + 1]
            if lhs.isDirectory != rhs.isDirectory {
                if !lhs.isDirectory && rhs.isDirectory {
                    return false
                }
                continue
            }
            if lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending {
                return false
            }
        }
        return true
    }

    private nonisolated static func performScanSync(
        at dirURL: URL,
        hasAccess: Bool,
        isExternalVolume: Bool
    ) throws -> [DiskItemInfo] {
        try Task.checkCancellation()
        do {
            let summaries = try TTZipCore.scanDirectory(path: dirURL.path, maxDepth: 1)
            try Task.checkCancellation()
            var mapped: [DiskItemInfo] = []
            mapped.reserveCapacity(summaries.count)
            for summary in summaries {
                try Task.checkCancellation()
                mapped.append(DiskItemInfo(summary: summary))
            }
            return mapped
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            TTLogger.shared.log(
                level: .warning,
                category: .general,
                message: "[DiskDirectoryScanner] Rust scanDirectory failed at \(dirURL.path): \(error). Attempting FileManager fallback."
            )
            return try performFallbackFileManagerScan(
                at: dirURL,
                hasAccess: hasAccess,
                isExternalVolume: isExternalVolume
            )
        }
    }

    private nonisolated static func performFallbackFileManagerScan(
        at dirURL: URL,
        hasAccess: Bool,
        isExternalVolume: Bool
    ) throws -> [DiskItemInfo] {
        do {
            let resourceKeys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey, .creationDateKey]
            let contents = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            )
            var items: [DiskItemInfo] = []
            items.reserveCapacity(contents.count)
            for fileURL in contents {
                try Task.checkCancellation()
                if let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) {
                    items.append(DiskItemInfo(url: fileURL, resourceValues: values))
                } else {
                    items.append(DiskItemInfo(url: fileURL))
                }
            }
            try Task.checkCancellation()
            return items
        } catch is CancellationError {
            throw CancellationError()
        } catch let fmError {
            try Task.checkCancellation()
            return try handleFallbackScanFailure(fmError, at: dirURL, hasAccess: hasAccess, isExternalVolume: isExternalVolume)
        }
    }

    private nonisolated static func handleFallbackScanFailure(
        _ fmError: Error,
        at dirURL: URL,
        hasAccess: Bool,
        isExternalVolume: Bool
    ) throws -> [DiskItemInfo] {
        TTLogger.shared.log(
            level: .error,
            category: .general,
            message: "[DiskDirectoryScanner] FileManager fallback failed at \(dirURL.path): \(fmError)"
        )
        if MillerColumnDirectoryScanner.isAccessDeniedError(fmError) {
            throw CocoaError(.fileReadNoPermission)
        }
        if !hasAccess && isExternalVolume {
            let authURL = URL(string: dirURL.absoluteString + "?subpath=__auth__") ?? dirURL
            return [
                DiskItemInfo(
                    virtualName: "Volume Access Required (Click to authorize)",
                    virtualURL: authURL,
                    isDirectory: false,
                    isArchive: false,
                    sizeText: "Permission Required",
                    rawSizeBytes: 0,
                    kindText: "Access Authorization",
                    isEncryptedLockItem: true
                )
            ]
        }
        throw fmError
    }
}
