// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Reason why a directory recursive scan stopped before visiting the entire directory tree.
public enum DirectoryScanTruncationReason: String, Sendable, Equatable, Hashable {
    case maxVisitedEntriesReached
    case maxDepthReached
    case maxResultsReached
}

/// Error surfaced when a local directory cannot be opened or scanned recursively.
public enum DirectoryRecursiveScanError: Error, LocalizedError, Sendable, Equatable {
    case targetDoesNotExist(String)
    case targetNotDirectory(String)
    case targetAccessDenied(String)
    case scanFailed(String)

    public var errorDescription: String? {
        switch self {
        case .targetDoesNotExist(let path):
            return "Target directory does not exist: \(path)"
        case .targetNotDirectory(let path):
            return "Target path is not a directory: \(path)"
        case .targetAccessDenied(let path):
            return "Permission denied when accessing directory: \(path)"
        case .scanFailed(let detail):
            return "Directory recursive scan failed: \(detail)"
        }
    }
}

/// Outcome of recursive directory scanning for the current directory group.
public struct DirectoryRecursiveSearchOutcome: Sendable, Equatable {
    public let items: [GlobalSearchResultItem]
    public let visitedEntryCount: Int
    public let maxDepthVisited: Int
    public let truncationReasons: Set<DirectoryScanTruncationReason>
    public let skippedUnauthorizedDirectories: Int
    public let skippedDatalessFiles: Int

    public var isTruncated: Bool {
        !truncationReasons.isEmpty
    }

    public init(
        items: [GlobalSearchResultItem],
        visitedEntryCount: Int = 0,
        maxDepthVisited: Int = 0,
        truncationReasons: Set<DirectoryScanTruncationReason> = [],
        skippedUnauthorizedDirectories: Int = 0,
        skippedDatalessFiles: Int = 0
    ) {
        self.items = items
        self.visitedEntryCount = visitedEntryCount
        self.maxDepthVisited = maxDepthVisited
        self.truncationReasons = truncationReasons
        self.skippedUnauthorizedDirectories = skippedUnauthorizedDirectories
        self.skippedDatalessFiles = skippedDatalessFiles
    }
}

/// Pluggable recursive directory scanner contract for deterministic testing and cooperative cancellation.
public protocol DirectoryRecursiveSearching: Sendable {
    func searchDirectoryRecursively(
        rootURL: URL,
        query: String,
        maxResults: Int,
        maxVisitedEntries: Int,
        maxDepth: Int
    ) async throws -> DirectoryRecursiveSearchOutcome
}

public extension DirectoryRecursiveSearching {
    func searchDirectoryRecursively(
        rootURL: URL,
        query: String,
        maxResults: Int = 60,
        maxVisitedEntries: Int = 8_000
    ) async throws -> DirectoryRecursiveSearchOutcome {
        try await searchDirectoryRecursively(
            rootURL: rootURL,
            query: query,
            maxResults: maxResults,
            maxVisitedEntries: maxVisitedEntries,
            maxDepth: 12
        )
    }
}
