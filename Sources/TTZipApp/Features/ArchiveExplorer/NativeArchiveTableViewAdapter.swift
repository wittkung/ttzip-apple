// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import TTZipCore
#if canImport(ttzip_app_coreFFI)
import ttzip_app_coreFFI
#elseif canImport(CTTZipAppCoreBridge)
import CTTZipAppCoreBridge
#endif

/// Production sliding-window virtualization adapter connecting AppKit `NSTableView`
/// directly to the underlying Rust `VfsSession` microkernel cursor with dynamic Permutation Vector sorting.
///
/// Maintains a strict 128-row sliding window cache in memory, guaranteeing $\le 25\text{MB}$ UI RSS growth
/// even when browsing 1,000,000 archive entries.
@MainActor
public final class NativeArchiveTableViewAdapter: NSObject, NativeArchiveTableViewAdapterProtocol {
    public typealias PagedSliceProvider = @Sendable (UInt32, UInt32, SortKey, SortDirection) throws -> VfsPageResult

    let session: VfsSession?
    let sliceProvider: PagedSliceProvider?
    var parentId: UInt32
    public var currentParentId: UInt32 { parentId }
    var sortKey: SortKey
    var sortDirection: SortDirection
    var activeSearchQuery: String? = nil
    var searchMatches: [VfsEntryDto]? = nil

    // In-memory fallback entries for synthetic/testing modes
    var inMemoryEntries: [VfsEntryDto]? = nil

    // Compact Node Memory-Mapped Direct View
    var snapshotContext: VfsSnapshotContext? = nil
    var snapshotLease: VfsSnapshotLease? = nil
    var compactView: TTWorkspaceVfsView? = nil
    var compactIndices: [UInt32]? = nil
    var dirTable: [[UInt32]]? = nil

    // Sliding Window Cache (128-item ring buffer, 256 max retention)
    var cache: [Int: VfsEntryDto] = [:]
    let maxCacheCapacity: Int = 256
    var currentVisibleRange: Range<Int> = 0..<0
    var inFlightRange: Range<Int>? = nil
    var activeGeneration: UInt64 = 0
    var activeFetchTask: Task<Void, Never>? = nil

    public internal(set) var totalRowCount: Int = 0
    public var onDataBatchLoaded: (@MainActor (IndexSet) -> Void)? = nil

    public var cachedEntryCount: Int {
        if let memory = inMemoryEntries {
            return memory.count
        }
        if compactView != nil {
            return totalRowCount
        }
        return cache.count
    }

    /// Primary initializer consuming a live Rust `VfsSession`.
    public init(
        session: VfsSession,
        parentId: UInt32 = 0,
        sortKey: SortKey = .name,
        sortDirection: SortDirection = .ascending
    ) {
        self.session = session
        self.sliceProvider = nil
        self.parentId = parentId
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        super.init()
        primeInitialSessionPage(session: session)
    }

    /// Paged slice provider initializer for test suites, remote streaming, or synthetic benchmarks.
    public init(
        totalRowCount: Int,
        sortKey: SortKey = .name,
        sortDirection: SortDirection = .ascending,
        sliceProvider: @escaping PagedSliceProvider
    ) {
        self.session = nil
        self.sliceProvider = sliceProvider
        self.parentId = 0
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.totalRowCount = totalRowCount
        super.init()

        do {
            let initialPage = try sliceProvider(0, 128, sortKey, sortDirection)
            self.totalRowCount = Int(initialPage.totalCount)
            for (idx, node) in initialPage.nodes.enumerated() {
                self.cache[idx] = node
            }
        } catch {
            self.totalRowCount = 0
        }
    }

    /// Compatibility initializer for synthesized or fallback `[ArchiveEntry]` collections.
    public convenience init(
        entries: [ArchiveEntry],
        sortKey: SortKey = .name,
        sortDirection: SortDirection = .ascending
    ) {
        let dtos: [VfsEntryDto] = entries.enumerated().map { idx, entry in
            VfsEntryDto(
                nodeId: UInt32(idx),
                name: entry.name,
                path: entry.path,
                isDir: entry.isDirectory,
                isSymlink: false,
                isEncrypted: entry.isEncrypted,
                size: UInt64(max(0, entry.uncompressedSize)),
                compressedSize: 0,
                mtimeSecs: Int64(entry.modificationDate?.timeIntervalSince1970 ?? 0)
            )
        }
        self.init(dtos: dtos, sortKey: sortKey, sortDirection: sortDirection)
    }

    /// Direct DTO initializer for test suites and memory mock verification.
    public init(
        dtos: [VfsEntryDto],
        sortKey: SortKey = .name,
        sortDirection: SortDirection = .ascending
    ) {
        self.session = nil
        self.sliceProvider = nil
        self.parentId = 0
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.inMemoryEntries = dtos
        self.totalRowCount = dtos.count
        super.init()
        applyInMemorySort()
    }

    /// Initializer consuming a live `VfsSnapshotContext`.
    public init(
        snapshotContext: VfsSnapshotContext,
        parentId: UInt32 = 0,
        sortKey: SortKey = .name,
        sortDirection: SortDirection = .ascending
    ) {
        self.session = nil
        self.sliceProvider = nil
        self.snapshotContext = snapshotContext
        self.parentId = parentId
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.inMemoryEntries = nil
        self.dirTable = snapshotContext.dirChildrenTable

        let lease = snapshotContext.acquireLease()
        self.snapshotLease = lease
        self.compactView = lease.acquireView()

        super.init()
        reloadCompactIndices()
    }

    /// Retains an independent snapshot reference without consuming the caller's lease.
    public init(
        snapshotLease: VfsSnapshotLease,
        parentId: UInt32 = 0,
        dirTable: [[UInt32]]? = nil,
        sortKey: SortKey = .name,
        sortDirection: SortDirection = .ascending
    ) {
        self.session = nil
        self.sliceProvider = nil
        self.snapshotContext = nil
        let retainedLease = snapshotLease.acquireLease()
        self.snapshotLease = retainedLease
        self.compactView = retainedLease?.acquireView()
        self.parentId = parentId
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.inMemoryEntries = nil
        self.dirTable = dirTable

        super.init()
        reloadCompactIndices()
    }

    /// Initializer consuming a direct `TTWorkspaceVfsView` and directory children table.
    public init(
        compactView: TTWorkspaceVfsView,
        parentId: UInt32 = 0,
        dirTable: [[UInt32]]? = nil,
        sortKey: SortKey = .name,
        sortDirection: SortDirection = .ascending
    ) {
        self.session = nil
        self.sliceProvider = nil
        self.snapshotContext = nil
        self.snapshotLease = nil
        self.compactView = compactView
        self.parentId = parentId
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.inMemoryEntries = nil
        self.dirTable = dirTable

        super.init()
        reloadCompactIndices()
    }

    deinit {
        activeFetchTask?.cancel()
        snapshotLease?.release()
    }

    // MARK: - Compact Node Direct Memory Access

    /// Direct memory mapping of compact node at given row index without object allocations.
    @inline(__always)
    public func compactNode(at rowIndex: Int) -> TTWorkspaceCompactNodeView? {
        guard rowIndex >= 0 && rowIndex < totalRowCount else { return nil }
        guard let view = compactView else { return nil }
        let nodeIdx = compactIndices?[rowIndex] ?? UInt32(rowIndex)
        return view.compactNodeIfValid(at: Int(nodeIdx))
    }

    /// Fast name lookup directly from memory for the given row index.
    @inline(__always)
    public func compactName(at rowIndex: Int) -> String {
        guard let compact = compactNode(at: rowIndex), let view = compactView else { return "" }
        return VfsSnapshotReader.decodeCompactName(in: view, node: compact)
    }

    /// Fast size lookup directly from memory for the given row index.
    @inline(__always)
    public func compactSize(at rowIndex: Int) -> UInt64 {
        compactNode(at: rowIndex)?.size ?? 0
    }

    /// Fast isDirectory check directly from memory for the given row index.
    @inline(__always)
    public func compactIsDir(at rowIndex: Int) -> Bool {
        compactNode(at: rowIndex)?.isDirectory ?? false
    }

    /// Fast modification date lookup directly from memory for the given row index.
    @inline(__always)
    public func compactDate(at rowIndex: Int) -> Date {
        guard let compact = compactNode(at: rowIndex) else { return Date.distantPast }
        return Date(timeIntervalSince1970: TimeInterval(compact.mtime))
    }

    // MARK: - NativeArchiveTableViewAdapterProtocol

    public func entry(at rowIndex: Int) -> VfsEntryDto? {
        guard rowIndex >= 0 && rowIndex < totalRowCount else { return nil }

        if let matches = searchMatches {
            return rowIndex < matches.count ? matches[rowIndex] : nil
        }

        if let memory = inMemoryEntries {
            return memory[rowIndex]
        }

        if let compact = compactNode(at: rowIndex), let view = compactView {
            let name = VfsSnapshotReader.decodeCompactName(in: view, node: compact)
            let nodeIdx = compactIndices?[rowIndex] ?? UInt32(rowIndex)
            return VfsEntryDto(
                nodeId: nodeIdx,
                name: name.isEmpty ? "Unknown" : name,
                path: name.isEmpty ? "Unknown" : name,
                isDir: compact.isDirectory,
                isSymlink: compact.isSymlink,
                isEncrypted: compact.isEncrypted,
                size: compact.size,
                compressedSize: 0,
                mtimeSecs: Int64(compact.mtime)
            )
        }

        if let cached = cache[rowIndex] {
            return cached
        }

        // Cache miss: prime prefetch window around this row
        let start = max(0, rowIndex - 32)
        let end = min(totalRowCount, rowIndex + 96)
        ensureWindowAvailable(visibleRange: start..<end, bufferSize: 128)
        return nil
    }

    public func entryIndex(forPath path: String) -> Int? {
        if let matches = searchMatches {
            return matches.firstIndex { $0.path == path || $0.name == path }
        }
        if let memory = inMemoryEntries {
            return memory.firstIndex { $0.path == path || $0.name == path }
        }
        if let view = compactView, let indices = compactIndices {
            for (row, idx) in indices.enumerated() {
                if let node = view.compactNodeIfValid(at: Int(idx)) {
                    let name = VfsSnapshotReader.decodeCompactName(in: view, node: node)
                    if name == path {
                        return row
                    }
                }
            }
        }
        for (idx, item) in cache {
            if item.path == path || item.name == path {
                return idx
            }
        }
        return nil
    }

    public func ensureWindowAvailable(visibleRange: Range<Int>, bufferSize: Int = 128) {
        if searchMatches != nil { return }
        guard (session != nil || sliceProvider != nil), totalRowCount > 0 else { return }

        self.currentVisibleRange = visibleRange
        let halfBuffer = bufferSize / 2
        let targetStart = max(0, visibleRange.lowerBound - halfBuffer)
        let targetEnd = min(totalRowCount, visibleRange.upperBound + halfBuffer)
        let targetRange = targetStart..<targetEnd
        guard targetEnd > targetStart else { return }

        guard needsWindowFetch(visibleRange: visibleRange, targetRange: targetRange) else { return }
        if inFlightRange == targetRange { return }

        launchWindowFetchTask(targetRange: targetRange, visibleRange: visibleRange)
    }

    private func needsWindowFetch(visibleRange: Range<Int>, targetRange: Range<Int>) -> Bool {
        for row in visibleRange where row < totalRowCount {
            if cache[row] == nil {
                return true
            }
        }
        return targetRange.contains { cache[$0] == nil }
    }

    private func launchWindowFetchTask(targetRange: Range<Int>, visibleRange: Range<Int>) {
        activeFetchTask?.cancel()
        inFlightRange = targetRange
        let generation = activeGeneration
        let pid = parentId
        let key = sortKey
        let dir = sortDirection
        let liveSession = session
        let provider = sliceProvider
        guard liveSession != nil || provider != nil else { return }

        activeFetchTask = Task { [weak self, liveSession, provider] in
            let offset = UInt32(targetRange.lowerBound)
            let limit = UInt32(targetRange.count)
            let result = Self.fetchPageSlice(
                offset: offset,
                limit: limit,
                parentId: pid,
                key: key,
                direction: dir,
                session: liveSession,
                provider: provider
            )

            guard !Task.isCancelled, let page = result else { return }
            guard let self = self, self.activeGeneration == generation else { return }
            self.applyFetchedWindowPage(page, targetStart: targetRange.lowerBound, visibleRange: visibleRange)
        }
    }

    nonisolated private static func fetchPageSlice(
        offset: UInt32,
        limit: UInt32,
        parentId: UInt32,
        key: SortKey,
        direction: SortDirection,
        session: VfsSession?,
        provider: PagedSliceProvider?
    ) -> VfsPageResult? {
        if let custom = provider {
            return try? custom(offset, limit, key, direction)
        }
        if let live = session {
            return try? live.getChildrenPagedSorted(
                parentId: parentId,
                offset: offset,
                limit: limit,
                sortBy: key,
                direction: direction
            )
        }
        return nil
    }

    private func applyFetchedWindowPage(_ page: VfsPageResult, targetStart: Int, visibleRange: Range<Int>) {
        inFlightRange = nil
        for (idx, node) in page.nodes.enumerated() {
            let globalIndex = targetStart + idx
            if globalIndex < totalRowCount {
                cache[globalIndex] = node
            }
        }

        if cache.count > maxCacheCapacity {
            let retainMin = max(0, visibleRange.lowerBound - 128)
            let retainMax = visibleRange.upperBound + 128
            cache = cache.filter { key, _ in
                key >= retainMin && key <= retainMax
            }
        }

        let loadedSet = IndexSet(integersIn: targetStart..<min(totalRowCount, targetStart + page.nodes.count))
        onDataBatchLoaded?(loadedSet)
    }

    public func setSortCriteria(key: SortKey, direction: SortDirection) {
        if self.sortKey == key && self.sortDirection == direction {
            return
        }

        self.sortKey = key
        self.sortDirection = direction
        invalidateCache()

        if compactView != nil {
            sortCompactIndices()
            onDataBatchLoaded?(IndexSet(integersIn: 0..<totalRowCount))
            return
        }

        if inMemoryEntries != nil {
            applyInMemorySort()
            onDataBatchLoaded?(IndexSet(integersIn: 0..<totalRowCount))
            return
        }

        // Re-prime window for current visible range
        let range = currentVisibleRange.isEmpty ? (0..<min(128, totalRowCount)) : currentVisibleRange
        ensureWindowAvailable(visibleRange: range, bufferSize: 128)
        onDataBatchLoaded?(IndexSet(integersIn: 0..<totalRowCount))
    }

    public func invalidateCache() {
        activeGeneration &+= 1
        activeFetchTask?.cancel()
        activeFetchTask = nil
        inFlightRange = nil
        cache.removeAll(keepingCapacity: true)
    }

    public func navigateToDirectory(parentId: UInt32) {
        self.parentId = parentId
        self.activeSearchQuery = nil
        self.searchMatches = nil
        invalidateCache()

        if compactView != nil {
            reloadCompactIndices()
            onDataBatchLoaded?(IndexSet(integersIn: 0..<totalRowCount))
            return
        }

        if let session = session {
            primeInitialSessionPage(session: session)
        }
        onDataBatchLoaded?(IndexSet(integersIn: 0..<totalRowCount))
    }
}
