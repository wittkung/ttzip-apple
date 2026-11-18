// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os
import TTZipCore

/// Instance-scoped native operations. Test tokens remain opaque and are never dereferenced.
internal struct VfsSnapshotOperations: Sendable {
    let acquire: @Sendable (OpaquePointer, UnsafeMutablePointer<TTWorkspaceVfsView>) -> UInt8
    let release: @Sendable (OpaquePointer) -> Void

    static let live = VfsSnapshotOperations(
        acquire: { handle, view in ttvfs_acquire_snapshot(handle, view) },
        release: { handle in ttvfs_release_snapshot(handle) }
    )
}

/// Owns one snapshot reference transferred by the caller.
/// Borrowed views remain valid only while this lease has not been explicitly released.
/// Callers must not use an escaped view concurrently with `release()`.
public final class VfsSnapshotLease: @unchecked Sendable {
    public let rawHandle: OpaquePointer
    private let operations: VfsSnapshotOperations
    private let isReleased = OSAllocatedUnfairLock(initialState: false)

    /// Adopts one existing owning reference; the caller must not release it separately.
    public convenience init(handle: OpaquePointer) {
        self.init(handle: handle, operations: .live)
    }

    internal init(handle: OpaquePointer, operations: VfsSnapshotOperations) {
        self.rawHandle = handle
        self.operations = operations
    }

    /// Adopts one existing owning reference represented as a raw pointer.
    public convenience init(rawPointer: UnsafeMutableRawPointer) {
        self.init(handle: OpaquePointer(rawPointer))
    }

    /// Borrows a view without adding a persistent reference.
    /// Returns nil after release or when native acquisition fails. The returned pointers
    /// must not outlive this lease's valid owning reference or race an explicit release.
    public func acquireView() -> TTWorkspaceVfsView? {
        isReleased.withLock { released -> TTWorkspaceVfsView? in
            guard !released else { return nil }
            var view = TTWorkspaceVfsView()
            guard operations.acquire(rawHandle, &view) != 0 else { return nil }
            operations.release(rawHandle)
            return view
        }
    }

    /// Creates a distinct owner while this lease still protects the native handle.
    public func acquireLease() -> VfsSnapshotLease? {
        isReleased.withLock { released -> VfsSnapshotLease? in
            guard !released else { return nil }
            var view = TTWorkspaceVfsView()
            guard operations.acquire(rawHandle, &view) != 0 else { return nil }
            return VfsSnapshotLease(handle: rawHandle, operations: operations)
        }
    }

    /// Consumes this owner's reference once, serialized with acquire operations.
    /// This does not extend the lifetime of views already returned to the caller.
    public func release() {
        isReleased.withLock { released in
            guard !released else { return }
            released = true
            operations.release(rawHandle)
        }
    }

    deinit {
        release()
    }
}

/// Carmack 8-byte prefix sort entry packing the leading 8 bytes of a filename into a `UInt64`
/// for register-level primary comparisons before falling back to arena byte comparisons.
public struct TTSortEntry: Sendable {
    public var prefix: UInt64
    public var secondaryKey: UInt64
    public var nodeIndex: UInt32
    public var isDirectory: UInt8

    @inline(__always)
    public init(prefix: UInt64, secondaryKey: UInt64, nodeIndex: UInt32, isDirectory: Bool) {
        self.prefix = prefix
        self.secondaryKey = secondaryKey
        self.nodeIndex = nodeIndex
        self.isDirectory = isDirectory ? 1 : 0
    }
}

