// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// An RAII guard that holds an active security-scoped bookmark session.
/// It keeps the bookmark scope alive as long as this object is held in memory
/// or until explicitly invalidated after an asynchronous intent operation completes.
public final class ActiveBookmarkSession: @unchecked Sendable {
    private let scope: SecurityScopedResourceScope
    private let lock = NSLock()
    private var _isInvalidated: Bool = false
    private let onInvalidate: (@Sendable () -> Void)?

    /// Indicates whether the bookmark session has been invalidated.
    public var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isInvalidated
    }

    /// Resolved URLs governed by this bookmark session.
    public var urls: [URL] {
        scope.urls
    }

    public init(
        scope: SecurityScopedResourceScope = SecurityScopedResourceScope(),
        onInvalidate: (@Sendable () -> Void)? = nil
    ) {
        self.scope = scope
        self.onInvalidate = onInvalidate
    }

    /// Idempotently releases the underlying security-scoped resource handles.
    public func invalidate() {
        lock.lock()
        guard !_isInvalidated else {
            lock.unlock()
            return
        }
        _isInvalidated = true
        lock.unlock()

        scope.cleanup()
        onInvalidate?()
    }

    deinit {
        invalidate()
    }
}
