// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import TTZipApp
#else
@testable import TTZipAppServices
#endif

final class SemanticCancellationAdmissionGate: @unchecked Sendable {
    private let entered = BoundedSignalReceipt()
    private let lock = NSLock()
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                waiter = continuation
                entered.signal()
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitEntered(timeoutSeconds: Double) async -> Bool {
        await entered.wait(timeoutSeconds: timeoutSeconds)
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }
}

final class SemanticCoreAdmissionTests: XCTestCase {
    @MainActor
    func testReusedTicketCannotInvokeNativeTwice() async {
        let executor = SemanticCoreBlockingExecutor()
        let tracker = ControlledGenerationBindingTracker()
        let ticket = executor.admit(generation: 1, key: "search:single-use")
        let first = await executor.run(ticket: ticket, cancelled: -1) {
            tracker.recordSearch()
            return 1
        }
        let second = await executor.run(ticket: ticket, cancelled: -1) {
            tracker.recordSearch()
            return 2
        }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, -1)
        XCTAssertEqual(tracker.searchCount, 1)
        XCTAssertEqual(executor.pendingAdmissionCount, 0)
    }

    func testDiscardedUnexecutedAdmissionLeavesNoEntry() {
        let executor = SemanticCoreBlockingExecutor()
        let ticket = executor.admit(generation: 1, key: "search:discard")
        XCTAssertEqual(executor.pendingAdmissionCount, 1)
        executor.discard(ticket)
        XCTAssertEqual(executor.pendingAdmissionCount, 0)
        executor.cancelAll()
        XCTAssertEqual(executor.pendingAdmissionCount, 0)
    }

    @MainActor
    func testAdmittedOperationCancelledBeforeExecutionNeverInvokesNative() async {
        let executor = SemanticCoreBlockingExecutor()
        let entered = BoundedSignalReceipt()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let tracker = ControlledGenerationBindingTracker()
        let runningTicket = executor.admit(generation: 1, key: "running")
        let running = BoundedTaskHandle {
            await executor.run(ticket: runningTicket, cancelled: -1) {
                entered.signal()
                release.wait()
                return 1
            }
        }
        guard await entered.wait(timeoutSeconds: 2.0) else {
            release.signal()
            XCTFail("Native lane did not enter the blocker")
            return
        }
        let ticket = executor.admit(generation: 1, key: "search:queued")
        let queued = BoundedTaskHandle {
            await executor.run(ticket: ticket, cancelled: -1) {
                tracker.recordSearch()
                return 2
            }
        }
        XCTAssertEqual(executor.pendingAdmissionCount, 2)
        executor.cancel(key: "search:queued")
        release.signal()
        let runningResult = await running.valueIfCompleted(timeoutSeconds: 2.0)
        let queuedResult = await queued.valueIfCompleted(timeoutSeconds: 2.0)
        XCTAssertEqual(runningResult, 1)
        XCTAssertEqual(queuedResult, -1)
        XCTAssertEqual(tracker.searchCount, 0)
        XCTAssertEqual(executor.pendingAdmissionCount, 0)
    }

    @MainActor
    func testSessionRejectedAfterAdmissionDiscardsTicketAndReleasesBinding() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tracker = ControlledGenerationBindingTracker()
        let gate = SemanticCancellationAdmissionGate()
        defer { gate.release() }
        let bridge = UniFFIRustSemanticCoreBridge(
            storageDirectory: tmp,
            engineFactory: { _ in ControlledGenerationUniFFIDouble(tracker: tracker) },
            beforeNativeQueueWait: { _ in await gate.wait() }
        )
        let search = BoundedTaskHandle {
            await bridge.search(SemanticSearchRequest(requestId: 889, windowId: "discard", query: "queued"))
        }
        guard await gate.waitEntered(timeoutSeconds: 2.0) else {
            gate.release()
            XCTFail("Search did not reach the pre-helper admission gate")
            return
        }
        let admittedCount = await bridge.pendingNativeAdmissionCount
        XCTAssertEqual(admittedCount, 1)
        let destroyed = await bridge.shutdown()
        XCTAssertTrue(destroyed)
        gate.release()
        let response = await search.valueIfCompleted(timeoutSeconds: 2.0)
        let finalCount = await bridge.pendingNativeAdmissionCount
        XCTAssertEqual(response?.isCancelled, true)
        XCTAssertEqual(tracker.searchCount, 0)
        XCTAssertEqual(finalCount, 0)
        XCTAssertEqual(tracker.liveCount, 0)
    }
}
