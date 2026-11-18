// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Darwin
import TTZipCore
import TTZipUI

// MARK: - Complete Filesystem Identity

/// Immutable identity of a scanned filesystem entry, binding its standardized path
/// to the POSIX `(st_dev, st_ino)` observed via `lstat` at scan time.
public struct StorageEntryIdentity: Sendable, Hashable, Codable {
    public let path: String
    public let parentRealPath: String
    public let device: UInt64
    public let inode: UInt64
    public let isDirectory: Bool
    public let isSymlink: Bool

    public init(
        path: String,
        parentRealPath: String = "",
        device: UInt64 = 0,
        inode: UInt64 = 0,
        isDirectory: Bool = true,
        isSymlink: Bool = false
    ) {
        self.path = path
        self.parentRealPath = parentRealPath
        self.device = device
        self.inode = inode
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }

    /// Captures the live `lstat` identity of `path` without following symlinks on the leaf.
    public static func capture(atPath path: String) -> StorageEntryIdentity? {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        let mode = st.st_mode & S_IFMT
        let isLink = (mode == S_IFLNK)
        let isDir = (mode == S_IFDIR)
        let parentPath = (path as NSString).deletingLastPathComponent
        let parentReal = Self.resolveRealPath(parentPath) ?? parentPath
        return StorageEntryIdentity(
            path: path,
            parentRealPath: parentReal,
            device: UInt64(bitPattern: Int64(st.st_dev)),
            inode: st.st_ino,
            isDirectory: isDir,
            isSymlink: isLink
        )
    }

    /// Resolves `realpath(3)` if the path exists on disk.
    public static func resolveRealPath(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = Darwin.realpath(path, &buf) else { return nil }
        return String(cString: resolved)
    }

    /// Creates a directory identity with canonicalized parent path.
    public static func directory(
        path: String,
        parentPath: String,
        device: UInt64,
        inode: UInt64
    ) -> StorageEntryIdentity {
        StorageEntryIdentity(
            path: path,
            parentRealPath: resolveRealPath(parentPath) ?? parentPath,
            device: device,
            inode: inode,
            isDirectory: true,
            isSymlink: false
        )
    }
}

// MARK: - Candidate Verification Tier & Evidence

/// Verification tier distinguishing evidence-backed rebuildable caches from name-only matches.
public enum ReclaimVerificationStatus: String, Sendable, Hashable, Codable {
    /// Positive project/cache evidence verified and no blocking condition hit; eligible for user selection.
    case verified
    /// Directory name matched a known cache name, but sibling/child evidence is missing; display-only.
    case nameOnly
}

/// Specific rule that identified a reclaimable candidate.
public enum ReclaimRuleKind: String, Sendable, Hashable, Codable {
    case nodeModules
    case xcodeDerivedData
    case cargoTarget
    case swiftPMBuild
    case gradleOrCMakeBuild
    case gradleCache
    case pythonVenv
    case pythonPycache
    case cacheDirTag
    case unverifiedNameMatch

    public func localizedReason(name: String, language: AppLanguage? = nil) -> String {
        switch self {
        case .nodeModules:
            return StorageLocaleKey.reasonNodeModules.resolve(for: language)
        case .xcodeDerivedData:
            return StorageLocaleKey.reasonDerivedData.resolve(for: language)
        case .cargoTarget:
            return StorageLocaleKey.reasonCargoTarget.resolve(for: language)
        case .swiftPMBuild:
            return StorageLocaleKey.reasonSwiftBuild.resolve(for: language)
        case .gradleOrCMakeBuild:
            return StorageLocaleKey.reasonGradleOrCMakeBuild.resolve(for: language)
        case .gradleCache:
            return StorageLocaleKey.reasonGradleCache.resolve(for: language)
        case .pythonVenv:
            return StorageLocaleKey.reasonPythonVenv.resolve(for: language)
        case .pythonPycache:
            return StorageLocaleKey.reasonPycache.resolve(for: language)
        case .cacheDirTag:
            return StorageLocaleKey.reasonCacheDirTag.resolve(for: language)
        case .unverifiedNameMatch:
            return StorageLocaleKey.reasonUnverifiedNameOnlyFormat.format(for: language, name)
        }
    }
}

// MARK: - Reclaimable Storage Item Model

/// Strongly-typed descriptor for an identified reclaimable cache or build artifact.
public struct ReclaimableStorageItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let url: URL
    public let path: String
    public let sizeBytes: UInt64
    public let logicalBytes: UInt64
    public let category: TileCategory
    public let reason: String
    public let ruleKind: ReclaimRuleKind?
    public let verification: ReclaimVerificationStatus
    public let identity: StorageEntryIdentity
    public let scanRootPath: String

    public var isSelectableForCleanup: Bool {
        verification == .verified && !identity.isSymlink && identity.isDirectory
    }

    public init(
        name: String,
        url: URL,
        sizeBytes: UInt64,
        logicalBytes: UInt64? = nil,
        category: TileCategory = .reclaimCache,
        reason: String,
        ruleKind: ReclaimRuleKind? = nil,
        verification: ReclaimVerificationStatus = .verified,
        identity: StorageEntryIdentity? = nil,
        scanRootPath: String = ""
    ) {
        let standardizedPath = url.path
        self.id = standardizedPath
        self.name = name
        self.url = url
        self.path = standardizedPath
        self.sizeBytes = sizeBytes
        self.logicalBytes = logicalBytes ?? sizeBytes
        self.category = category
        self.reason = reason
        self.ruleKind = ruleKind
        self.verification = verification
        if let identity {
            self.identity = identity
        } else if let captured = StorageEntryIdentity.capture(atPath: standardizedPath) {
            self.identity = captured
        } else {
            self.identity = StorageEntryIdentity(path: standardizedPath)
        }
        self.scanRootPath = scanRootPath
    }

    public func localizedReason(for language: AppLanguage) -> String {
        if let ruleKind {
            return ruleKind.localizedReason(name: name, language: language)
        }
        return reason
    }
}

// MARK: - Storage Scanner State Machine & Accounting Summary

/// Complete accounting metrics for a single directory scan generation.
public struct StorageScanSummary: Sendable, Equatable {
    public let rootPath: String
    public let allocatedBytes: UInt64
    public let logicalBytes: UInt64
    public let reclaimableBytes: UInt64
    public let scannedFiles: Int
    public let scannedDirectories: Int
    public let deduplicatedHardLinks: Int
    public let skippedSymlinks: Int
    public let skippedMountPoints: Int
    public let inaccessibleDirectories: [String]
    public let isTruncated: Bool
    public let durationSec: Double

    public init(
        rootPath: String,
        allocatedBytes: UInt64,
        logicalBytes: UInt64,
        reclaimableBytes: UInt64,
        scannedFiles: Int,
        scannedDirectories: Int,
        deduplicatedHardLinks: Int = 0,
        skippedSymlinks: Int = 0,
        skippedMountPoints: Int = 0,
        inaccessibleDirectories: [String] = [],
        isTruncated: Bool = false,
        durationSec: Double = 0.1
    ) {
        self.rootPath = rootPath
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.reclaimableBytes = reclaimableBytes
        self.scannedFiles = scannedFiles
        self.scannedDirectories = scannedDirectories
        self.deduplicatedHardLinks = deduplicatedHardLinks
        self.skippedSymlinks = skippedSymlinks
        self.skippedMountPoints = skippedMountPoints
        self.inaccessibleDirectories = inaccessibleDirectories
        self.isTruncated = isTruncated
        self.durationSec = durationSec
    }
}

/// State machine driving the local storage scanning and deduplication flow.
public enum StorageScannerState: Sendable, Equatable {
    case idle
    case scanning(currentPath: String, scannedItems: Int, itemsPerSec: Int)
    case completed(totalBytes: UInt64, reclaimableBytes: UInt64, durationSec: Double)
    case empty(rootPath: String)
    case cancelled
    case permissionDenied(path: String)
    case failed(message: String)
}

/// Thread-safe cooperative cancellation token checked at every directory entry during scanning and cleanup.
public final class StorageScanCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled: Bool = false

    public init() {}

    public func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }
}

/// Complete result returned by `StorageDirectoryScanner.scanDirectory`.
public struct StorageScanOutput: Sendable {
    public enum TerminalStatus: Sendable, Equatable {
        case completed
        case empty
        case cancelled
        case permissionDenied(path: String)
        case failed(message: String)
    }

    public let status: TerminalStatus
    public let summary: StorageScanSummary
    public let verifiedCandidates: [ReclaimableStorageItem]
    public let unverifiedCandidates: [ReclaimableStorageItem]
    public let tiles: [TreemapTile]

    public init(
        status: TerminalStatus,
        summary: StorageScanSummary,
        verifiedCandidates: [ReclaimableStorageItem],
        unverifiedCandidates: [ReclaimableStorageItem],
        tiles: [TreemapTile]
    ) {
        self.status = status
        self.summary = summary
        self.verifiedCandidates = verifiedCandidates
        self.unverifiedCandidates = unverifiedCandidates
        self.tiles = tiles
    }
}

// MARK: - Cleanup Per-Item Outcome & Batch Report

/// Reason a candidate was rejected by the pre-trash revalidation gate.
public enum StorageCleanupRejectionReason: String, Sendable, Equatable {
    case protectedSystemPath
    case outsideAuthorizedRoot
    case symlinkOrParentChanged
    case identityChangedSinceScan
    case evidenceNoLongerValid
    case unverifiedCandidate
    case subtreeContainsProtectedContent
    case subtreeInspectionIncomplete

    public func localizedDescription(for language: AppLanguage? = nil) -> String {
        switch self {
        case .protectedSystemPath:
            return StorageLocaleKey.outcomeRejectedProtected.resolve(for: language)
        case .outsideAuthorizedRoot:
            return StorageLocaleKey.outcomeRejectedOutsideScope.resolve(for: language)
        case .symlinkOrParentChanged:
            return StorageLocaleKey.outcomeRejectedSymlinkOrParentChanged.resolve(for: language)
        case .identityChangedSinceScan:
            return StorageLocaleKey.outcomeRejectedIdentityChanged.resolve(for: language)
        case .evidenceNoLongerValid:
            return StorageLocaleKey.outcomeRejectedEvidenceLost.resolve(for: language)
        case .unverifiedCandidate:
            return StorageLocaleKey.outcomeRejectedUnverified.resolve(for: language)
        case .subtreeContainsProtectedContent:
            return StorageLocaleKey.outcomeRejectedSubtreeProtected.resolve(for: language)
        case .subtreeInspectionIncomplete:
            return StorageLocaleKey.outcomeRejectedSubtreeIncomplete.resolve(for: language)
        }
    }
}

/// Per-item outcome produced when executing a cleanup request.
public enum StorageCleanupItemOutcome: Sendable, Equatable {
    case trashed(trashedURL: URL?)
    case coveredByParent(parentPath: String)
    case rejected(StorageCleanupRejectionReason)
    case cancelled
    case failed(message: String)

    public var isSuccess: Bool {
        switch self {
        case .trashed, .coveredByParent:
            return true
        case .rejected, .cancelled, .failed:
            return false
        }
    }

    public func localizedStatus(for language: AppLanguage? = nil) -> String {
        switch self {
        case .trashed:
            return StorageLocaleKey.outcomeTrashed.resolve(for: language)
        case .coveredByParent:
            return StorageLocaleKey.outcomeCoveredByParent.resolve(for: language)
        case .rejected(let reason):
            return reason.localizedDescription(for: language)
        case .cancelled:
            return StorageLocaleKey.outcomeCancelled.resolve(for: language)
        case .failed(let msg):
            return StorageLocaleKey.outcomeFailedFormat.format(for: language, msg)
        }
    }
}

/// Record for a single item in a cleanup batch report.
public struct StorageCleanupItemRecord: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let estimatedBytes: UInt64
    public let outcome: StorageCleanupItemOutcome

    public init(name: String, path: String, estimatedBytes: UInt64, outcome: StorageCleanupItemOutcome) {
        self.id = path
        self.name = name
        self.path = path
        self.estimatedBytes = estimatedBytes
        self.outcome = outcome
    }
}

/// Complete report for a user-initiated cleanup operation, bound to its origin task generation and directory.
public struct StorageCleanupReport: Sendable, Equatable {
    public let cleanupGeneration: UInt64
    public let scanGeneration: UInt64
    public let rootPath: String
    public let records: [StorageCleanupItemRecord]
    public let trashedCount: Int
    public let coveredByParentCount: Int
    public let rejectedOrFailedCount: Int
    public let cancelledCount: Int
    /// Estimated allocated bytes of items moved to macOS Trash (physical volume space is freed only after emptying Trash).
    public let trashedEstimatedBytes: UInt64
    public var reclaimedEstimatedBytes: UInt64 { trashedEstimatedBytes }

    public init(
        cleanupGeneration: UInt64 = 0,
        scanGeneration: UInt64 = 0,
        rootPath: String = "",
        records: [StorageCleanupItemRecord],
        trashedCount: Int,
        coveredByParentCount: Int,
        rejectedOrFailedCount: Int,
        cancelledCount: Int = 0,
        reclaimedEstimatedBytes: UInt64
    ) {
        self.cleanupGeneration = cleanupGeneration
        self.scanGeneration = scanGeneration
        self.rootPath = rootPath
        self.records = records
        self.trashedCount = trashedCount
        self.coveredByParentCount = coveredByParentCount
        self.rejectedOrFailedCount = rejectedOrFailedCount
        self.cancelledCount = cancelledCount
        self.trashedEstimatedBytes = reclaimedEstimatedBytes
    }

    public var isAllSuccess: Bool {
        rejectedOrFailedCount == 0 && cancelledCount == 0 && trashedCount > 0
    }
}
