// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCoreArchive
import TTZipCoreTypes

/// Thread-safe sandbox LRU temporary media cache pool for native AVSampleBuffer & CoreAudio playback.
/// Provides concrete POSIX filesystem URLs for archive media entries with zero disk leak.
public actor ArchiveMediaCachePool {
    public struct LeasedMediaFile: Sendable, Equatable, Hashable {
        public let url: URL
        public let lease: PreviewCacheLease

        public init(url: URL, lease: PreviewCacheLease) {
            self.url = url
            self.lease = lease
        }
    }

    public struct Extraction: Sendable {
        fileprivate let toDisk: @Sendable (String, String, String, String?) async throws -> Void
        fileprivate let toMemory: @Sendable (String, String, String?) async throws -> Data?

        public init(
            toDisk: @escaping @Sendable (_ archivePath: String, _ entryPath: String, _ outputDirectory: String, _ password: String?) async throws -> Void,
            toMemory: @escaping @Sendable (_ archivePath: String, _ entryPath: String, _ password: String?) async throws -> Data?
        ) {
            self.toDisk = toDisk
            self.toMemory = toMemory
        }
    }

    public static let standaloneExtraction = Extraction(
        toDisk: { archivePath, entryPath, outputDirectory, password in
            _ = try await ArchiveRuntime.extractSingleEntry(
                archivePath: archivePath,
                entryPath: entryPath,
                destinationDir: outputDirectory,
                password: password,
                handling: .policy(.replace)
            )
        },
        toMemory: { archivePath, entryPath, password in
            try await ArchiveRuntime.readEntry(
                archivePath: archivePath,
                entryPath: entryPath,
                password: password
            )
        }
    )
    
    // MARK: - Singleton
    
    public static let shared = ArchiveMediaCachePool()
    
    // MARK: - Cache Limits
    
    /// Maximum cache disk budget (1.0 GB).
    public let maxQuotaBytes: Int64
    
    /// Maximum number of cached media items.
    public let maxItemCount: Int
    
    // MARK: - Storage Structure
    
    private struct CacheEntry: Sendable {
        let key: String
        let fileURL: URL
        let directoryURL: URL
        let size: Int64
        var accessSequence: UInt64
    }

    private struct InflightExtraction: Sendable {
        let id: UUID
        let task: Task<URL, Error>
        let directoryURL: URL
        let generation: UInt64
    }

    private struct DeferredDeletion: Sendable {
        let key: String
        let directoryURL: URL
        var holders: Set<UUID>
    }

    private struct AcquisitionRequest: Sendable {
        let key: String
        let archivePath: String
        let entryPath: String
        let uncompressedSize: Int64
        let password: String?
        let extraction: Extraction
    }
    
    // MARK: - Private State
    
    private let cacheRootDirectory: URL
    private let sourceIdentityProvider: @Sendable (String) -> String
    private var entries: [String: CacheEntry] = [:]
    private var inflightTasks: [String: InflightExtraction] = [:]
    private var activeConsumerLeases: [String: Set<UUID>] = [:]
    private var deferredDeletions: [UUID: DeferredDeletion] = [:]
    private var purgeGeneration: UInt64 = 0
    private var nextDirectorySequence: UInt64 = 0
    private var nextAccessSequence: UInt64 = 0
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    
    // MARK: - Initialization
    
    public init(
        maxQuotaBytes: Int64 = 1024 * 1024 * 1024,
        maxItemCount: Int = 30,
        customRootDirectory: URL? = nil
    ) {
        self.init(
            maxQuotaBytes: maxQuotaBytes,
            maxItemCount: maxItemCount,
            customRootDirectory: customRootDirectory,
            sourceIdentityProvider: { Self.sourceFileIdentityToken(at: $0) }
        )
    }

    init(
        maxQuotaBytes: Int64 = 1024 * 1024 * 1024,
        maxItemCount: Int = 30,
        customRootDirectory: URL? = nil,
        sourceIdentityProvider: @escaping @Sendable (String) -> String
    ) {
        self.maxQuotaBytes = maxQuotaBytes
        self.maxItemCount = maxItemCount
        self.sourceIdentityProvider = sourceIdentityProvider
        
        let root = customRootDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipMediaCache", isDirectory: true)
        self.cacheRootDirectory = root
        
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        self.memoryPressureSource = source
        
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = source.data
            Task { [weak self] in
                guard let self else { return }
                if data.contains(.critical) {
                    await self.purgeAll()
                } else if data.contains(.warning) {
                    await self.purgeIdleEntries(retentionRatio: 0.3)
                }
            }
        }
        source.resume()
        
        Self.setupCacheDirectory(at: root)
        Self.cleanupOldSessions(at: root)
    }

    deinit {
        memoryPressureSource?.cancel()
    }
    
    // MARK: - Public API
    
    private static func extractViaDisk(
        _ request: AcquisitionRequest,
        itemDir: URL,
        sanitizedName: String,
        targetFileURL: URL
    ) async -> Bool {
        guard (try? await request.extraction.toDisk(request.archivePath, request.entryPath, itemDir.path, request.password)) != nil,
              let foundURL = locateExtractedFile(in: itemDir, expectedName: sanitizedName) else {
            return false
        }
        if foundURL.path != targetFileURL.path {
            try? FileManager.default.removeItem(at: targetFileURL)
            try? FileManager.default.moveItem(at: foundURL, to: targetFileURL)
        }
        return FileManager.default.fileExists(atPath: targetFileURL.path)
    }

    private static func performMediaExtraction(_ request: AcquisitionRequest, itemDir: URL) async throws -> URL {
        let sanitizedName = sanitizeFileName(request.entryPath)
        try FileManager.default.createDirectory(
            at: itemDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let targetFileURL = itemDir.appendingPathComponent(sanitizedName)
        do {
            var extracted = await extractViaDisk(
                request,
                itemDir: itemDir,
                sanitizedName: sanitizedName,
                targetFileURL: targetFileURL
            )
            if !extracted, let data = try await request.extraction.toMemory(request.archivePath, request.entryPath, request.password) {
                try data.write(to: targetFileURL, options: .atomic)
                extracted = true
            }
            guard extracted && FileManager.default.fileExists(atPath: targetFileURL.path) else {
                throw ArchiveError.fileNotFound
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetFileURL.path)
            return targetFileURL
        } catch {
            try? FileManager.default.removeItem(at: itemDir)
            throw error
        }
    }

    private nonisolated func makeAcquisitionRequest(
        archivePath: String,
        entryPath: String,
        uncompressedSize: Int64,
        crc32: UInt32,
        password: String?,
        extraction: Extraction
    ) throws -> AcquisitionRequest {
        try Task.checkCancellation()
        let key = Self.cacheKey(
            archivePath: archivePath,
            sourceIdentity: sourceIdentityProvider(archivePath),
            entryPath: entryPath,
            uncompressedSize: uncompressedSize,
            crc32: crc32
        )
        return AcquisitionRequest(
            key: key,
            archivePath: archivePath,
            entryPath: entryPath,
            uncompressedSize: uncompressedSize,
            password: password,
            extraction: extraction
        )
    }

    /// Acquires a concrete POSIX file URL paired with a per-consumer lease token.
    /// Computes the source-file identity key off-actor before registering the lease so slow
    /// remote mounts cannot stall `releaseLease` or `purgeAll` on the actor executor.
    public nonisolated func acquireLeasedMedia(
        archivePath: String,
        entryPath: String,
        uncompressedSize: Int64,
        crc32: UInt32 = 0,
        password: String? = nil,
        consumerID: UUID = UUID(),
        extraction: Extraction = ArchiveMediaCachePool.standaloneExtraction
    ) async throws -> LeasedMediaFile {
        let request = try makeAcquisitionRequest(
            archivePath: archivePath,
            entryPath: entryPath,
            uncompressedSize: uncompressedSize,
            crc32: crc32,
            password: password,
            extraction: extraction
        )
        return try await acquireLeasedMedia(request, consumerID: consumerID)
    }

    private func acquireLeasedMedia(
        _ request: AcquisitionRequest,
        consumerID: UUID
    ) async throws -> LeasedMediaFile {
        try Task.checkCancellation()

        let key = request.key
        let lease = PreviewCacheLease(key: key, consumerID: consumerID)
        activeConsumerLeases[key, default: []].insert(consumerID)

        if let existingURL = getCachedURLIfValid(key: key) {
            return LeasedMediaFile(url: existingURL, lease: lease)
        }

        let inflight = startOrJoinExtraction(request)

        let targetFileURL: URL
        do {
            targetFileURL = try await inflight.task.value
        } catch {
            finishExtractionFailure(key: key, inflight: inflight, lease: lease)
            throw error
        }

        finishExtractionSuccess(
            key: key,
            inflight: inflight,
            targetFileURL: targetFileURL,
            uncompressedSize: request.uncompressedSize
        )
        if Task.isCancelled {
            releaseLease(lease)
            throw CancellationError()
        }
        return LeasedMediaFile(url: targetFileURL, lease: lease)
    }

    /// Returns a concrete POSIX file URL for an archive media entry, extracting it into the LRU cache if needed.
    /// Deduplicates simultaneous requests for the same media key.
    public nonisolated func getOrExtractMedia(
        archivePath: String,
        entryPath: String,
        uncompressedSize: Int64,
        crc32: UInt32 = 0,
        password: String? = nil
    ) async throws -> URL {
        try await getOrExtractMedia(
            archivePath: archivePath,
            entryPath: entryPath,
            uncompressedSize: uncompressedSize,
            crc32: crc32,
            password: password,
            extraction: Self.standaloneExtraction
        )
    }

    /// Uses the supplied extraction on a cache miss.
    public nonisolated func getOrExtractMedia(
        archivePath: String,
        entryPath: String,
        uncompressedSize: Int64,
        crc32: UInt32 = 0,
        password: String? = nil,
        extraction: Extraction
    ) async throws -> URL {
        let request = try makeAcquisitionRequest(
            archivePath: archivePath,
            entryPath: entryPath,
            uncompressedSize: uncompressedSize,
            crc32: crc32,
            password: password,
            extraction: extraction
        )
        return try await getOrExtractMedia(request)
    }

    private func getOrExtractMedia(_ request: AcquisitionRequest) async throws -> URL {
        let leased = try await acquireLeasedMedia(request, consumerID: UUID())
        if entries[request.key]?.fileURL == leased.url {
            releaseLeaseInternal(leased.lease, reclaimImmediatelyIfIdle: false, protecting: request.key)
            return leased.url
        }
        releaseLease(leased.lease)
        throw CancellationError()
    }

    /// Releases a consumer lease token and reclaims deferred or over-quota directories once no leases remain.
    public func releaseLease(_ lease: PreviewCacheLease, reclaimImmediatelyIfIdle: Bool = false) {
        releaseLeaseInternal(
            lease,
            reclaimImmediatelyIfIdle: reclaimImmediatelyIfIdle,
            protecting: nil
        )
    }
    
    /// Stages in-memory Data into a sandboxed cache file preserving extension, returning a concrete file URL.
    public func stageData(_ data: Data, fileName: String, sourceURL: URL? = nil) throws -> URL {
        let sanitizedName = Self.sanitizeFileName(fileName)
        let rawKeySource = "\(sourceURL?.absoluteString ?? fileName):\(data.count):\(data.prefix(64).base64EncodedString())"
        let key = Self.sha256Hex(rawKeySource)
        
        if let existingURL = getCachedURLIfValid(key: key) {
            return existingURL
        }
        
        let itemDir = nextItemDirectory(for: key, staged: true)
        
        try FileManager.default.createDirectory(
            at: itemDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        
        let targetFileURL = itemDir.appendingPathComponent(sanitizedName)
        try data.write(to: targetFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetFileURL.path)
        
        let entry = CacheEntry(
            key: key,
            fileURL: targetFileURL,
            directoryURL: itemDir,
            size: Int64(data.count),
            accessSequence: advanceAccessSequence()
        )
        
        entries[key] = entry
        evictIfNeeded(protecting: key)
        
        return targetFileURL
    }
    
    /// Purges all unleased cached media files immediately, hides leased entries from new lookups,
    /// and defers deletion of leased directories until their final consumer releases its lease.
    public func purgeAll() {
        purgeGeneration &+= 1
        retireLeasedEntriesForPurge()

        let protectedPaths = Set(
            deferredDeletions.values.flatMap { Self.pathVariants(for: $0.directoryURL) }
        )

        for entry in entries.values {
            let candidates = Self.pathVariants(for: entry.directoryURL)
            if !candidates.contains(where: { protectedPaths.contains($0) }) {
                try? FileManager.default.removeItem(at: entry.directoryURL)
            }
        }

        entries.removeAll()
        inflightTasks.removeAll()

        if protectedPaths.isEmpty {
            try? FileManager.default.removeItem(at: cacheRootDirectory)
        } else {
            Self.pruneUnprotectedItems(in: cacheRootDirectory, protectedPaths: protectedPaths)
        }
        setupCacheDirectory()
    }
    
    /// Evicts oldest accessed unleased media cache items until unleased count matches retention ratio.
    public func purgeIdleEntries(retentionRatio: Double = 0.5) {
        let unleasedEntries = entries.values
            .filter { !isLeased($0.key) }
            .sorted { $0.accessSequence < $1.accessSequence }
        guard !unleasedEntries.isEmpty else { return }

        let clampedRatio = max(0.0, min(1.0, retentionRatio))
        let targetCount = Int(Double(unleasedEntries.count) * clampedRatio)
        let evictCount = unleasedEntries.count - targetCount

        for entry in unleasedEntries.prefix(evictCount) {
            try? FileManager.default.removeItem(at: entry.directoryURL)
            entries.removeValue(forKey: entry.key)
        }
    }
    
    /// Cleans up orphaned or outdated cache sessions from previous application launches.
    public nonisolated static func cleanupOldSessions(at root: URL) {
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        
        let expirationCutoff = Date().addingTimeInterval(-86400) // 24 hours
        for dir in subdirs {
            let modDate = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modDate < expirationCutoff {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }
    
    public nonisolated func cleanupOldSessions() {
        Self.cleanupOldSessions(at: cacheRootDirectory)
    }
    
    // MARK: - Inspection Accessors
    
    /// Total number of active cached media items.
    public var cachedItemCount: Int {
        entries.count
    }
    
    /// Total cumulative byte size of cached media files.
    public var totalCacheSizeBytes: Int64 {
        entries.values.reduce(0) { $0 + $1.size }
    }

    /// Number of purged directories retained on disk solely for active consumer leases.
    public var pendingDeferredDeletionCount: Int {
        deferredDeletions.count
    }

    /// Total number of active consumer leases currently protecting `key` across live and deferred entries.
    public func activeLeaseCount(forKey key: String) -> Int {
        let liveCount = activeConsumerLeases[key]?.count ?? 0
        let deferredCount = deferredDeletions.values.reduce(0) { partial, deferred in
            deferred.key == key ? partial + deferred.holders.count : partial
        }
        return liveCount + deferredCount
    }
    
    /// Root directory of the media cache.
    public nonisolated var cacheDirectoryURL: URL {
        return cacheRootDirectory
    }
    
    // MARK: - Private State Helpers

    private func advanceAccessSequence() -> UInt64 {
        nextAccessSequence &+= 1
        return nextAccessSequence
    }

    private func isLeased(_ key: String) -> Bool {
        !(activeConsumerLeases[key]?.isEmpty ?? true)
    }

    private func nextItemDirectory(for key: String, staged: Bool = false) -> URL {
        nextDirectorySequence &+= 1
        let folderName = "\(key)_\(nextDirectorySequence)"
        if staged {
            return cacheRootDirectory
                .appendingPathComponent("staged", isDirectory: true)
                .appendingPathComponent(folderName, isDirectory: true)
        }
        return cacheRootDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    private func startOrJoinExtraction(_ request: AcquisitionRequest) -> InflightExtraction {
        if let ongoing = inflightTasks[request.key] {
            return ongoing
        }

        let itemDir = nextItemDirectory(for: request.key)
        let generation = purgeGeneration
        let task = Task<URL, Error> {
            try await Self.performMediaExtraction(request, itemDir: itemDir)
        }
        let inflight = InflightExtraction(
            id: UUID(),
            task: task,
            directoryURL: itemDir,
            generation: generation
        )
        inflightTasks[request.key] = inflight
        return inflight
    }

    private func finishExtractionSuccess(
        key: String,
        inflight: InflightExtraction,
        targetFileURL: URL,
        uncompressedSize: Int64
    ) {
        if inflightTasks[key]?.id == inflight.id {
            inflightTasks.removeValue(forKey: key)
        }

        guard inflight.generation == purgeGeneration else {
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: targetFileURL.path)[.size] as? Int64) ?? uncompressedSize
        entries[key] = CacheEntry(
            key: key,
            fileURL: targetFileURL,
            directoryURL: inflight.directoryURL,
            size: fileSize,
            accessSequence: advanceAccessSequence()
        )
        evictIfNeeded(protecting: key)
    }

    private func finishExtractionFailure(
        key: String,
        inflight: InflightExtraction,
        lease: PreviewCacheLease
    ) {
        if inflightTasks[key]?.id == inflight.id {
            inflightTasks.removeValue(forKey: key)
        }
        releaseLease(lease)
    }

    private func retireLeasedEntriesForPurge() {
        for (key, holders) in activeConsumerLeases where !holders.isEmpty {
            let directoryURL = entries[key]?.directoryURL ?? inflightTasks[key]?.directoryURL
            guard let directoryURL else { continue }
            deferredDeletions[UUID()] = DeferredDeletion(
                key: key,
                directoryURL: directoryURL,
                holders: holders
            )
        }
        activeConsumerLeases.removeAll()
    }

    private func releaseDeferredLease(_ lease: PreviewCacheLease) -> Bool {
        guard let deferredID = deferredDeletions.first(where: {
            $0.value.key == lease.key && $0.value.holders.contains(lease.consumerID)
        })?.key else {
            return false
        }

        deferredDeletions[deferredID]?.holders.remove(lease.consumerID)
        if deferredDeletions[deferredID]?.holders.isEmpty == true,
           let retired = deferredDeletions.removeValue(forKey: deferredID) {
            try? FileManager.default.removeItem(at: retired.directoryURL)
        }
        return true
    }

    private func releaseLeaseInternal(
        _ lease: PreviewCacheLease,
        reclaimImmediatelyIfIdle: Bool,
        protecting protectedKey: String?
    ) {
        if releaseDeferredLease(lease) {
            return
        }

        guard var holders = activeConsumerLeases[lease.key],
              holders.remove(lease.consumerID) != nil else {
            return
        }

        if !holders.isEmpty {
            activeConsumerLeases[lease.key] = holders
            return
        }

        activeConsumerLeases.removeValue(forKey: lease.key)
        if reclaimImmediatelyIfIdle,
           inflightTasks[lease.key] == nil,
           let entry = entries.removeValue(forKey: lease.key) {
            try? FileManager.default.removeItem(at: entry.directoryURL)
        } else {
            evictIfNeeded(protecting: protectedKey)
        }
    }
    
    private func getCachedURLIfValid(key: String) -> URL? {
        if var existing = entries[key] {
            if FileManager.default.fileExists(atPath: existing.fileURL.path) {
                existing.accessSequence = advanceAccessSequence()
                entries[key] = existing
                return existing.fileURL
            } else {
                entries.removeValue(forKey: key)
            }
        }
        return nil
    }
    
    // MARK: - Private Helpers

    private nonisolated func setupCacheDirectory() {
        Self.setupCacheDirectory(at: cacheRootDirectory)
    }

    private func evictIfNeeded(protecting protectedKey: String? = nil) {
        var currentSize = entries.values.reduce(0) { $0 + $1.size }
        var currentCount = entries.count
        
        guard currentSize > maxQuotaBytes || currentCount > maxItemCount else { return }
        
        let sortedEntries = entries.values.sorted { $0.accessSequence < $1.accessSequence }
        
        for entry in sortedEntries {
            guard currentSize > maxQuotaBytes || currentCount > maxItemCount else { break }
            if entry.key == protectedKey || isLeased(entry.key) {
                continue
            }
            
            try? FileManager.default.removeItem(at: entry.directoryURL)
            entries.removeValue(forKey: entry.key)
            currentSize -= entry.size
            currentCount -= 1
        }
    }
}
