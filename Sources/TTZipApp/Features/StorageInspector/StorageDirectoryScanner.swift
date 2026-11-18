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

    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "qlgenerator", "appex",
        "xcodeproj", "xcworkspace", "xcarchive", "playground", "photoslibrary"
    ]

    struct DirectChildAccumulator {
        let name: String
        let path: String
        let isDir: Bool
        let isSymlink: Bool
        var allocatedBytes: UInt64
        var logicalBytes: UInt64
        var category: TileCategory
        var isVerifiedReclaim: Bool
    }

    struct SeenInodeKey: Hashable {
        let dev: UInt64
        let ino: UInt64
    }

    struct TraversalContext {
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
    struct SubtreeSafetySnapshot {
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

    static func terminalEmptyOutput(
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
}
