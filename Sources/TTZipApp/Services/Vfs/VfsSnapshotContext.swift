// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os
import TTZipCore

/// Client-side view struct representing an in-process UniVFS snapshot.
///
/// Pointers inside this view borrow from the underlying `ttvfs_lease_s` mapping and remain valid
/// only while an owning lease reference stays alive. `nodes` points to either 24-byte
/// `TTWorkspaceCompactNode` records or 64-byte `TTWorkspaceEntryNode` records depending on
/// `isCompactFormat`.
public struct TTWorkspaceVfsView: @unchecked Sendable {
    public var header: OpaquePointer?
    public var nodes: OpaquePointer?
    public var node_count: UInt64
    public var string_arena: UnsafePointer<CChar>?
    public var string_arena_len: UInt64
    public var generation: UInt64

    public init(
        header: OpaquePointer? = nil,
        nodes: OpaquePointer? = nil,
        node_count: UInt64 = 0,
        string_arena: UnsafePointer<CChar>? = nil,
        string_arena_len: UInt64 = 0,
        generation: UInt64 = 0
    ) {
        self.header = header
        self.nodes = nodes
        self.node_count = node_count
        self.string_arena = string_arena
        self.string_arena_len = string_arena_len
        self.generation = generation
    }
}

private typealias TTVfsAcquireSnapshotFunc = @convention(c) (
    OpaquePointer,
    UnsafeMutableRawPointer
) -> UInt8

private typealias TTVfsReleaseSnapshotFunc = @convention(c) (
    OpaquePointer
) -> Void

private let _vfsLogger = Logger(subsystem: "com.metastudyline.ttzip", category: "VfsCABI")

private let _cabiAcquireSnapshot: TTVfsAcquireSnapshotFunc? = {
    guard let handle = dlopen(nil as String?, RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "ttvfs_acquire_snapshot") else { return nil }
    return unsafeBitCast(sym, to: TTVfsAcquireSnapshotFunc.self)
}()

private let _cabiReleaseSnapshot: TTVfsReleaseSnapshotFunc? = {
    guard let handle = dlopen(nil as String?, RTLD_LAZY) else {
        _vfsLogger.fault("Failed to acquire process handle via dlopen for C-ABI snapshot release")
        assertionFailure("Failed to acquire process handle via dlopen for C-ABI snapshot release")
        return nil
    }
    let sym = dlsym(handle, "ttvfs_release_snapshot") ?? dlsym(handle, "ttzip_vfs_release_snapshot")
    guard let validSym = sym else {
        _vfsLogger.fault("Missing C-ABI snapshot release symbol: neither ttvfs_release_snapshot nor ttzip_vfs_release_snapshot found")
        assertionFailure("Missing C-ABI snapshot release symbol: neither ttvfs_release_snapshot nor ttzip_vfs_release_snapshot found")
        return nil
    }
    return unsafeBitCast(validSym, to: TTVfsReleaseSnapshotFunc.self)
}()

@inline(__always)
public func ttvfs_release_snapshot(_ lease: OpaquePointer) {
    _cabiReleaseSnapshot?(lease)
}

@inline(__always)
public func ttvfs_acquire_snapshot(_ lease: OpaquePointer, _ outView: UnsafeMutablePointer<TTWorkspaceVfsView>) -> UInt8 {
    guard let fn = _cabiAcquireSnapshot else { return 0 }
    return fn(lease, UnsafeMutableRawPointer(outView))
}

// MARK: - TTWorkspaceVfsView CompactNode & DirChildren Extensions

extension TTWorkspaceVfsView {
    public static let featureFlagCSR: UInt32 = 1 << 0
    public static let featureFlagCompactNodes: UInt32 = 1 << 4

    /// Determines whether the 24-byte `TTWorkspaceCompactNode` layout is active.
    ///
    /// Returns `true` when `header` is `nil`, `featureFlagCompactNodes` (`1 << 4`) is set,
    /// or `featureFlagCSR` (`1 << 0`) is clear (loaded from `header.feature_flags` at byte offset 56),
    /// matching Rust's `TTWorkspaceSnapshotHeader::is_compact_format`.
    @inline(__always)
    public var isCompactFormat: Bool {
        guard let headerPtr = self.header else {
            return true
        }
        let rawHeader = UnsafeRawPointer(headerPtr)
        let flags = rawHeader.load(fromByteOffset: 56, as: UInt32.self)
        return (flags & Self.featureFlagCompactNodes != 0) || (flags & Self.featureFlagCSR == 0)
    }

    /// Returns `true` when the 64-byte `TTWorkspaceEntryNode` CSR layout is active.
    @inline(__always)
    public var isLegacyFormat: Bool {
        !isCompactFormat
    }

    /// Byte stride of each node record in `nodes` (24 for compact nodes, 64 for CSR entry nodes).
    @inline(__always)
    public var nodeStride: Int {
        isCompactFormat ? 24 : 64
    }

    /// Raw untyped pointer to the underlying nodes buffer.
    @inline(__always)
    public var rawNodesPointer: UnsafeRawPointer? {
        guard let nodes = self.nodes else { return nil }
        return UnsafeRawPointer(nodes)
    }

    /// Untyped pointer alias to `nodes`; callers must verify `isCompactFormat` before reading
    /// 24-byte `TTWorkspaceCompactNode` records.
    @inline(__always)
    public var compactNodes: UnsafeRawPointer? {
        rawNodesPointer
    }

    /// Unchecked 24-byte compact node view at `index` (does not check `index < node_count` or `isCompactFormat`).
    @inline(__always)
    public func compactNode(at index: Int) -> TTWorkspaceCompactNodeView {
        precondition(rawNodesPointer != nil, "TTWorkspaceVfsView nodes pointer is nil")
        return TTWorkspaceCompactNodeView(base: rawNodesPointer!, index: index)
    }

    /// Bounds-checked 24-byte compact node view at `index` (caller must still ensure `isCompactFormat`).
    @inline(__always)
    public func compactNodeIfValid(at index: Int) -> TTWorkspaceCompactNodeView? {
        guard let raw = rawNodesPointer, index >= 0 && UInt64(index) < node_count else {
            return nil
        }
        return TTWorkspaceCompactNodeView(base: raw, index: index)
    }

    /// Resolves child node indices for a directory compact node using the caller-supplied
    /// `dirTable` (since `ttzip_vfs_open_compact_catalog` does not serialize directory buckets into
    /// the snapshot sections). Returns `[]` when `dirTable` is `nil` or out of range.
    @inline(__always)
    public func dirChildren(for node: TTWorkspaceCompactNodeView, dirTable: [[UInt32]]? = nil) -> [UInt32] {
        guard node.isDirectory else { return [] }
        return dirChildren(at: node.dirChildrenIdx, dirTable: dirTable)
    }

    /// Resolves child node indices for `dirIndex` in `dirTable`, or `[]` if `dirTable` is `nil` or out of bounds.
    @inline(__always)
    public func dirChildren(at dirIndex: UInt32, dirTable: [[UInt32]]? = nil) -> [UInt32] {
        let idx = Int(dirIndex)
        if let dirTable = dirTable, idx >= 0 && idx < dirTable.count {
            return dirTable[idx]
        }
        return []
    }
}


/// Opaque pointer wrapper representing the C-ABI `ttvfs_lease_t`.
public typealias TTVFSLease = OpaquePointer


/// Owns one snapshot reference transferred by the caller.
/// Derived leases acquire independent references; views borrow from a valid owner.
public final class VfsSnapshotContext: @unchecked Sendable {
    private let lease: TTVFSLease
    private let operations: VfsSnapshotOperations

    /// External directory children lookup table (`dirChildrenIdx -> [childNodeIndex]`).
    /// Compact catalog snapshots only serialize node and string sections, so compact directory
    /// traversal requires this table to be populated separately.
    public var dirChildrenTable: [[UInt32]]?

    /// Adopts one existing owning reference; the caller must not release it separately.
    public convenience init(
        lease: TTVFSLease,
        dirChildrenTable: [[UInt32]]? = nil
    ) {
        self.init(lease: lease, dirChildrenTable: dirChildrenTable, operations: .live)
    }

    internal init(
        lease: TTVFSLease,
        dirChildrenTable: [[UInt32]]? = nil,
        operations: VfsSnapshotOperations
    ) {
        self.lease = lease
        self.dirChildrenTable = dirChildrenTable
        self.operations = operations
    }

    public var rawLease: TTVFSLease { lease }

    /// Acquires an independent owning reference for the returned lease.
    /// Traps via `precondition` if native acquisition fails.
    public func acquireLease() -> VfsSnapshotLease {
        var view = TTWorkspaceVfsView()
        let success = operations.acquire(lease, &view)
        precondition(success != 0, "Failed to acquire a snapshot lease")
        return VfsSnapshotLease(handle: lease, operations: operations)
    }

    deinit {
        operations.release(lease)
    }

    /// Acquires a temporary reference for the duration of `body` and releases it on exit.
    /// Pointers inside `TTWorkspaceVfsView` must not escape `body`.
    public func withSnapshot<T>(_ body: (TTWorkspaceVfsView) throws -> T) rethrows -> T {
        var view = TTWorkspaceVfsView()
        let success = operations.acquire(lease, &view)
        precondition(success != 0, "Failed to acquire valid TTWorkspaceVfsView from lease")
        defer {
            operations.release(lease)
        }

        return try body(view)
    }

    /// Searches node names for `query` up to `maxResults`, falling back to an in-process UTF-8 scan
    /// when the `ttzip_vfs_search` C-ABI symbol is unavailable.
    public func search(query: String, maxResults: Int) -> [UInt32] {
        guard maxResults > 0 else { return [] }

        typealias SearchFunc = @convention(c) (
            TTVFSLease,
            UnsafePointer<CChar>,
            UInt32,
            UnsafeMutablePointer<UInt32>,
            UnsafeMutablePointer<UInt32>
        ) -> Int32
        
        let handle = dlopen(nil, RTLD_LAZY)
        if let sym = dlsym(handle, "ttzip_vfs_search") {
            let cSearch = unsafeBitCast(sym, to: SearchFunc.self)
            let cappedMaxResults = Int(min(UInt64(maxResults), UInt64(UInt32.max)))
            return query.withCString { cString in
                var indices = [UInt32](repeating: 0, count: cappedMaxResults)
                var outCount: UInt32 = 0
                let ret = indices.withUnsafeMutableBufferPointer { bufPtr in
                    guard let baseAddress = bufPtr.baseAddress else { return Int32(-1) }
                    return cSearch(lease, cString, UInt32(cappedMaxResults), baseAddress, &outCount)
                }
                if ret == 0 {
                    return Array(indices.prefix(Int(outCount)))
                } else {
                    return []
                }
            }
        } else {
            return withSnapshot { view in
                Self.fallbackSearch(in: view, query: query, maxResults: maxResults)
            }
        }
    }

    internal static func fallbackSearch(
        in view: TTWorkspaceVfsView,
        query: String,
        maxResults: Int
    ) -> [UInt32] {
        guard maxResults > 0,
              let nodesPtr = view.nodes,
              let arenaPtr = view.string_arena else { return [] }
        let rawNodes = UnsafeRawPointer(nodesPtr)
        let arenaLen = view.string_arena_len
        let cappedCount = Int(min(view.node_count, UInt64(UInt32.max)))
        let cappedMaxResults = min(maxResults, cappedCount)
        guard cappedMaxResults > 0 else { return [] }
        var results = [UInt32]()
        results.reserveCapacity(cappedMaxResults)

        let lowerQuery = query.lowercased()

        for i in 0..<cappedCount {
            if results.count >= cappedMaxResults { break }
            let name: String
            if view.isCompactFormat {
                let node = TTWorkspaceCompactNodeView(base: rawNodes, index: i)
                name = VfsSnapshotReader.decodeName(
                    arena: arenaPtr,
                    arenaLen: arenaLen,
                    offset: node.nameOffset,
                    len: node.nameLen
                )
            } else {
                let node = TTWorkspaceEntryNodeView(base: rawNodes, index: i)
                name = VfsSnapshotReader.decodeName(
                    arena: arenaPtr,
                    arenaLen: arenaLen,
                    offset: node.nameOffset,
                    len: node.nameLen
                )
            }
            if !name.isEmpty && name.lowercased().contains(lowerQuery) {
                results.append(UInt32(i))
            }
        }
        return results
    }

    /// Reads a slice of child node view models for the given parent node.
    public func readChildrenSlice(of parentID: UInt32, offset: Int, limit: Int) -> [VfsNodeViewModel] {
        withSnapshot { view in
            VfsSnapshotReader.readChildrenSlice(of: parentID, in: view, offset: offset, limit: limit, dirTable: self.dirChildrenTable)
        }
    }

    /// Reads node view models corresponding to specific snapshot indices.
    public func readIndexedEntries(indices: [UInt32], offset: Int, limit: Int) -> [VfsNodeViewModel] {
        withSnapshot { view in
            VfsSnapshotReader.readIndexedEntries(indices: indices, in: view, offset: offset, limit: limit, dirTable: self.dirChildrenTable)
        }
    }

    /// Reads compact node view at given index within the current snapshot lease.
    public func compactNode(at index: Int) -> TTWorkspaceCompactNodeView? {
        withSnapshot { view in
            view.compactNodeIfValid(at: index)
        }
    }

    /// Resolves directory child indices for a given compact node from context's directory table.
    public func dirChildren(for node: TTWorkspaceCompactNodeView) -> [UInt32] {
        withSnapshot { view in
            view.dirChildren(for: node, dirTable: dirChildrenTable)
        }
    }

    /// Reads a slice of compact node child view models for a given parent compact node.
    public func readCompactChildrenSlice(
        for node: TTWorkspaceCompactNodeView,
        childIndices: [UInt32]? = nil,
        offset: Int,
        limit: Int
    ) -> [VfsNodeViewModel] {
        let indices = childIndices ?? dirChildren(for: node)
        return withSnapshot { view in
            VfsSnapshotReader.readCompactChildrenSlice(
                childIndices: indices,
                in: view,
                offset: offset,
                limit: limit
            )
        }
    }
}

