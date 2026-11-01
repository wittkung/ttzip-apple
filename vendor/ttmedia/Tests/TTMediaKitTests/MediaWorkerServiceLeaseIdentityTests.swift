// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import XCTest
@testable import TTMediaKit

// MARK: - Bounded wait

/// Resumes a wait exactly once, whichever side arrives first.
///
/// The test side must never block forever on a service reply, so every wait is
/// bounded: the timeout resolves the wait, and the late reply is discarded
/// instead of resuming a continuation twice.
private final class BoundedWait<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?

    /// Installs the waiting continuation.
    /// - Returns: a result that already arrived, if there was one.
    func install(_ continuation: CheckedContinuation<T, Error>) -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        if let pending {
            self.pending = nil
            return pending
        }
        self.continuation = continuation
        return nil
    }

    /// Resolves the wait, exactly once.
    func resolve(_ result: Result<T, Error>) {
        lock.lock()
        if let continuation = self.continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.pending = result
        lock.unlock()
    }
}

// MARK: - Controlled transport

/// A transport whose close boundary can be parked, so a test can interleave an
/// in-flight close with a superseding open or an invalidation.
///
/// The service under test is the **production** `MediaWorkerService`; only the
/// transport boundary is controlled, through the service's internal injection
/// seam.
private final class ControlledServiceTransport: MediaWorkerServiceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var activeSessionId: String?
    private var closedSessionIds: [String] = []
    private var replacedSessionIds: [String] = []
    private var openCount = 0
    private var shouldHoldClose = false
    private var shouldFailClose = false
    private var shouldFailAfterRelease = false
    private var didEnterClose = false
    private var didCompleteClose = false
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var isCloseReleased = false
    private var closeEntryWaiters: [CheckedContinuation<Bool, Never>] = []
    private var closeCompletionWaiters: [CheckedContinuation<Bool, Never>] = []

    var currentSessionId: String? { lock.withLock { activeSessionId } }
    var closedSessions: [String] { lock.withLock { closedSessionIds } }
    var replacedSessions: [String] { lock.withLock { replacedSessionIds } }

    // MARK: Synchronous helpers
    //
    // Every critical section lives in a synchronous helper, so the lock is never
    // taken from an asynchronous context.

    /// Parks the next close inside the transport until `releaseClose()` is called.
    func holdNextClose() {
        lock.withLock { shouldHoldClose = true }
    }

    /// Makes the next close fail.
    func failNextClose() {
        lock.withLock { shouldFailClose = true }
    }

    /// Makes the parked close fail once it is released.
    func failCloseAfterRelease() {
        lock.withLock { shouldFailAfterRelease = true }
    }

    /// Releases the parked close.
    func releaseClose() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            isCloseReleased = true
            let continuation = closeContinuation
            closeContinuation = nil
            return continuation
        }
        pending?.resume()
    }

    private var hasEnteredClose: Bool { lock.withLock { didEnterClose } }
    private var hasCompletedClose: Bool { lock.withLock { didCompleteClose } }

    private func registerCloseEntryWaiter(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didEnterClose { return false }
        closeEntryWaiters.append(continuation)
        return true
    }

    private func takeCloseEntryWaiters() -> [CheckedContinuation<Bool, Never>] {
        lock.lock()
        defer { lock.unlock() }
        let pending = closeEntryWaiters
        closeEntryWaiters.removeAll()
        return pending
    }

    private func registerCloseCompletionWaiter(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didCompleteClose { return false }
        closeCompletionWaiters.append(continuation)
        return true
    }

    private func takeCloseCompletionWaiters() -> [CheckedContinuation<Bool, Never>] {
        lock.lock()
        defer { lock.unlock() }
        let pending = closeCompletionWaiters
        closeCompletionWaiters.removeAll()
        return pending
    }

    /// Decides whether this close should park, and whether it should fail.
    private func beginClose() -> (shouldHold: Bool, shouldFail: Bool, shouldFailAfterRelease: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let shouldHold = shouldHoldClose
        shouldHoldClose = false
        let shouldFail = shouldFailClose
        shouldFailClose = false
        let failAfterRelease = shouldFailAfterRelease
        shouldFailAfterRelease = false
        return (shouldHold, shouldFail, failAfterRelease)
    }

    /// Marks the close as having entered the transport boundary.
    private func markCloseEntered() {
        let waiters: [CheckedContinuation<Bool, Never>] = lock.withLock {
            didEnterClose = true
            let pending = closeEntryWaiters
            closeEntryWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume(returning: true) }
    }

    /// Parks the close until it is released.
    private func parkUntilReleased() async {
        let alreadyReleased: Bool = lock.withLock { isCloseReleased }
        if alreadyReleased { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if isCloseReleased { return true }
                closeContinuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Completes the close: a stale close is a silent no-op, exactly like the
    /// real transport.
    private func finishClose(sessionId: String) {
        let waiters: [CheckedContinuation<Bool, Never>] = lock.withLock {
            if activeSessionId == sessionId {
                activeSessionId = nil
                closedSessionIds.append(sessionId)
            }
            didCompleteClose = true
            let pending = closeCompletionWaiters
            closeCompletionWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume(returning: true) }
    }

    /// Opens a session; the real transport releases the previous demuxer handle
    /// on replace.
    private func openSession() -> String {
        lock.lock()
        defer { lock.unlock() }
        openCount += 1
        let sessionId = "controlled-session-\(openCount)"
        if let previous = activeSessionId {
            replacedSessionIds.append(previous)
        }
        activeSessionId = sessionId
        return sessionId
    }

    // MARK: Transport operations

    func openMedia(
        path: String, targetTracks: [Int]?
    ) async throws -> (sessionId: String, metadata: [String: Any]) {
        (openSession(), ["format": "mkv"])
    }

    func closeMedia(sessionId: String) async throws {
        let (shouldHold, shouldFail, shouldFailAfterRelease) = beginClose()
        if shouldFail {
            throw MediaWorkerError.closeFailed("controlled transport failure")
        }
        if shouldHold {
            markCloseEntered()
            await parkUntilReleased()
            if shouldFailAfterRelease {
                throw MediaWorkerError.closeFailed("controlled transport failure after release")
            }
        }
        finishClose(sessionId: sessionId)
    }

    func readNextPacket(sessionId: String) async throws -> Data? { nil }
    func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double { timestamp }
    func subtitleData(sessionId: String, track: Int64, requestID: UInt64) async throws -> Data { Data() }

    // MARK: Bounded waits

    /// Waits, with a bound, until a close has entered the transport.
    func waitForCloseEntry(boundedBy budget: TimeInterval) async -> Bool {
        if hasEnteredClose { return true }
        return await withCheckedContinuation { continuation in
            guard registerCloseEntryWaiter(continuation) else {
                continuation.resume(returning: true)
                return
            }
            Task {
                try? await Task.sleep(for: .milliseconds(Int(budget * 1000)))
                for waiter in takeCloseEntryWaiters() { waiter.resume(returning: false) }
            }
        }
    }

    /// Waits, with a bound, until a parked close has completed.
    func waitForCloseCompletion(boundedBy budget: TimeInterval) async -> Bool {
        if hasCompletedClose { return true }
        return await withCheckedContinuation { continuation in
            guard registerCloseCompletionWaiter(continuation) else {
                continuation.resume(returning: true)
                return
            }
            Task {
                try? await Task.sleep(for: .milliseconds(Int(budget * 1000)))
                for waiter in takeCloseCompletionWaiters() { waiter.resume(returning: false) }
            }
        }
    }
}

// MARK: - Service lease identity

/// The service's lease identity rules.
///
/// A managed lease is owned by exactly one disposer, and an asynchronous
/// completion may only dispose of the lease it claimed. Restoring the **active**
/// qualification and retaining the **unreleased cleanup responsibility** are two
/// different facts: a lease whose generation was superseded may never become
/// active again, but its responsibility must never be dropped either.
///
/// These tests drive the **production** `MediaWorkerService` through its
/// internal injection seam.
final class MediaWorkerServiceLeaseIdentityTests: XCTestCase {

    private var fixtureURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ttzip-mm38-lease-\(UUID().uuidString).bin")
        try Data([0x1A, 0x45, 0xDF, 0xA3]).write(to: fixtureURL)
    }

    override func tearDownWithError() throws {
        if let fixtureURL { try? FileManager.default.removeItem(at: fixtureURL) }
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private func makeHandle() throws -> FileHandle {
        try FileHandle(forReadingFrom: fixtureURL)
    }

    /// Opens a lease. The wait is **bounded**: a service that never replies
    /// fails the test instead of hanging it.
    @discardableResult
    private func open(
        _ service: MediaWorkerService,
        _ handle: FileHandle,
        budget: TimeInterval = 2.0
    ) async throws -> String {
        let waiter = BoundedWait<String>()
        return try await withCheckedThrowingContinuation { continuation in
            if let ready = waiter.install(continuation) {
                continuation.resume(with: ready)
                return
            }
            service.openFileMedia(handle, targetTracks: nil) { success, sessionId, _ in
                if success, let sessionId {
                    waiter.resolve(.success(sessionId))
                } else {
                    waiter.resolve(.failure(MediaWorkerError.openFailed("open failed")))
                }
            }
            Task {
                try? await Task.sleep(for: .milliseconds(Int(budget * 1000)))
                waiter.resolve(.failure(MediaWorkerError.openFailed("open timed out")))
            }
        }
    }

    /// Closes a lease. The wait is **bounded** for the same reason.
    private func close(
        _ service: MediaWorkerService,
        sessionId: String,
        budget: TimeInterval = 2.0
    ) async -> (success: Bool, message: String?) {
        let waiter = BoundedWait<(success: Bool, message: String?)>()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                if let ready = waiter.install(continuation) {
                    continuation.resume(with: ready)
                    return
                }
                service.closeMedia(forSession: sessionId) { success, message in
                    waiter.resolve(.success((success: success, message: message)))
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(Int(budget * 1000)))
                    waiter.resolve(.failure(MediaWorkerError.closeFailed("close timed out")))
                }
            }
        } catch {
            return (success: false, message: "close timed out")
        }
    }

    /// Waits for the **service's own** retirement to reach a terminal state.
    ///
    /// The transport's completion receipt is earlier than the service's own
    /// cleanup, so it cannot prove the cleanup finished. This waits for the
    /// service's observable terminal state, and it waits for the *condition* —
    /// it exits as soon as the condition holds and fails when the budget is
    /// exhausted, rather than sleeping for a fixed duration.
    private func waitForRetirement(
        _ service: MediaWorkerService,
        toReach count: Int,
        budget: TimeInterval = 2.0
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int(budget * 1000)))
        while clock.now < deadline {
            if service.completedRetirementCount >= count { return true }
            await Task.yield()
        }
        return service.completedRetirementCount >= count
    }

    // MARK: ① A close that entered before a superseding open

    func testCloseThatEnteredBeforeASupersedingOpenCannotDisposeTheNewLease() async throws {
        let transport = ControlledServiceTransport()
        transport.holdNextClose()
        let service = MediaWorkerService(transport: transport)

        let handleA = try makeHandle()
        let idA = try await open(service, handleA)

        // The close parks inside the transport.
        let closeTask = Task { await self.close(service, sessionId: idA) }
        let entered = await transport.waitForCloseEntry(boundedBy: 2.0)
        XCTAssertTrue(entered, "the close must reach the controlled transport boundary")
        if !entered {
            // Release the controlled work unconditionally before finishing.
            transport.releaseClose()
            _ = await closeTask.value
            return
        }

        // A second lease is published while A's close is still parked.
        let handleB = try makeHandle()
        let fdB = handleB.fileDescriptor
        let idB = try await open(service, handleB)
        XCTAssertNotEqual(idA, idB)
        XCTAssertNotEqual(fcntl(fdB, F_GETFD), -1, "B's capability must be live before A's close completes")

        // A's close now completes.
        transport.releaseClose()
        let result = await closeTask.value

        XCTAssertTrue(result.success, "A's close completed its transport operation")
        XCTAssertNotEqual(
            fcntl(fdB, F_GETFD), -1,
            "A's close must NOT dispose of the capability that belongs to B"
        )
        XCTAssertEqual(transport.currentSessionId, idB, "the transport must still own B")
        XCTAssertEqual(service.currentLeaseIdentity?.sessionId, idB, "B must remain the published lease")
    }

    // MARK: ② A failed release must not be reported as a confirmed release

    func testAFailedTransportReleaseIsNotReportedAsReleased() async throws {
        let transport = ControlledServiceTransport()
        transport.failNextClose()
        let service = MediaWorkerService(transport: transport)

        let handle = try makeHandle()
        let fd = handle.fileDescriptor
        let sessionId = try await open(service, handle)

        let result = await close(service, sessionId: sessionId)

        XCTAssertFalse(result.success, "a failed release must not be reported as released")
        let message = result.message ?? ""
        XCTAssertTrue(
            message.hasPrefix("transport-failure:"),
            "the failure kind must be explicit, got: \(message)"
        )
        // The release did not happen, so the lease must stay visible: its
        // responsibility is never dropped by a failed attempt.
        XCTAssertEqual(
            service.currentLeaseIdentity?.sessionId, sessionId,
            "a failed release must leave the lease visible, not drop it"
        )
        XCTAssertNotEqual(
            fcntl(fd, F_GETFD), -1,
            "the capability of an unreleased lease must not be closed behind the caller's back"
        )
    }

    func testALeaseWhoseReleaseFailedCanBeClosedAgain() async throws {
        let transport = ControlledServiceTransport()
        transport.failNextClose()
        let service = MediaWorkerService(transport: transport)

        let handle = try makeHandle()
        let fd = handle.fileDescriptor
        let sessionId = try await open(service, handle)

        let failed = await close(service, sessionId: sessionId)
        XCTAssertFalse(failed.success)

        // The lease is still published, so a retry can finish the release.
        let retried = await close(service, sessionId: sessionId)
        XCTAssertTrue(retried.success, "a retry must be able to complete the release")
        XCTAssertNil(retried.message)
        XCTAssertEqual(fcntl(fd, F_GETFD), -1, "the successful retry must close the capability")
        XCTAssertNil(service.currentLeaseIdentity, "a released lease is no longer published")
    }

    // MARK: ③ The ABA case: a superseded generation may never be restored as active

    func testARestoreAfterANewerGenerationIsRejectedAndTheResponsibilityIsKept() async throws {
        let transport = ControlledServiceTransport()
        transport.holdNextClose()
        transport.failCloseAfterRelease()
        let service = MediaWorkerService(transport: transport)

        let handleA = try makeHandle()
        let fdA = handleA.fileDescriptor
        let idA = try await open(service, handleA)

        // A's close claims the lease and parks inside the transport.
        let closeA = Task { await self.close(service, sessionId: idA) }
        let entered = await transport.waitForCloseEntry(boundedBy: 2.0)
        XCTAssertTrue(entered, "the close must reach the controlled transport boundary")
        if !entered {
            transport.releaseClose()
            _ = await closeA.value
            return
        }

        // B is published while A's close is parked.
        let handleB = try makeHandle()
        let fdB = handleB.fileDescriptor
        let idB = try await open(service, handleB)
        XCTAssertNotEqual(idA, idB)

        // B is closed and released, so the slot is empty again.
        let closeB = await close(service, sessionId: idB)
        XCTAssertTrue(closeB.success, "B's close releases the lease")
        XCTAssertNil(service.currentLeaseIdentity, "the slot is empty after B's close")

        // Now A's close fails and tries to restore itself.
        transport.releaseClose()
        let resultA = await closeA.value
        XCTAssertFalse(resultA.success, "A's failed release must not be reported as released")

        // The ABA: A must NOT be revived as the active lease, even though the
        // slot is empty and A was the last lease to be claimed.
        XCTAssertNotEqual(
            service.currentLeaseIdentity?.sessionId, idA,
            "a lease whose generation was superseded must never be restored as active"
        )
        XCTAssertNil(
            service.currentLeaseIdentity,
            "no lease may be active after both closes finished"
        )
        // B was closed deliberately, so B's capability is legitimately gone.
        XCTAssertEqual(fcntl(fdB, F_GETFD), -1, "B's capability was released by B's own close")
        // A was not released: the service keeps its capability with the retained
        // lease, so the responsibility is not dropped.
        XCTAssertNotEqual(
            fcntl(fdA, F_GETFD), -1,
            "A's capability must stay held by the retained lease"
        )
        // The responsibility is not dropped: A is retained and observable.
        XCTAssertTrue(
            service.unreleasedLeaseIdentities.contains { $0.sessionId == idA },
            "the unreleased lease must stay observable instead of being dropped"
        )
    }

    /// The other half of the ABA protection: while a newer lease is still
    /// published, the old lease's restore must not displace it.
    func testARestoreNeverDisplacesTheNewerPublishedLease() async throws {
        let transport = ControlledServiceTransport()
        transport.holdNextClose()
        transport.failCloseAfterRelease()
        let service = MediaWorkerService(transport: transport)

        let handleA = try makeHandle()
        let idA = try await open(service, handleA)

        let closeA = Task { await self.close(service, sessionId: idA) }
        let entered = await transport.waitForCloseEntry(boundedBy: 2.0)
        XCTAssertTrue(entered, "the close must reach the controlled transport boundary")
        if !entered {
            transport.releaseClose()
            _ = await closeA.value
            return
        }

        // B is published and stays published while A's close is parked.
        let handleB = try makeHandle()
        let fdB = handleB.fileDescriptor
        let idB = try await open(service, handleB)
        XCTAssertNotEqual(idA, idB)

        // A's close fails while B is still the published lease.
        transport.releaseClose()
        let resultA = await closeA.value
        XCTAssertFalse(resultA.success, "A's failed release must not be reported as released")

        // The newer lease survives: it is still active and its capability is alive.
        XCTAssertEqual(service.currentLeaseIdentity?.sessionId, idB, "the newer lease must survive the restore")
        XCTAssertNotEqual(fcntl(fdB, F_GETFD), -1, "the newer lease's capability must stay alive")
        XCTAssertEqual(transport.currentSessionId, idB, "the transport must still own the newer lease")
        // A's responsibility is retained, not dropped.
        XCTAssertTrue(
            service.unreleasedLeaseIdentities.contains { $0.sessionId == idA },
            "the unreleased lease must stay observable instead of being dropped"
        )
    }

    // MARK: ④ Normal cycles, and a stale retry must not touch the current lease

    func testNormalOpenCloseCyclesStayAvailableAndAStaleRetryDoesNotTouchTheCurrentLease() async throws {
        let transport = ControlledServiceTransport()
        let service = MediaWorkerService(transport: transport)

        var staleSessionId = ""
        for round in 0..<12 {
            let handle = try makeHandle()
            let sessionId = try await open(service, handle)
            let result = await close(service, sessionId: sessionId)
            XCTAssertTrue(result.success, "round \(round) must release its lease")
            if round == 0 { staleSessionId = sessionId }
        }
        XCTAssertEqual(transport.closedSessions.count, 12, "every round must reach the transport exactly once")

        // The current lease.
        let handle = try makeHandle()
        let currentId = try await open(service, handle)

        // A retry of an old session must not touch the current lease.
        let stale = await close(service, sessionId: staleSessionId)
        XCTAssertFalse(stale.success, "a stale retry must not report a release")
        XCTAssertTrue(
            (stale.message ?? "").hasPrefix("identity-mismatch:"),
            "a stale retry must be reported as an identity mismatch, got: \(stale.message ?? "nil")"
        )
        XCTAssertEqual(service.currentLeaseIdentity?.sessionId, currentId, "the current lease must survive a stale retry")
        XCTAssertEqual(transport.currentSessionId, currentId, "the transport must still own the current session")
    }

    func testTheSecondCloseOfTheSameSessionIsAnIdentityMismatch() async throws {
        let transport = ControlledServiceTransport()
        let service = MediaWorkerService(transport: transport)

        let handle = try makeHandle()
        let sessionId = try await open(service, handle)

        let first = await close(service, sessionId: sessionId)
        XCTAssertTrue(first.success, "the first close releases the lease")
        XCTAssertNil(first.message)

        let second = await close(service, sessionId: sessionId)
        XCTAssertFalse(second.success, "a repeated close must not report a release")
        XCTAssertTrue(
            (second.message ?? "").hasPrefix("identity-mismatch:"),
            "a repeated close must be reported as an identity mismatch, got: \(second.message ?? "nil")"
        )
        XCTAssertEqual(transport.closedSessions.count, 1, "the transport must not be closed twice")
    }

    // MARK: ⑤ open / invalidate interleaving

    /// A confirmed invalidation releases both halves of the lease: the transport
    /// no longer owns the session and the capability is closed.
    ///
    /// It must not leave a retained responsibility behind — a service that keeps
    /// claiming ownership of a lease it already released is exactly the kind of
    /// false ownership this contract forbids.
    func testASuccessfulInvalidationClosesTheCapabilityAndRetainsNoResponsibility() async throws {
        let transport = ControlledServiceTransport()
        let service = MediaWorkerService(transport: transport)

        let handle = try makeHandle()
        let fd = handle.fileDescriptor
        _ = try await open(service, handle)

        service.invalidate()

        // The assertion point is the service's own terminal state.
        let completed = await waitForRetirement(service, toReach: 1)
        XCTAssertTrue(completed, "the invalidation must reach a terminal state")
        XCTAssertEqual(
            fcntl(fd, F_GETFD), -1,
            "a confirmed release must close the capability it owns"
        )
        XCTAssertTrue(
            service.unreleasedLeaseIdentities.isEmpty,
            "a confirmed release must not leave a retained responsibility behind"
        )
        XCTAssertNil(service.currentLeaseIdentity, "an invalidated lease must not stay published")
    }

    /// The other half: an invalidation whose transport release is not confirmed
    /// keeps an **observable owner**. The service keeps the capability and owns
    /// the transport that may still hold the worker side.
    func testAnInvalidationWhoseReleaseIsNotConfirmedKeepsAnObservableOwner() async throws {
        let transport = ControlledServiceTransport()
        transport.failNextClose()
        let service = MediaWorkerService(transport: transport)

        let handle = try makeHandle()
        let fd = handle.fileDescriptor
        let sessionId = try await open(service, handle)

        service.invalidate()

        let completed = await waitForRetirement(service, toReach: 1)
        XCTAssertTrue(completed, "the invalidation must reach a terminal state")
        XCTAssertTrue(
            service.unreleasedLeaseIdentities.contains { $0.sessionId == sessionId },
            "an unconfirmed release must keep an observable owner instead of dropping the responsibility"
        )
        XCTAssertNotEqual(
            fcntl(fd, F_GETFD), -1,
            "the retained capability must stay with the service that owns it"
        )
        XCTAssertNil(
            service.currentLeaseIdentity,
            "an invalidated lease must not become active again — the connection is going away"
        )
    }

    func testInvalidateCannotDisposeALeasePublishedAfterItStarted() async throws {
        let transport = ControlledServiceTransport()
        transport.holdNextClose()
        let service = MediaWorkerService(transport: transport)

        let handleA = try makeHandle()
        let idA = try await open(service, handleA)

        // Invalidation claims the published lease and parks its cleanup.
        service.invalidate()
        let entered = await transport.waitForCloseEntry(boundedBy: 2.0)
        XCTAssertTrue(entered, "the invalidation cleanup must reach the controlled transport boundary")
        if !entered {
            transport.releaseClose()
            return
        }

        // A new lease is published while the invalidation cleanup is parked.
        let handleB = try makeHandle()
        let fdB = handleB.fileDescriptor
        let idB = try await open(service, handleB)
        XCTAssertNotEqual(idA, idB)
        XCTAssertNotEqual(fcntl(fdB, F_GETFD), -1, "B's capability must be live")

        transport.releaseClose()

        // The assertion point is the **service's own** terminal state, not the
        // transport's earlier receipt.
        let completed = await waitForRetirement(service, toReach: 1)
        XCTAssertTrue(completed, "the service's invalidate cleanup must reach a terminal state")
        XCTAssertNotEqual(
            fcntl(fdB, F_GETFD), -1,
            "the invalidation cleanup must NOT dispose of the capability that belongs to B"
        )
        XCTAssertEqual(service.currentLeaseIdentity?.sessionId, idB, "B must remain the published lease")
        XCTAssertEqual(transport.currentSessionId, idB, "the transport must still own B")
    }
}
