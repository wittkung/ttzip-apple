// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
#if canImport(ttzip_app_coreFFI)
@preconcurrency import ttzip_app_coreFFI
#elseif canImport(CTTZipAppCoreBridge)
@preconcurrency import CTTZipAppCoreBridge
#endif

/// Typed 24-byte view over 8-byte aligned `TTWorkspaceCompactNode` snapshot memory.
///
/// Field loads use `UnsafeRawPointer.load(fromByteOffset:as:)`, which requires `base` to be at
/// least 8-byte aligned and backed by a live snapshot lease for at least `(index + 1) * 24` bytes.
public struct TTWorkspaceCompactNodeView: @unchecked Sendable {
    public let rawPointer: UnsafeRawPointer

    @inline(__always)
    public init(base: UnsafeRawPointer, index: Int) {
        self.rawPointer = base.advanced(by: index * 24)
    }

    @inline(__always)
    public var nameOffset: UInt32 { rawPointer.load(fromByteOffset: 0, as: UInt32.self) }

    @inline(__always)
    public var nameLen: UInt16 { rawPointer.load(fromByteOffset: 4, as: UInt16.self) }

    @inline(__always)
    public var flags: UInt16 { rawPointer.load(fromByteOffset: 6, as: UInt16.self) }

    @inline(__always)
    public var size: UInt64 { rawPointer.load(fromByteOffset: 8, as: UInt64.self) }

    @inline(__always)
    public var mtime: UInt32 { rawPointer.load(fromByteOffset: 16, as: UInt32.self) }

    @inline(__always)
    public var dirChildrenIdx: UInt32 { rawPointer.load(fromByteOffset: 20, as: UInt32.self) }

    @inline(__always)
    public var isDirectory: Bool { (flags & 0x01) != 0 } // TT_NODE_FLAG_DIR

    @inline(__always)
    public var isSymlink: Bool { (flags & 0x02) != 0 }

    @inline(__always)
    public var isEncrypted: Bool { (flags & 0x04) != 0 }

    @inline(__always)
    public var isReadOnly: Bool { (flags & 0x08) != 0 }
}

/// Typed 64-byte view over 8-byte (or 64-byte) aligned `TTWorkspaceEntryNode` CSR snapshot memory.
///
/// Field loads use `UnsafeRawPointer.load(fromByteOffset:as:)`, which requires `base` to be at
/// least 8-byte aligned and backed by a live snapshot lease for at least `(index + 1) * 64` bytes.
public struct TTWorkspaceEntryNodeView: @unchecked Sendable {
    public let rawPointer: UnsafeRawPointer

    @inline(__always)
    public init(base: UnsafeRawPointer, index: Int) {
        self.rawPointer = base.advanced(by: index * 64)
    }

    @inline(__always)
    public var parentID: UInt32 { rawPointer.load(fromByteOffset: 0, as: UInt32.self) }

    @inline(__always)
    public var firstChildID: UInt32 { rawPointer.load(fromByteOffset: 4, as: UInt32.self) }

    @inline(__always)
    public var childCount: UInt32 { rawPointer.load(fromByteOffset: 8, as: UInt32.self) }

    @inline(__always)
    public var nameOffset: UInt32 { rawPointer.load(fromByteOffset: 12, as: UInt32.self) }

    @inline(__always)
    public var sortPrefix: UInt64 { rawPointer.load(fromByteOffset: 16, as: UInt64.self) }

    @inline(__always)
    public var uncompressedSize: UInt64 { rawPointer.load(fromByteOffset: 24, as: UInt64.self) }

    @inline(__always)
    public var mtimeEpochSecs: Int64 { rawPointer.load(fromByteOffset: 32, as: Int64.self) }

    @inline(__always)
    public var auxPayload: UInt64 { rawPointer.load(fromByteOffset: 40, as: UInt64.self) }

    @inline(__always)
    public var stableID: UInt64 { rawPointer.load(fromByteOffset: 48, as: UInt64.self) }

    @inline(__always)
    public var fileType: UInt32 { rawPointer.load(fromByteOffset: 56, as: UInt32.self) }

    @inline(__always)
    public var flags: UInt16 { rawPointer.load(fromByteOffset: 60, as: UInt16.self) }

    @inline(__always)
    public var nameLen: UInt16 { rawPointer.load(fromByteOffset: 62, as: UInt16.self) }

    @inline(__always)
    public var isDirectory: Bool {
        (fileType & UInt32(S_IFMT)) == UInt32(S_IFDIR)
    }
}

/// View model representing a single file or directory row in the UI.
public struct VfsNodeViewModel: Identifiable, Sendable {
    public let id: UInt64 // stable_id
    public let name: String
    public let isDirectory: Bool
    public let uncompressedSize: UInt64
    public let childCount: UInt32
    public let modificationDate: Date
}

/// Reads `VfsNodeViewModel` slices from a borrowed `TTWorkspaceVfsView` without materializing the full snapshot.
///
/// This type does not own a snapshot lease; callers must keep the underlying lease alive for the
/// duration of all reads. Slice and name-decoding helpers validate node indices, CSR child ranges,
/// and `nameOffset + nameLen <= string_arena_len`.
public struct VfsSnapshotReader: @unchecked Sendable {
    public let view: TTWorkspaceVfsView?
    public let rawBase: UnsafeRawPointer?

    public init(view: TTWorkspaceVfsView? = nil) {
        self.view = view
        self.rawBase = view?.nodes.map { UnsafeRawPointer($0) }
    }

    public init(base: UnsafeRawPointer) {
        self.view = nil
        self.rawBase = base
    }

    /// Unchecked 24-byte compact node view at `index` (traps if `rawBase` and `view?.nodes` are nil;
    /// does not check `index < node_count` or `isCompactFormat`).
    @inline(__always)
    public func compactNode(at index: Int) -> TTWorkspaceCompactNodeView {
        guard let base = rawBase ?? (view?.nodes.map { UnsafeRawPointer($0) }) else {
            fatalError("Cannot access compactNode: nil base or nodes pointer")
        }
        return TTWorkspaceCompactNodeView(base: base, index: index)
    }

    /// Unchecked 24-byte compact node view at `index` in `view` (traps if `view.nodes` is nil;
    /// does not check `index < node_count` or `isCompactFormat`).
    @inline(__always)
    public static func compactNode(at index: Int, in view: TTWorkspaceVfsView) -> TTWorkspaceCompactNodeView {
        guard let nodes = view.nodes else {
            fatalError("Cannot access compactNode: nil nodes pointer")
        }
        return TTWorkspaceCompactNodeView(base: UnsafeRawPointer(nodes), index: index)
    }

    /// Bounds-checked 24-byte compact node view at `index` (caller must still ensure `isCompactFormat`).
    @inline(__always)
    public func compactNodeIfValid(at index: Int) -> TTWorkspaceCompactNodeView? {
        guard let view = view, let base = rawBase ?? (view.nodes.map { UnsafeRawPointer($0) }),
              index >= 0 && UInt64(index) < view.node_count else {
            return nil
        }
        return TTWorkspaceCompactNodeView(base: base, index: index)
    }

    /// Bounds-checked 24-byte compact node view at `index` in `view` (caller must still ensure `isCompactFormat`).
    @inline(__always)
    public static func compactNodeIfValid(at index: Int, in view: TTWorkspaceVfsView) -> TTWorkspaceCompactNodeView? {
        guard let nodes = view.nodes, index >= 0 && UInt64(index) < view.node_count else {
            return nil
        }
        return TTWorkspaceCompactNodeView(base: UnsafeRawPointer(nodes), index: index)
    }

    @inline(__always)
    public static func decodeCompactName(
        arena: UnsafePointer<CChar>?,
        arenaLen: UInt64,
        node: TTWorkspaceCompactNodeView
    ) -> String {
        decodeName(arena: arena, arenaLen: arenaLen, offset: node.nameOffset, len: node.nameLen)
    }

    @inline(__always)
    public static func decodeCompactName(
        in view: TTWorkspaceVfsView,
        node: TTWorkspaceCompactNodeView
    ) -> String {
        decodeName(arena: view.string_arena, arenaLen: view.string_arena_len, offset: node.nameOffset, len: node.nameLen)
    }

    public static func readCompactNode(
        at index: Int,
        in view: TTWorkspaceVfsView,
        childCount: UInt32 = 0
    ) -> VfsNodeViewModel? {
        guard let compact = compactNodeIfValid(at: index, in: view) else { return nil }
        let name = decodeCompactName(in: view, node: compact)
        return VfsNodeViewModel(
            id: UInt64(index),
            name: name.isEmpty ? "Unknown" : name,
            isDirectory: compact.isDirectory,
            uncompressedSize: compact.size,
            childCount: childCount,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(compact.mtime))
        )
    }

    public static func readCompactChildrenSlice(
        childIndices: [UInt32],
        in view: TTWorkspaceVfsView,
        offset: Int,
        limit: Int
    ) -> [VfsNodeViewModel] {
        guard let nodesPtr = view.nodes,
              offset >= 0,
              limit > 0,
              offset < childIndices.count else { return [] }
        let rawNodes = UnsafeRawPointer(nodesPtr)
        let stringArena = view.string_arena
        let arenaLen = view.string_arena_len
        let remaining = childIndices.count - offset
        let maxItems = min(limit, remaining)
        var viewModels = [VfsNodeViewModel]()
        viewModels.reserveCapacity(maxItems)

        for i in 0..<maxItems {
            let rawChildIdx = childIndices[offset + i]
            guard UInt64(rawChildIdx) < view.node_count,
                  let childIdx = Int(exactly: rawChildIdx) else { continue }
            let compact = TTWorkspaceCompactNodeView(base: rawNodes, index: childIdx)
            let name = decodeName(arena: stringArena, arenaLen: arenaLen, offset: compact.nameOffset, len: compact.nameLen)
            let vm = VfsNodeViewModel(
                id: UInt64(rawChildIdx),
                name: name.isEmpty ? "Unknown" : name,
                isDirectory: compact.isDirectory,
                uncompressedSize: compact.size,
                childCount: 0,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(compact.mtime))
            )
            viewModels.append(vm)
        }
        return viewModels
    }

    /// Decodes a UTF-8 slice `[offset ..< offset + len]` from `arena` when `offset + len <= arenaLen`.
    @inline(__always)
    public static func decodeName(
        arena: UnsafePointer<CChar>?,
        arenaLen: UInt64,
        offset: UInt32,
        len: UInt16
    ) -> String {
        guard let arenaPtr = arena, len > 0 else { return "" }
        let start = UInt64(offset)
        let count = UInt64(len)
        let end = start + count
        guard end <= arenaLen,
              let byteOffset = Int(exactly: start),
              let byteCount = Int(exactly: count) else {
            return ""
        }
        let namePtr = arenaPtr.advanced(by: byteOffset)
        return namePtr.withMemoryRebound(to: UInt8.self, capacity: byteCount) { ptr in
            let buffer = UnsafeBufferPointer(start: ptr, count: byteCount)
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    public static func readChildren(
        of parentID: UInt32,
        in view: TTWorkspaceVfsView,
        limit: Int? = nil,
        dirTable: [[UInt32]]? = nil
    ) -> [VfsNodeViewModel] {
        return readChildrenSlice(of: parentID, in: view, offset: 0, limit: limit ?? .max, dirTable: dirTable)
    }

    /// Reads a slice of children for `parentID` in either 24-byte compact format (requires a
    /// matching `dirTable`) or 64-byte CSR format (uses contiguous `firstChildID ..< firstChildID + childCount`).
    public static func readChildrenSlice(
        of parentID: UInt32,
        in view: TTWorkspaceVfsView,
        offset: Int,
        limit: Int,
        dirTable: [[UInt32]]? = nil
    ) -> [VfsNodeViewModel] {
        guard let nodesPtr = view.nodes, offset >= 0, limit > 0 else { return [] }
        let rawNodes = UnsafeRawPointer(nodesPtr)

        if view.isCompactFormat {
            guard UInt64(parentID) < view.node_count,
                  let pIdx = Int(exactly: parentID) else { return [] }
            let parentCompact = TTWorkspaceCompactNodeView(base: rawNodes, index: pIdx)
            guard parentCompact.isDirectory else { return [] }

            let childIndices: [UInt32]
            if let dt = dirTable,
               let dirIdx = Int(exactly: parentCompact.dirChildrenIdx),
               dirIdx >= 0,
               dirIdx < dt.count {
                childIndices = dt[dirIdx]
            } else {
                childIndices = []
            }

            return readCompactChildrenSlice(
                childIndices: childIndices,
                in: view,
                offset: offset,
                limit: limit
            )
        } else {
            return readCsrChildrenSlice(
                of: parentID,
                rawNodes: rawNodes,
                in: view,
                offset: offset,
                limit: limit
            )
        }
    }

    private static func readCsrChildrenSlice(
        of parentID: UInt32,
        rawNodes: UnsafeRawPointer,
        in view: TTWorkspaceVfsView,
        offset: Int,
        limit: Int
    ) -> [VfsNodeViewModel] {
        guard UInt64(parentID) < view.node_count,
              let parentIndex = Int(exactly: parentID) else {
            return []
        }
        let parentNode = TTWorkspaceEntryNodeView(base: rawNodes, index: parentIndex)
        let rawFirstChild = parentNode.firstChildID
        let rawChildCount = parentNode.childCount
        guard rawChildCount > 0, rawFirstChild != UInt32.max else {
            return []
        }
        let childrenEnd = UInt64(rawFirstChild) + UInt64(rawChildCount)
        guard childrenEnd <= view.node_count,
              let firstChild = Int(exactly: rawFirstChild),
              let childCount = Int(exactly: rawChildCount),
              offset < childCount else {
            return []
        }

        let maxItems = min(limit, childCount - offset)
        var viewModels = [VfsNodeViewModel]()
        viewModels.reserveCapacity(maxItems)

        for i in 0..<maxItems {
            let childIndex = firstChild + offset + i
            viewModels.append(makeCsrNodeViewModel(rawNodes: rawNodes, index: childIndex, in: view))
        }
        return viewModels
    }

    /// Reads view models for `indices[offset ..< min(indices.count, offset + limit)]` in either
    /// 24-byte compact format or 64-byte CSR format.
    public static func readIndexedEntries(
        indices: [UInt32],
        in view: TTWorkspaceVfsView,
        offset: Int,
        limit: Int,
        dirTable: [[UInt32]]? = nil
    ) -> [VfsNodeViewModel] {
        guard let nodesPtr = view.nodes,
              offset >= 0,
              limit > 0,
              offset < indices.count else {
            return []
        }
        let rawNodes = UnsafeRawPointer(nodesPtr)
        let maxItems = min(limit, indices.count - offset)
        var viewModels = [VfsNodeViewModel]()
        viewModels.reserveCapacity(maxItems)

        for i in 0..<maxItems {
            let rawIdx = indices[offset + i]
            guard UInt64(rawIdx) < view.node_count,
                  let childIndex = Int(exactly: rawIdx) else { continue }
            if view.isCompactFormat {
                viewModels.append(makeCompactIndexedViewModel(
                    rawNodes: rawNodes,
                    rawIdx: rawIdx,
                    index: childIndex,
                    in: view,
                    dirTable: dirTable
                ))
            } else {
                viewModels.append(makeCsrNodeViewModel(rawNodes: rawNodes, index: childIndex, in: view))
            }
        }
        return viewModels
    }

    private static func makeCompactIndexedViewModel(
        rawNodes: UnsafeRawPointer,
        rawIdx: UInt32,
        index: Int,
        in view: TTWorkspaceVfsView,
        dirTable: [[UInt32]]?
    ) -> VfsNodeViewModel {
        let compact = TTWorkspaceCompactNodeView(base: rawNodes, index: index)
        let name = decodeCompactName(in: view, node: compact)
        let childCount: UInt32
        if compact.isDirectory,
           let dt = dirTable,
           let dirIdx = Int(exactly: compact.dirChildrenIdx),
           dirIdx >= 0,
           dirIdx < dt.count {
            childCount = UInt32(clamping: dt[dirIdx].count)
        } else {
            childCount = 0
        }
        return VfsNodeViewModel(
            id: UInt64(rawIdx),
            name: name.isEmpty ? "Unknown" : name,
            isDirectory: compact.isDirectory,
            uncompressedSize: compact.size,
            childCount: childCount,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(compact.mtime))
        )
    }

    private static func makeCsrNodeViewModel(
        rawNodes: UnsafeRawPointer,
        index: Int,
        in view: TTWorkspaceVfsView
    ) -> VfsNodeViewModel {
        let childNode = TTWorkspaceEntryNodeView(base: rawNodes, index: index)
        let name = decodeName(
            arena: view.string_arena,
            arenaLen: view.string_arena_len,
            offset: childNode.nameOffset,
            len: childNode.nameLen
        )
        return VfsNodeViewModel(
            id: childNode.stableID,
            name: name.isEmpty ? "Unknown" : name,
            isDirectory: childNode.isDirectory,
            uncompressedSize: childNode.uncompressedSize,
            childCount: childNode.childCount,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(childNode.mtimeEpochSecs))
        )
    }
}

#if DEBUG
extension TTWorkspaceCompactNodeView {
    /// In-file verification validating the exact 24-byte geometry and offset layout.
    public static func verifyGeometry() -> Bool {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 24)

        buffer.storeBytes(of: UInt32(0x12345678), toByteOffset: 0, as: UInt32.self)
        buffer.storeBytes(of: UInt16(0x0402), toByteOffset: 4, as: UInt16.self)
        buffer.storeBytes(of: UInt16(0x000F), toByteOffset: 6, as: UInt16.self)
        buffer.storeBytes(of: UInt64(0x0102030405060708), toByteOffset: 8, as: UInt64.self)
        buffer.storeBytes(of: UInt32(0x55667788), toByteOffset: 16, as: UInt32.self)
        buffer.storeBytes(of: UInt32(0x99AABBCC), toByteOffset: 20, as: UInt32.self)

        let view = TTWorkspaceCompactNodeView(base: buffer, index: 0)
        assert(view.nameOffset == 0x12345678)
        assert(view.nameLen == 0x0402)
        assert(view.flags == 0x000F)
        assert(view.size == 0x0102030405060708)
        assert(view.mtime == 0x55667788)
        assert(view.dirChildrenIdx == 0x99AABBCC)
        assert(view.isDirectory)
        assert(view.isSymlink)
        assert(view.isEncrypted)
        assert(view.isReadOnly)
        return true
    }
}
#endif

