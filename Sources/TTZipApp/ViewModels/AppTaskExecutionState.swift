// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
#if canImport(TTZipAppServices)
import TTZipAppServices
#endif

/// Task execution projection moved intact from AppSubStates for its file-size boundary.
@Observable
@MainActor
public final class TaskExecutionState {
    public var statusMessage: String = "Ready"
    public var progressValue: Double = 0.0
    public var taskStateName: String = "Idle"
    public var canPauseTask: Bool = false
    public var canResumeTask: Bool = false
    public var canCancelTask: Bool = false
    public var currentTaskID: UUID? = nil

    /// Epoch of the foreground archive-open request that currently owns the foreground.
    ///
    /// Read-only outside this class: the foreground identity is acquired, released and
    /// invalidated through `beginArchiveRequest(epoch:)`, `endArchiveRequest(ifOwnedBy:)` and
    /// `invalidateArchiveRequest()` only, so a caller can never release a request it does not
    /// own.
    public private(set) var archiveRequestOwnerEpoch: UInt64? = nil

    /// Busy identities of the background operations that are alive in this window.
    ///
    /// A set rather than a single slot: several background operations may overlap in one
    /// window, and each of them releases only its own identity. The set holds live identities
    /// only — it never stores a completion state, a result or a priority.
    private var activeBusyOperationIDs: Set<UUID> = []

    // Command History (Undo / Redo)
    public var canUndo: Bool = false
    public var canRedo: Bool = false
    public var lastCommandDescription: String? = nil

    /// Read-only projection of the busy state of this window.
    ///
    /// True while the foreground archive request is alive or while at least one background
    /// operation is alive. It is never written directly: the flag is derived from the busy
    /// identities, so an operation that finishes cannot switch the flag off while another
    /// operation of the same window is still running.
    public var isLoading: Bool {
        archiveRequestOwnerEpoch != nil || !activeBusyOperationIDs.isEmpty
    }

    public init() {}

    // MARK: - Foreground archive request identity

    /// Acquires the foreground for an archive-open request.
    ///
    /// A newer request replaces the foreground identity of an older one: the request that
    /// started later owns the foreground, and the abandoned one must not be able to release it.
    public func beginArchiveRequest(epoch: UInt64) {
        archiveRequestOwnerEpoch = epoch
    }

    /// Releases the foreground when the given request still owns it.
    ///
    /// Returns `true` when the request owned the foreground and released it, and `false` when
    /// the foreground already belonged to a newer request. Releasing twice is idempotent.
    @discardableResult
    public func endArchiveRequest(ifOwnedBy epoch: UInt64) -> Bool {
        guard archiveRequestOwnerEpoch == epoch else { return false }
        archiveRequestOwnerEpoch = nil
        return true
    }

    /// Invalidates the foreground identity without touching the background operations.
    ///
    /// Used by navigation, archive close and window reset: the foreground request is abandoned
    /// while the background operations keep running and keep the window busy.
    public func invalidateArchiveRequest() {
        archiveRequestOwnerEpoch = nil
    }

    // MARK: - Background busy identities

    /// Acquires a busy identity for a background operation and returns it.
    ///
    /// The caller releases exactly this identity when the operation finishes. Passing an
    /// existing identifier re-uses it, which lets a tracked task keep its own task UUID as its
    /// busy identity.
    @discardableResult
    public func beginBusyOperation(id: UUID = UUID()) -> UUID {
        activeBusyOperationIDs.insert(id)
        return id
    }

    /// Releases a busy identity. Releasing an unknown identity is a no-op.
    public func endBusyOperation(id: UUID) {
        activeBusyOperationIDs.remove(id)
    }
}
