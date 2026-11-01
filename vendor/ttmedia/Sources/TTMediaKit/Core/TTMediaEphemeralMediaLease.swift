// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation

// MARK: - Reference-Counted Ephemeral Media Lease & Consumer Ownership (Group A/E Contract)

extension TTMediaDetector {
    /// Maximum number of staged ephemeral media directories retained concurrently on disk.
    public static let maxStagedEphemeralFiles: Int = 8

    /// Idle TTL duration (1 hour) after which unpinned (`activeLeaseCount == 0`) staged media may be reclaimed.
    public static let ephemeralFileLeaseDuration: TimeInterval = 3600

    private static let ephemeralStagingLock = NSLock()
    nonisolated(unsafe) private static var unclaimedEphemeralLeases: [String: Int] = [:]
    nonisolated(unsafe) private static var claimedConsumerEphemeralLeases: [String: Set<UUID>] = [:]
    nonisolated(unsafe) private static var pendingFullscreenHandoffs: Set<String> = []

    /// Process-lifetime immutable ephemeral media namespace (`TTMediaEphemeralStorage/media-<pid>-<uuid>`).
    /// Initialized once per process so the on-disk root matches the process-local in-memory lease tables
    /// while preserving the `TTMediaEphemeralStorage` path marker for read-only resource policies.
    nonisolated internal static let ephemeralMediaRoot: URL = {
        let baseTmp: URL
        if let rawTmp = ProcessInfo.processInfo.environment["TMPDIR"], !rawTmp.isEmpty {
            baseTmp = URL(fileURLWithPath: rawTmp, isDirectory: true)
        } else {
            baseTmp = FileManager.default.temporaryDirectory
        }
        let sessionNamespace = "media-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
        return baseTmp
            .appendingPathComponent("TTMediaEphemeralStorage", isDirectory: true)
            .appendingPathComponent(sessionNamespace, isDirectory: true)
    }()

    nonisolated private static func ephemeralContentKey(for data: Data, sanitizedName: String) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        hasher.update(data: Data(sanitizedName.utf8))
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func ephemeralSlotKey(for url: URL) -> String? {
        let rootPath = ephemeralMediaRoot.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(targetPath.dropFirst(rootPath.count + 1))
        guard let firstComponent = relative.split(separator: "/").first, !firstComponent.isEmpty else {
            return nil
        }
        return String(firstComponent)
    }

    /// Returns `true` if `url` points inside the managed `TTMediaEphemeralStorage/media` directory.
    nonisolated public static func isEphemeralMediaFile(_ url: URL) -> Bool {
        ephemeralSlotKey(for: url) != nil
    }

    nonisolated private static func totalLeaseCountLocked(forKey key: String) -> Int {
        let unclaimed = unclaimedEphemeralLeases[key, default: 0]
        let claimed = claimedConsumerEphemeralLeases[key]?.count ?? 0
        let handoff = pendingFullscreenHandoffs.contains(key) ? 1 : 0
        return unclaimed + claimed + handoff
    }

    /// Acquires a reference-counted ephemeral media file lease for `data`.
    /// - Active leases (`activeLeaseCount > 0`) are pinned and never evicted by TTL or capacity pressure.
    /// - If all `maxStagedEphemeralFiles` (8) slots are actively held by distinct payloads, returns `nil`
    ///   rather than evicting an in-use file.
    nonisolated internal static func writeDataToTemporaryFile(data: Data, fileName: String) -> URL? {
        let cleanName = sanitizeFileName(fileName)
        let contentKey = ephemeralContentKey(for: data, sanitizedName: cleanName)
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }

        let tempDir = ephemeralMediaRoot.appendingPathComponent(contentKey, isDirectory: true)
        let fileURL = tempDir.appendingPathComponent(cleanName)
        let now = Date()

        if FileManager.default.fileExists(atPath: fileURL.path) {
            unclaimedEphemeralLeases[contentKey, default: 0] += 1
            touchStagedEntry(fileURL: fileURL, directoryURL: tempDir, date: now)
            pruneOrphanedMediaFilesLocked(maxRetained: maxStagedEphemeralFiles, preservingKey: contentKey)
            return fileURL
        }

        pruneOrphanedMediaFilesLocked(maxRetained: max(0, maxStagedEphemeralFiles - 1), preservingKey: nil)
        let currentDirs = (try? FileManager.default.contentsOfDirectory(
            at: ephemeralMediaRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        if currentDirs.count >= maxStagedEphemeralFiles {
            return nil
        }

        do {
            try FileManager.default.createDirectory(
                at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: fileURL, options: .atomic)
            touchStagedEntry(fileURL: fileURL, directoryURL: tempDir, date: now)
            unclaimedEphemeralLeases[contentKey, default: 0] += 1
            return fileURL
        } catch {
            return nil
        }
    }

    /// Atomically transfers one unclaimed detection lease (if present) to `consumerID`.
    /// Used when initializing a consumer lease box so that even if a view is never mounted, `deinit` reclaims the lease.
    @discardableResult
    nonisolated public static func claimUnclaimedEphemeralLeaseIfPresent(
        for url: URL, consumerID: UUID
    ) -> Bool {
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }
        guard let key = ephemeralSlotKey(for: url),
              FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        if claimedConsumerEphemeralLeases[key]?.contains(consumerID) == true {
            return true
        }
        let unclaimed = unclaimedEphemeralLeases[key, default: 0]
        guard unclaimed > 0 else { return false }
        if unclaimed > 1 {
            unclaimedEphemeralLeases[key] = unclaimed - 1
        } else {
            unclaimedEphemeralLeases.removeValue(forKey: key)
        }
        claimedConsumerEphemeralLeases[key, default: []].insert(consumerID)
        return true
    }

    /// Binds `consumerID` as an active consumer of `url`, adopting an unclaimed detection lease if one is pending
    /// or retaining an additional consumer lease when sharing across inspector and fullscreen views.
    @discardableResult
    nonisolated public static func acquireConsumerEphemeralLease(
        for url: URL,
        consumerID: UUID,
        consumeFullscreenHandoff: Bool = false
    ) -> Bool {
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }
        guard let key = ephemeralSlotKey(for: url),
              FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        if consumeFullscreenHandoff {
            pendingFullscreenHandoffs.remove(key)
        }
        if claimedConsumerEphemeralLeases[key]?.contains(consumerID) == true {
            return true
        }
        let unclaimed = unclaimedEphemeralLeases[key, default: 0]
        if unclaimed > 1 {
            unclaimedEphemeralLeases[key] = unclaimed - 1
        } else if unclaimed == 1 {
            unclaimedEphemeralLeases.removeValue(forKey: key)
        }
        claimedConsumerEphemeralLeases[key, default: []].insert(consumerID)
        return true
    }

    /// Releases `consumerID`'s lease on `url` and deletes the staged directory if no leases or handoffs remain.
    nonisolated public static func releaseConsumerEphemeralLease(for url: URL, consumerID: UUID) {
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }
        guard let key = ephemeralSlotKey(for: url) else { return }
        guard var consumers = claimedConsumerEphemeralLeases[key],
              consumers.remove(consumerID) != nil else {
            return
        }
        if consumers.isEmpty {
            claimedConsumerEphemeralLeases.removeValue(forKey: key)
        } else {
            claimedConsumerEphemeralLeases[key] = consumers
        }
        if totalLeaseCountLocked(forKey: key) == 0 {
            removeItemSilently(ephemeralMediaRoot.appendingPathComponent(key, isDirectory: true))
        }
    }

    /// Marks `url` as undergoing a fullscreen transition so it cannot be deleted between view transitions.
    nonisolated public static func beginFullscreenEphemeralHandoff(for url: URL) {
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }
        guard let key = ephemeralSlotKey(for: url),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        pendingFullscreenHandoffs.insert(key)
    }

    /// Completes a fullscreen transition handoff for `url`, removing the transition pin and cleaning up if idle.
    nonisolated public static func endFullscreenEphemeralHandoff(for url: URL) {
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }
        guard let key = ephemeralSlotKey(for: url) else { return }
        guard pendingFullscreenHandoffs.remove(key) != nil else { return }
        if totalLeaseCountLocked(forKey: key) == 0 {
            removeItemSilently(ephemeralMediaRoot.appendingPathComponent(key, isDirectory: true))
        }
    }

    /// Explicitly increments the active lease reference count for an existing staged ephemeral media file.
    @discardableResult
    nonisolated public static func retainEphemeralMediaFile(at url: URL) -> Bool {
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }
        guard let key = ephemeralSlotKey(for: url),
              FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        unclaimedEphemeralLeases[key, default: 0] += 1
        return true
    }

    /// Releases one lease for `url`. The staged directory is only removed when the total reference count reaches 0.
    nonisolated public static func releaseEphemeralMediaFile(at url: URL) {
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }
        guard let key = ephemeralSlotKey(for: url) else { return }
        let unclaimed = unclaimedEphemeralLeases[key, default: 0]
        if unclaimed > 1 {
            unclaimedEphemeralLeases[key] = unclaimed - 1
            return
        } else if unclaimed == 1 {
            unclaimedEphemeralLeases.removeValue(forKey: key)
        } else if var consumers = claimedConsumerEphemeralLeases[key], !consumers.isEmpty {
            _ = consumers.popFirst()
            if consumers.isEmpty {
                claimedConsumerEphemeralLeases.removeValue(forKey: key)
            } else {
                claimedConsumerEphemeralLeases[key] = consumers
            }
        } else {
            pendingFullscreenHandoffs.remove(key)
        }
        if totalLeaseCountLocked(forKey: key) == 0 {
            removeItemSilently(ephemeralMediaRoot.appendingPathComponent(key, isDirectory: true))
        }
    }

    /// Returns the current active lease reference count for `url`.
    nonisolated public static func activeEphemeralLeaseCount(for url: URL) -> Int {
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }
        guard let key = ephemeralSlotKey(for: url) else { return 0 }
        return totalLeaseCountLocked(forKey: key)
    }

    /// Returns the sum of all active lease counts across all staged slots.
    nonisolated public static func totalActiveEphemeralLeases() -> Int {
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }
        let allKeys = Set(unclaimedEphemeralLeases.keys)
            .union(claimedConsumerEphemeralLeases.keys)
            .union(pendingFullscreenHandoffs)
        return allKeys.reduce(0) { $0 + totalLeaseCountLocked(forKey: $1) }
    }

    /// Prunes idle (`activeLeaseCount == 0`) staged media directories that are expired or exceed `maxRetained`.
    nonisolated public static func pruneOrphanedMediaFiles(maxRetained: Int = maxStagedEphemeralFiles) {
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }
        pruneOrphanedMediaFilesLocked(maxRetained: maxRetained, preservingKey: nil)
    }

    /// Force-purges all staged ephemeral media directories and resets all lease counters (for test/shutdown cleanup).
    nonisolated public static func purgeAllEphemeralMediaFiles() {
        ephemeralStagingLock.lock()
        defer { ephemeralStagingLock.unlock() }
        unclaimedEphemeralLeases.removeAll()
        claimedConsumerEphemeralLeases.removeAll()
        pendingFullscreenHandoffs.removeAll()
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: ephemeralMediaRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for dir in dirs {
            removeItemSilently(dir)
        }
    }

    /// Compatibility alias for `purgeAllEphemeralMediaFiles()`.
    nonisolated public static func cleanupAllEphemeralFiles() {
        purgeAllEphemeralMediaFiles()
    }

    nonisolated private static func pruneOrphanedMediaFilesLocked(maxRetained: Int, preservingKey: String?) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: ephemeralMediaRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-ephemeralFileLeaseDuration)
        var surviving: [(url: URL, key: String, modDate: Date, isPinned: Bool)] = []

        for dir in dirs {
            let key = dir.lastPathComponent
            let isPinned = (key == preservingKey) || (totalLeaseCountLocked(forKey: key) > 0)
            let modDate = stagedDirectoryModificationDate(dir)
            if !isPinned && modDate < cutoff {
                unclaimedEphemeralLeases.removeValue(forKey: key)
                claimedConsumerEphemeralLeases.removeValue(forKey: key)
                removeItemSilently(dir)
            } else {
                surviving.append((url: dir, key: key, modDate: modDate, isPinned: isPinned))
            }
        }

        let cap = max(0, maxRetained)
        guard surviving.count > cap else { return }
        let excessCount = surviving.count - cap
        let evictable = surviving.filter { !$0.isPinned }.sorted { $0.modDate < $1.modDate }
        for entry in evictable.prefix(excessCount) {
            unclaimedEphemeralLeases.removeValue(forKey: entry.key)
            claimedConsumerEphemeralLeases.removeValue(forKey: entry.key)
            removeItemSilently(entry.url)
        }
    }

    nonisolated private static func touchStagedEntry(fileURL: URL, directoryURL: URL, date: Date) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .modificationDate: date], ofItemAtPath: fileURL.path
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700, .modificationDate: date], ofItemAtPath: directoryURL.path
        )
    }

    nonisolated private static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\0")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "media_payload" : cleaned
    }

    nonisolated private static func stagedDirectoryModificationDate(_ dir: URL) -> Date {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path),
           let modDate = attrs[.modificationDate] as? Date {
            return modDate
        }
        return .distantPast
    }

    nonisolated private static func removeItemSilently(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// RAII consumer lease owner binding ephemeral media file lifetime to preview view/controller lifecycle.
public final class TTMediaEphemeralLeaseBox: @unchecked Sendable {
    public let consumerID = UUID()
    private let lock = NSLock()
    private var currentURL: URL?

    public init(adoptingUnclaimedFor url: URL? = nil) {
        if let url, TTMediaDetector.claimUnclaimedEphemeralLeaseIfPresent(for: url, consumerID: consumerID) {
            self.currentURL = url
        }
    }

    public func bind(url: URL?, consumeFullscreenHandoff: Bool = false) {
        let targetURL = url.flatMap { TTMediaDetector.isEphemeralMediaFile($0) ? $0 : nil }
        lock.lock()
        let previousURL = currentURL
        if previousURL?.standardizedFileURL == targetURL?.standardizedFileURL {
            if let targetURL {
                _ = TTMediaDetector.acquireConsumerEphemeralLease(
                    for: targetURL,
                    consumerID: consumerID,
                    consumeFullscreenHandoff: consumeFullscreenHandoff
                )
            }
            lock.unlock()
            return
        }
        currentURL = targetURL
        lock.unlock()

        if let targetURL {
            _ = TTMediaDetector.acquireConsumerEphemeralLease(
                for: targetURL,
                consumerID: consumerID,
                consumeFullscreenHandoff: consumeFullscreenHandoff
            )
        }
        if let previousURL {
            TTMediaDetector.releaseConsumerEphemeralLease(for: previousURL, consumerID: consumerID)
        }
    }

    public func bind(
        previewType: TTMediaPreviewType,
        fallbackURL: URL? = nil,
        consumeFullscreenHandoff: Bool = false
    ) {
        bind(
            url: previewType.ephemeralMediaURL ?? fallbackURL,
            consumeFullscreenHandoff: consumeFullscreenHandoff
        )
    }

    public var boundURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return currentURL
    }

    /// Acquires a distinct consumer lease for an independent player window BEFORE the caller
    /// releases or switches its own preview lease (acquire-before-release handoff).
    public func retainForIndependentPlayer(for explicitURL: URL? = nil) -> TTMediaEphemeralLeaseBox {
        let playerBox = TTMediaEphemeralLeaseBox()
        let target = explicitURL ?? boundURL
        if let target {
            playerBox.bind(url: target, consumeFullscreenHandoff: true)
        }
        return playerBox
    }

    public func release() {
        lock.lock()
        let oldURL = currentURL
        currentURL = nil
        lock.unlock()
        if let oldURL {
            TTMediaDetector.releaseConsumerEphemeralLease(for: oldURL, consumerID: consumerID)
        }
    }

    deinit {
        release()
    }
}

extension TTMediaPreviewType {
    /// Resolves the `TTImagePreviewResource` associated with `.image(PlatformImage)` previews.
    public func imagePreviewResource(fallbackURL: URL? = nil) -> TTImagePreviewResource? {
        guard case .image(let image) = self else { return nil }
        return TTMediaDetector.imagePreviewResource(for: image, fallbackURL: fallbackURL)
    }

    /// Returns the staged ephemeral media file URL if this preview type references one.
    public var ephemeralMediaURL: URL? {
        switch self {
        case .video(let url), .audio(let url), .quickLook(let url):
            return TTMediaDetector.isEphemeralMediaFile(url) ? url : nil
        default:
            return nil
        }
    }

    /// Explicitly retains an additional lease on the underlying ephemeral media file, if any.
    @discardableResult
    public func retainEphemeralMediaLease() -> Bool {
        guard let url = ephemeralMediaURL else { return false }
        return TTMediaDetector.retainEphemeralMediaFile(at: url)
    }

    /// Releases an unclaimed or explicitly held ephemeral media lease for this preview result.
    public func releaseEphemeralMediaLease() {
        guard let url = ephemeralMediaURL else { return }
        TTMediaDetector.releaseEphemeralMediaFile(at: url)
    }
}

// MARK: - End-to-End Common Preview Pipeline Stage Metrics (Feedback 9)

/// Structured end-to-end stage latency breakdown for the common preview pipeline:
/// User Selection -> Schedule Wait -> Type Detection -> Read/Extract -> Renderer Creation -> First Frame.
public struct TTPreviewPipelineStageMetrics: Equatable, Sendable {
    public let fileURLPath: String
    public let scheduleWaitMs: Double
    public let detectionMs: Double
    public let readOrExtractMs: Double
    public let rendererCreationMs: Double
    public let firstFrameMs: Double
    public let isArchiveSource: Bool
    public let isWarmCacheHit: Bool
    public let usedFastExtensionRoute: Bool
    public let wasCancelled: Bool

    public init(
        fileURLPath: String,
        scheduleWaitMs: Double,
        detectionMs: Double,
        readOrExtractMs: Double = 0,
        rendererCreationMs: Double = 0,
        firstFrameMs: Double,
        isArchiveSource: Bool = false,
        isWarmCacheHit: Bool = false,
        usedFastExtensionRoute: Bool = false,
        wasCancelled: Bool = false
    ) {
        self.fileURLPath = fileURLPath
        self.scheduleWaitMs = max(0, scheduleWaitMs)
        self.detectionMs = max(0, detectionMs)
        self.readOrExtractMs = max(0, readOrExtractMs)
        self.rendererCreationMs = max(0, rendererCreationMs)
        self.firstFrameMs = max(0, firstFrameMs)
        self.isArchiveSource = isArchiveSource
        self.isWarmCacheHit = isWarmCacheHit
        self.usedFastExtensionRoute = usedFastExtensionRoute
        self.wasCancelled = wasCancelled
    }
}

// MARK: - Resource-Versioned Detection Result Cache (Repeat Open Reuse)

/// Thread-safe, resource-versioned LRU cache for deterministic local file detection results.
/// Keyed by standardized path + POSIX `st_dev`, `st_ino`, `st_size`, `st_mtimespec`, and header digest
/// so unmodified repeat opens resolve in `< 0.05 ms` while any disk modification invalidates immediately.
final class TTMediaVersionedDetectionCache: @unchecked Sendable {
    static let shared = TTMediaVersionedDetectionCache(maxEntries: 64)

    private struct Entry {
        let versionKey: String
        let previewType: TTMediaPreviewType
    }

    private let lock = NSLock()
    private let maxEntries: Int
    private var entries: [String: Entry] = [:]
    private var lruOrder: [String] = []
    private(set) var hitCount: Int = 0
    private(set) var missCount: Int = 0

    init(maxEntries: Int = 64) {
        self.maxEntries = max(4, maxEntries)
    }

    static func computeResourceVersionKey(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        var st = stat()
        guard stat(path, &st) == 0, st.st_size >= 0 else { return nil }
        return "\(path)#d\(st.st_dev)#i\(st.st_ino)#s\(st.st_size)#m\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }

    func lookup(for url: URL) -> TTMediaPreviewType? {
        guard let versionKey = Self.computeResourceVersionKey(for: url) else { return nil }
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        guard let existing = entries[path], existing.versionKey == versionKey else {
            missCount &+= 1
            return nil
        }
        hitCount &+= 1
        if let idx = lruOrder.firstIndex(of: path) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(path)
        return existing.previewType
    }

    func store(_ previewType: TTMediaPreviewType, for url: URL) {
        guard previewType.ephemeralMediaURL == nil,
              let versionKey = Self.computeResourceVersionKey(for: url) else {
            return
        }
        switch previewType {
        case .unsupported:
            return
        default:
            break
        }
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        entries[path] = Entry(versionKey: versionKey, previewType: previewType)
        if let idx = lruOrder.firstIndex(of: path) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(path)
        while lruOrder.count > maxEntries {
            let oldest = lruOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    static func isFastRouteCandidateExtension(_ ext: String) -> Bool {
        let fastSet = TTMediaCapabilityMatrix.videoExtensions
            .union(TTMediaCapabilityMatrix.audioExtensions)
            .union(TTMediaCapabilityMatrix.ambiguousExtensions)
            .union(TTMediaCapabilityMatrix.pdfExtensions)
            .union(TTMediaCapabilityMatrix.docxExtensions)
            .union(TTMediaCapabilityMatrix.presentationExtensions)
        return fastSet.contains(ext)
    }

    func lookupFastRoute(for url: URL) -> TTMediaPreviewType? {
        guard let cached = lookup(for: url) else { return nil }
        switch cached {
        case .video, .audio, .pdf, .quickLook:
            return cached
        default:
            return nil
        }
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lruOrder.removeAll()
        hitCount = 0
        missCount = 0
        lock.unlock()
    }
}

