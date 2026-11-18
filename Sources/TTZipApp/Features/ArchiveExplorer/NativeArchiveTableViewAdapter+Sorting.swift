// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTZipCore
#if canImport(ttzip_app_coreFFI)
import ttzip_app_coreFFI
#elseif canImport(CTTZipAppCoreBridge)
import CTTZipAppCoreBridge
#endif

// MARK: - Compact Index Sorting & Search Filtering

@MainActor
extension NativeArchiveTableViewAdapter {
    func reloadCompactIndices() {
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
    static func computePrefix8(arena: UnsafePointer<CChar>?, arenaLen: UInt64, offset: UInt32, len: UInt16) -> UInt64 {
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
    static func computeExtensionPrefix8(arena: UnsafePointer<CChar>?, arenaLen: UInt64, offset: UInt32, len: UInt16) -> UInt64 {
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

    func sortCompactIndices() {
        guard var indices = compactIndices, let view = compactView, let rawNodes = view.rawNodesPointer else { return }
        guard indices.count > 1 else { return }

        let arena = view.string_arena
        let arenaLen = view.string_arena_len
        let key = self.sortKey
        let isAscending = (self.sortDirection == .ascending)

        var sortEntries = Self.buildSortEntries(
            indices: indices,
            rawNodes: rawNodes,
            arena: arena,
            arenaLen: arenaLen,
            key: key
        )
        sortEntries.sort { a, b in
            Self.compareSortEntries(
                a,
                b,
                key: key,
                isAscending: isAscending,
                rawNodes: rawNodes,
                arena: arena,
                arenaLen: arenaLen
            )
        }

        for i in 0..<indices.count {
            indices[i] = sortEntries[i].nodeIndex
        }
        self.compactIndices = indices
    }

    private static func buildSortEntries(
        indices: [UInt32],
        rawNodes: UnsafeRawPointer,
        arena: UnsafePointer<CChar>?,
        arenaLen: UInt64,
        key: SortKey
    ) -> [TTSortEntry] {
        var sortEntries = [TTSortEntry]()
        sortEntries.reserveCapacity(indices.count)

        for idx in indices {
            let node = TTWorkspaceCompactNodeView(base: rawNodes, index: Int(idx))
            let namePrefix = computePrefix8(arena: arena, arenaLen: arenaLen, offset: node.nameOffset, len: node.nameLen)
            let prefix: UInt64
            let secondary: UInt64

            switch key {
            case .name:
                prefix = namePrefix
                secondary = 0
            case .size:
                prefix = namePrefix
                secondary = node.size
            case .modifiedTime:
                prefix = namePrefix
                secondary = UInt64(node.mtime)
            case .extension:
                prefix = computeExtensionPrefix8(arena: arena, arenaLen: arenaLen, offset: node.nameOffset, len: node.nameLen)
                secondary = namePrefix
            }

            sortEntries.append(TTSortEntry(
                prefix: prefix,
                secondaryKey: secondary,
                nodeIndex: idx,
                isDirectory: node.isDirectory
            ))
        }
        return sortEntries
    }

    private static func compareSortEntries(
        _ a: TTSortEntry,
        _ b: TTSortEntry,
        key: SortKey,
        isAscending: Bool,
        rawNodes: UnsafeRawPointer,
        arena: UnsafePointer<CChar>?,
        arenaLen: UInt64
    ) -> Bool {
        if a.isDirectory != b.isDirectory {
            return a.isDirectory > b.isDirectory
        }

        let ord = primaryComparison(
            a,
            b,
            key: key,
            rawNodes: rawNodes,
            arena: arena,
            arenaLen: arenaLen
        )
        if ord == .orderedSame {
            if a.prefix != b.prefix {
                return a.prefix < b.prefix
            }
            return compareNodeNames(a.nodeIndex, b.nodeIndex, rawNodes: rawNodes, arena: arena, arenaLen: arenaLen) == .orderedAscending
        }
        return isAscending ? (ord == .orderedAscending) : (ord == .orderedDescending)
    }

    private static func primaryComparison(
        _ a: TTSortEntry,
        _ b: TTSortEntry,
        key: SortKey,
        rawNodes: UnsafeRawPointer,
        arena: UnsafePointer<CChar>?,
        arenaLen: UInt64
    ) -> ComparisonResult {
        switch key {
        case .name:
            if a.prefix != b.prefix {
                return a.prefix < b.prefix ? .orderedAscending : .orderedDescending
            }
            return compareNodeNames(a.nodeIndex, b.nodeIndex, rawNodes: rawNodes, arena: arena, arenaLen: arenaLen)
        case .size, .modifiedTime:
            guard a.secondaryKey != b.secondaryKey else { return .orderedSame }
            return a.secondaryKey < b.secondaryKey ? .orderedAscending : .orderedDescending
        case .extension:
            guard a.prefix != b.prefix else { return .orderedSame }
            return a.prefix < b.prefix ? .orderedAscending : .orderedDescending
        }
    }

    private static func compareNodeNames(
        _ indexA: UInt32,
        _ indexB: UInt32,
        rawNodes: UnsafeRawPointer,
        arena: UnsafePointer<CChar>?,
        arenaLen: UInt64
    ) -> ComparisonResult {
        let nodeA = TTWorkspaceCompactNodeView(base: rawNodes, index: Int(indexA))
        let nodeB = TTWorkspaceCompactNodeView(base: rawNodes, index: Int(indexB))
        let nameA = VfsSnapshotReader.decodeCompactName(arena: arena, arenaLen: arenaLen, node: nodeA)
        let nameB = VfsSnapshotReader.decodeCompactName(arena: arena, arenaLen: arenaLen, node: nodeB)
        return nameA.localizedStandardCompare(nameB)
    }

    // MARK: - Search Filtering & In-Memory Sorting

    public func setSearchQuery(query: String?) {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        guard self.activeSearchQuery != normalized else { return }

        self.activeSearchQuery = normalized
        invalidateCache()

        if let activeQuery = normalized {
            applyActiveSearchQuery(activeQuery)
        } else {
            restoreEntriesAfterClearingSearch()
        }
        onDataBatchLoaded?(IndexSet(integersIn: 0..<totalRowCount))
    }

    private func applyActiveSearchQuery(_ query: String) {
        if let session = session {
            let matches = (try? session.searchTopK(query: query, limit: 1000)) ?? []
            primeSearchMatches(matches)
        } else if let view = compactView {
            primeSearchMatches(searchCompactViewMatches(query: query, view: view))
        } else if let memory = inMemoryEntries {
            let matches = memory.filter {
                $0.path.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
            }
            primeSearchMatches(matches)
        }
    }

    private func searchCompactViewMatches(query: String, view: TTWorkspaceVfsView) -> [VfsEntryDto] {
        let lowerQ = query.lowercased()
        let total = Int(min(view.node_count, UInt64(UInt32.max)))
        var matches = [VfsEntryDto]()
        for idx in 0..<total {
            guard let node = view.compactNodeIfValid(at: idx) else { continue }
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
        return matches
    }

    private func primeSearchMatches(_ matches: [VfsEntryDto]) {
        self.searchMatches = matches
        self.totalRowCount = matches.count
        for (idx, node) in matches.prefix(128).enumerated() {
            self.cache[idx] = node
        }
    }

    private func restoreEntriesAfterClearingSearch() {
        self.searchMatches = nil
        if compactView != nil {
            reloadCompactIndices()
        } else if let memory = inMemoryEntries {
            self.totalRowCount = memory.count
            applyInMemorySort()
        } else if let session = session {
            primeInitialSessionPage(session: session)
        }
    }

    func primeInitialSessionPage(session: VfsSession) {
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

    func applyInMemorySort() {
        guard var items = inMemoryEntries else { return }
        items.sort { a, b in
            if a.isDir != b.isDir {
                return a.isDir
            }
            let ord = compareInMemoryEntries(a, b)
            if ord == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return self.sortDirection == .ascending ? (ord == .orderedAscending) : (ord == .orderedDescending)
        }
        self.inMemoryEntries = items
    }

    private func compareInMemoryEntries(_ a: VfsEntryDto, _ b: VfsEntryDto) -> ComparisonResult {
        switch self.sortKey {
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .size:
            return a.size < b.size ? .orderedAscending : (a.size > b.size ? .orderedDescending : .orderedSame)
        case .modifiedTime:
            return a.mtimeSecs < b.mtimeSecs ? .orderedAscending : (a.mtimeSecs > b.mtimeSecs ? .orderedDescending : .orderedSame)
        case .extension:
            let extA = (a.name as NSString).pathExtension.lowercased()
            let extB = (b.name as NSString).pathExtension.lowercased()
            return extA.compare(extB)
        }
    }
}
