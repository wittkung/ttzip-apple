// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

extension PreviewLRUCacheManager {
    nonisolated static func reconcileExistingItems(
        in baseDir: URL,
        fileManager: FileManager
    ) -> [String: CacheItem] {
        var restored: [String: CacheItem] = [:]
        guard let subdirs = try? fileManager.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else {
            return restored
        }
        for dir in subdirs where dir.hasDirectoryPath && !isSymbolicLink(at: dir.path) {
            ensureRestrictedDirectory(at: dir)
            let key = sanitizeKey(dir.lastPathComponent)
            guard dir.lastPathComponent == key else { continue }
            if let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ),
               let file = files.first(where: { !$0.lastPathComponent.hasPrefix(".") }),
               isValidRegularFile(at: file.path, requireNonEmpty: true),
               checkBoundary(fileURL: file, expectedKeyDir: dir, rootDir: baseDir) {
                let attrs = try? fileManager.attributesOfItem(atPath: file.path)
                let size = (attrs?[.size] as? Int64) ?? 0
                let date = (attrs?[.modificationDate] as? Date) ?? Date()
                restored[key] = CacheItem(key: key, fileURL: file.standardizedFileURL, sizeBytes: size, lastAccessed: date)
            }
        }
        return restored
    }

    /// Stages in-memory `Data` atomically into the unified LRU preview cache while enforcing hard quotas and active-resource locks.
    public func stageFile(
        data: Data,
        key: String? = nil,
        suggestedFileName: String,
        pinActive: Bool = false,
        consumerID: UUID? = nil
    ) throws -> URL {
        let safeFilename = Self.sanitizeFilename(suggestedFileName)
        let resolvedKey = Self.sanitizeKey(key ?? safeFilename)
        let incomingBytes = Int64(data.count)
        let maxBytes = effectiveMaxCacheSizeBytes

        if incomingBytes > maxBytes {
            throw EphemeralPreviewCacheError.singleFileExceedsQuota(
                fileBytes: incomingBytes,
                maxTotalBytes: maxBytes
            )
        }
        if activeStagingReservations[resolvedKey] != nil {
            throw EphemeralPreviewCacheError.concurrentStagingInProgress(key: resolvedKey, fileName: safeFilename)
        }
        if items[resolvedKey] != nil && hasActiveConsumerHold(resolvedKey) {
            throw EphemeralPreviewCacheError.activeResourcePinned(fileName: safeFilename)
        }

        try enforceQuotaBeforeWrite(safeKey: resolvedKey, incomingBytes: incomingBytes)

        guard let destinationURL = targetURL(forKey: resolvedKey, filename: safeFilename) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let keyDir = destinationURL.deletingLastPathComponent()
        let tempSibling = keyDir.appendingPathComponent(".tmp_\(UUID().uuidString)")
        try data.write(to: tempSibling, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempSibling.path)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempSibling, to: destinationURL)

        let verifiedURL = destinationURL.standardizedFileURL
        items[resolvedKey] = CacheItem(
            key: resolvedKey,
            fileURL: verifiedURL,
            sizeBytes: incomingBytes,
            lastAccessed: Date()
        )
        if let consumerID {
            activeConsumerLeases[resolvedKey, default: []].insert(consumerID)
        } else if pinActive {
            anonymousPinCounts[resolvedKey, default: 0] += 1
        }
        return verifiedURL
    }

    func removeKeyDirectoryIfWithinBoundary(_ fileURL: URL) {
        let parentDir = fileURL.deletingLastPathComponent()
        if isURLWithinCacheBoundary(fileURL, expectedKeyDir: parentDir) {
            try? fileManager.removeItem(at: parentDir)
        }
    }

    public func cachedURL(forKey key: String, expectedFilename: String? = nil) -> URL? {
        let safeKey = Self.sanitizeKey(key)
        guard var item = items[safeKey] ?? items[key] else { return nil }
        let expectedKeyDir = cacheDir.appendingPathComponent(safeKey, isDirectory: true)
        let matchesExpectedName: Bool = {
            guard let expectedFilename = expectedFilename else { return true }
            let safeExpected = Self.sanitizeFilename(expectedFilename)
            return item.fileURL.lastPathComponent == safeExpected
        }()
        guard matchesExpectedName,
              Self.isValidRegularFile(at: item.fileURL.path, requireNonEmpty: true),
              isURLWithinCacheBoundary(item.fileURL, expectedKeyDir: expectedKeyDir) else {
            items.removeValue(forKey: safeKey)
            items.removeValue(forKey: key)
            return nil
        }

        item.lastAccessed = Date()
        items[safeKey] = item
        return item.fileURL
    }

    /// Atomically resolves a cached preview URL and acquires a per-consumer lease in the same actor turn.
    public func acquireCachedURL(
        forKey key: String,
        expectedFilename: String? = nil,
        consumerID: UUID = UUID()
    ) -> (url: URL, lease: PreviewCacheLease)? {
        guard let validURL = cachedURL(forKey: key, expectedFilename: expectedFilename) else {
            return nil
        }
        let lease = acquireLease(forKey: key, consumerID: consumerID)
        return (validURL, lease)
    }

    @discardableResult
    public func register(
        key: String, fileURL: URL, expectedFilename: String? = nil, requireNonEmpty: Bool = false
    ) -> URL? {
        try? registerValidated(
            key: key, fileURL: fileURL, expectedFilename: expectedFilename,
            requireNonEmpty: requireNonEmpty, pinActive: false
        )
    }

    func candidateExtractedURLs(
        in keyDir: URL, directTargetURL: URL, filename: String, subpath: String?
    ) -> [URL] {
        let safeExpected = Self.sanitizeFilename(filename)
        var candidates: [URL] = [directTargetURL]
        if let subpath,
           let nested = Self.nestedCandidateURL(in: keyDir, subpath: subpath, expectedFilename: safeExpected) {
            candidates.append(nested)
        }
        if let entries = try? fileManager.contentsOfDirectory(atPath: keyDir.path) {
            for name in entries where !name.hasPrefix(".") && name == safeExpected {
                candidates.append(keyDir.appendingPathComponent(name, isDirectory: false))
            }
        }
        return candidates
    }

    public func resolveAndRegisterExtractedPreview(
        forKey key: String,
        filename: String,
        subpath: String? = nil,
        pinActive: Bool = false,
        consumerID: UUID? = nil,
        reservationID: UUID? = nil
    ) throws -> URL? {
        let safeKey = Self.sanitizeKey(key)
        if (activeStagingReservations[safeKey] != nil) != (reservationID != nil) {
            return nil
        }
        try verifyReservationForRegistration(safeKey: safeKey, reservationID: reservationID)

        guard let directTargetURL = targetURL(forKey: key, filename: filename) else {
            releaseIfReserved(forKey: safeKey, reservationID: reservationID)
            return nil
        }
        let candidates = candidateExtractedURLs(
            in: directTargetURL.deletingLastPathComponent(),
            directTargetURL: directTargetURL,
            filename: filename,
            subpath: subpath
        )
        for candidate in candidates where Self.isValidRegularFile(at: candidate.path, requireNonEmpty: true) {
            do {
                return try registerValidated(
                    key: key, fileURL: candidate, expectedFilename: filename, requireNonEmpty: true,
                    pinActive: pinActive, consumerID: consumerID, reservationID: reservationID
                )
            } catch let quotaErr as EphemeralPreviewCacheError {
                throw quotaErr
            } catch {
                continue
            }
        }
        releaseIfReserved(forKey: safeKey, reservationID: reservationID)
        return nil
    }

    public func resolveAndRegisterExtractedPreview(
        forKey key: String, filename: String, subpath: String? = nil
    ) -> URL? {
        try? resolveAndRegisterExtractedPreview(
            forKey: key, filename: filename, subpath: subpath,
            pinActive: false, consumerID: nil, reservationID: nil
        )
    }

    public nonisolated func targetURL(forKey key: String, filename: String) -> URL? {
        guard !Self.isSymbolicLink(at: cacheDir.path) else { return nil }
        Self.ensureRestrictedDirectory(at: cacheDir)
        let safeKey = Self.sanitizeKey(key)
        let safeFilename = Self.sanitizeFilename(filename)

        let keyDir = cacheDir.appendingPathComponent(safeKey, isDirectory: true)
        guard !Self.isSymbolicLink(at: keyDir.path) else { return nil }
        Self.ensureRestrictedDirectory(at: keyDir)
        let candidateURL = keyDir.appendingPathComponent(safeFilename, isDirectory: false)

        guard isURLWithinCacheBoundary(candidateURL, expectedKeyDir: keyDir) else {
            return nil
        }
        return candidateURL
    }

    nonisolated func isURLWithinCacheBoundary(_ fileURL: URL, expectedKeyDir: URL) -> Bool {
        Self.checkBoundary(fileURL: fileURL, expectedKeyDir: expectedKeyDir, rootDir: cacheDir)
    }

    public nonisolated func existingCachedURL(forKey key: String, filename: String) -> URL? {
        guard let candidate = targetURL(forKey: key, filename: filename),
              Self.isValidRegularFile(at: candidate.path, requireNonEmpty: false),
              isURLWithinCacheBoundary(candidate, expectedKeyDir: candidate.deletingLastPathComponent()) else {
            return nil
        }
        return candidate
    }
}
