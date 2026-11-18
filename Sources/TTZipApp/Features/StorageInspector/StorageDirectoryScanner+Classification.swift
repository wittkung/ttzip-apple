// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreGraphics
import Darwin
import Foundation
import TTZipCore
import TTZipUI

// MARK: - Subtree Classification & Stack Traversal

extension StorageDirectoryScanner {
    static func resolveCandidateAfterSubtree(
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
    static func appendResolvedCandidate(
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

    static func finalizeScanOutput(
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

    struct SubtreeTotals {
        var allocatedBytes: UInt64 = 0
        var logicalBytes: UInt64 = 0
        var reclaimableBytes: UInt64 = 0
        var protectedDescendantHits: Int = 0
        var dominantCategory: TileCategory = .others
    }

    struct PendingCandidateFrame {
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

    enum SubtreeWorkItem {
        case enter(path: String, insideReclaim: Bool, insidePkg: Bool)
        case finishCandidate(PendingCandidateFrame)
    }

    static func traverseSubtree(
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

    static func recordVisitedEntry(name: String, context: inout TraversalContext) {
        context.visitedEntries += 1
        if context.perEntryDelayNanoseconds > 0 {
            Thread.sleep(forTimeInterval: Double(context.perEntryDelayNanoseconds) / 1_000_000_000.0)
        }
        if context.visitedEntries % 256 == 0 {
            context.onProgress?(name, context.visitedEntries)
        }
    }

    static func accountRegularFile(
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

    static func extractEntryName(_ entryPtr: UnsafeMutablePointer<Darwin.dirent>) -> String {
        withUnsafePointer(to: entryPtr.pointee.d_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    static func isPackageDirectoryName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return packageExtensions.contains(ext)
    }

    static func cancelledOutput(rootPath: String) -> StorageScanOutput {
        terminalEmptyOutput(status: .cancelled, rootPath: rootPath)
    }

    static func durationSeconds(since start: ContinuousClock.Instant) -> Double {
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
