// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
import os
@testable import TTZipApp
#if !SWIFT_PACKAGE
@testable import TTZipAppServices
@testable import TTZipAppViews
#endif

/// Exercises real Swift wrappers with count-only native operations and zero-node views.
/// This does not validate native mapping, parsing, IPC, or table layout.
@MainActor
final class VfsSnapshotLeaseTests: XCTestCase {
    func testAdoptedOwnerWithoutViewIsReleasedExactlyOnce() {
        let native = SnapshotReferenceCounter()
        let lease = VfsSnapshotLease(handle: native.handle, operations: native.operations)
        XCTAssertEqual(native.snapshot.references, 1)
        XCTAssertEqual(native.snapshot.acquireCalls, 0)
        lease.release()
        XCTAssertEqual(native.snapshot.references, 0)
        XCTAssertEqual(native.snapshot.releaseCalls, 1)
        assertNoInvalidOperations(native)
    }

    func testRepeatedViewAcquisitionDoesNotAccumulateReferences() {
        let native = SnapshotReferenceCounter()
        let lease = VfsSnapshotLease(handle: native.handle, operations: native.operations)
        for _ in 0..<8 {
            XCTAssertNotNil(lease.acquireView())
            XCTAssertEqual(native.snapshot.references, 1)
        }
        XCTAssertEqual(native.snapshot.acquireCalls, 8)
        XCTAssertEqual(native.snapshot.releaseCalls, 8)
        lease.release()
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testFailedViewAcquisitionDoesNotReleaseAnOwnedReference() {
        let native = SnapshotReferenceCounter()
        let lease = VfsSnapshotLease(handle: native.handle, operations: native.operations)
        native.failNextAcquire()
        XCTAssertNil(lease.acquireView())
        XCTAssertEqual(native.snapshot.references, 1)
        XCTAssertEqual(native.snapshot.acquireCalls, 1)
        XCTAssertEqual(native.snapshot.releaseCalls, 0)
        XCTAssertNotNil(lease.acquireView())
        XCTAssertEqual(native.snapshot.references, 1)
        lease.release()
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testReleasedWrapperDoesNotAttemptViewAcquisition() {
        let native = SnapshotReferenceCounter()
        let lease = VfsSnapshotLease(handle: native.handle, operations: native.operations)
        lease.release()
        XCTAssertNil(lease.acquireView())
        XCTAssertEqual(native.snapshot.acquireCalls, 0)
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testExplicitReleaseRepeatedAndDeinitRemainIdempotent() {
        let native = SnapshotReferenceCounter()
        var lease: VfsSnapshotLease? = VfsSnapshotLease(
            handle: native.handle,
            operations: native.operations
        )
        weak let observedLease = lease
        lease?.release()
        lease?.release()
        lease = nil
        XCTAssertNil(observedLease)
        XCTAssertEqual(native.snapshot.releaseCalls, 1)
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testDeinitReleasesAdoptedOwnerWithoutExplicitRelease() {
        let native = SnapshotReferenceCounter()
        autoreleasepool {
            let lease = VfsSnapshotLease(handle: native.handle, operations: native.operations)
            withExtendedLifetime(lease) {
                XCTAssertEqual(native.snapshot.references, 1)
            }
        }
        XCTAssertEqual(native.snapshot.releaseCalls, 1)
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testContextAndTwoDerivedOwnersCanReleaseContextFirst() {
        let native = SnapshotReferenceCounter()
        var context: VfsSnapshotContext? = VfsSnapshotContext(
            lease: native.handle,
            operations: native.operations
        )
        let first = context!.acquireLease()
        let second = context!.acquireLease()
        XCTAssertEqual(native.snapshot.references, 3)
        context = nil
        XCTAssertEqual(native.snapshot.references, 2)
        first.release()
        XCTAssertEqual(native.snapshot.references, 1)
        XCTAssertNotNil(second.acquireView())
        XCTAssertEqual(native.snapshot.references, 1)
        second.release()
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testDerivedOwnerCanReleaseBeforeContext() {
        let native = SnapshotReferenceCounter()
        var context: VfsSnapshotContext? = VfsSnapshotContext(
            lease: native.handle,
            operations: native.operations
        )
        let lease = context!.acquireLease()
        XCTAssertEqual(native.snapshot.references, 2)
        lease.release()
        XCTAssertEqual(native.snapshot.references, 1)
        context?.withSnapshot { view in
            XCTAssertEqual(view.node_count, 0)
            XCTAssertEqual(native.snapshot.references, 2)
        }
        XCTAssertEqual(native.snapshot.references, 1)
        context = nil
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testTwoAdaptersRetainIndependentOwnersFromAnExternalWrapper() {
        let native = SnapshotReferenceCounter()
        let lease = VfsSnapshotLease(handle: native.handle, operations: native.operations)
        var first: NativeArchiveTableViewAdapter? = NativeArchiveTableViewAdapter(snapshotLease: lease)
        var second: NativeArchiveTableViewAdapter? = NativeArchiveTableViewAdapter(snapshotLease: lease)
        XCTAssertEqual(first?.totalRowCount, 0)
        XCTAssertEqual(second?.totalRowCount, 0)
        XCTAssertEqual(native.snapshot.references, 3)
        lease.release()
        XCTAssertEqual(native.snapshot.references, 2)
        first = nil
        XCTAssertEqual(native.snapshot.references, 1)
        XCTAssertEqual(second?.totalRowCount, 0)
        second = nil
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testContextAdapterKeepsItsOwnersAfterExternalContextIsDropped() {
        let native = SnapshotReferenceCounter()
        var context: VfsSnapshotContext? = VfsSnapshotContext(
            lease: native.handle,
            operations: native.operations
        )
        weak let observedContext = context
        var adapter: NativeArchiveTableViewAdapter? = NativeArchiveTableViewAdapter(snapshotContext: context!)
        XCTAssertEqual(adapter?.totalRowCount, 0)
        XCTAssertEqual(native.snapshot.references, 2)
        context = nil
        XCTAssertNotNil(observedContext, "The adapter also keeps the context alive")
        XCTAssertEqual(native.snapshot.references, 2)
        adapter = nil
        XCTAssertNil(observedContext)
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testContextAdapterCanReleaseBeforeExternalContext() {
        let native = SnapshotReferenceCounter()
        var context: VfsSnapshotContext? = VfsSnapshotContext(
            lease: native.handle,
            operations: native.operations
        )
        var adapter: NativeArchiveTableViewAdapter? = NativeArchiveTableViewAdapter(snapshotContext: context!)
        XCTAssertEqual(adapter?.totalRowCount, 0)
        XCTAssertEqual(native.snapshot.references, 2)
        adapter = nil
        XCTAssertEqual(native.snapshot.references, 1)
        context?.withSnapshot { view in
            XCTAssertEqual(view.node_count, 0)
        }
        XCTAssertEqual(native.snapshot.references, 1)
        context = nil
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testAdapterCannotTakeOwnershipFromAReleasedWrapper() {
        let native = SnapshotReferenceCounter()
        let lease = VfsSnapshotLease(handle: native.handle, operations: native.operations)
        lease.release()
        autoreleasepool {
            let adapter = NativeArchiveTableViewAdapter(snapshotLease: lease)
            XCTAssertEqual(adapter.totalRowCount, 0)
            XCTAssertEqual(native.snapshot.acquireCalls, 0)
        }
        XCTAssertEqual(native.snapshot.references, 0)
        XCTAssertEqual(native.snapshot.releaseCalls, 1)
        assertNoInvalidOperations(native)
    }

    func testFailedAdapterRetainDoesNotConsumeTheExternalOwner() {
        let native = SnapshotReferenceCounter()
        let lease = VfsSnapshotLease(handle: native.handle, operations: native.operations)
        native.failNextAcquire()
        autoreleasepool {
            let adapter = NativeArchiveTableViewAdapter(snapshotLease: lease)
            XCTAssertEqual(adapter.totalRowCount, 0)
            XCTAssertEqual(native.snapshot.references, 1)
            XCTAssertEqual(native.snapshot.releaseCalls, 0)
        }
        XCTAssertEqual(native.snapshot.references, 1)
        XCTAssertNotNil(lease.acquireView())
        lease.release()
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testWrapperCanCreateAnIndependentOwner() {
        let native = SnapshotReferenceCounter()
        let source = VfsSnapshotLease(handle: native.handle, operations: native.operations)
        let derived = source.acquireLease()
        XCTAssertNotNil(derived)
        XCTAssertEqual(native.snapshot.references, 2)
        source.release()
        XCTAssertEqual(native.snapshot.references, 1)
        XCTAssertNotNil(derived?.acquireView())
        XCTAssertEqual(native.snapshot.references, 1)
        derived?.release()
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testReleasedWrapperCannotCreateAnotherOwner() {
        let native = SnapshotReferenceCounter()
        let source = VfsSnapshotLease(handle: native.handle, operations: native.operations)
        source.release()
        XCTAssertNil(source.acquireLease())
        XCTAssertEqual(native.snapshot.acquireCalls, 0)
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    func testFailedOwnerAcquisitionDoesNotReleaseTheSourceOwner() {
        let native = SnapshotReferenceCounter()
        let source = VfsSnapshotLease(handle: native.handle, operations: native.operations)
        native.failNextAcquire()
        XCTAssertNil(source.acquireLease())
        XCTAssertEqual(native.snapshot.acquireCalls, 1)
        XCTAssertEqual(native.snapshot.releaseCalls, 0)
        XCTAssertEqual(native.snapshot.references, 1)
        XCTAssertNotNil(source.acquireView())
        XCTAssertEqual(native.snapshot.references, 1)
        source.release()
        XCTAssertEqual(native.snapshot.references, 0)
        assertNoInvalidOperations(native)
    }

    private func assertNoInvalidOperations(
        _ native: SnapshotReferenceCounter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(native.snapshot.invalidHandleCalls, 0, file: file, line: line)
        XCTAssertEqual(native.snapshot.zeroOwnerAcquires, 0, file: file, line: line)
        XCTAssertEqual(native.snapshot.underflowReleases, 0, file: file, line: line)
    }
}

/// No pointer is allocated, read or freed: the token is used only for equality checks.
private final class SnapshotReferenceCounter: @unchecked Sendable {
    struct State: Sendable {
        var references = 1
        var acquireCalls = 0
        var releaseCalls = 0
        var invalidHandleCalls = 0
        var zeroOwnerAcquires = 0
        var underflowReleases = 0
        var failNextAcquire = false
    }

    let handle = OpaquePointer(bitPattern: 0x5A17)!
    private let state = OSAllocatedUnfairLock(initialState: State())

    var snapshot: State { state.withLock { $0 } }

    var operations: VfsSnapshotOperations {
        VfsSnapshotOperations(
            acquire: { [self] handle, view in acquire(handle, into: view) },
            release: { [self] handle in release(handle) }
        )
    }

    func failNextAcquire() {
        state.withLock { $0.failNextAcquire = true }
    }

    private func acquire(
        _ candidate: OpaquePointer,
        into view: UnsafeMutablePointer<TTWorkspaceVfsView>
    ) -> UInt8 {
        let matchesHandle = candidate == handle
        let succeeded: Bool = state.withLock { value in
            value.acquireCalls += 1
            guard matchesHandle else {
                value.invalidHandleCalls += 1
                return false
            }
            guard value.references > 0 else {
                value.zeroOwnerAcquires += 1
                return false
            }
            if value.failNextAcquire {
                value.failNextAcquire = false
                return false
            }
            value.references += 1
            return true
        }
        guard succeeded else { return 0 }
        view.pointee = TTWorkspaceVfsView()
        return 1
    }

    private func release(_ candidate: OpaquePointer) {
        let matchesHandle = candidate == handle
        state.withLock { value in
            value.releaseCalls += 1
            guard matchesHandle else {
                value.invalidHandleCalls += 1
                return
            }
            guard value.references > 0 else {
                value.underflowReleases += 1
                return
            }
            value.references -= 1
        }
    }
}
