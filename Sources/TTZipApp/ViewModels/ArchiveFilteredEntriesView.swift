// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

/// A lightweight, non-copying random-access view over an array of `ArchiveEntry`
/// filtered by a contiguous array of matching entry indices.
///
/// When `matchingIndices` is `nil`, this behaves as a zero-copy identity view
/// over the entire source array.
public struct ArchiveFilteredEntriesView: RandomAccessCollection, Sendable {
    public typealias Element = ArchiveEntry
    public typealias Index = Int

    public let source: [ArchiveEntry]
    public let matchingIndices: ContiguousArray<Int32>?

    @inlinable
    public init(source: [ArchiveEntry], matchingIndices: ContiguousArray<Int32>? = nil) {
        self.source = source
        self.matchingIndices = matchingIndices
    }

    @inlinable
    public var startIndex: Int { 0 }

    @inlinable
    public var endIndex: Int {
        matchingIndices?.count ?? source.count
    }

    @inlinable
    public subscript(position: Int) -> ArchiveEntry {
        if let indices = matchingIndices {
            return source[Int(indices[position])]
        }
        return source[position]
    }

    @inlinable
    public var count: Int {
        matchingIndices?.count ?? source.count
    }

    @inlinable
    public var isEmpty: Bool {
        matchingIndices?.isEmpty ?? source.isEmpty
    }

    @inlinable
    public func index(after i: Int) -> Int { i + 1 }

    @inlinable
    public func index(before i: Int) -> Int { i - 1 }
}
