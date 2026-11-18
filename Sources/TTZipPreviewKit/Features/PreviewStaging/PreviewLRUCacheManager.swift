// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import CryptoKit
import Darwin
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

    nonisolated var fileManager: FileManager { FileManager.default }
    let cacheDir: URL

    struct CacheItem: Sendable {
        let key: String
        let fileURL: URL
        let sizeBytes: Int64
        var lastAccessed: Date
    }

    struct InFlightStagingEntry {
        let reservation: PreviewStagingReservation
        let pinAnonymouslyOnCommit: Bool
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    var items: [String: CacheItem] = [:]
    var activeConsumerLeases: [String: Set<UUID>] = [:]
    var anonymousPinCounts: [String: Int] = [:]
    var activeStagingReservations: [String: InFlightStagingEntry] = [:]

    public init(
        customCacheDir: URL? = nil,
        maxStagedFiles: Int = 64,
        maxCacheSizeBytesOverride: Int64? = nil
    ) {
        self.maxStagedFiles = max(1, maxStagedFiles)
        self.maxCacheSizeBytesOverride = maxCacheSizeBytesOverride.map { max(1, $0) }

        let fm = FileManager.default
        let sharedCacheRoot = fm.temporaryDirectory
            .appendingPathComponent("TTZipLRUPreviewCache", isDirectory: true)
        let defaultRoot = sharedCacheRoot
            .appendingPathComponent("session-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        let baseDir = customCacheDir ?? defaultRoot
        Self.ensureRestrictedDirectory(at: baseDir)
        self.cacheDir = baseDir
        let parentDir = baseDir.deletingLastPathComponent()
        if parentDir.lastPathComponent == "TTZipLRUPreviewCache" {
            Self.pruneDeadProcessSessionDirectories(in: parentDir, excluding: baseDir, fileManager: fm)
        }
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

    /// Removes sibling `session-<pid>-*` directories under `cacheRoot` whose owning process `<pid>` is no longer alive.
    @discardableResult
    public nonisolated static func pruneDeadProcessSessionDirectories(
        in cacheRoot: URL,
        excluding currentSessionDir: URL? = nil,
        fileManager: FileManager = .default
    ) -> Int {
        guard !isSymbolicLink(at: cacheRoot.path),
              let siblings = try? fileManager.contentsOfDirectory(
                  at: cacheRoot,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return 0
        }
        let excludedStandardized = currentSessionDir?.standardizedFileURL
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var removedCount = 0
        for siblingURL in siblings {
            guard siblingURL.standardizedFileURL != excludedStandardized,
                  !isSymbolicLink(at: siblingURL.path) else {
                continue
            }
            let name = siblingURL.lastPathComponent
            guard name.hasPrefix("session-") else { continue }
            let remainder = name.dropFirst("session-".count)
            guard let hyphenIndex = remainder.firstIndex(of: "-"),
                  let pid = Int32(remainder[..<hyphenIndex]),
                  pid > 0,
                  pid != currentPID else {
                continue
            }
            errno = 0
            if Darwin.kill(pid, 0) != 0 && errno == ESRCH {
                if (try? fileManager.removeItem(at: siblingURL)) != nil {
                    removedCount += 1
                }
            }
        }
        return removedCount
    }

    // MARK: - Per-Consumer Lease Holding & Independent Player Handoff

    func hasActiveConsumerHold(_ safeKey: String) -> Bool {
        if let holders = activeConsumerLeases[safeKey], !holders.isEmpty { return true }
        if let count = anonymousPinCounts[safeKey], count > 0 { return true }
        return false
    }

    func isProtectedFromEviction(_ safeKey: String) -> Bool {
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

    func releaseIfReserved(forKey safeKey: String, reservationID: UUID?) {
        if let reservationID {
            releaseStagingReservationInternal(forKey: safeKey, reservationID: reservationID)
        }
    }

    func verifyReservationForRegistration(safeKey: String, reservationID: UUID?) throws {
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

    private func effectiveFootprintBytes(forKey key: String) -> Int64 {
        let itemBytes = items[key]?.sizeBytes ?? 0
        let reservedBytes = activeStagingReservations[key]?.reservation.reservedBytes ?? 0
        return max(itemBytes, reservedBytes)
    }

    func enforceQuotaBeforeWrite(safeKey: String, incomingBytes: Int64) throws {
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
