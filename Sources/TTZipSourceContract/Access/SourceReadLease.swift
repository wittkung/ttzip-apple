// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public protocol SourceReadLease: AnyObject, Sendable {
    /// Releases access at most once, including when multiple cleanup paths call this method.
    func release()
}

public typealias SourceReadLeaseProvider = @Sendable (URL) async -> (any SourceReadLease)?
