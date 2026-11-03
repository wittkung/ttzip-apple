// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Dispatch
import Foundation
import XCTest
@testable import TTZipApp

/// Records what the memory pressure handler saw and delivered.
private final class MemoryPressureDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveredEvents: [DispatchSource.MemoryPressureEvent] = []
    private var readOnMainThread = true
    private var deliveredOnMainThread = false

    /// The thread the handler body ran on when it read the source event.
    var handlerRanOnMainThread: Bool {
        lock.withLock { readOnMainThread }
    }

    /// The thread the delivery closure ran on.
    var deliveryRanOnMainThread: Bool {
        lock.withLock { deliveredOnMainThread }
    }

    var events: [DispatchSource.MemoryPressureEvent] {
        lock.withLock { deliveredEvents }
    }

    func recordEventRead(onMainThread: Bool) {
        lock.withLock { readOnMainThread = onMainThread }
    }

    func recordDelivery(_ event: DispatchSource.MemoryPressureEvent, onMainThread: Bool) {
        lock.withLock {
            deliveredEvents.append(event)
            deliveredOnMainThread = onMainThread
        }
    }
}

/// Regression coverage for issue #114.
///
/// The Darwin memory pressure handler used to be formed inside a `@MainActor` context.
/// `setEventHandler` takes a C block, so Swift 6 wrapped the isolated closure in a thunk
/// that verifies the running executor. GCD fired that callback on the source's background
/// queue, the check failed, and TTZip died with `EXC_BREAKPOINT` instead of reacting to
/// memory pressure.
@MainActor
final class MemoryPressureIsolationTests: XCTestCase {
    /// Fires the handler from a background queue and expects the event to reach the main actor.
    ///
    /// The handler is installed through the coordinator's own installation path. A timer
    /// source stands in for the memory pressure source because a real kernel memory
    /// pressure event cannot be triggered on demand, and the timer fires on the same
    /// background queue GCD would use.
    func testHandlerDeliversOnMainActorWhenSourceFiresOnBackgroundQueue() {
        let source = DispatchSource.makeTimerSource(
            flags: .strict,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        let recorder = MemoryPressureDeliveryRecorder()
        let delivered = expectation(description: "memory pressure event delivered on the main actor")
        delivered.assertForOverFulfill = false

        AppMemoryPressureCoordinator.installMemoryPressureHandler(
            on: source,
            readEvent: {
                recorder.recordEventRead(onMainThread: Thread.isMainThread)
                return .warning
            },
            deliver: { event in
                recorder.recordDelivery(event, onMainThread: Thread.isMainThread)
                delivered.fulfill()
            }
        )

        source.schedule(deadline: .now())
        source.resume()

        wait(for: [delivered], timeout: 10)

        XCTAssertFalse(
            recorder.handlerRanOnMainThread,
            "the handler body must run on the source's queue, not on the main thread"
        )
        XCTAssertTrue(
            recorder.deliveryRanOnMainThread,
            "the isolated work must be delivered on the main actor"
        )
        XCTAssertEqual(recorder.events, [.warning], "the handler must forward the source event")
    }

    /// The handler must be installed from a nonisolated factory, never from the main actor.
    ///
    /// A handler formed in a main-actor-isolated context inherits that isolation, and the
    /// executor check Swift 6 emits for an isolated closure handed to a C block callback
    /// traps as soon as GCD fires the callback off the main thread.
    func testCoordinatorInstallsTheHandlerFromANonisolatedFactory() throws {
        let sourceText = try XCTUnwrap(coordinatorSourceText(), "the coordinator source must be readable")

        XCTAssertEqual(
            sourceText.components(separatedBy: "setEventHandler(").count - 1,
            1,
            "the memory pressure handler must be installed in exactly one place"
        )
        XCTAssertTrue(
            sourceText.contains("nonisolated static func installMemoryPressureHandler"),
            "the handler must be installed by a nonisolated factory so it carries no main-actor isolation"
        )

        let setupStart = try XCTUnwrap(sourceText.range(of: "private func setupSource()"))
        let setupEnd = try XCTUnwrap(
            sourceText.range(of: "\n    }", range: setupStart.upperBound..<sourceText.endIndex),
            "setupSource must have a closing brace"
        )
        let setupBody = String(sourceText[setupStart.lowerBound..<setupEnd.upperBound])
        XCTAssertFalse(
            setupBody.contains("setEventHandler("),
            "setupSource must not form the handler closure inside the main actor"
        )
    }

    /// Locates the coordinator source in the test runfiles.
    private func coordinatorSourceText() -> String? {
        let packageRoot = applePackageRoot
        let coordinatorFile = packageRoot
            .appendingPathComponent("Sources/TTZipApp/Services/AppMemoryPressureCoordinator.swift")
        guard let text = try? String(contentsOf: coordinatorFile, encoding: .utf8) else {
            return nil
        }
        return text
    }

    /// The `products/ttzip/apple` package root, in the runfiles or in the source tree.
    private var applePackageRoot: URL {
        if let srcDir = ProcessInfo.processInfo.environment["RUNFILES_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
            let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "_main"
            let runfilesTarget = URL(fileURLWithPath: srcDir)
                .appendingPathComponent(workspace)
                .appendingPathComponent("products/ttzip/apple")
            if FileManager.default.fileExists(atPath: runfilesTarget.appendingPathComponent("Package.swift").path) {
                return runfilesTarget
            }
        }
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: currentDir.appendingPathComponent("Package.swift").path) {
            return currentDir
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
