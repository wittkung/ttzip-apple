// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Shared generation fence for verification results from every window.
public final class ArchiveCredentialGeneration: @unchecked Sendable {
    public static let shared = ArchiveCredentialGeneration()

    private let lock = NSLock()
    private var generations: [String: UInt64] = [:]

    public init() {}

    public func snapshot(for logicalKey: String) -> UInt64 {
        lock.withLock { generations[logicalKey, default: 0] }
    }

    @discardableResult
    public func invalidate(_ logicalKey: String) -> UInt64 {
        lock.withLock {
            generations[logicalKey, default: 0] &+= 1
            return generations[logicalKey, default: 0]
        }
    }

    public func isCurrent(_ generation: UInt64, for logicalKey: String) -> Bool {
        lock.withLock { generations[logicalKey, default: 0] == generation }
    }

    /// The credential write and generation check must occupy one critical section.
    /// A separate `isCurrent` check would allow Forget to interleave before persistence.
    public func performIfCurrent<Result>(
        _ generation: UInt64,
        for logicalKey: String,
        _ operation: () throws -> Result
    ) rethrows -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard generations[logicalKey, default: 0] == generation else { return nil }
        return try operation()
    }

    /// Invalidates in-flight verification before removing its persistent credential.
    public func invalidateAndPerform<Result>(
        for logicalKey: String,
        _ operation: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        generations[logicalKey, default: 0] &+= 1
        return try operation()
    }
}
