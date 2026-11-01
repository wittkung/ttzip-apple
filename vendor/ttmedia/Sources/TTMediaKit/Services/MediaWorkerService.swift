// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Darwin
import TTMediaDemux

/// The transport operations the media worker service depends on.
///
/// This protocol is the service's **internal injection seam**: it lets a test
/// drive the *production* service body against a controlled transport boundary.
/// The production transport conforms unchanged, and the public XPC surface
/// (`TTMediaWorkerProtocol`) is untouched.
protocol MediaWorkerServiceTransport: AnyObject {
    func openMedia(
        path: String, targetTracks: [Int]?
    ) async throws -> (sessionId: String, metadata: [String: Any])
    func closeMedia(sessionId: String) async throws
    func readNextPacket(sessionId: String) async throws -> Data?
    func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double
    func subtitleData(sessionId: String, track: Int64, requestID: UInt64) async throws -> Data
    /// The session the transport currently owns, if any.
    var currentSessionId: String? { get }
}

extension MediaWorkerDirectTransport: MediaWorkerServiceTransport {
    var currentSessionId: String? { currentActiveSessionId }
}

/// Why a close attempt did not release the lease.
enum MediaWorkerCloseFailure: Error, Equatable {
    /// The session was not the published lease: nothing was disposed.
    case identityMismatch
    /// The worker side may still hold the session.
    case transportFailure(String)
    /// The managed capability could not be closed.
    case capabilityCloseFailed
}

/// One managed lease: the host-granted read-only capability together with the
/// identity that owns it.
///
/// The generation makes the identity unique even if a session id were ever
/// reused, and it is what lets a late completion recognise that the lease it
/// started with is no longer the published one.
private struct ManagedLease: Equatable {
    let sessionId: String
    let generation: UInt64
}

/// A lease together with the capability it owns.
private struct HeldLease {
    let lease: ManagedLease
    let handle: FileHandle
}

/// One connection owns one demuxer and one host-granted read-only file capability.
public final class MediaWorkerService: NSObject, TTMediaWorkerProtocol, @unchecked Sendable {
    private static let maxCancelledRequestHistory = 256

    private let transport: any MediaWorkerServiceTransport
    private let lock = NSLock()
    /// The published lease, if any. Every capability the service holds is owned
    /// by exactly one lease, and a lease is disposed by exactly one owner.
    private var held: HeldLease?
    /// The generation of the next published lease.
    private var nextGeneration: UInt64 = 0
    private var cancelledRequests: Set<UInt64> = []
    private var cancelledRequestOrder: [UInt64] = []
    /// Leases whose release could not be confirmed.
    ///
    /// A lease lands here when its release attempt failed **and** it could not be
    /// restored as the active lease. It is **not** dropped: the service keeps the
    /// capability, and it owns the transport that holds the worker side, so both
    /// halves of the responsibility stay with the service and stay observable.
    private var unreleasedLeases: [HeldLease] = []
    /// Counts retirements that reached a terminal state.
    ///
    /// This is the service's **own completion signal** for one lease cleanup: it
    /// says the cleanup finished, nothing more. It is **not** ownership — the
    /// ownership of a lease that could not be released is carried by
    /// `unreleasedLeaseIdentities`, and only that list does.
    private var completedRetirementCountStorage = 0

    /// Creates a service that owns `transport`.
    ///
    /// The injection seam exists so the **production service body** can be
    /// exercised against a controlled transport boundary. It is internal on
    /// purpose: the XPC surface is unchanged.
    internal init(transport: any MediaWorkerServiceTransport) {
        self.transport = transport
        super.init()
    }

    public override convenience init() {
        self.init(transport: MediaWorkerDirectTransport())
    }

    /// The identity of a published lease.
    struct LeaseIdentity: Equatable {
        let sessionId: String
        let generation: UInt64
    }

    /// The identity of the currently published lease, if any.
    ///
    /// Internal: it lets a test observe the ownership state directly instead of
    /// inferring it from the transport.
    /// The leases whose release is not confirmed, with the identity of each.
    ///
    /// This list — and only this list — carries the responsibility for a lease
    /// that could not be released.
    internal var unreleasedLeaseIdentities: [LeaseIdentity] {
        lock.withLock {
            unreleasedLeases.map {
                LeaseIdentity(sessionId: $0.lease.sessionId, generation: $0.lease.generation)
            }
        }
    }

    /// How many lease retirements reached a terminal state.
    ///
    /// A completion signal, not ownership — see `unreleasedLeaseIdentities`.
    internal var completedRetirementCount: Int {
        lock.withLock { completedRetirementCountStorage }
    }

    internal var currentLeaseIdentity: LeaseIdentity? {
        lock.withLock {
            held.map { LeaseIdentity(sessionId: $0.lease.sessionId, generation: $0.lease.generation) }
        }
    }

    deinit {
        // A lease whose release could not be confirmed keeps its capability
        // here. Close it now rather than leaking the descriptor; there is no
        // reporter left at this point.
        for lease in unreleasedLeases {
            try? lease.handle.close()
        }
    }

    internal func hasCancelledRequest(_ requestID: UInt64) -> Bool {
        lock.withLock { cancelledRequests.contains(requestID) }
    }

    public func openMedia(
        at path: String, targetTracks: [NSNumber]?,
        reply: @escaping @Sendable (Bool, String?, [String: Any]?) -> Void
    ) {
        reply(false, "A host-authorized read-only file handle is required", nil)
    }

    public func openFileMedia(
        _ file: FileHandle, targetTracks: [NSNumber]?,
        reply: @escaping @Sendable (Bool, String?, [String: Any]?) -> Void
    ) {
        Task {
            do {
                let flags = fcntl(file.fileDescriptor, F_GETFL)
                guard flags >= 0, flags & O_ACCMODE == O_RDONLY else {
                    throw MediaWorkerError.openFailed("Only read-only file handles are accepted")
                }
                // fdescfs duplicates only the supplied descriptor; no user path is resolved.
                let result = try await transport.openMedia(
                    path: "/dev/fd/\(file.fileDescriptor)", targetTracks: targetTracks?.map(\.intValue)
                )
                // PUBLISH: install the new lease. The lease it supersedes is
                // detached by the commit, so exactly one owner disposes of that
                // capability — and a close that is already in flight for the
                // superseded lease keeps owning it.
                switch commit(.publish(sessionId: result.sessionId, handle: file)) {
                case .callerOwns(let superseded):
                    if !dispose(capability: superseded.handle) {
                        // The superseded lease's capability could not be closed.
                        // The new lease is unaffected, so the superseded lease is
                        // retained: the responsibility stays observable instead of
                        // being swallowed.
                        commit(.retain(superseded))
                    }
                case .nothingToOwn, .restoredToActive, .retainedUnreleased:
                    break
                }
                reply(true, result.sessionId, result.metadata)
            } catch {
                try? file.close()
                reply(false, error.localizedDescription, nil)
            }
        }
    }

    public func subtitles(
        forSession sessionId: String, track: Int64,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        let requestID = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: sessionId)
        subtitles(forSession: sessionId, track: track, requestID: requestID, reply: reply)
    }

    public func subtitles(
        forSession sessionId: String,
        track: Int64,
        requestID: UInt64,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        Task {
            do {
                try validate(sessionId)
                let data = try await transport.subtitleData(
                    sessionId: sessionId,
                    track: track,
                    requestID: requestID
                )
                reply(data, nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    public func cancelSubtitle(
        forSession sessionId: String,
        requestID: UInt64,
        reply: @escaping @Sendable (Bool) -> Void
    ) {
        let matchesSession = lock.withLock { () -> Bool in
            guard held?.lease.sessionId == sessionId else { return false }
            if requestID != 0 {
                recordCancelledRequestLocked(requestID)
            }
            return true
        }
        if matchesSession {
            SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sessionId, requestID: requestID)
        }
        reply(matchesSession)
    }

    public func configureSubtitleRequestDelay(
        forRequestID requestID: UInt64,
        delayMs: UInt32,
        reply: @escaping @Sendable (Bool) -> Void
    ) {
        guard requestID != 0 else {
            reply(false)
            return
        }
        ttmedia_subtitles_set_request_cluster_delay_ms(requestID, delayMs)
        reply(true)
    }

    public func subtitleRequestStatus(
        forSession sessionId: String,
        requestID: UInt64,
        reply: @escaping @Sendable (Int32, UInt64, Bool) -> Void
    ) {
        let matchesSession = lock.withLock { held?.lease.sessionId == sessionId }
        let clusters = requestID != 0 ? ttmedia_subtitles_last_scanned_clusters(requestID) : 0
        let cancelled = matchesSession
            && SubtitleSessionRequestRegistry.shared.isCancelled(sessionId: sessionId, requestID: requestID)
        reply(getpid(), clusters, cancelled)
    }

    public func readNextPacket(forSession sessionId: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task {
            do {
                try validate(sessionId)
                reply(try await transport.readNextPacket(sessionId: sessionId), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    public func seek(
        to timestamp: Double, sessionId: String, accurate: Bool,
        reply: @escaping @Sendable (Bool, Double, String?) -> Void
    ) {
        Task {
            do {
                try validate(sessionId)
                reply(true, try await transport.seek(to: timestamp, sessionId: sessionId, accurate: accurate), nil)
            } catch { reply(false, timestamp, error.localizedDescription) }
        }
    }

    public func closeMedia(forSession sessionId: String, reply: @escaping @Sendable (Bool, String?) -> Void) {
        Task {
            // CLAIM the lease before any await. From here this call owns exactly
            // one capability: a lease published while the transport operation is
            // in flight can never be disposed by this close.
            let claim = commit(.claim(sessionId: sessionId))
            guard case .callerOwns(let claimed) = claim else {
                // Identity mismatch: the session is not the published lease, so
                // nothing was disposed and nothing may be reported as released.
                reply(false, Self.closeFailureMessage(.identityMismatch))
                return
            }
            SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: sessionId)
            do {
                try await transport.closeMedia(sessionId: sessionId)
            } catch {
                // The transport operation did not complete: the worker side may
                // still hold the session, so the lease must NOT be reported as
                // released. The lease may still serve media, so it can be
                // restored and the release retried.
                finishUnreleased(
                    claimed,
                    failure: .transportFailure(error.localizedDescription),
                    mayBecomeActive: true,
                    reply: reply
                )
                return
            }
            guard transport.currentSessionId != sessionId else {
                // The transport still owns the session: its side was not released.
                // The lease may still serve media, so it can be restored and the
                // release retried.
                finishUnreleased(
                    claimed,
                    failure: .transportFailure("the transport still owns the session"),
                    mayBecomeActive: true,
                    reply: reply
                )
                return
            }
            guard dispose(capability: claimed.handle) else {
                // The worker side is released, so the lease can never serve media
                // again and must not be published again. The capability could not
                // be closed, so the service keeps it and the responsibility stays
                // observable instead of being dropped.
                finishUnreleased(
                    claimed,
                    failure: .capabilityCloseFailed,
                    mayBecomeActive: false,
                    reply: reply
                )
                return
            }
            finishRetirement()
            reply(true, nil)
        }
    }

    public func setSleepState(state: Int, reply: @escaping @Sendable (Bool) -> Void) {
        reply(true)
    }

    public func invalidate() {
        // CLAIM the published lease before the asynchronous cleanup starts, so the
        // cleanup can only ever dispose of the lease it owns — never a lease that
        // is published after this point.
        let claim = commit(.claimCurrent)
        guard case .callerOwns(let claimed) = claim else { return }
        let sessionId = claimed.lease.sessionId
        SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: sessionId)
        Task { [self] in
            do {
                try await transport.closeMedia(sessionId: sessionId)
            } catch {
                // The worker side may still hold the session, so the release is NOT
                // confirmed. The lease is retained: the service keeps the
                // capability and owns the transport, so the responsibility stays
                // with it. It must not become active again — the connection is
                // going away.
                commit(.retain(claimed))
                finishRetirement()
                return
            }
            guard transport.currentSessionId != sessionId else {
                // The transport still owns the session: its side was not released,
                // so the release is NOT confirmed. The lease is retained for the
                // same reason as above — it must not become active again, and the
                // responsibility must not be dropped.
                commit(.retain(claimed))
                finishRetirement()
                return
            }
            guard dispose(capability: claimed.handle) else {
                // The worker side is released, but the capability could not be
                // closed. The service keeps the capability and the responsibility
                // stays observable instead of being dropped.
                commit(.retain(claimed))
                finishRetirement()
                return
            }
            // Both halves of the release are confirmed: the transport no longer
            // owns the session and the capability is closed. Nothing is retained,
            // so the service claims no responsibility it does not hold.
            finishRetirement()
        }
    }

    /// Completes a close that did **not** release the lease.
    ///
    /// - Parameter mayBecomeActive: whether the lease may still become the
    ///   active one. It is `false` once the worker side was released: the lease
    ///   can never serve media again, so publishing it would only publish a
    ///   zombie, while the capability it still holds must not be leaked.
    ///
    /// Restoring the **active** qualification and retaining the **unreleased
    /// cleanup responsibility** are two different facts:
    ///
    /// - The lease is restored as the active one when it may still become active
    ///   — its worker side was not released, so it can still serve media — and no
    ///   newer generation was published after the claim. Its capability was
    ///   never closed, so the lease is complete and the release can be retried.
    /// - Otherwise the lease is retained by the service. The service keeps the
    ///   capability and owns the transport that holds the worker side, so the
    ///   responsibility stays observable instead of being dropped.
    private func finishUnreleased(
        _ claimed: HeldLease,
        failure: MediaWorkerCloseFailure,
        mayBecomeActive: Bool,
        reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        switch commit(.restore(claimed, mayBecomeActive: mayBecomeActive)) {
        case .restoredToActive, .retainedUnreleased:
            // The service keeps the capability in both cases: restored as the
            // active lease, or retained as an unreleased one.
            break
        case .callerOwns, .nothingToOwn:
            // The commit handed the lease back, so this call still owns the
            // capability and disposes of it.
            _ = dispose(capability: claimed.handle)
        }
        finishRetirement()
        reply(false, Self.closeFailureMessage(failure))
    }

    private func validate(_ sessionId: String) throws {
        guard lock.withLock({ held?.lease.sessionId == sessionId }) else {
            throw MediaWorkerError.connectionInvalidated
        }
    }

    private func recordCancelledRequestLocked(_ requestID: UInt64) {
        if cancelledRequests.insert(requestID).inserted {
            cancelledRequestOrder.append(requestID)
            while cancelledRequestOrder.count > Self.maxCancelledRequestHistory {
                let evicted = cancelledRequestOrder.removeFirst()
                cancelledRequests.remove(evicted)
            }
        }
    }

    /// The single commit boundary for lease ownership.
    private enum LeaseAction {
        /// Install a newly opened lease; the lease it supersedes is detached.
        case publish(sessionId: String, handle: FileHandle)
        /// Detach the published lease for disposal, if the session still owns it.
        case claim(sessionId: String)
        /// Detach the published lease for disposal, whichever session it is.
        case claimCurrent
        /// Put a claimed lease back as the published one.
        ///
        /// - Parameter mayBecomeActive: whether the lease may still become the
        ///   active one **at all**. A lease whose worker side was already
        ///   released can never serve media again, so it must never be
        ///   published — it can only be retained as an unreleased one.
        case restore(HeldLease, mayBecomeActive: Bool)
        /// Keep a lease that can no longer be released under the service's care.
        case retain(HeldLease)
    }

    /// Where a lease's ownership went after a commit.
    ///
    /// Every case carries **exactly one** meaning, so a single optional can
    /// never be read as several different things at once.
    private enum LeaseCommitOutcome {
        /// The lease was detached; the caller owns it and must dispose of it.
        case callerOwns(HeldLease)
        /// Nothing was detached: the session is not the published lease, or
        /// nothing was superseded.
        case nothingToOwn
        /// The lease became the published one again: it is active, and it still
        /// needs cleanup.
        case restoredToActive
        /// The lease can no longer become active, but it still needs cleanup. The
        /// service **retains** it, so the responsibility is never dropped.
        case retainedUnreleased(HeldLease)
    }

    /// Performs the one and only mutation of the service's lease state.
    ///
    /// Every transition — publishing a newly opened lease, claiming a lease for
    /// disposal, claiming the published lease for invalidation, restoring a
    /// claimed lease, and retaining a lease that cannot be released — goes
    /// through here. The critical section never spans an `await`, and the
    /// identity check for a claim happens **inside** it, so it is decided
    /// against the state that is current at the moment of the claim rather than
    /// against a state observed before an await.
    ///
    /// - Returns: where the ownership went. The caller acts on the outcome; it
    ///   never has to guess what a missing lease meant.
    @discardableResult
    private func commit(_ action: LeaseAction) -> LeaseCommitOutcome {
        lock.withLock {
            switch action {
            case .publish(let sessionId, let handle):
                nextGeneration &+= 1
                let lease = ManagedLease(sessionId: sessionId, generation: nextGeneration)
                let superseded = held
                held = HeldLease(lease: lease, handle: handle)
                resetCancelledRequestsLocked()
                guard let superseded else { return .nothingToOwn }
                return .callerOwns(superseded)
            case .claim(let sessionId):
                guard let current = held, current.lease.sessionId == sessionId else { return .nothingToOwn }
                held = nil
                resetCancelledRequestsLocked()
                return .callerOwns(current)
            case .claimCurrent:
                guard let current = held else { return .nothingToOwn }
                held = nil
                resetCancelledRequestsLocked()
                return .callerOwns(current)
            case .restore(let claimed, let mayBecomeActive):
                // Restoring the **active** qualification and retaining the
                // **unreleased cleanup responsibility** are two different facts.
                //
                // The active qualification needs two things:
                //
                // 1. The lease may still become active **at all** — its worker
                //    side was not released, so it can still serve media. A lease
                //    whose worker side is gone is a zombie: publishing it would
                //    let callers issue media calls against a dead session.
                // 2. No newer generation was published after the claim. A newer
                //    generation is exactly the ABA case: the slot may be empty
                //    right now, but the old lease must never be revived over the
                //    newer one.
                //
                // When either condition fails, the lease cannot become active
                // again — but it still needs cleanup, so it is retained and the
                // responsibility stays observable instead of being dropped.
                guard mayBecomeActive, held == nil, claimed.lease.generation == nextGeneration else {
                    unreleasedLeases.append(claimed)
                    return .retainedUnreleased(claimed)
                }
                held = claimed
                return .restoredToActive
            case .retain(let claimed):
                unreleasedLeases.append(claimed)
                return .retainedUnreleased(claimed)
            }
        }
    }

    /// Records that one lease retirement reached its terminal state.
    private func finishRetirement() {
        lock.withLock { completedRetirementCountStorage += 1 }
    }

    /// Closes a capability that this call owns.
    ///
    /// - Returns: `true` when the capability was closed, `false` when the close
    ///   failed. A failed close is **not** a release: the caller must report the
    ///   failure instead of claiming the lease was released.
    private func dispose(capability: FileHandle) -> Bool {
        do {
            try capability.close()
            return true
        } catch {
            return false
        }
    }

    /// The wire reply carries a free-form error string, so the failure kind is
    /// encoded as a stable prefix the host can classify without a wire change.
    internal static func closeFailureMessage(_ failure: MediaWorkerCloseFailure) -> String {
        switch failure {
        case .identityMismatch:
            return "identity-mismatch: the session is not the published lease"
        case .transportFailure(let detail):
            return "transport-failure: \(detail)"
        case .capabilityCloseFailed:
            return "capability-close-failed: the managed capability could not be closed"
        }
    }

    private func resetCancelledRequestsLocked() {
        cancelledRequests.removeAll()
        cancelledRequestOrder.removeAll()
    }
}
