// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import TTZipCore

public typealias VfsEntryDto = VfsPagedNode
public typealias SortKey = VfsSortKey
public typealias SortDirection = VfsSortDirection

/// Protocol defining the sliding-window virtualization boundary between AppKit `NSTableView`
/// and the underlying Rust `VfsSession` paging cursor with dynamic Permutation Vector sorting.
@MainActor
public protocol NativeArchiveTableViewAdapterProtocol: AnyObject {
    /// Total number of rows in the currently browsed directory or search result set.
    var totalRowCount: Int { get }

    /// Returns the cached entry at the specified row index, or nil if currently being fetched.
    func entry(at rowIndex: Int) -> VfsEntryDto?

    /// Called by the table view delegate when the visible row range changes,
    /// triggering asynchronous background prefetching for the sliding window.
    func ensureWindowAvailable(visibleRange: Range<Int>, bufferSize: Int)

    /// Dynamic multi-column sorting trigger using Rust Permutation Vector (O(1) cursor indexing).
    func setSortCriteria(key: SortKey, direction: SortDirection)

    /// Invalidate the active sliding window cache upon directory navigation or search query change.
    func invalidateCache()

    /// Returns the row index for a given entry path, if cached or present.
    func entryIndex(forPath path: String) -> Int?

    /// Number of entries currently retained in the active in-memory cache window.
    var cachedEntryCount: Int { get }

    /// Current directory parent ID for hierarchical navigation (0 = root).
    var currentParentId: UInt32 { get }

    /// Navigate to child directory by node ID.
    func navigateToDirectory(parentId: UInt32)

    /// Live search filtering via microkernel zero-alloc SIMD search.
    func setSearchQuery(query: String?)

    /// Delegate callback for asynchronous batch fulfillment.
    var onDataBatchLoaded: (@MainActor (IndexSet) -> Void)? { get set }
}
