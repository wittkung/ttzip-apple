// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTZipSearchKit
import Foundation
import Observation
import TTZipCore
import TTZipUI

/// Strictly classified origin scope for a top-bar explorer search request.
public enum ExplorerSearchScopeIdentity: Sendable, Equatable {
    /// Local physical directory (`file://` without virtual `?subpath=`).
    case physicalDirectory(URL)
    /// Open or accepted archive container with an optional inner directory subpath.
    case archiveContext(archivePath: String, subpath: String)
    /// External device context (e.g. Android MTP/ADB) that must never be passed to local POSIX traversal.
    case externalDevice(deviceIdentifier: String, displayPath: String)
    /// Non-local or malformed target that cannot be scanned on disk.
    case unsupported(rawLocation: String, reason: String)

    public var displayPath: String {
        switch self {
        case .physicalDirectory(let url):
            return url.path
        case .archiveContext(let archivePath, let subpath):
            return subpath.isEmpty ? archivePath : "\(archivePath) → \(subpath)"
        case .externalDevice(_, let path):
            return path
        case .unsupported(let raw, _):
            return raw
        }
    }

    public var physicalDirectoryURL: URL? {
        if case .physicalDirectory(let url) = self {
            return url
        }
        return nil
    }
}

/// Phase of one search result group ("Current Directory" or "Full Disk").
public enum ExplorerSearchGroupPhase: Sendable, Equatable {
    case idle
    case loading
    case completed
    case empty
    case error(String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var isEmptyMatch: Bool {
        if case .empty = self { return true }
        return false
    }

    public var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

/// Coverage and permission status for a search group, reported honestly to the user.
public struct ExplorerSearchCoverageNote: Sendable, Equatable {
    public let scopeDescription: String
    public let visitedEntryCount: Int
    public let maxDepthVisited: Int
    public let truncationReasons: Set<DirectoryScanTruncationReason>
    public let skippedUnauthorizedSubdirectoryCount: Int
    public let skippedDatalessFileCount: Int
    public let isModelReady: Bool
    public let isSemanticQueryEncoded: Bool
    public let hasSemanticContentHits: Bool
    public let indexedScopeCount: Int
    public let indexedSegmentCount: UInt32

    /// True when the directory scan stopped early due to entry budget, depth ceiling, or result cap.
    /// When `isTruncated == true` and 0 items matched, the UI must never claim exhaustive absence of matches.
    public var isTruncated: Bool {
        !truncationReasons.isEmpty
    }

    public init(
        scopeDescription: String,
        visitedEntryCount: Int = 0,
        maxDepthVisited: Int = 0,
        truncationReasons: Set<DirectoryScanTruncationReason> = [],
        skippedUnauthorizedSubdirectoryCount: Int = 0,
        skippedDatalessFileCount: Int = 0,
        isModelReady: Bool = false,
        isSemanticQueryEncoded: Bool = false,
        hasSemanticContentHits: Bool = false,
        indexedScopeCount: Int = 0,
        indexedSegmentCount: UInt32 = 0
    ) {
        self.scopeDescription = scopeDescription
        self.visitedEntryCount = visitedEntryCount
        self.maxDepthVisited = maxDepthVisited
        self.truncationReasons = truncationReasons
        self.skippedUnauthorizedSubdirectoryCount = skippedUnauthorizedSubdirectoryCount
        self.skippedDatalessFileCount = skippedDatalessFileCount
        self.isModelReady = isModelReady
        self.isSemanticQueryEncoded = isSemanticQueryEncoded
        self.hasSemanticContentHits = hasSemanticContentHits
        self.indexedScopeCount = indexedScopeCount
        self.indexedSegmentCount = indexedSegmentCount
    }
}

/// Immutable snapshot of one search group in the dual-group explorer search workspace.
public struct ExplorerSearchGroupSnapshot: Sendable, Equatable {
    public let title: String
    public let subtitle: String
    public let phase: ExplorerSearchGroupPhase
    public let items: [GlobalSearchResultItem]
    public let coverage: ExplorerSearchCoverageNote

    /// Search zero-match state never allows folder/file creation (`EmptyFolderPlaceholderView` is forbidden).
    public var allowsCreationInEmptyState: Bool { false }

    public init(
        title: String,
        subtitle: String,
        phase: ExplorerSearchGroupPhase,
        items: [GlobalSearchResultItem],
        coverage: ExplorerSearchCoverageNote
    ) {
        self.title = title
        self.subtitle = subtitle
        self.phase = phase
        self.items = items
        self.coverage = coverage
    }
}

/// Pluggable system metadata search provider contract for the Full-Disk search group.
public protocol SystemFileSearchProviding: Sendable {
    func searchAllAccessibleItems(
        query: String,
        maxResults: Int,
        additionalScopes: [URL]
    ) async -> [GlobalSearchResultItem]
}

extension SpotlightArchiveSearchProvider: SystemFileSearchProviding {}

/// Process-wide monotonically increasing request ID allocator ensuring request IDs
/// never collide across multiple browser windows or search surfaces (`⌘K` vs top bar).
public enum SearchRequestIDAllocator {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter: UInt64 = 10_000

    public static func nextRequestID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        counter &+= 1
        return counter
    }
}
