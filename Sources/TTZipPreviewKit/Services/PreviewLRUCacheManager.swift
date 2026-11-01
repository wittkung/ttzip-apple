// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import CryptoKit
import TTZipUI

/// Authoritative production LRU preview cache manager providing hard quota enforcement, per-consumer lease tokens,
/// pre-write staging reservations, symlink boundary verification, and automated session lifecycle cleanup.
public actor PreviewLRUCacheManager {
    public static let shared = PreviewLRUCacheManager()

    /// Generates a deterministic, salt-free cache key for an archive entry.
    public nonisolated static func deterministicCacheKey(archivePath: String, subpath: String) -> String {
        let fullId = "\(archivePath)::\(subpath)"
        let digest = SHA256.hash(data: Data(fullId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let quotaDefaultsKey = "PreviewCacheQuotaGB"
    public let maxStagedFiles: Int
    private let maxCacheSizeBytesOverride: Int64?

    public var maxCacheSizeGB: Double {
        get {
            let saved = UserDefaults.standard.double(forKey: Self.quotaDefaultsKey)
            return saved > 0 ? saved : 10.0
        }
        set {
            let clamped = max(0.5, newValue)
            UserDefaults.standard.set(clamped, forKey: Self.quotaDefaultsKey)
            evictIfNecessary()
        }
    }

    public var maxCacheSizeBytes: Int64 {
        if let override = maxCacheSizeBytesOverride { return override }
        return Int64(maxCacheSizeGB * 1024.0 * 1024.0 * 1024.0)
    }

    public var effectiveMaxCacheSizeBytes: Int64 { maxCacheSizeBytes }

    nonisolated private var fileManager: FileManager { FileManager.default }
    private let cacheDir: URL

    private struct CacheItem: Sendable {
        let key: String
        let fileURL: URL
        let sizeBytes: Int64
        var lastAccessed: Date
    }

    private struct InFlightStagingEntry {
        let reservation: PreviewStagingReservation
        let pinAnonymouslyOnCommit: Bool
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private var items: [String: CacheItem] = [:]
    private var activeConsumerLeases: [String: Set<UUID>] = [:]
    private var anonymousPinCounts: [String: Int] = [:]
    private var activeStagingReservations: [String: InFlightStagingEntry] = [:]

    public init(
        customCacheDir: URL? = nil,
        maxStagedFiles: Int = 64,
        maxCacheSizeBytesOverride: Int64? = nil
    ) {
        self.maxStagedFiles = max(1, maxStagedFiles)
        self.maxCacheSizeBytesOverride = maxCacheSizeBytesOverride.map { max(1, $0) }

        let fm = FileManager.default
        let defaultRoot = fm.temporaryDirectory
            .appendingPathComponent("TTZipLRUPreviewCache", isDirectory: true)
            .appendingPathComponent("session-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        let baseDir = customCacheDir ?? defaultRoot
        Self.ensureRestrictedDirectory(at: baseDir)
        self.cacheDir = baseDir
        self.items = Self.reconcileExistingItems(in: baseDir, fileManager: fm)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.purgeAll()
            }
        }
    }

    nonisolated private static func reconcileExistingItems(
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

    // MARK: - Per-Consumer Lease Holding & Independent Player Handoff

    private func hasActiveConsumerHold(_ safeKey: String) -> Bool {
        if let holders = activeConsumerLeases[safeKey], !holders.isEmpty { return true }
        if let count = anonymousPinCounts[safeKey], count > 0 { return true }
        return false
    }

    private func isProtectedFromEviction(_ safeKey: String) -> Bool {
        hasActiveConsumerHold(safeKey) || activeStagingReservations[safeKey] != nil
    }

    /// Acquires a per-consumer lease token protecting `key` from eviction until `releaseLease(_:)` is called with that token.
    @discardableResult
    public func acquireLease(forKey key: String, consumerID: UUID = UUID()) -> PreviewCacheLease {
        let safeKey = Self.sanitizeKey(key)
        activeConsumerLeases[safeKey, default: []].insert(consumerID)
        return PreviewCacheLease(key: safeKey, consumerID: consumerID)
    }

    /// Clones an active consumer lease for an independent player window (acquire-before-release handoff).
    /// Ensures the independent player holds its own `consumerID` lease before the browser/inspector releases its lease.
    @discardableResult
    public func cloneLease(from existingLease: PreviewCacheLease, newConsumerID: UUID = UUID()) -> PreviewCacheLease {
        acquireLease(forKey: existingLease.key, consumerID: newConsumerID)
    }

    /// Acquires a dedicated consumer lease for an independent player window given a staged cache file URL.
    public func acquireIndependentPlayerLease(
        forFileURL fileURL: URL,
        consumerID: UUID = UUID()
    ) -> PreviewCacheLease? {
        let keyCandidate = Self.sanitizeKey(fileURL.deletingLastPathComponent().lastPathComponent)
        if items[keyCandidate] != nil || activeStagingReservations[keyCandidate] != nil {
            return acquireLease(forKey: keyCandidate, consumerID: consumerID)
        }
        if let matched = items.values.first(where: { $0.fileURL.standardizedFileURL == fileURL.standardizedFileURL }) {
            return acquireLease(forKey: matched.key, consumerID: consumerID)
        }
        return nil
    }

    /// Releases a specific consumer's lease token without dropping protection held by other active consumers on the same key.
    /// When `reclaimImmediatelyIfIdle` is `true` and no other consumers or pins remain on `key`, removes the staged entry from disk immediately.
    public func releaseLease(_ lease: PreviewCacheLease, reclaimImmediatelyIfIdle: Bool = false) {
        let safeKey = Self.sanitizeKey(lease.key)
        if var holders = activeConsumerLeases[safeKey] {
            holders.remove(lease.consumerID)
            if holders.isEmpty {
                activeConsumerLeases.removeValue(forKey: safeKey)
            } else {
                activeConsumerLeases[safeKey] = holders
            }
        }
        if let staging = activeStagingReservations[safeKey],
           staging.reservation.consumerID == lease.consumerID {
            releaseStagingReservationInternal(forKey: safeKey, reservationID: staging.reservation.id)
        }
        if reclaimImmediatelyIfIdle, !isProtectedFromEviction(safeKey), let item = items.removeValue(forKey: safeKey) {
            removeKeyDirectoryIfWithinBoundary(item.fileURL)
        } else if !isProtectedFromEviction(safeKey) {
            evictIfNecessary()
        }
    }

    /// Returns the total number of active consumer leases and paired anonymous pins currently holding `key`.
    public func activeLeaseCount(forKey key: String) -> Int {
        let safeKey = Self.sanitizeKey(key)
        return (activeConsumerLeases[safeKey]?.count ?? 0) + (anonymousPinCounts[safeKey] ?? 0)
    }

    /// Paired reference-counted pin for callers that do not track an explicit `PreviewCacheLease`.
    public func pin(key: String) {
        let safeKey = Self.sanitizeKey(key)
        anonymousPinCounts[safeKey, default: 0] += 1
    }

    /// Paired reference-counted unpin; decrements the anonymous pin count and cancels any uncommitted anonymous staging reservation.
    public func unpin(key: String) {
        let safeKey = Self.sanitizeKey(key)
        if let current = anonymousPinCounts[safeKey] {
            if current > 1 {
                anonymousPinCounts[safeKey] = current - 1
            } else {
                anonymousPinCounts.removeValue(forKey: safeKey)
            }
        }
        if !hasActiveConsumerHold(safeKey),
           items[safeKey] == nil,
           let staging = activeStagingReservations[safeKey],
           staging.reservation.consumerID == nil {
            releaseStagingReservationInternal(forKey: safeKey, reservationID: staging.reservation.id)
        }
    }

    public func isPinned(key: String) -> Bool {
        isProtectedFromEviction(Self.sanitizeKey(key))
    }

    public func pinFile(url: URL) {
        let keyCandidate = url.deletingLastPathComponent().lastPathComponent
        if items[keyCandidate] != nil || activeStagingReservations[keyCandidate] != nil {
            pin(key: keyCandidate)
        } else {
            pin(key: Self.sanitizeKey(url.lastPathComponent))
        }
    }

    public func unpinFile(url: URL) {
        let keyCandidate = url.deletingLastPathComponent().lastPathComponent
        if anonymousPinCounts[keyCandidate] != nil || activeStagingReservations[keyCandidate] != nil {
            unpin(key: keyCandidate)
        } else {
            unpin(key: Self.sanitizeKey(url.lastPathComponent))
        }
    }

    public func isPinned(fileURL: URL) -> Bool {
        let keyCandidate = fileURL.deletingLastPathComponent().lastPathComponent
        return isProtectedFromEviction(keyCandidate) || isProtectedFromEviction(Self.sanitizeKey(fileURL.lastPathComponent))
    }

    public func pinnedKeyCount() -> Int {
        let allKeys = Set(items.keys).union(activeStagingReservations.keys)
        return allKeys.filter { isProtectedFromEviction($0) }.count
    }

    public func stagedFileCount() -> Int {
        items.count
    }

    public func activeStagingCount() -> Int {
        activeStagingReservations.count
    }

    public func reservedStagingBytes() -> Int64 {
        activeStagingReservations.values.reduce(0) { $0 + $1.reservation.reservedBytes }
    }

    public func totalStagedBytes() -> Int64 {
        items.values.reduce(0) { $0 + $1.sizeBytes }
    }

    public nonisolated func getSessionRoot() -> URL {
        cacheDir
    }

    // MARK: - Hard Quota Admission & Pre-Write Staging Reservations

    /// Reserves an in-flight file slot and estimated byte footprint before archive extraction begins.
    /// Explicitly rejects concurrent reservations for the same key with `.concurrentStagingInProgress`.
    public func acquireStagingReservation(
        forKey key: String,
        filename: String,
        estimatedBytes: Int64,
        consumerID: UUID? = nil,
        pinActive: Bool = true,
        rejectIfPinned: Bool = false
    ) throws -> PreviewStagingReservation {
        let safeKey = Self.sanitizeKey(key)
        let safeFilename = Self.sanitizeFilename(filename)
        let incoming = max(0, estimatedBytes)
        let maxBytes = effectiveMaxCacheSizeBytes

        if incoming > maxBytes {
            throw EphemeralPreviewCacheError.singleFileExceedsQuota(
                fileBytes: incoming,
                maxTotalBytes: maxBytes
            )
        }
        if activeStagingReservations[safeKey] != nil {
            throw EphemeralPreviewCacheError.concurrentStagingInProgress(
                key: safeKey,
                fileName: safeFilename
            )
        }
        if (rejectIfPinned || items[safeKey] != nil) && hasActiveConsumerHold(safeKey) {
            throw EphemeralPreviewCacheError.activeResourcePinned(fileName: safeFilename)
        }

        try enforceQuotaBeforeWrite(safeKey: safeKey, incomingBytes: incoming)

        guard let url = targetURL(forKey: safeKey, filename: filename) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let reservation = PreviewStagingReservation(
            key: safeKey,
            filename: safeFilename,
            targetURL: url,
            reservedBytes: incoming,
            consumerID: consumerID
        )
        activeStagingReservations[safeKey] = InFlightStagingEntry(
            reservation: reservation,
            pinAnonymouslyOnCommit: pinActive && (consumerID == nil)
        )
        return reservation
    }

    /// Checks hard quotas, records a pre-write staging reservation (counting in-flight file count and estimated bytes),
    /// and returns the validated destination URL inside the cache boundary.
    public func acquireStagingTargetURL(
        forKey key: String, filename: String, estimatedBytes: Int64,
        pinActive: Bool = true, rejectIfPinned: Bool = false
    ) throws -> URL {
        try acquireStagingReservation(
            forKey: key, filename: filename, estimatedBytes: estimatedBytes,
            consumerID: nil, pinActive: pinActive, rejectIfPinned: rejectIfPinned
        ).targetURL
    }

    /// Releases an uncommitted pre-write staging reservation upon extraction failure or task cancellation.
    public func cancelStagingReservation(_ reservation: PreviewStagingReservation) {
        releaseStagingReservationInternal(forKey: reservation.key, reservationID: reservation.id)
    }

    /// Releases an uncommitted pre-write staging reservation for `key` owned by `reservationID`.
    public func cancelStagingReservation(forKey key: String, reservationID: UUID) {
        releaseStagingReservationInternal(forKey: Self.sanitizeKey(key), reservationID: reservationID)
    }

    /// Suspends until the current in-flight staging reservation for `key` commits or cancels, enabling same-key coalescing.
    public func waitForInFlightStaging(forKey key: String) async {
        let safeKey = Self.sanitizeKey(key)
        guard activeStagingReservations[safeKey] != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if var entry = activeStagingReservations[safeKey] {
                entry.waiters.append(continuation)
                activeStagingReservations[safeKey] = entry
            } else {
                continuation.resume()
            }
        }
    }

    private func releaseStagingReservationInternal(forKey safeKey: String, reservationID: UUID) {
        guard let entry = activeStagingReservations[safeKey],
              entry.reservation.id == reservationID else {
            return
        }
        activeStagingReservations.removeValue(forKey: safeKey)
        if items[safeKey] == nil {
            cleanupUncommittedReservationArtifacts(entry.reservation)
        }
        for waiter in entry.waiters {
            waiter.resume()
        }
    }

    private func cleanupUncommittedReservationArtifacts(_ reservation: PreviewStagingReservation) {
        let target = reservation.targetURL
        let keyDir = target.deletingLastPathComponent()
        guard isURLWithinCacheBoundary(target, expectedKeyDir: keyDir) else { return }
        Self.purgeDirectoryContentsWithinBoundary(at: keyDir, keyDir: keyDir, rootDir: cacheDir)
        Self.ensureRestrictedDirectory(at: keyDir)
    }

    private func consumeStagingReservationOnCommit(
        forKey safeKey: String, reservationID: UUID?
    ) -> InFlightStagingEntry? {
        guard let reservationID,
              let entry = activeStagingReservations[safeKey],
              entry.reservation.id == reservationID else {
            return nil
        }
        activeStagingReservations.removeValue(forKey: safeKey)
        for waiter in entry.waiters {
            waiter.resume()
        }
        return entry
    }

    private func releaseIfReserved(forKey safeKey: String, reservationID: UUID?) {
        if let reservationID {
            releaseStagingReservationInternal(forKey: safeKey, reservationID: reservationID)
        }
    }

    private func verifyReservationForRegistration(safeKey: String, reservationID: UUID?) throws {
        if let activeEntry = activeStagingReservations[safeKey] {
            guard activeEntry.reservation.id == reservationID else {
                throw EphemeralPreviewCacheError.concurrentStagingInProgress(
                    key: safeKey, fileName: activeEntry.reservation.filename
                )
            }
        } else if reservationID != nil {
            throw CocoaError(.userCancelled)
        }
    }

    private func validateFileForRegistration(
        safeKey: String, fileURL: URL, expectedFilename: String?, requireNonEmpty: Bool
    ) throws {
        if let expectedFilename, fileURL.lastPathComponent != Self.sanitizeFilename(expectedFilename) {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let expectedKeyDir = cacheDir.appendingPathComponent(safeKey, isDirectory: true)
        guard isURLWithinCacheBoundary(fileURL, expectedKeyDir: expectedKeyDir),
              Self.isValidRegularFile(at: fileURL.path, requireNonEmpty: requireNonEmpty) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    /// Validates an extracted preview file against boundary, symlink, reservation ownership, and hard byte/count quotas,
    /// atomically promoting the owned staging reservation to a registered `CacheItem` and acquiring a consumer lease if requested.
    @discardableResult
    public func registerValidated(
        key: String,
        fileURL: URL,
        expectedFilename: String? = nil,
        requireNonEmpty: Bool = false,
        pinActive: Bool = false,
        consumerID: UUID? = nil,
        reservationID: UUID? = nil
    ) throws -> URL {
        let safeKey = Self.sanitizeKey(key)
        try verifyReservationForRegistration(safeKey: safeKey, reservationID: reservationID)
        do {
            try validateFileForRegistration(
                safeKey: safeKey, fileURL: fileURL, expectedFilename: expectedFilename, requireNonEmpty: requireNonEmpty
            )
        } catch {
            releaseIfReserved(forKey: safeKey, reservationID: reservationID)
            throw error
        }

        let verifiedURL = fileURL.standardizedFileURL
        let actualSize = (try? fileManager.attributesOfItem(atPath: verifiedURL.path)[.size] as? Int64) ?? 0
        do {
            if actualSize > effectiveMaxCacheSizeBytes {
                throw EphemeralPreviewCacheError.singleFileExceedsQuota(
                    fileBytes: actualSize, maxTotalBytes: effectiveMaxCacheSizeBytes
                )
            }
            try enforceQuotaBeforeWrite(safeKey: safeKey, incomingBytes: actualSize)
        } catch {
            releaseIfReserved(forKey: safeKey, reservationID: reservationID)
            removeKeyDirectoryIfWithinBoundary(verifiedURL)
            items.removeValue(forKey: safeKey)
            throw error
        }

        let consumedStaging = consumeStagingReservationOnCommit(forKey: safeKey, reservationID: reservationID)
        items[safeKey] = CacheItem(key: safeKey, fileURL: verifiedURL, sizeBytes: actualSize, lastAccessed: Date())
        recordLeaseOrAnonymousPinOnCommit(
            safeKey: safeKey, consumerID: consumerID, pinActive: pinActive, consumedStaging: consumedStaging
        )
        return verifiedURL
    }

    private func recordLeaseOrAnonymousPinOnCommit(
        safeKey: String, consumerID: UUID?, pinActive: Bool, consumedStaging: InFlightStagingEntry?
    ) {
        if let resolvedConsumerID = consumerID ?? consumedStaging?.reservation.consumerID {
            activeConsumerLeases[safeKey, default: []].insert(resolvedConsumerID)
        } else if pinActive || (consumedStaging?.pinAnonymouslyOnCommit == true) {
            anonymousPinCounts[safeKey, default: 0] += 1
        }
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

    private func effectiveFootprintBytes(forKey key: String) -> Int64 {
        let itemBytes = items[key]?.sizeBytes ?? 0
        let reservedBytes = activeStagingReservations[key]?.reservation.reservedBytes ?? 0
        return max(itemBytes, reservedBytes)
    }

    private func enforceQuotaBeforeWrite(safeKey: String, incomingBytes: Int64) throws {
        let maxBytes = effectiveMaxCacheSizeBytes
        let allOccupiedKeys = Set(items.keys).union(activeStagingReservations.keys)
        let otherProtectedKeys = allOccupiedKeys.filter { $0 != safeKey && isProtectedFromEviction($0) }
        let protectedCount = otherProtectedKeys.count
        let protectedBytes = otherProtectedKeys.reduce(into: Int64(0)) { acc, k in
            acc += effectiveFootprintBytes(forKey: k)
        }

        if protectedCount >= maxStagedFiles || (protectedBytes + incomingBytes) > maxBytes {
            throw EphemeralPreviewCacheError.quotaExceeded(
                requiredBytes: incomingBytes,
                availableBytes: max(0, maxBytes - protectedBytes),
                stagedCount: allOccupiedKeys.count,
                maxFiles: maxStagedFiles,
                pinnedCount: pinnedKeyCount()
            )
        }

        if items[safeKey] != nil && !hasActiveConsumerHold(safeKey) {
            items.removeValue(forKey: safeKey)
        }

        evictUnpinnedEntries(forIncomingBytes: incomingBytes, excludingKey: safeKey)

        let remainingOtherKeys = Set(items.keys).union(activeStagingReservations.keys).subtracting([safeKey])
        let projectedCount = remainingOtherKeys.count + 1
        let currentBytesExcludingKey = remainingOtherKeys.reduce(into: Int64(0)) { acc, k in
            acc += effectiveFootprintBytes(forKey: k)
        }
        if projectedCount > maxStagedFiles || (currentBytesExcludingKey + incomingBytes) > maxBytes {
            throw EphemeralPreviewCacheError.quotaExceeded(
                requiredBytes: incomingBytes,
                availableBytes: max(0, maxBytes - currentBytesExcludingKey),
                stagedCount: remainingOtherKeys.count,
                maxFiles: maxStagedFiles,
                pinnedCount: pinnedKeyCount()
            )
        }
    }

    private func evictUnpinnedEntries(forIncomingBytes incomingBytes: Int64, excludingKey: String) {
        let maxBytes = effectiveMaxCacheSizeBytes
        let sortedUnpinned = items.values
            .filter { $0.key != excludingKey && !isProtectedFromEviction($0.key) }
            .sorted { $0.lastAccessed < $1.lastAccessed }

        for victim in sortedUnpinned {
            let otherKeys = Set(items.keys).union(activeStagingReservations.keys).subtracting([excludingKey])
            let needsCountEviction = (otherKeys.count + 1) > maxStagedFiles
            let currentBytes = otherKeys.reduce(into: Int64(0)) { $0 += effectiveFootprintBytes(forKey: $1) }
            let needsByteEviction = (currentBytes + incomingBytes) > maxBytes
            guard needsCountEviction || needsByteEviction else { break }

            removeKeyDirectoryIfWithinBoundary(victim.fileURL)
            items.removeValue(forKey: victim.key)
        }
    }

    private func removeKeyDirectoryIfWithinBoundary(_ fileURL: URL) {
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

    private func candidateExtractedURLs(
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

    private nonisolated func isURLWithinCacheBoundary(_ fileURL: URL, expectedKeyDir: URL) -> Bool {
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

    private func evictIfNecessary() {
        var currentTotalSize = items.values.reduce(0) { $0 + $1.sizeBytes }
        let maxBytes = effectiveMaxCacheSizeBytes
        guard currentTotalSize > maxBytes || items.count > maxStagedFiles else { return }

        let sortedUnpinned = items.values
            .filter { !isProtectedFromEviction($0.key) }
            .sorted { $0.lastAccessed < $1.lastAccessed }
        for item in sortedUnpinned {
            removeKeyDirectoryIfWithinBoundary(item.fileURL)
            items.removeValue(forKey: item.key)
            currentTotalSize -= item.sizeBytes
            if currentTotalSize <= maxBytes && items.count <= maxStagedFiles {
                break
            }
        }
    }

    public func purgeAll() {
        items.removeAll()
        activeConsumerLeases.removeAll()
        anonymousPinCounts.removeAll()
        let pendingEntries = activeStagingReservations.values
        activeStagingReservations.removeAll()
        for entry in pendingEntries {
            for waiter in entry.waiters {
                waiter.resume()
            }
        }
        try? fileManager.removeItem(at: cacheDir)
        Self.ensureRestrictedDirectory(at: cacheDir)
    }
}
