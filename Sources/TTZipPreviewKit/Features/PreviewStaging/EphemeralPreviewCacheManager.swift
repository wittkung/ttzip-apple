// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import CryptoKit
import Darwin
import TTZipUI

/// Errors thrown when staging archive-extracted preview files violates hard session quotas or active-resource locks.
public enum EphemeralPreviewCacheError: Error, LocalizedError, Equatable, Sendable {
    case singleFileExceedsQuota(fileBytes: Int64, maxTotalBytes: Int64)
    case quotaExceeded(requiredBytes: Int64, availableBytes: Int64, stagedCount: Int, maxFiles: Int, pinnedCount: Int)
    case activeResourcePinned(fileName: String)
    case concurrentStagingInProgress(key: String, fileName: String)

    public var errorDescription: String? {
        switch self {
        case .singleFileExceedsQuota(let fileBytes, let maxTotalBytes):
            return "Single preview file (\(fileBytes) bytes) exceeds session quota (\(maxTotalBytes) bytes)."
        case .quotaExceeded(let requiredBytes, let availableBytes, let stagedCount, let maxFiles, let pinnedCount):
            return "Preview cache quota exhausted (required: \(requiredBytes)B, available: \(availableBytes)B, staged: \(stagedCount)/\(maxFiles), pinned: \(pinnedCount))."
        case .activeResourcePinned(let fileName):
            return "Cannot overwrite or evict active pinned preview resource: \(fileName)."
        case .concurrentStagingInProgress(let key, let fileName):
            return "Concurrent staging reservation already in progress for key \(key) (\(fileName))."
        }
    }
}

/// Unique per-consumer lease token protecting an active cached preview entry from eviction or overwrite.
/// Releasing one consumer's `PreviewCacheLease` never drops protection held by other concurrent consumers.
public struct PreviewCacheLease: Sendable, Hashable, Equatable {
    public let key: String
    public let consumerID: UUID

    public init(key: String, consumerID: UUID = UUID()) {
        self.key = PreviewLRUCacheManager.sanitizeKey(key)
        self.consumerID = consumerID
    }
}

/// Pre-write staging reservation accounting for an in-flight archive extraction slot and estimated byte footprint
/// prior to file materialization on disk.
public struct PreviewStagingReservation: Sendable, Hashable, Equatable {
    public let id: UUID
    public let key: String
    public let filename: String
    public let targetURL: URL
    public let reservedBytes: Int64
    public let consumerID: UUID?

    public init(
        id: UUID = UUID(),
        key: String,
        filename: String,
        targetURL: URL,
        reservedBytes: Int64,
        consumerID: UUID? = nil
    ) {
        self.id = id
        self.key = PreviewLRUCacheManager.sanitizeKey(key)
        self.filename = PreviewLRUCacheManager.sanitizeFilename(filename)
        self.targetURL = targetURL
        self.reservedBytes = max(0, reservedBytes)
        self.consumerID = consumerID
    }
}

/// Unified compatibility facade over `PreviewLRUCacheManager` for sandboxed ephemeral file staging.
///
/// ### Architectural Ownership Boundary (F4 Unified Archive Preview Cache vs. Group A TTMediaDetector Staging)
/// - **`PreviewLRUCacheManager` & `EphemeralPreviewCacheManager` (`TTZipPreviewKit`) — F4 Unified Archive-Preview Cache**:
///   `PreviewLRUCacheManager` is the single authoritative archive-preview staging manager wired to `ExplorerItemInspectorView`,
///   `AppViewState`, and `MillerColumnItemRowView`. `EphemeralPreviewCacheManager` delegates all staging, quota enforcement,
///   active-resource pinning, and lifecycle cleanup directly to `PreviewLRUCacheManager` (`backingManager`) so that only one
///   unified staging mechanism exists in `TTZipPreviewKit`.
/// - **`TTMediaDetector` Ephemeral Media Staging (`TTMediaKit`, path `temporaryDirectory/TTMediaEphemeralStorage/media/<content-sha256>/`) — Group A**:
///   Owns transient materialization of in-memory `Data` buffers strictly for `AVPlayer` (`video`/`audio`) and macOS `QLPreviewView` (`Office` binary documents)
///   when `TTMediaDetector.classifyUnified(source: .memory(...))` is called without a backing disk URL, governed by SHA-256 deduplication and `maxStagedEphemeralFiles = 8`.
public actor EphemeralPreviewCacheManager {
    public static let shared = EphemeralPreviewCacheManager(backingManager: PreviewLRUCacheManager.shared)

    /// Maximum number of staged files retained concurrently in the session sandbox.
    public let maxStagedFiles: Int
    /// Maximum total byte footprint allowed across all staged files in the session sandbox (default 512 MB).
    public let maxTotalBytes: Int64

    /// Underlying authoritative production cache manager.
    public let backingManager: PreviewLRUCacheManager

    public init(backingManager: PreviewLRUCacheManager) {
        self.backingManager = backingManager
        self.maxStagedFiles = backingManager.maxStagedFiles
        self.maxTotalBytes = 512 * 1024 * 1024
    }

    public init(maxStagedFiles: Int = 64, maxTotalBytes: Int64 = 512 * 1024 * 1024) {
        let clampedFiles = max(1, maxStagedFiles)
        let clampedBytes = max(1, maxTotalBytes)
        self.maxStagedFiles = clampedFiles
        self.maxTotalBytes = clampedBytes

        let uniqueSession = "ttzip_previews_\(ProcessInfo.processInfo.processIdentifier)_\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipPreviewCache", isDirectory: true)
            .appendingPathComponent(uniqueSession, isDirectory: true)
        self.backingManager = PreviewLRUCacheManager(
            customCacheDir: tempDir,
            maxStagedFiles: clampedFiles,
            maxCacheSizeBytesOverride: clampedBytes
        )
    }

    /// Acquires a per-consumer lease token for the specified file name.
    public func acquireLease(for suggestedFileName: String, consumerID: UUID = UUID()) async -> PreviewCacheLease {
        let key = PreviewLRUCacheManager.sanitizeFilename(suggestedFileName)
        return await backingManager.acquireLease(forKey: key, consumerID: consumerID)
    }

    /// Releases a previously acquired per-consumer lease token.
    public func releaseLease(_ lease: PreviewCacheLease) async {
        await backingManager.releaseLease(lease)
    }

    /// Pins or unpins a staged file name to prevent eviction or overwrite while actively in use.
    public func setPinned(_ isPinned: Bool, for suggestedFileName: String) async {
        let key = PreviewLRUCacheManager.sanitizeFilename(suggestedFileName)
        if isPinned {
            await backingManager.pin(key: key)
        } else {
            await backingManager.unpin(key: key)
        }
    }

    /// Pins a staged file URL or file name to prevent eviction or overwrite while actively in use.
    public func pinFile(_ fileNameOrPath: String) async {
        let name = (fileNameOrPath as NSString).lastPathComponent
        await setPinned(true, for: name)
    }

    /// Pins a staged file URL to prevent eviction or overwrite while actively in use.
    public func pinFile(url: URL) async {
        await backingManager.pinFile(url: url)
    }

    /// Unpins a staged file URL or file name so it becomes eligible for quota eviction.
    public func unpinFile(_ fileNameOrPath: String) async {
        let name = (fileNameOrPath as NSString).lastPathComponent
        await setPinned(false, for: name)
    }

    /// Unpins a staged file URL so it becomes eligible for quota eviction.
    public func unpinFile(url: URL) async {
        await backingManager.unpinFile(url: url)
    }

    /// Returns whether the specified staged file URL is currently pinned.
    public func isPinned(fileURL: URL) async -> Bool {
        await backingManager.isPinned(fileURL: fileURL)
    }

    /// Returns whether the specified file name is currently pinned.
    public func isPinned(fileName: String) async -> Bool {
        let key = PreviewLRUCacheManager.sanitizeFilename(fileName)
        return await backingManager.isPinned(key: key)
    }

    /// Current number of staged files tracked in the session.
    public func stagedFileCount() async -> Int {
        await backingManager.stagedFileCount()
    }

    /// Current total byte size of all staged files tracked in the session.
    public func totalStagedBytes() async -> Int64 {
        await backingManager.totalStagedBytes()
    }

    /// Stages data into an isolated file via the underlying `PreviewLRUCacheManager`, enforcing file count, byte quotas, and active-resource pinning.
    public func stageFile(data: Data, preferredFileName: String) async throws -> URL {
        try await backingManager.stageFile(data: data, suggestedFileName: preferredFileName)
    }

    /// Stages data into an isolated file via the underlying `PreviewLRUCacheManager`, enforcing file count, byte quotas, and active-resource pinning.
    public func stageFile(data: Data, suggestedFileName: String) async throws -> URL {
        try await backingManager.stageFile(data: data, suggestedFileName: suggestedFileName)
    }

    /// Returns the session directory URL.
    public func getSessionRoot() -> URL {
        backingManager.getSessionRoot()
    }

    /// Removes all staged preview files and deletes the session directory.
    public func cleanupAll() async {
        await cleanupSessionDirectory()
    }

    /// Removes all staged preview files, resets accounting, and deletes the session directory.
    public func cleanupSessionDirectory() async {
        await backingManager.purgeAll()
        let root = backingManager.getSessionRoot()
        if root.lastPathComponent.hasPrefix("ttzip_previews_"),
           FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

extension PreviewLRUCacheManager {
    nonisolated static func isSymbolicLink(at path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    nonisolated static func isValidRegularFile(at path: String, requireNonEmpty: Bool) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return !requireNonEmpty || st.st_size > 0
    }

    nonisolated static func ensureRestrictedDirectory(at url: URL) {
        guard !isSymbolicLink(at: url.path) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard !isSymbolicLink(at: url.path) else { return }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public nonisolated static func sanitizeComponent(_ raw: String, fallback: String) -> String {
        let noNull = raw.replacingOccurrences(of: "\0", with: "")
        let unified = noNull.replacingOccurrences(of: "\\", with: "/")
        let segments = unified.split(separator: "/").map(String.init)
        let candidate = segments.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if candidate.isEmpty || candidate == "." || candidate == ".." || candidate.contains("..") {
            return fallback
        }
        let cleaned = candidate
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return fallback
        }
        return cleaned
    }

    public nonisolated static func sanitizeKey(_ rawKey: String) -> String {
        let fallbackHash = SHA256.hash(data: Data(rawKey.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        let fallback = fallbackHash.isEmpty ? "default_key" : "key_\(fallbackHash)"

        let noNull = rawKey.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if noNull.isEmpty || noNull == "." || noNull == ".." || noNull.contains("..") || noNull.contains("/") || noNull.contains("\\") || noNull.contains(":") {
            return fallback
        }
        return sanitizeComponent(noNull, fallback: fallback)
    }

    public nonisolated static func sanitizeFilename(_ rawFilename: String) -> String {
        let fallbackHash = SHA256.hash(data: Data(rawFilename.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let fallback = "entry_\(fallbackHash)"
        return sanitizeComponent(rawFilename, fallback: fallback)
    }

    nonisolated static func nestedCandidateURL(
        in keyDir: URL,
        subpath: String,
        expectedFilename: String
    ) -> URL? {
        let unified = subpath.replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: "\\", with: "/")
        let segments = unified.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !segments.isEmpty, !segments.contains("..") else { return nil }
        var cur = keyDir
        for (idx, seg) in segments.enumerated() {
            let isLast = (idx == segments.count - 1)
            let cleanSeg = isLast ? sanitizeFilename(seg) : sanitizeComponent(seg, fallback: "")
            guard !cleanSeg.isEmpty else { return nil }
            cur = cur.appendingPathComponent(cleanSeg, isDirectory: !isLast)
        }
        guard cur.lastPathComponent == expectedFilename else { return nil }
        return cur
    }

    nonisolated static func checkBoundary(
        fileURL: URL,
        expectedKeyDir: URL,
        rootDir: URL
    ) -> Bool {
        guard !isSymbolicLink(at: rootDir.path),
              !isSymbolicLink(at: expectedKeyDir.path),
              !isSymbolicLink(at: fileURL.path) else {
            return false
        }
        let keyStandard = expectedKeyDir.standardizedFileURL.path
        let fileStandard = fileURL.standardizedFileURL.path
        let keyStandardPrefix = keyStandard.hasSuffix("/") ? keyStandard : keyStandard + "/"
        guard fileStandard.hasPrefix(keyStandardPrefix) else { return false }

        let relTail = String(fileStandard.dropFirst(keyStandardPrefix.count))
        var stepURL = URL(fileURLWithPath: keyStandard, isDirectory: true)
        for seg in relTail.split(separator: "/").map(String.init) {
            if seg.isEmpty || seg == "." || seg == ".." { return false }
            stepURL.appendPathComponent(seg)
            if isSymbolicLink(at: stepURL.path) { return false }
        }

        let rootResolved = rootDir.standardizedFileURL.resolvingSymlinksInPath().path
        let keyResolved = expectedKeyDir.standardizedFileURL.resolvingSymlinksInPath().path
        let fileResolved = fileURL.standardizedFileURL.resolvingSymlinksInPath().path

        let rootPrefix = rootResolved.hasSuffix("/") ? rootResolved : rootResolved + "/"
        guard keyResolved.hasPrefix(rootPrefix) else { return false }

        let keyPrefix = keyResolved.hasSuffix("/") ? keyResolved : keyResolved + "/"
        guard fileResolved.hasPrefix(keyPrefix) else { return false }

        return true
    }

    nonisolated static func purgeDirectoryContentsWithinBoundary(
        at dirURL: URL,
        keyDir: URL,
        rootDir: URL
    ) {
        let fm = FileManager.default
        guard !isSymbolicLink(at: rootDir.path),
              !isSymbolicLink(at: keyDir.path),
              !isSymbolicLink(at: dirURL.path),
              let names = try? fm.contentsOfDirectory(atPath: dirURL.path) else {
            return
        }
        for name in names where !name.isEmpty && name != "." && name != ".." {
            let childURL = dirURL.appendingPathComponent(name, isDirectory: false)
            guard checkBoundary(fileURL: childURL, expectedKeyDir: keyDir, rootDir: rootDir) else {
                continue
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: childURL.path, isDirectory: &isDir), isDir.boolValue {
                purgeDirectoryContentsWithinBoundary(at: childURL, keyDir: keyDir, rootDir: rootDir)
            }
            try? fm.removeItem(at: childURL)
        }
    }
}
