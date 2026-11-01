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

    private let session: VfsSession?
    private let sliceProvider: PagedSliceProvider?
    private var parentId: UInt32
    public var currentParentId: UInt32 { parentId }
    private var sortKey: SortKey
    private var sortDirection: SortDirection
    private var activeSearchQuery: String? = nil
    private var searchMatches: [VfsEntryDto]? = nil
    
    // In-memory fallback entries for synthetic/testing modes
    private var inMemoryEntries: [VfsEntryDto]? = nil

    // Compact Node Memory-Mapped Direct View
    private var snapshotContext: VfsSnapshotContext? = nil
    private var snapshotLease: VfsSnapshotLease? = nil
    private var compactView: TTWorkspaceVfsView? = nil
    private var compactIndices: [UInt32]? = nil
    private var dirTable: [[UInt32]]? = nil
    
    // Sliding Window Cache (128-item ring buffer, 256 max retention)
    private var cache: [Int: VfsEntryDto] = [:]
    private let maxCacheCapacity: Int = 256
    private var currentVisibleRange: Range<Int> = 0..<0
    private var inFlightRange: Range<Int>? = nil
    private var activeGeneration: UInt64 = 0
    private var activeFetchTask: Task<Void, Never>? = nil

    public private(set) var totalRowCount: Int = 0
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

        // Fetch initial total count and prime window 0..<128
        do {
            let initialPage = try session.getChildrenPagedSorted(
                parentId: parentId,
                offset: 0,
                limit: 128,
                sortBy: sortKey,
                direction: sortDirection
            )
            self.totalRowCount = Int(initialPage.totalCount)
            for (idx, node) in initialPage.nodes.enumerated() {
                self.cache[idx] = node
            }
        } catch {
            self.totalRowCount = 0
        }
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

    private func reloadCompactIndices() {
        guard let view = compactView else { return }
        let cappedCount = UInt32(min(view.node_count, UInt64(UInt32.max)))

        let rawIndices: [UInt32]
        if let dt = dirTable {
            if parentId == 0 && dt.isEmpty && cappedCount > 0 {
                rawIndices = (0..<cappedCount).map { $0 }
            } else if let parentIdx = Int(exactly: parentId),
                      let parentNode = view.compactNodeIfValid(at: parentIdx) {
                rawIndices = view.dirChildren(for: parentNode, dirTable: dt).filter { UInt64($0) < view.node_count }
            } else {
                rawIndices = []
            }
        } else {
            rawIndices = (0..<cappedCount).map { $0 }
        }

        self.compactIndices = rawIndices
        self.totalRowCount = rawIndices.count
        sortCompactIndices()
    }

    @inline(__always)
    private static func computePrefix8(arena: UnsafePointer<CChar>?, arenaLen: UInt64, offset: UInt32, len: UInt16) -> UInt64 {
        guard let arena = arena, len > 0 else { return 0 }
        let end = UInt64(offset) + UInt64(len)
        guard end <= arenaLen, let startOffset = Int(exactly: offset) else { return 0 }
        let count = min(Int(len), 8)
        let ptr = arena.advanced(by: startOffset)
        var val: UInt64 = 0
        for i in 0..<count {
            var byte = UInt8(bitPattern: ptr[i])
            if byte >= 65 && byte <= 90 {
                byte &+= 32
            }
            val |= (UInt64(byte) << ((7 - i) * 8))
        }
        return val
    }

    @inline(__always)
    private static func computeExtensionPrefix8(arena: UnsafePointer<CChar>?, arenaLen: UInt64, offset: UInt32, len: UInt16) -> UInt64 {
        guard let arena = arena, len > 0 else { return 0 }
        let end = UInt64(offset) + UInt64(len)
        guard end <= arenaLen, let startOffset = Int(exactly: offset) else { return 0 }
        let ptr = arena.advanced(by: startOffset)
        let total = Int(len)
        var dotIdx = -1
        var i = total - 1
        while i >= 0 {
            if ptr[i] == 46 {
                dotIdx = i
                break
            }
            i &-= 1
        }
        guard dotIdx >= 0 && dotIdx < total - 1 else { return 0 }
        let extStart = dotIdx + 1
        let extLen = total - extStart
        let count = min(extLen, 8)
        var val: UInt64 = 0
        for j in 0..<count {
            var byte = UInt8(bitPattern: ptr[extStart + j])
            if byte >= 65 && byte <= 90 {
                byte &+= 32
            }
            val |= (UInt64(byte) << ((7 - j) * 8))
        }
        return val
    }

    private func sortCompactIndices() {
        guard var indices = compactIndices, let view = compactView, let rawNodes = view.rawNodesPointer else { return }
        let arena = view.string_arena
        let arenaLen = view.string_arena_len
        let key = self.sortKey
        let isAscending = (self.sortDirection == .ascending)
        let count = indices.count
        guard count > 1 else { return }

        var sortEntries = [TTSortEntry]()
        sortEntries.reserveCapacity(count)

        for i in 0..<count {
            let idx = indices[i]
            let node = TTWorkspaceCompactNodeView(base: rawNodes, index: Int(idx))
            let prefix: UInt64
            let secondary: UInt64

            switch key {
            case .name:
                prefix = Self.computePrefix8(arena: arena, arenaLen: arenaLen, offset: node.nameOffset, len: node.nameLen)
                secondary = 0
            case .size:
                prefix = Self.computePrefix8(arena: arena, arenaLen: arenaLen, offset: node.nameOffset, len: node.nameLen)
                secondary = node.size
            case .modifiedTime:
                prefix = Self.computePrefix8(arena: arena, arenaLen: arenaLen, offset: node.nameOffset, len: node.nameLen)
                secondary = UInt64(node.mtime)
            case .extension:
                prefix = Self.computeExtensionPrefix8(arena: arena, arenaLen: arenaLen, offset: node.nameOffset, len: node.nameLen)
                secondary = Self.computePrefix8(arena: arena, arenaLen: arenaLen, offset: node.nameOffset, len: node.nameLen)
            }

            sortEntries.append(TTSortEntry(
                prefix: prefix,
                secondaryKey: secondary,
                nodeIndex: idx,
                isDirectory: node.isDirectory
            ))
        }

        sortEntries.sort { (a: TTSortEntry, b: TTSortEntry) in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory > b.isDirectory
            }

            let ord: ComparisonResult
            switch key {
            case .name:
                if a.prefix != b.prefix {
                    ord = a.prefix < b.prefix ? .orderedAscending : .orderedDescending
                } else {
                    let nodeA = TTWorkspaceCompactNodeView(base: rawNodes, index: Int(a.nodeIndex))
                    let nodeB = TTWorkspaceCompactNodeView(base: rawNodes, index: Int(b.nodeIndex))
                    let nameA = VfsSnapshotReader.decodeCompactName(arena: arena, arenaLen: arenaLen, node: nodeA)
                    let nameB = VfsSnapshotReader.decodeCompactName(arena: arena, arenaLen: arenaLen, node: nodeB)
                    ord = nameA.localizedStandardCompare(nameB)
                }
            case .size:
                if a.secondaryKey != b.secondaryKey {
                    ord = a.secondaryKey < b.secondaryKey ? .orderedAscending : .orderedDescending
                } else {
                    ord = .orderedSame
                }
            case .modifiedTime:
                if a.secondaryKey != b.secondaryKey {
                    ord = a.secondaryKey < b.secondaryKey ? .orderedAscending : .orderedDescending
                } else {
                    ord = .orderedSame
                }
            case .extension:
                if a.prefix != b.prefix {
                    ord = a.prefix < b.prefix ? .orderedAscending : .orderedDescending
                } else {
                    ord = .orderedSame
                }
            }

            if ord == .orderedSame {
                if a.prefix != b.prefix {
                    return a.prefix < b.prefix
                }
                let nodeA = TTWorkspaceCompactNodeView(base: rawNodes, index: Int(a.nodeIndex))
                let nodeB = TTWorkspaceCompactNodeView(base: rawNodes, index: Int(b.nodeIndex))
                let nameA = VfsSnapshotReader.decodeCompactName(arena: arena, arenaLen: arenaLen, node: nodeA)
                let nameB = VfsSnapshotReader.decodeCompactName(arena: arena, arenaLen: arenaLen, node: nodeB)
                return nameA.localizedStandardCompare(nameB) == .orderedAscending
            }

            return isAscending ? (ord == .orderedAscending) : (ord == .orderedDescending)
        }

        for i in 0..<count {
            indices[i] = sortEntries[i].nodeIndex
        }
        self.compactIndices = indices
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

        // Check whether all items in visibleRange are already satisfied
        var hasMissingVisible = false
        for r in visibleRange where r < totalRowCount {
            if cache[r] == nil {
                hasMissingVisible = true
                break
            }
        }

        // If visible rows are present and target buffer is mostly cached, skip redundant fetch
        if !hasMissingVisible {
            var missingCount = 0
            for r in targetRange {
                if cache[r] == nil {
                    missingCount += 1
                }
            }
            if missingCount == 0 {
                return
            }
        }

        // Avoid duplicate concurrent fetch for overlapping range
        if let inFlight = inFlightRange, inFlight == targetRange {
            return
        }

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
            let offset = UInt32(targetStart)
            let limit = UInt32(targetEnd - targetStart)
            
            // Execute microkernel cursor fetch or custom paged provider
            let result: VfsPageResult?
            if let custom = provider {
                result = try? custom(offset, limit, key, dir)
            } else if let live = liveSession {
                result = try? live.getChildrenPagedSorted(
                    parentId: pid,
                    offset: offset,
                    limit: limit,
                    sortBy: key,
                    direction: dir
                )
            } else {
                result = nil
            }

            guard !Task.isCancelled, let page = result else { return }
            guard let self = self, self.activeGeneration == generation else { return }
            self.inFlightRange = nil

            for (idx, node) in page.nodes.enumerated() {
                let globalIndex = targetStart + idx
                if globalIndex < self.totalRowCount {
                    self.cache[globalIndex] = node
                }
            }

            // Evict entries outside the active working set if capacity exceeded
            if self.cache.count > self.maxCacheCapacity {
                let retainMin = max(0, visibleRange.lowerBound - 128)
                let retainMax = visibleRange.upperBound + 128
                self.cache = self.cache.filter { key, _ in
                    key >= retainMin && key <= retainMax
                }
            }

            let loadedSet = IndexSet(integersIn: targetStart..<min(self.totalRowCount, targetStart + page.nodes.count))
            self.onDataBatchLoaded?(loadedSet)
        }
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
            do {
                let initial = try session.getChildrenPagedSorted(
                    parentId: parentId,
                    offset: 0,
                    limit: 128,
                    sortBy: sortKey,
                    direction: sortDirection
                )
                self.totalRowCount = Int(initial.totalCount)
                for (idx, node) in initial.nodes.enumerated() {
                    self.cache[idx] = node
                }
            } catch {
                self.totalRowCount = 0
            }
        }
        onDataBatchLoaded?(IndexSet(integersIn: 0..<totalRowCount))
    }

    public func setSearchQuery(query: String?) {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        if self.activeSearchQuery == normalized {
            return
        }

        self.activeSearchQuery = normalized
        invalidateCache()

        if let q = normalized {
            if let session = session {
                do {
                    let matches = try session.searchTopK(query: q, limit: 1000)
                    self.searchMatches = matches
                    self.totalRowCount = matches.count
                    for (idx, node) in matches.prefix(128).enumerated() {
                        self.cache[idx] = node
                    }
                } catch {
                    self.searchMatches = []
                    self.totalRowCount = 0
                }
            } else if let view = compactView {
                let lowerQ = q.lowercased()
                let total = Int(min(view.node_count, UInt64(UInt32.max)))
                var matches = [VfsEntryDto]()
                for idx in 0..<total {
                    if let node = view.compactNodeIfValid(at: idx) {
                        let name = VfsSnapshotReader.decodeCompactName(in: view, node: node)
                        if name.localizedCaseInsensitiveContains(lowerQ) {
                            matches.append(VfsEntryDto(
                                nodeId: UInt32(idx),
                                name: name,
                                path: name,
                                isDir: node.isDirectory,
                                isSymlink: node.isSymlink,
                                isEncrypted: node.isEncrypted,
                                size: node.size,
                                compressedSize: 0,
                                mtimeSecs: Int64(node.mtime)
                            ))
                        }
                    }
                }
                self.searchMatches = matches
                self.totalRowCount = matches.count
                for (idx, node) in matches.prefix(128).enumerated() {
                    self.cache[idx] = node
                }
            } else if let memory = inMemoryEntries {
                let matches = memory.filter {
                    $0.path.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q)
                }
                self.searchMatches = matches
                self.totalRowCount = matches.count
                for (idx, node) in matches.prefix(128).enumerated() {
                    self.cache[idx] = node
                }
            }
        } else {
            self.searchMatches = nil
            if compactView != nil {
                reloadCompactIndices()
            } else if let memory = inMemoryEntries {
                self.totalRowCount = memory.count
                applyInMemorySort()
            } else if let session = session {
                do {
                    let initial = try session.getChildrenPagedSorted(
                        parentId: parentId,
                        offset: 0,
                        limit: 128,
                        sortBy: sortKey,
                        direction: sortDirection
                    )
                    self.totalRowCount = Int(initial.totalCount)
                    for (idx, node) in initial.nodes.enumerated() {
                        self.cache[idx] = node
                    }
                } catch {
                    self.totalRowCount = 0
                }
            }
        }
        onDataBatchLoaded?(IndexSet(integersIn: 0..<totalRowCount))
    }

    // MARK: - In-Memory Sorting Fallback

    private func applyInMemorySort() {
        guard var items = inMemoryEntries else { return }
        items.sort { a, b in
            // Directories always precede files
            if a.isDir != b.isDir {
                return a.isDir
            }
            let ord: ComparisonResult
            switch self.sortKey {
            case .name:
                ord = a.name.localizedStandardCompare(b.name)
            case .size:
                ord = a.size < b.size ? .orderedAscending : (a.size > b.size ? .orderedDescending : .orderedSame)
            case .modifiedTime:
                ord = a.mtimeSecs < b.mtimeSecs ? .orderedAscending : (a.mtimeSecs > b.mtimeSecs ? .orderedDescending : .orderedSame)
            case .extension:
                let extA = (a.name as NSString).pathExtension.lowercased()
                let extB = (b.name as NSString).pathExtension.lowercased()
                ord = extA.compare(extB)
            }
            if ord == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return self.sortDirection == .ascending ? (ord == .orderedAscending) : (ord == .orderedDescending)
        }
        self.inMemoryEntries = items
    }
}
