// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import TTZipCore
import TTZipUI

// MARK: - Pre-Cleanup Revalidation Gate & POSIX Probes

extension ForensicPathGuard {
    /// Revalidates a candidate right before moving it to Trash, defending against TOCTOU symlink swaps,
    /// inode replacement, parent redirection, scope escape, evidence loss, and protected subtree contents.
    public static func revalidateBeforeTrash(
        item: ReclaimableStorageItem,
        authorizedScanRootPath: String,
        cancelToken: StorageScanCancelToken = StorageScanCancelToken(),
        maxSubtreeEntries: Int = defaultSubtreeInspectionBudget
    ) -> StorageCleanupRejectionReason? {
        guard item.verification == .verified else {
            return .unverifiedCandidate
        }

        let targetPath = item.path
        if isProtectedSystemPath(targetPath) {
            return .protectedSystemPath
        }

        let effectiveRoot = authorizedScanRootPath.isEmpty ? item.scanRootPath : authorizedScanRootPath
        if let scopeError = verifyScopeAndAncestors(item: item, effectiveRoot: effectiveRoot) {
            return scopeError
        }

        return verifyLiveIdentityAndEvidence(
            item: item,
            effectiveRoot: effectiveRoot,
            cancelToken: cancelToken,
            maxSubtreeEntries: maxSubtreeEntries
        )
    }

    private static func verifyScopeAndAncestors(
        item: ReclaimableStorageItem,
        effectiveRoot: String
    ) -> StorageCleanupRejectionReason? {
        let targetPath = item.path
        if !effectiveRoot.isEmpty {
            let rootReal = resolveCanonicalPath(effectiveRoot)
            if !isStrictDescendant(childPath: resolveCanonicalPath(targetPath), ofRootPath: rootReal) {
                return .outsideAuthorizedRoot
            }
        }

        let parentPath = (targetPath as NSString).deletingLastPathComponent
        guard let currentParentReal = StorageEntryIdentity.resolveRealPath(parentPath) else {
            return .symlinkOrParentChanged
        }
        if !item.identity.parentRealPath.isEmpty && currentParentReal != item.identity.parentRealPath {
            return .symlinkOrParentChanged
        }

        if !effectiveRoot.isEmpty && hasSymlinkOrMissingAncestor(from: parentPath, downTo: effectiveRoot) {
            return .symlinkOrParentChanged
        }
        return nil
    }

    private static func hasSymlinkOrMissingAncestor(from startParent: String, downTo rootPath: String) -> Bool {
        var cursor = startParent
        let stopPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        while cursor.count >= stopPath.count && cursor != "/" {
            var ancStat = Darwin.stat()
            if Darwin.lstat(cursor, &ancStat) != 0 || (ancStat.st_mode & S_IFMT) == S_IFLNK {
                return true
            }
            if cursor == stopPath { break }
            let next = (cursor as NSString).deletingLastPathComponent
            if next == cursor { break }
            cursor = next
        }
        return false
    }

    private static func verifyLiveIdentityAndEvidence(
        item: ReclaimableStorageItem,
        effectiveRoot: String,
        cancelToken: StorageScanCancelToken,
        maxSubtreeEntries: Int
    ) -> StorageCleanupRejectionReason? {
        let targetPath = item.path
        guard let liveIdentity = StorageEntryIdentity.capture(atPath: targetPath) else {
            return .identityChangedSinceScan
        }
        if liveIdentity.isSymlink || !liveIdentity.isDirectory {
            return .symlinkOrParentChanged
        }
        if item.identity.inode != 0 && (liveIdentity.inode != item.identity.inode || liveIdentity.device != item.identity.device) {
            return .identityChangedSinceScan
        }

        guard let targetReal = StorageEntryIdentity.resolveRealPath(targetPath) else {
            return .identityChangedSinceScan
        }
        if isProtectedSystemPath(targetReal) {
            return .protectedSystemPath
        }
        if !effectiveRoot.isEmpty && !isStrictDescendant(childPath: targetReal, ofRootPath: resolveCanonicalPath(effectiveRoot)) {
            return .outsideAuthorizedRoot
        }

        let recheck = evaluateCandidate(
            name: (targetPath as NSString).lastPathComponent,
            isDir: true,
            isSymlink: false,
            url: URL(fileURLWithPath: targetPath),
            scanRootPath: effectiveRoot,
            inspectSubtree: false
        )
        guard recheck.verification == .verified else {
            return .evidenceNoLongerValid
        }

        switch inspectCandidateSubtreeSafety(
            atPath: targetReal,
            cancelToken: cancelToken,
            maxEntries: maxSubtreeEntries
        ) {
        case .clean:
            return nil
        case .containsProtectedContent:
            return .subtreeContainsProtectedContent
        case .incomplete:
            return .subtreeInspectionIncomplete
        }
    }

    // MARK: - Low-Level POSIX Probes

    static func extractDirentName(_ entryPtr: UnsafeMutablePointer<Darwin.dirent>) -> String {
        withUnsafePointer(to: entryPtr.pointee.d_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    static func regularFileExists(in dirPath: String, named fileName: String) -> Bool {
        regularFileExists(atPath: (dirPath as NSString).appendingPathComponent(fileName))
    }

    static func hasAnyRegularFile(in dirPath: String, names: [String]) -> Bool {
        names.contains { regularFileExists(in: dirPath, named: $0) }
    }

    static func regularFileExists(atPath path: String) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    static func directoryExists(atPath path: String) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func containsVCSDirectory(atPath dirPath: String) -> Bool {
        for vcs in [".git", ".hg", ".svn"] {
            var st = Darwin.stat()
            if Darwin.lstat((dirPath as NSString).appendingPathComponent(vcs), &st) == 0 {
                return true
            }
        }
        return false
    }

    static func hasValidCacheDirTag(inDirectory dirPath: String) -> Bool {
        let tagPath = (dirPath as NSString).appendingPathComponent("CACHEDIR.TAG")
        guard regularFileExists(atPath: tagPath),
              let handle = FileHandle(forReadingAtPath: tagPath) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64),
              let prefix = String(data: data, encoding: .utf8) else {
            return false
        }
        return prefix.hasPrefix(cacheDirTagSignature)
    }

    static func isPurePycacheDirectory(atPath dirPath: String) -> Bool {
        guard let dir = Darwin.opendir(dirPath) else { return false }
        defer { Darwin.closedir(dir) }

        var pycCount = 0
        while let entryPtr = Darwin.readdir(dir) {
            let name = extractDirentName(entryPtr)
            if name == "." || name == ".." || name == ".DS_Store" { continue }
            let lower = name.lowercased()
            if lower.hasSuffix(".pyc") || lower.hasSuffix(".pyo") {
                pycCount += 1
            } else {
                return false
            }
        }
        return pycCount > 0
    }
}
