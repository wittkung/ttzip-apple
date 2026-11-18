// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import TTZipPreviewKit

/// Tracks preview cache keys associated with logical archive identities with retention bounded
/// to actual staged cache resources so forgetting an archive's password evicts only its previews.
public final class ArchivePreviewKeyRegistry: @unchecked Sendable {
    public static let shared = ArchivePreviewKeyRegistry()

    private let lock = NSLock()
    private var keysByLogicalArchive: [String: Set<String>] = [:]
    private var reservationIDsByKey: [String: Set<UUID>] = [:]
    private var consumerIDsByKey: [String: Set<UUID>] = [:]

    public init() {}

    public func record(archivePath: String, cacheKey: String) {
        let logicalKey = ArchiveCredentialIdentity.logicalKey(for: archivePath)
        record(logicalKey: logicalKey, cacheKey: cacheKey)
    }

    public func recordReservation(_ reservation: PreviewStagingReservation, archivePath: String) {
        let logicalKey = ArchiveCredentialIdentity.logicalKey(for: archivePath)
        let safeKey = reservation.key
        guard !logicalKey.isEmpty, !safeKey.isEmpty else { return }
        let sessionRoot = PreviewLRUCacheManager.shared.getSessionRoot()
        lock.withLock {
            pruneAllUnstagedKeysLocked(sessionRoot: sessionRoot)
            _ = keysByLogicalArchive[logicalKey, default: []].insert(safeKey)
            _ = reservationIDsByKey[safeKey, default: []].insert(reservation.id)
            if let consumerID = reservation.consumerID {
                _ = consumerIDsByKey[safeKey, default: []].insert(consumerID)
            }
        }
    }

    public func recordLease(_ lease: PreviewCacheLease, archivePath: String) {
        let logicalKey = ArchiveCredentialIdentity.logicalKey(for: archivePath)
        let safeKey = lease.key
        guard !logicalKey.isEmpty, !safeKey.isEmpty else { return }
        let sessionRoot = PreviewLRUCacheManager.shared.getSessionRoot()
        lock.withLock {
            pruneAllUnstagedKeysLocked(sessionRoot: sessionRoot)
            _ = keysByLogicalArchive[logicalKey, default: []].insert(safeKey)
            _ = consumerIDsByKey[safeKey, default: []].insert(lease.consumerID)
        }
    }

    public func record(archivePath: String, subpath: String) {
        let trimmedArchive = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubpath = subpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArchive.isEmpty, !trimmedSubpath.isEmpty else { return }
        let logicalKey = ArchiveCredentialIdentity.logicalKey(for: trimmedArchive)
        let normalizedArchive = URL(fileURLWithPath: trimmedArchive)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let candidateArchivePaths = Set([trimmedArchive, normalizedArchive])
        let strippedSubpath = trimmedSubpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidateSubpaths = strippedSubpath.isEmpty
            ? Set([trimmedSubpath])
            : Set([trimmedSubpath, strippedSubpath])
        let sessionRoot = PreviewLRUCacheManager.shared.getSessionRoot()
        var keys: Set<String> = []
        for arch in candidateArchivePaths {
            for sub in candidateSubpaths {
                keys.insert(PreviewLRUCacheManager.deterministicCacheKey(archivePath: arch, subpath: sub))
            }
        }
        lock.withLock {
            pruneAllUnstagedKeysLocked(sessionRoot: sessionRoot)
            keysByLogicalArchive[logicalKey, default: []].formUnion(keys)
        }
    }

    public func record(logicalKey: String, cacheKey: String) {
        guard !logicalKey.isEmpty, !cacheKey.isEmpty else { return }
        let sessionRoot = PreviewLRUCacheManager.shared.getSessionRoot()
        lock.withLock {
            pruneAllUnstagedKeysLocked(sessionRoot: sessionRoot)
            _ = keysByLogicalArchive[logicalKey, default: []].insert(cacheKey)
        }
    }

    public func removeKey(_ cacheKey: String) {
        _ = removeAndConsumeResources(forKey: cacheKey)
    }

    public func removeAndConsumeResources(
        forKey cacheKey: String
    ) -> (reservationIDs: Set<UUID>, consumerIDs: Set<UUID>) {
        guard !cacheKey.isEmpty else { return ([], []) }
        return lock.withLock {
            for logicalKey in Array(keysByLogicalArchive.keys) {
                guard var set = keysByLogicalArchive[logicalKey] else { continue }
                set.remove(cacheKey)
                if set.isEmpty {
                    keysByLogicalArchive.removeValue(forKey: logicalKey)
                } else {
                    keysByLogicalArchive[logicalKey] = set
                }
            }
            let reservations = reservationIDsByKey.removeValue(forKey: cacheKey) ?? []
            let consumers = consumerIDsByKey.removeValue(forKey: cacheKey) ?? []
            return (reservations, consumers)
        }
    }

    public func pruneUnstagedKeys(forArchivePath archivePath: String, sessionRoot: URL) {
        let logicalKey = ArchiveCredentialIdentity.logicalKey(for: archivePath)
        guard !logicalKey.isEmpty else { return }
        lock.withLock {
            pruneUnstagedKeysLocked(forLogicalKey: logicalKey, sessionRoot: sessionRoot)
        }
    }

    public func consumeKeys(forLogicalKey logicalKey: String, archivePaths: Set<String>) -> Set<String> {
        var matchingLogicalKeys: Set<String> = [logicalKey]
        for path in archivePaths where !path.isEmpty {
            matchingLogicalKeys.insert(ArchiveCredentialIdentity.logicalKey(for: path))
        }
        return lock.withLock {
            var collected: Set<String> = []
            for key in matchingLogicalKeys {
                if let removed = keysByLogicalArchive.removeValue(forKey: key) {
                    collected.formUnion(removed)
                }
            }
            return collected
        }
    }

    private func pruneAllUnstagedKeysLocked(sessionRoot: URL) {
        for logicalKey in Array(keysByLogicalArchive.keys) {
            pruneUnstagedKeysLocked(forLogicalKey: logicalKey, sessionRoot: sessionRoot)
        }
    }

    private func pruneUnstagedKeysLocked(forLogicalKey logicalKey: String, sessionRoot: URL) {
        guard var set = keysByLogicalArchive[logicalKey] else { return }
        set = set.filter { key in
            let keyDir = sessionRoot.appendingPathComponent(key, isDirectory: true)
            if FileManager.default.fileExists(atPath: keyDir.path) {
                return true
            }
            reservationIDsByKey.removeValue(forKey: key)
            consumerIDsByKey.removeValue(forKey: key)
            return false
        }
        if set.isEmpty {
            keysByLogicalArchive.removeValue(forKey: logicalKey)
        } else {
            keysByLogicalArchive[logicalKey] = set
        }
    }
}

extension PreviewLRUCacheManager {
    private nonisolated static func isSymlinkPath(_ path: String) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private nonisolated static func normalizeCacheKeyComponent(_ rawKey: String) -> String {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
    }

    /// Evicts a single preview cache entry by key, revoking in-flight staging reservations and consumer leases.
    public func evictArchiveEntry(forKey key: String) {
        let safeKey = Self.normalizeCacheKeyComponent(key)
        guard !safeKey.isEmpty else { return }
        let tracked = ArchivePreviewKeyRegistry.shared.removeAndConsumeResources(forKey: safeKey)
        for reservationID in tracked.reservationIDs {
            cancelStagingReservation(forKey: safeKey, reservationID: reservationID)
        }
        for consumerID in tracked.consumerIDs {
            releaseLease(
                PreviewCacheLease(key: safeKey, consumerID: consumerID),
                reclaimImmediatelyIfIdle: true
            )
        }
        for _ in 0..<32 {
            let before = activeLeaseCount(forKey: safeKey)
            guard before > 0 else { break }
            unpin(key: safeKey)
            if activeLeaseCount(forKey: safeKey) >= before {
                break
            }
        }
        let sessionRoot = getSessionRoot()
        let keyDir = sessionRoot.appendingPathComponent(safeKey, isDirectory: true)
        if !Self.isSymlinkPath(sessionRoot.path),
           !Self.isSymlinkPath(keyDir.path),
           FileManager.default.fileExists(atPath: keyDir.path) {
            try? FileManager.default.removeItem(at: keyDir)
        }
        _ = cachedURL(forKey: safeKey)
    }

    private func discoverStagedPreviewSnapshot() -> (stagedKeys: Set<String>, stagedFilenames: Set<String>) {
        let sessionRoot = getSessionRoot()
        guard !Self.isSymlinkPath(sessionRoot.path),
              let keyDirs = try? FileManager.default.contentsOfDirectory(
                  at: sessionRoot,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return ([], [])
        }
        var stagedKeys: Set<String> = []
        var filenames: Set<String> = []
        for keyDir in keyDirs where !Self.isSymlinkPath(keyDir.path) {
            let keyName = Self.normalizeCacheKeyComponent(keyDir.lastPathComponent)
            if !keyName.isEmpty {
                stagedKeys.insert(keyName)
            }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: keyDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for fileURL in files where !fileURL.lastPathComponent.isEmpty {
                filenames.insert(fileURL.lastPathComponent)
            }
        }
        return (stagedKeys, filenames)
    }

    private func collectBoundedEvictionKeys(
        archivePaths: Set<String>,
        entrySubpaths: Set<String>,
        stagedKeys: Set<String>,
        stagedFilenames: Set<String>
    ) -> Set<String> {
        let boundedSubpaths = entrySubpaths.union(stagedFilenames)
        guard !boundedSubpaths.isEmpty, !stagedKeys.isEmpty || !entrySubpaths.isEmpty else {
            return []
        }
        var expandedSubpaths: Set<String> = []
        for rawSubpath in boundedSubpaths where !rawSubpath.isEmpty {
            expandedSubpaths.insert(rawSubpath)
            let trimmed = rawSubpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty {
                expandedSubpaths.insert(trimmed)
            }
        }
        var keysToEvict: Set<String> = []
        for archivePath in archivePaths where !archivePath.isEmpty {
            for subpath in expandedSubpaths {
                let candidate = Self.deterministicCacheKey(archivePath: archivePath, subpath: subpath)
                if stagedKeys.contains(candidate) || activeLeaseCount(forKey: candidate) > 0 {
                    keysToEvict.insert(candidate)
                }
            }
        }
        return keysToEvict
    }

    /// Evicts all preview cache entries scoped to the given logical archive and active selected subpaths.
    public func evictArchiveEntries(
        logicalKey: String,
        archivePaths: Set<String>,
        entrySubpaths: Set<String>
    ) {
        let snapshot = discoverStagedPreviewSnapshot()
        let registeredKeys = ArchivePreviewKeyRegistry.shared.consumeKeys(
            forLogicalKey: logicalKey,
            archivePaths: archivePaths
        )
        let candidateKeys = registeredKeys.union(
            collectBoundedEvictionKeys(
                archivePaths: archivePaths,
                entrySubpaths: entrySubpaths,
                stagedKeys: snapshot.stagedKeys,
                stagedFilenames: snapshot.stagedFilenames
            )
        )
        for key in candidateKeys {
            let safeKey = Self.normalizeCacheKeyComponent(key)
            if registeredKeys.contains(key)
                || snapshot.stagedKeys.contains(safeKey)
                || activeLeaseCount(forKey: safeKey) > 0 {
                evictArchiveEntry(forKey: safeKey)
            }
        }
    }
}
