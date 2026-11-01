// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreGraphics
import Darwin
import TTZipCore
import TTZipUI

// MARK: - POSIX lstat Directory Scanner

public enum StorageDirectoryScanner {
    /// Default hard ceiling on visited entries per scan to bound memory and runtime.
    public static let defaultMaxVisitedEntries: Int = 5_000_000

    private static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "qlgenerator", "appex",
        "xcodeproj", "xcworkspace", "xcarchive", "playground", "photoslibrary"
    ]

    private struct DirectChildAccumulator {
        let name: String
        let path: String
        let isDir: Bool
        let isSymlink: Bool
        var allocatedBytes: UInt64
        var logicalBytes: UInt64
        var category: TileCategory
        var isVerifiedReclaim: Bool
    }

    private struct SeenInodeKey: Hashable {
        let dev: UInt64
        let ino: UInt64
    }

    private struct TraversalContext {
        let rootPath: String
        let rootDev: UInt64
        let cancelToken: StorageScanCancelToken
        let maxVisitedEntries: Int
        let perEntryDelayNanoseconds: UInt64
        let onProgress: (@Sendable (String, Int) -> Void)?

        var seenHardlinks = Set<SeenInodeKey>()
        var totalAllocated: UInt64 = 0
        var totalLogical: UInt64 = 0
        var totalReclaimable: UInt64 = 0
        var scannedFiles: Int = 0
        var scannedDirs: Int = 0
        var deduplicatedHardLinks: Int = 0
        var skippedSymlinks: Int = 0
        var skippedMounts: Int = 0
        var inaccessibleDirs: [String] = []
        var visitedEntries: Int = 0
        var isTruncated: Bool = false

        var directChildren: [DirectChildAccumulator] = []
        var verifiedCandidates: [ReclaimableStorageItem] = []
        var unverifiedCandidates: [ReclaimableStorageItem] = []
    }

    /// Snapshot of safety counters before entering a candidate subtree.
    private struct SubtreeSafetySnapshot {
        let protectedHits: Int
        let inaccessibleCount: Int
        let skippedMounts: Int
    }

    /// Scans `rootURL` using POSIX `opendir`/`readdir`/`lstat` without following symlinks or crossing mount points,
    /// checking `cancelToken.isCancelled` and `maxVisitedEntries` budget inside `readdir` loops.
    public static func scanDirectory(
        rootURL: URL,
        cancelToken: StorageScanCancelToken = StorageScanCancelToken(),
        maxVisitedEntries: Int = defaultMaxVisitedEntries,
        perEntryDelayNanoseconds: UInt64 = 0,
        onProgress: (@Sendable (String, Int) -> Void)? = nil
    ) -> StorageScanOutput {
        let startTime = ContinuousClock.now
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path

        switch probeRootDirectory(
            rootPath: rootPath,
            cancelToken: cancelToken,
            maxVisitedEntries: maxVisitedEntries
        ) {
        case .failure(let errorOutput):
            return errorOutput
        case .success(let (rootDev, immediateNames, rootTruncated)):
            if immediateNames.isEmpty && !rootTruncated {
                return terminalEmptyOutput(
                    status: .empty,
                    rootPath: rootPath,
                    durationSec: durationSeconds(since: startTime)
                )
            }

            var context = TraversalContext(
                rootPath: rootPath,
                rootDev: rootDev,
                cancelToken: cancelToken,
                maxVisitedEntries: maxVisitedEntries,
                perEntryDelayNanoseconds: perEntryDelayNanoseconds,
                onProgress: onProgress
            )
            context.isTruncated = rootTruncated

            for childName in immediateNames {
                if cancelToken.isCancelled {
                    return cancelledOutput(rootPath: rootPath)
                }
                if context.visitedEntries >= maxVisitedEntries {
                    context.isTruncated = true
                    break
                }
                processImmediateChild(name: childName, context: &context)
            }

            if cancelToken.isCancelled {
                return cancelledOutput(rootPath: rootPath)
            }

            return finalizeScanOutput(context: &context, startTime: startTime)
        }
    }

    private enum RootProbeResult {
        case success((UInt64, [String], Bool))
        case failure(StorageScanOutput)
    }

    private static func probeRootDirectory(
        rootPath: String,
        cancelToken: StorageScanCancelToken,
        maxVisitedEntries: Int
    ) -> RootProbeResult {
        var rootStat = Darwin.stat()
        guard Darwin.lstat(rootPath, &rootStat) == 0 else {
            return .failure(errorOutputForErrno(errno, rootPath: rootPath))
        }
        let rootDev = UInt64(bitPattern: Int64(rootStat.st_dev))

        guard let rootDirPtr = Darwin.opendir(rootPath) else {
            return .failure(errorOutputForErrno(errno, rootPath: rootPath))
        }

        let effectiveBudget = max(0, maxVisitedEntries)
        var immediateNames: [String] = []
        var rootTruncated = false
        while let entryPtr = Darwin.readdir(rootDirPtr) {
            if cancelToken.isCancelled {
                Darwin.closedir(rootDirPtr)
                return .failure(cancelledOutput(rootPath: rootPath))
            }
            let name = extractEntryName(entryPtr)
            if name == "." || name == ".." || name == ".DS_Store" {
                continue
            }
            if immediateNames.count >= effectiveBudget {
                rootTruncated = true
                break
            }
            immediateNames.append(name)
        }
        Darwin.closedir(rootDirPtr)
        immediateNames.sort()
        return .success((rootDev, immediateNames, rootTruncated))
    }

    private static func errorOutputForErrno(_ err: Int32, rootPath: String) -> StorageScanOutput {
        let status: StorageScanOutput.TerminalStatus = (err == EACCES || err == EPERM)
            ? .permissionDenied(path: rootPath)
            : .failed(message: String(cString: Darwin.strerror(err)))
        return terminalEmptyOutput(status: status, rootPath: rootPath)
    }

    private static func terminalEmptyOutput(
        status: StorageScanOutput.TerminalStatus,
        rootPath: String,
        durationSec: Double = 0.001
    ) -> StorageScanOutput {
        let summary = StorageScanSummary(
            rootPath: rootPath,
            allocatedBytes: 0,
            logicalBytes: 0,
            reclaimableBytes: 0,
            scannedFiles: 0,
            scannedDirectories: 0,
            durationSec: durationSec
        )
        return StorageScanOutput(
            status: status,
            summary: summary,
            verifiedCandidates: [],
            unverifiedCandidates: [],
            tiles: []
        )
    }

    private static func processImmediateChild(name: String, context: inout TraversalContext) {
        let childPath = (context.rootPath as NSString).appendingPathComponent(name)
        let childURL = URL(fileURLWithPath: childPath)

        var st = Darwin.stat()
        guard Darwin.lstat(childPath, &st) == 0 else { return }

        recordVisitedEntry(name: name, context: &context)

        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK {
            context.skippedSymlinks += 1
            context.directChildren.append(DirectChildAccumulator(
                name: name,
                path: childPath,
                isDir: false,
                isSymlink: true,
                allocatedBytes: 0,
                logicalBytes: 0,
                category: .others,
                isVerifiedReclaim: false
            ))
            return
        }

        let entryDev = UInt64(bitPattern: Int64(st.st_dev))
        if entryDev != context.rootDev {
            context.skippedMounts += 1
            return
        }

        if mode == S_IFREG {
            context.scannedFiles += 1
            let (alloc, logic, wasDup) = accountRegularFile(stat: st, dev: entryDev, seen: &context.seenHardlinks)
            if wasDup { context.deduplicatedHardLinks += 1 }
            context.totalAllocated &+= alloc
            context.totalLogical &+= logic

            let (cat, _) = ForensicPathGuard.classifyRegularFileOrDirectory(name: name, isDir: false, url: childURL)
            context.directChildren.append(DirectChildAccumulator(
                name: name,
                path: childPath,
                isDir: false,
                isSymlink: false,
                allocatedBytes: alloc,
                logicalBytes: logic,
                category: cat,
                isVerifiedReclaim: false
            ))
        } else if mode == S_IFDIR {
            processImmediateDirectoryChild(name: name, path: childPath, url: childURL, stat: st, dev: entryDev, context: &context)
        }
    }

    private static func processImmediateDirectoryChild(
        name: String,
        path: String,
        url: URL,
        stat st: Darwin.stat,
        dev: UInt64,
        context: inout TraversalContext
    ) {
        context.scannedDirs += 1
        let isPkg = isPackageDirectoryName(name)
        let eval = ForensicPathGuard.evaluateCandidate(
            name: name,
            isDir: true,
            isSymlink: false,
            url: url,
            scanRootPath: context.rootPath,
            isInsidePackage: isPkg,
            inspectSubtree: false
        )

        let snapshotBefore = SubtreeSafetySnapshot(
            protectedHits: 0,
            inaccessibleCount: context.inaccessibleDirs.count,
            skippedMounts: context.skippedMounts
        )
        let subtree = traverseSubtree(
            dirPath: path,
            insideReclaimableAncestor: eval.verification == .verified,
            insidePackageAncestor: isPkg,
            context: &context
        )
        guard !context.cancelToken.isCancelled else { return }

        context.totalAllocated &+= subtree.allocatedBytes
        context.totalLogical &+= subtree.logicalBytes

        let childIdentity = StorageEntryIdentity.directory(
            path: path,
            parentPath: context.rootPath,
            device: dev,
            inode: st.st_ino
        )

        let resolvedEval = resolveCandidateAfterSubtree(
            eval: eval,
            snapshotBefore: snapshotBefore,
            subtreeProtectedHits: subtree.protectedDescendantHits,
            context: context
        )

        context.totalReclaimable &+= appendResolvedCandidate(
            name: name,
            url: url,
            allocatedBytes: subtree.allocatedBytes,
            logicalBytes: subtree.logicalBytes,
            verification: resolvedEval.verification,
            rule: resolvedEval.rule,
            reason: resolvedEval.reason,
            identity: childIdentity,
            fallbackSubtreeReclaimable: subtree.reclaimableBytes,
            context: &context
        )

        let isVerified = resolvedEval.verification == .verified
        let tileCategory: TileCategory = isVerified
            ? .reclaimCache
            : (isPkg ? .executableBinary : subtree.dominantCategory)

        context.directChildren.append(DirectChildAccumulator(
            name: name,
            path: path,
            isDir: true,
            isSymlink: false,
            allocatedBytes: subtree.allocatedBytes,
            logicalBytes: subtree.logicalBytes,
            category: tileCategory,
            isVerifiedReclaim: isVerified || subtree.reclaimableBytes > 0
        ))
    }

    private static func resolveCandidateAfterSubtree(
        eval: (category: TileCategory, verification: ReclaimVerificationStatus?, rule: ReclaimRuleKind?, reason: String),
        snapshotBefore: SubtreeSafetySnapshot,
        subtreeProtectedHits: Int,
        context: TraversalContext
    ) -> (category: TileCategory, verification: ReclaimVerificationStatus?, rule: ReclaimRuleKind?, reason: String) {
        guard eval.verification == .verified else { return eval }
        if subtreeProtectedHits > snapshotBefore.protectedHits {
            let reason = StorageLocaleKey.outcomeRejectedSubtreeProtected.resolve()
            return (.others, .nameOnly, .unverifiedNameMatch, reason)
        }
        let hadInaccessible = context.inaccessibleDirs.count > snapshotBefore.inaccessibleCount
        let hadMountSkip = context.skippedMounts > snapshotBefore.skippedMounts
        if hadInaccessible || hadMountSkip || context.isTruncated {
            let reason = StorageLocaleKey.outcomeRejectedSubtreeIncomplete.resolve()
            return (.others, .nameOnly, .unverifiedNameMatch, reason)
        }
        return eval
    }

    @discardableResult
    private static func appendResolvedCandidate(
        name: String,
        url: URL,
        allocatedBytes: UInt64,
        logicalBytes: UInt64,
        verification: ReclaimVerificationStatus?,
        rule: ReclaimRuleKind?,
        reason: String,
        identity: StorageEntryIdentity,
        fallbackSubtreeReclaimable: UInt64 = 0,
        context: inout TraversalContext
    ) -> UInt64 {
        guard let verification else { return fallbackSubtreeReclaimable }
        let item = ReclaimableStorageItem(
            name: name,
            url: url,
            sizeBytes: allocatedBytes,
            logicalBytes: logicalBytes,
            category: verification == .verified ? .reclaimCache : .others,
            reason: reason,
            ruleKind: rule,
            verification: verification,
            identity: identity,
            scanRootPath: context.rootPath
        )
        if verification == .verified {
            context.verifiedCandidates.append(item)
            return allocatedBytes
        }
        context.unverifiedCandidates.append(item)
        return 0
    }

    private static func finalizeScanOutput(
        context: inout TraversalContext,
        startTime: ContinuousClock.Instant
    ) -> StorageScanOutput {
        context.verifiedCandidates.sort {
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.path < $1.path
        }
        context.unverifiedCandidates.sort {
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.path < $1.path
        }

        // Strictly use allocatedBytes for Treemap tiles so zero-block sparse files are never drawn as huge tiles.
        let rawTileEntries = context.directChildren.map { child in
            (
                name: child.name,
                path: child.path,
                bytes: child.allocatedBytes,
                category: child.category,
                isReclaim: child.isVerifiedReclaim,
                isDir: child.isDir && !child.isSymlink
            )
        }

        let totalForTiles = rawTileEntries.reduce(0 as UInt64) { $0 &+ $1.bytes }
        let tiles = StorageTreemapLayoutEngine.computeSquarifiedLayout(
            entries: rawTileEntries,
            totalBytes: totalForTiles
        )

        let summary = StorageScanSummary(
            rootPath: context.rootPath,
            allocatedBytes: context.totalAllocated,
            logicalBytes: context.totalLogical,
            reclaimableBytes: context.totalReclaimable,
            scannedFiles: context.scannedFiles,
            scannedDirectories: context.scannedDirs,
            deduplicatedHardLinks: context.deduplicatedHardLinks,
            skippedSymlinks: context.skippedSymlinks,
            skippedMountPoints: context.skippedMounts,
            inaccessibleDirectories: context.inaccessibleDirs,
            isTruncated: context.isTruncated,
            durationSec: durationSeconds(since: startTime)
        )

        return StorageScanOutput(
            status: .completed,
            summary: summary,
            verifiedCandidates: context.verifiedCandidates,
            unverifiedCandidates: context.unverifiedCandidates,
            tiles: tiles
        )
    }

    // MARK: - Subtree Iterative Stack Traversal

    private struct SubtreeTotals {
        var allocatedBytes: UInt64 = 0
        var logicalBytes: UInt64 = 0
        var reclaimableBytes: UInt64 = 0
        var protectedDescendantHits: Int = 0
        var dominantCategory: TileCategory = .others
    }

    private struct PendingCandidateFrame {
        let name: String
        let url: URL
        let rule: ReclaimRuleKind?
        let verification: ReclaimVerificationStatus
        let reason: String
        let identity: StorageEntryIdentity
        let allocBefore: UInt64
        let logicBefore: UInt64
        let safetySnapshot: SubtreeSafetySnapshot
    }

    private enum SubtreeWorkItem {
        case enter(path: String, insideReclaim: Bool, insidePkg: Bool)
        case finishCandidate(PendingCandidateFrame)
    }

    private static func traverseSubtree(
        dirPath: String,
        insideReclaimableAncestor: Bool,
        insidePackageAncestor: Bool,
        context: inout TraversalContext
    ) -> SubtreeTotals {
        var totals = SubtreeTotals()
        var categoryBytes: [TileCategory: UInt64] = [:]
        var stack: [SubtreeWorkItem] = [
            .enter(path: dirPath, insideReclaim: insideReclaimableAncestor, insidePkg: insidePackageAncestor)
        ]

        while let work = stack.popLast() {
            if context.cancelToken.isCancelled { return totals }

            switch work {
            case .finishCandidate(let frame):
                finishSubtreeCandidate(frame: frame, totals: &totals, context: &context)

            case .enter(let currentDir, let insideReclaim, let insidePkg):
                expandDirectoryFrame(
                    currentDir: currentDir,
                    insideReclaim: insideReclaim,
                    insidePkg: insidePkg,
                    stack: &stack,
                    totals: &totals,
                    categoryBytes: &categoryBytes,
                    context: &context
                )
            }
        }

        if let dominant = categoryBytes.max(by: { $0.value < $1.value })?.key {
            totals.dominantCategory = dominant
        }
        return totals
    }

    private static func finishSubtreeCandidate(
        frame: PendingCandidateFrame,
        totals: inout SubtreeTotals,
        context: inout TraversalContext
    ) {
        let candidateAlloc = totals.allocatedBytes >= frame.allocBefore ? (totals.allocatedBytes - frame.allocBefore) : 0
        let candidateLogic = totals.logicalBytes >= frame.logicBefore ? (totals.logicalBytes - frame.logicBefore) : 0
        let rawEval: (TileCategory, ReclaimVerificationStatus?, ReclaimRuleKind?, String) = (
            frame.verification == .verified ? .reclaimCache : .others,
            frame.verification,
            frame.rule,
            frame.reason
        )
        let resolved = resolveCandidateAfterSubtree(
            eval: rawEval,
            snapshotBefore: frame.safetySnapshot,
            subtreeProtectedHits: totals.protectedDescendantHits,
            context: context
        )
        totals.reclaimableBytes &+= appendResolvedCandidate(
            name: frame.name,
            url: frame.url,
            allocatedBytes: candidateAlloc,
            logicalBytes: candidateLogic,
            verification: resolved.verification ?? .nameOnly,
            rule: resolved.rule,
            reason: resolved.reason,
            identity: frame.identity,
            context: &context
        )
    }

    private static func expandDirectoryFrame(
        currentDir: String,
        insideReclaim: Bool,
        insidePkg: Bool,
        stack: inout [SubtreeWorkItem],
        totals: inout SubtreeTotals,
        categoryBytes: inout [TileCategory: UInt64],
        context: inout TraversalContext
    ) {
        if context.visitedEntries >= context.maxVisitedEntries {
            context.isTruncated = true
            return
        }

        guard let childNames = readDirectoryChildNames(atPath: currentDir, context: &context) else {
            return
        }

        for name in childNames {
            if context.cancelToken.isCancelled { return }
            if context.visitedEntries >= context.maxVisitedEntries {
                context.isTruncated = true
                break
            }
            processSubtreeEntry(
                name: name,
                parentDir: currentDir,
                insideReclaim: insideReclaim,
                insidePkg: insidePkg,
                stack: &stack,
                totals: &totals,
                categoryBytes: &categoryBytes,
                context: &context
            )
        }
    }

    private static func readDirectoryChildNames(
        atPath dirPath: String,
        context: inout TraversalContext
    ) -> [String]? {
        guard let dirPtr = Darwin.opendir(dirPath) else {
            let err = errno
            if err == EACCES || err == EPERM {
                context.inaccessibleDirs.append(dirPath)
            }
            return nil
        }

        let remainingBudget = max(0, context.maxVisitedEntries - context.visitedEntries)
        var names: [String] = []
        while let entryPtr = Darwin.readdir(dirPtr) {
            if context.cancelToken.isCancelled {
                Darwin.closedir(dirPtr)
                return nil
            }
            let name = extractEntryName(entryPtr)
            if name == "." || name == ".." || name == ".DS_Store" { continue }
            if names.count >= remainingBudget {
                context.isTruncated = true
                break
            }
            names.append(name)
        }
        Darwin.closedir(dirPtr)
        return names
    }

    private static func processSubtreeEntry(
        name: String,
        parentDir: String,
        insideReclaim: Bool,
        insidePkg: Bool,
        stack: inout [SubtreeWorkItem],
        totals: inout SubtreeTotals,
        categoryBytes: inout [TileCategory: UInt64],
        context: inout TraversalContext
    ) {
        if ForensicPathGuard.isProtectedSubtreeEntryName(name) {
            totals.protectedDescendantHits += 1
        }

        let fullPath = (parentDir as NSString).appendingPathComponent(name)
        var st = Darwin.stat()
        guard Darwin.lstat(fullPath, &st) == 0 else { return }

        recordVisitedEntry(name: name, context: &context)

        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK {
            context.skippedSymlinks += 1
            return
        }

        let entryDev = UInt64(bitPattern: Int64(st.st_dev))
        if entryDev != context.rootDev {
            context.skippedMounts += 1
            return
        }

        if mode == S_IFREG {
            context.scannedFiles += 1
            let (alloc, logic, wasDup) = accountRegularFile(stat: st, dev: entryDev, seen: &context.seenHardlinks)
            if wasDup { context.deduplicatedHardLinks += 1 }
            totals.allocatedBytes &+= alloc
            totals.logicalBytes &+= logic
            let (cat, _) = ForensicPathGuard.classifyRegularFileOrDirectory(
                name: name,
                isDir: false,
                url: URL(fileURLWithPath: fullPath)
            )
            categoryBytes[cat, default: 0] &+= alloc
            return
        }

        guard mode == S_IFDIR else { return }
        enqueueSubtreeDirectory(
            name: name,
            fullPath: fullPath,
            parentDir: parentDir,
            stat: st,
            entryDev: entryDev,
            insideReclaim: insideReclaim,
            insidePkg: insidePkg,
            stack: &stack,
            totals: &totals,
            context: &context
        )
    }

    private static func enqueueSubtreeDirectory(
        name: String,
        fullPath: String,
        parentDir: String,
        stat st: Darwin.stat,
        entryDev: UInt64,
        insideReclaim: Bool,
        insidePkg: Bool,
        stack: inout [SubtreeWorkItem],
        totals: inout SubtreeTotals,
        context: inout TraversalContext
    ) {
        context.scannedDirs += 1
        let childIsPkg = insidePkg || isPackageDirectoryName(name)
        let childURL = URL(fileURLWithPath: fullPath)

        if !insideReclaim && !childIsPkg {
            let eval = ForensicPathGuard.evaluateCandidate(
                name: name,
                isDir: true,
                isSymlink: false,
                url: childURL,
                scanRootPath: context.rootPath,
                isInsidePackage: childIsPkg,
                inspectSubtree: false
            )
            if let verification = eval.verification {
                let identity = StorageEntryIdentity(
                    path: fullPath,
                    parentRealPath: StorageEntryIdentity.resolveRealPath(parentDir) ?? parentDir,
                    device: entryDev,
                    inode: st.st_ino,
                    isDirectory: true,
                    isSymlink: false
                )
                let safetySnapshot = SubtreeSafetySnapshot(
                    protectedHits: totals.protectedDescendantHits,
                    inaccessibleCount: context.inaccessibleDirs.count,
                    skippedMounts: context.skippedMounts
                )
                stack.append(.finishCandidate(PendingCandidateFrame(
                    name: name,
                    url: childURL,
                    rule: eval.rule,
                    verification: verification,
                    reason: eval.reason,
                    identity: identity,
                    allocBefore: totals.allocatedBytes,
                    logicBefore: totals.logicalBytes,
                    safetySnapshot: safetySnapshot
                )))
                stack.append(.enter(path: fullPath, insideReclaim: verification == .verified, insidePkg: childIsPkg))
                return
            }
        }

        stack.append(.enter(path: fullPath, insideReclaim: insideReclaim, insidePkg: childIsPkg))
    }

    // MARK: - Helpers

    private static func recordVisitedEntry(name: String, context: inout TraversalContext) {
        context.visitedEntries += 1
        if context.perEntryDelayNanoseconds > 0 {
            Thread.sleep(forTimeInterval: Double(context.perEntryDelayNanoseconds) / 1_000_000_000.0)
        }
        if context.visitedEntries % 256 == 0 {
            context.onProgress?(name, context.visitedEntries)
        }
    }

    private static func accountRegularFile(
        stat st: Darwin.stat,
        dev: UInt64,
        seen: inout Set<SeenInodeKey>
    ) -> (allocated: UInt64, logical: UInt64, wasDuplicateHardlink: Bool) {
        if st.st_nlink > 1 {
            let key = SeenInodeKey(dev: dev, ino: st.st_ino)
            if !seen.insert(key).inserted {
                return (0, 0, true)
            }
        }
        let logical = UInt64(max(0, st.st_size))
        let allocated = st.st_blocks > 0 ? UInt64(st.st_blocks) * 512 : 0
        return (allocated, logical, false)
    }

    private static func extractEntryName(_ entryPtr: UnsafeMutablePointer<Darwin.dirent>) -> String {
        withUnsafePointer(to: entryPtr.pointee.d_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    private static func isPackageDirectoryName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return packageExtensions.contains(ext)
    }

    private static func cancelledOutput(rootPath: String) -> StorageScanOutput {
        terminalEmptyOutput(status: .cancelled, rootPath: rootPath)
    }

    private static func durationSeconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return max(0.001, secs)
    }

    public static func computeSquarifiedLayoutWithDirs(
        entries: [(name: String, path: String, bytes: UInt64, category: TileCategory, isReclaim: Bool, isDir: Bool)],
        totalBytes: UInt64
    ) -> [TreemapTile] {
        StorageTreemapLayoutEngine.computeSquarifiedLayout(entries: entries, totalBytes: totalBytes)
    }
}
