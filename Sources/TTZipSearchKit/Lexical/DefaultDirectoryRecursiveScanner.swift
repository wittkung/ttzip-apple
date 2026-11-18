// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation

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

    private let archiveExtensions: Set<String>
    private let withMaterializationDisabled: @Sendable (() throws -> DirectoryRecursiveSearchOutcome) throws -> DirectoryRecursiveSearchOutcome
    private let customDatalessDetector: (@Sendable (String, UInt32) -> Bool)?
    private let entryVisitHook: (@Sendable (String, Int) throws -> Void)?
    private let scanTerminationHook: (@Sendable (Bool, Int) -> Void)?

    public init(
        archiveExtensions: Set<String>,
        withMaterializationDisabled: @escaping @Sendable (() throws -> DirectoryRecursiveSearchOutcome) throws -> DirectoryRecursiveSearchOutcome,
        customDatalessDetector: (@Sendable (String, UInt32) -> Bool)? = nil,
        entryVisitHook: (@Sendable (String, Int) throws -> Void)? = nil,
        scanTerminationHook: (@Sendable (Bool, Int) -> Void)? = nil
    ) {
        self.archiveExtensions = archiveExtensions
        self.withMaterializationDisabled = withMaterializationDisabled
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

        let relay = DetachedScanTaskCancellationRelay()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let childTask = Task.detached(priority: .userInitiated) {
                try withMaterializationDisabled {
                    try performScan(
                        rootURL: rootURL,
                        lowerTokens: lowerTokens,
                        maxResults: maxResults,
                        maxVisitedEntries: maxVisitedEntries,
                        maxDepth: maxDepth
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

    private func performScan(
        rootURL: URL,
        lowerTokens: [String],
        maxResults: Int,
        maxVisitedEntries: Int,
        maxDepth: Int
    ) throws -> DirectoryRecursiveSearchOutcome {
        var acc = MutableScanAccumulator(queue: [])
        var wasCancelled = false
        defer {
            scanTerminationHook?(wasCancelled, acc.visitedCount)
        }
        do {
            try Task.checkCancellation()
            let rootPath = try Self.validateRootDirectory(rootURL)
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

    private func scanDirectoryNode(
        _ current: ScanQueueNode,
        lowerTokens: [String],
        maxResults: Int,
        maxVisitedEntries: Int,
        maxDepth: Int,
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
                acc: &acc
            )
        }
    }

    private func inspectDirectoryEntry(
        name: String,
        parent: ScanQueueNode,
        lowerTokens: [String],
        maxResults: Int,
        maxDepth: Int,
        acc: inout MutableScanAccumulator
    ) {
        let fullPath = parent.path.hasSuffix("/") ? parent.path + name : parent.path + "/" + name
        let relPath = parent.relativePrefix.isEmpty ? name : parent.relativePrefix + "/" + name

        var st = stat()
        guard lstat(fullPath, &st) == 0 else {
            Self.recordStatError(errno, acc: &acc)
            return
        }
        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK { return }
        let isDataless = customDatalessDetector?(fullPath, st.st_flags) ?? Self.isStatFlagDataless(st.st_flags)
        if isDataless {
            acc.skippedDataless += 1
            return
        }

        let isDir = fileType == S_IFDIR
        if isDir {
            Self.enqueueSubdirectoryIfEligible(name: name, fullPath: fullPath, relPath: relPath, parentDepth: parent.depth, maxDepth: maxDepth, acc: &acc)
        }

        guard Self.matchesTokens(name: name, relativePath: relPath, lowerTokens: lowerTokens) else { return }
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

    private func makeResultItem(
        fullPath: String,
        name: String,
        relativePath: String,
        isDirectory: Bool,
        byteSize: Int64,
        depth: Int
    ) -> GlobalSearchResultItem {
        let ext = (name as NSString).pathExtension.lowercased()
        let isArchive = !isDirectory && archiveExtensions.contains(ext)
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
