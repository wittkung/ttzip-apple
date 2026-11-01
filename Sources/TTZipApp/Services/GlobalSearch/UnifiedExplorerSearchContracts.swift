// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
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

/// Reason why a directory recursive scan stopped before visiting the entire directory tree.
public enum DirectoryScanTruncationReason: String, Sendable, Equatable, Hashable {
    case maxVisitedEntriesReached
    case maxDepthReached
    case maxResultsReached
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

/// Thread-safe cancellation relay forwarding outer `withTaskCancellationHandler` signals
/// to a detached child task, handling races where `cancel()` arrives before or after registration.
private final class DetachedScanTaskCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled: Bool = false
    private var childTask: Task<DirectoryRecursiveSearchOutcome, Error>?

    func bind(_ task: Task<DirectoryRecursiveSearchOutcome, Error>) {
        let cancelImmediately: Bool = {
            lock.lock()
            defer { lock.unlock() }
            childTask = task
            return isCancelled
        }()
        if cancelImmediately {
            task.cancel()
        }
    }

    func cancel() {
        let taskToCancel: Task<DirectoryRecursiveSearchOutcome, Error>? = {
            lock.lock()
            defer { lock.unlock() }
            isCancelled = true
            return childTask
        }()
        taskToCancel?.cancel()
    }
}

/// Production recursive directory scanner using POSIX `opendir`/`readdir`/`lstat` off the main thread.
/// Skips `SF_DATALESS` cloud placeholders, symlinks, and hidden/build directories, tracks
/// unreadable subdirectories without escalating permissions, and reports budget/depth truncation.
public struct DefaultDirectoryRecursiveScanner: DirectoryRecursiveSearching {
    public static let excludedDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn", ".build", ".cache", "node_modules",
        "target", "DerivedData", "Pods", "__pycache__", ".venv", "venv"
    ]

    private struct ScanQueueNode {
        let path: String
        let relativePrefix: String
        let depth: Int
    }

    private struct MutableScanAccumulator {
        var queue: [ScanQueueNode]
        var visitedCount: Int = 0
        var maxDepthVisited: Int = 0
        var truncationReasons: Set<DirectoryScanTruncationReason> = []
        var skippedUnauthorized: Int = 0
        var skippedDataless: Int = 0
        var matchedItems: [GlobalSearchResultItem] = []
    }

    private let customDatalessDetector: (@Sendable (String, UInt32) -> Bool)?
    private let entryVisitHook: (@Sendable (String, Int) throws -> Void)?
    private let scanTerminationHook: (@Sendable (Bool, Int) -> Void)?

    public init(
        customDatalessDetector: (@Sendable (String, UInt32) -> Bool)? = nil,
        entryVisitHook: (@Sendable (String, Int) throws -> Void)? = nil,
        scanTerminationHook: (@Sendable (Bool, Int) -> Void)? = nil
    ) {
        self.customDatalessDetector = customDatalessDetector
        self.entryVisitHook = entryVisitHook
        self.scanTerminationHook = scanTerminationHook
    }

    public static func isStatFlagDataless(_ flags: UInt32) -> Bool {
        (flags & UInt32(SF_DATALESS)) != 0
    }

    public func searchDirectoryRecursively(
        rootURL: URL,
        query: String,
        maxResults: Int = 60,
        maxVisitedEntries: Int = 8_000,
        maxDepth: Int = 12
    ) async throws -> DirectoryRecursiveSearchOutcome {
        try Task.checkCancellation()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxResults > 0 else {
            return DirectoryRecursiveSearchOutcome(items: [])
        }
        let lowerTokens = trimmed
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !lowerTokens.isEmpty else {
            return DirectoryRecursiveSearchOutcome(items: [])
        }

        let detector = customDatalessDetector
        let visitHook = entryVisitHook
        let terminationHook = scanTerminationHook
        let relay = DetachedScanTaskCancellationRelay()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let childTask = Task.detached(priority: .userInitiated) {
                try DatalessProtection.withMaterializationDisabled {
                    try Self.performScan(
                        rootURL: rootURL,
                        lowerTokens: lowerTokens,
                        maxResults: maxResults,
                        maxVisitedEntries: maxVisitedEntries,
                        maxDepth: maxDepth,
                        customDatalessDetector: detector,
                        entryVisitHook: visitHook,
                        scanTerminationHook: terminationHook
                    )
                }
            }
            relay.bind(childTask)
            return try await childTask.value
        } onCancel: {
            relay.cancel()
        }
    }

    private static func validateRootDirectory(_ rootURL: URL) throws -> String {
        let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path
        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else {
            let code = errno
            if code == EACCES || code == EPERM {
                throw DirectoryRecursiveScanError.targetAccessDenied(rootPath)
            }
            throw DirectoryRecursiveScanError.targetDoesNotExist(rootPath)
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw DirectoryRecursiveScanError.targetNotDirectory(rootPath)
        }
        guard let initialStream = Darwin.opendir(rootPath) else {
            let code = errno
            if code == EACCES || code == EPERM {
                throw DirectoryRecursiveScanError.targetAccessDenied(rootPath)
            }
            throw DirectoryRecursiveScanError.scanFailed(String(cString: strerror(code)))
        }
        Darwin.closedir(initialStream)
        return rootPath
    }

    private static func performScan(
        rootURL: URL,
        lowerTokens: [String],
        maxResults: Int,
        maxVisitedEntries: Int,
        maxDepth: Int,
        customDatalessDetector: (@Sendable (String, UInt32) -> Bool)?,
        entryVisitHook: (@Sendable (String, Int) throws -> Void)?,
        scanTerminationHook: (@Sendable (Bool, Int) -> Void)?
    ) throws -> DirectoryRecursiveSearchOutcome {
        var acc = MutableScanAccumulator(queue: [])
        var wasCancelled = false
        defer {
            scanTerminationHook?(wasCancelled, acc.visitedCount)
        }
        do {
            try Task.checkCancellation()
            let rootPath = try validateRootDirectory(rootURL)
            acc.queue = [ScanQueueNode(path: rootPath, relativePrefix: "", depth: 0)]
            var queueIndex = 0

            while queueIndex < acc.queue.count {
                try Task.checkCancellation()
                if acc.visitedCount >= maxVisitedEntries {
                    acc.truncationReasons.insert(.maxVisitedEntriesReached)
                    break
                }
                let current = acc.queue[queueIndex]
                queueIndex += 1
                if current.depth > acc.maxDepthVisited {
                    acc.maxDepthVisited = current.depth
                }
                try scanDirectoryNode(
                    current,
                    lowerTokens: lowerTokens,
                    maxResults: maxResults,
                    maxVisitedEntries: maxVisitedEntries,
                    maxDepth: maxDepth,
                    customDatalessDetector: customDatalessDetector,
                    entryVisitHook: entryVisitHook,
                    acc: &acc
                )
            }
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }

        acc.matchedItems.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return DirectoryRecursiveSearchOutcome(
            items: acc.matchedItems,
            visitedEntryCount: acc.visitedCount,
            maxDepthVisited: acc.maxDepthVisited,
            truncationReasons: acc.truncationReasons,
            skippedUnauthorizedDirectories: acc.skippedUnauthorized,
            skippedDatalessFiles: acc.skippedDataless
        )
    }

    private static func scanDirectoryNode(
        _ current: ScanQueueNode,
        lowerTokens: [String],
        maxResults: Int,
        maxVisitedEntries: Int,
        maxDepth: Int,
        customDatalessDetector: (@Sendable (String, UInt32) -> Bool)?,
        entryVisitHook: (@Sendable (String, Int) throws -> Void)?,
        acc: inout MutableScanAccumulator
    ) throws {
        guard let dir = Darwin.opendir(current.path) else {
            let code = errno
            if code == EACCES || code == EPERM {
                acc.skippedUnauthorized += 1
            }
            return
        }
        defer { Darwin.closedir(dir) }

        while let entryPtr = Darwin.readdir(dir) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entryPtr.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entryPtr.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." || name.hasPrefix(".") {
                continue
            }
            if acc.visitedCount >= maxVisitedEntries {
                acc.truncationReasons.insert(.maxVisitedEntriesReached)
                break
            }
            acc.visitedCount += 1
            let fullPath = current.path.hasSuffix("/") ? current.path + name : current.path + "/" + name
            if let entryVisitHook {
                try entryVisitHook(fullPath, acc.visitedCount)
            }
            inspectDirectoryEntry(
                name: name,
                parent: current,
                lowerTokens: lowerTokens,
                maxResults: maxResults,
                maxDepth: maxDepth,
                customDatalessDetector: customDatalessDetector,
                acc: &acc
            )
        }
    }

    private static func inspectDirectoryEntry(
        name: String,
        parent: ScanQueueNode,
        lowerTokens: [String],
        maxResults: Int,
        maxDepth: Int,
        customDatalessDetector: (@Sendable (String, UInt32) -> Bool)?,
        acc: inout MutableScanAccumulator
    ) {
        let fullPath = parent.path.hasSuffix("/") ? parent.path + name : parent.path + "/" + name
        let relPath = parent.relativePrefix.isEmpty ? name : parent.relativePrefix + "/" + name

        var st = stat()
        guard lstat(fullPath, &st) == 0 else {
            recordStatError(errno, acc: &acc)
            return
        }
        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK { return }
        let isDataless = customDatalessDetector?(fullPath, st.st_flags) ?? isStatFlagDataless(st.st_flags)
        if isDataless {
            acc.skippedDataless += 1
            return
        }

        let isDir = fileType == S_IFDIR
        if isDir {
            enqueueSubdirectoryIfEligible(name: name, fullPath: fullPath, relPath: relPath, parentDepth: parent.depth, maxDepth: maxDepth, acc: &acc)
        }

        guard matchesTokens(name: name, relativePath: relPath, lowerTokens: lowerTokens) else { return }
        if acc.matchedItems.count < maxResults {
            acc.matchedItems.append(
                makeResultItem(
                    fullPath: fullPath,
                    name: name,
                    relativePath: relPath,
                    isDirectory: isDir,
                    byteSize: Int64(st.st_size),
                    depth: parent.depth
                )
            )
        } else {
            acc.truncationReasons.insert(.maxResultsReached)
        }
    }

    private static func recordStatError(_ code: Int32, acc: inout MutableScanAccumulator) {
        if code == EACCES || code == EPERM {
            acc.skippedUnauthorized += 1
        } else if code == EDEADLK {
            acc.skippedDataless += 1
        }
    }

    private static func enqueueSubdirectoryIfEligible(
        name: String,
        fullPath: String,
        relPath: String,
        parentDepth: Int,
        maxDepth: Int,
        acc: inout MutableScanAccumulator
    ) {
        if excludedDirectoryNames.contains(name) { return }
        if parentDepth < maxDepth {
            acc.queue.append(ScanQueueNode(path: fullPath, relativePrefix: relPath, depth: parentDepth + 1))
        } else {
            acc.truncationReasons.insert(.maxDepthReached)
        }
    }

    private static func matchesTokens(
        name: String,
        relativePath: String,
        lowerTokens: [String]
    ) -> Bool {
        let lowerName = name.lowercased()
        let lowerRel = relativePath.lowercased()
        let foldedName = lowerName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let foldedRel = lowerRel.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        return lowerTokens.allSatisfy { token in
            let foldedToken = token.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return lowerName.contains(token)
                || lowerRel.contains(token)
                || foldedName.contains(foldedToken)
                || foldedRel.contains(foldedToken)
        }
    }

    private static func makeResultItem(
        fullPath: String,
        name: String,
        relativePath: String,
        isDirectory: Bool,
        byteSize: Int64,
        depth: Int
    ) -> GlobalSearchResultItem {
        let ext = (name as NSString).pathExtension.lowercased()
        let isArchive = !isDirectory && SpotlightArchiveSearchProvider.supportedArchiveExtensions.contains(ext)
        let depthPenalty = min(0.25, Float(depth) * 0.03)
        let score: Float = (depth == 0 ? 0.98 : 0.92) - depthPenalty

        if isArchive {
            return GlobalSearchResultItem(
                id: "dirscan:archive:\(fullPath)",
                title: name,
                subtitle: relativePath,
                hitType: .archiveFile,
                archivePath: fullPath,
                diskPath: nil,
                isDirectory: false,
                byteSize: byteSize,
                score: score,
                matchBadge: depth == 0 ? nil : "Subfolder"
            )
        }
        return GlobalSearchResultItem(
            id: "dirscan:item:\(fullPath)",
            title: name,
            subtitle: relativePath,
            hitType: .archiveEntry,
            archivePath: nil,
            entrySubpath: nil,
            diskPath: fullPath,
            isDirectory: isDirectory,
            byteSize: byteSize,
            score: score,
            matchBadge: depth == 0 ? nil : "Subfolder"
        )
    }
}
