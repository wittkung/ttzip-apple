// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Reference-counted RAII lease for a security-scoped URL resource.
/// Ensures deterministic balance between startAccessingSecurityScopedResource
/// and stopAccessingSecurityScopedResource to eliminate Darwin kernel port leaks.
public final class SecurityScopeLease: @unchecked Sendable {
    public let url: URL
    public let activatedURL: URL
    public let leaseKey: String
    public let ownsSecurityScope: Bool
    private let onReleaseHandler: @Sendable () -> Void
    private let lock = NSLock()
    private var _isReleased: Bool = false

    /// Indicates whether the lease has already been released.
    public var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isReleased
    }

    /// Initializes a security-scoped resource lease with explicit root activation metadata.
    /// - Parameters:
    ///   - url: Requested target URL.
    ///   - activatedURL: Root URL on which the security scope was activated (or normalized target URL).
    ///   - leaseKey: Reference-counting key in `RootFolderAccessManager`.
    ///   - ownsSecurityScope: Indicates whether this lease holds an active security scope or managed count.
    ///   - onRelease: Closure executed exactly once with `leaseKey` when lease drops or `release()` is invoked.
    public init(
        url: URL,
        activatedURL: URL,
        leaseKey: String,
        ownsSecurityScope: Bool = true,
        onRelease: @escaping @Sendable (String) -> Void
    ) {
        self.url = url
        self.activatedURL = activatedURL
        self.leaseKey = leaseKey
        self.ownsSecurityScope = ownsSecurityScope
        self.onReleaseHandler = { onRelease(leaseKey) }
    }

    /// Initializes a security-scoped resource lease targeting a single URL.
    public convenience init(url: URL, onRelease: @escaping @Sendable (URL) -> Void) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        self.init(
            url: url,
            activatedURL: canonical,
            leaseKey: canonical.path,
            ownsSecurityScope: true,
            onRelease: { _ in onRelease(url) }
        )
    }

    /// Explicitly releases the security-scoped lease. Safe to call multiple times (idempotent).
    public func release() {
        lock.lock()
        guard !_isReleased else {
            lock.unlock()
            return
        }
        _isReleased = true
        lock.unlock()

        onReleaseHandler()
    }

    deinit {
        release()
    }
}
