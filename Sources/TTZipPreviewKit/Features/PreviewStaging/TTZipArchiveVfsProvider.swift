// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os
import TTZipArchiveContract

/// Thread-safe in-memory Virtual File System (VFS) resource provider for archive contents.
/// Resolves `ttzip-vfs://<archiveId>/<entryPath>` URIs without extracting files to disk.
public final class TTZipArchiveVfsProvider: TTZipVfsResourceProvider, Sendable {
    
    public static let shared = TTZipArchiveVfsProvider()
    
    /// Maximum slice size served in a single partial byte range response (4MB limit to prevent memory bloat).
    public static let maxRangeSliceSize: Int = 4 * 1024 * 1024

    /// Maximum entry size buffered directly in memory before routing range reads through the media cache pool.
    public static let maxInMemoryEntryBytes: Int64 = 8 * 1024 * 1024
    
    /// Bounded in-memory cache configuration.
    public static let memoryCacheCostLimit: Int = 64 * 1024 * 1024
    public static let memoryCacheCountLimit: Int = 128
    
    private struct BoundedMemoryCache: Sendable {
        let maxCost: Int
        let maxCount: Int
        private(set) var currentCost: Int = 0
        private var storage: [String: Data] = [:]
        private var accessOrder: [String] = []
        
        init(maxCost: Int, maxCount: Int) {
            self.maxCost = maxCost
            self.maxCount = maxCount
        }
        
        mutating func get(_ key: String) -> Data? {
            guard let data = storage[key] else { return nil }
            if let idx = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: idx)
                accessOrder.append(key)
            }
            return data
        }
        
        mutating func set(_ key: String, data: Data) {
            if let old = storage[key] {
                currentCost -= old.count
                if let idx = accessOrder.firstIndex(of: key) {
                    accessOrder.remove(at: idx)
                }
            }
            
            while (currentCost + data.count > maxCost || storage.count >= maxCount), !accessOrder.isEmpty {
                let oldestKey = accessOrder.removeFirst()
                if let evicted = storage.removeValue(forKey: oldestKey) {
                    currentCost -= evicted.count
                }
            }
            
            if currentCost + data.count <= maxCost {
                storage[key] = data
                accessOrder.append(key)
                currentCost += data.count
            }
        }
        
        mutating func remove(_ key: String) {
            if let removed = storage.removeValue(forKey: key) {
                currentCost -= removed.count
            }
            if let idx = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: idx)
            }
        }
    }
    
    struct SessionHandle: Equatable, Sendable {
        let archiveId: String
        fileprivate let generation: UUID
    }

    struct SessionVersion: Equatable, Sendable {
        let generation: UUID
        let sourceIdentity: String
        let identityEpoch: UInt64
    }

    fileprivate struct ArchiveSession: Sendable {
        let generation = UUID()
        let archivePath: String
        let password: String?
        var sourceIdentity: String
        var identityEpoch: UInt64 = 0
        var cachedKeys: Set<String>
        var entrySizes: [String: Int64]

        var version: SessionVersion {
            SessionVersion(
                generation: generation,
                sourceIdentity: sourceIdentity,
                identityEpoch: identityEpoch
            )
        }
    }

    struct ResolvedSession: Sendable {
        let archivePath: String
        let password: String?
        let version: SessionVersion
        let cachedData: Data?
        let knownEntrySize: Int64?

        fileprivate init(session: ArchiveSession, cachedData: Data? = nil, knownEntrySize: Int64? = nil) {
            self.archivePath = session.archivePath
            self.password = session.password
            self.version = session.version
            self.cachedData = cachedData
            self.knownEntrySize = knownEntrySize
        }
    }
    
    enum MediaCacheSource: Sendable {
        case standalone
        case hosted(ArchiveMediaCachePool.Extraction)
    }

    private struct VfsProviderState: Sendable {
        var sessions: [String: ArchiveSession] = [:]
        var sessionRefCounts: [String: Int] = [:]
        var cache: BoundedMemoryCache
        var mediaCacheSource: MediaCacheSource = .standalone
        var hostedReadAccess: ReadAccess?
    }

    @MainActor
    package func installReadAccess(_ access: ReadAccess) {
        lock.withLock { state in
            if state.hostedReadAccess == nil {
                state.hostedReadAccess = access
            }
        }
    }

    var readAccess: ReadAccess {
        lock.withLock { $0.hostedReadAccess } ?? .archiveRuntime
    }

    var currentMediaCacheSource: MediaCacheSource {
        lock.withLock { $0.mediaCacheSource }
    }

    @MainActor
    public func installMediaCacheExtraction(_ extraction: ArchiveMediaCachePool.Extraction) {
        lock.withLock { state in
            guard case .standalone = state.mediaCacheSource else { return }
            state.mediaCacheSource = .hosted(extraction)
        }
    }
    
    let mediaCachePool: ArchiveMediaCachePool
    private let sourceIdentityProvider: @Sendable (String) -> String
    private let lock: OSAllocatedUnfairLock<VfsProviderState>

    public convenience init(mediaCachePool: ArchiveMediaCachePool = .shared) {
        self.init(
            mediaCachePool: mediaCachePool,
            sourceIdentityProvider: { ArchiveMediaCachePool.sourceFileIdentityToken(at: $0) }
        )
    }

    init(
        mediaCachePool: ArchiveMediaCachePool = .shared,
        sourceIdentityProvider: @escaping @Sendable (String) -> String
    ) {
        self.mediaCachePool = mediaCachePool
        self.sourceIdentityProvider = sourceIdentityProvider
        self.lock = OSAllocatedUnfairLock(
            initialState: VfsProviderState(
                sessions: [:],
                sessionRefCounts: [:],
                cache: BoundedMemoryCache(
                    maxCost: TTZipArchiveVfsProvider.memoryCacheCostLimit,
                    maxCount: TTZipArchiveVfsProvider.memoryCacheCountLimit
                )
            )
        )
    }

    private static func cacheKey(archiveId: String, entryPath: String) -> String {
        "\(archiveId)/\(entryPath)"
    }

    /// Advances `session.sourceIdentity` only if the active session still matches `expectedVersion`,
    /// preventing delayed writers or stale stat reads from rolling a newer identity backward.
    private static func advanceSessionIdentityIfMatching(
        archiveId: String,
        expectedVersion: SessionVersion,
        to currentIdentity: String,
        in state: inout VfsProviderState
    ) -> ArchiveSession? {
        guard var session = state.sessions[archiveId] else { return nil }
        guard session.version == expectedVersion else { return session }
        if session.sourceIdentity != currentIdentity {
            for key in session.cachedKeys {
                state.cache.remove(key)
            }
            session.cachedKeys.removeAll()
            session.entrySizes.removeAll()
            session.sourceIdentity = currentIdentity
            session.identityEpoch &+= 1
            state.sessions[archiveId] = session
        }
        return session
    }

    func reconciledSession(archiveId: String, entryPath: String? = nil) -> ResolvedSession? {
        var snapshot = lock.withLock { state -> (String, SessionVersion)? in
            state.sessions[archiveId].map { ($0.archivePath, $0.version) }
        }
        let cacheKey = entryPath.map { Self.cacheKey(archiveId: archiveId, entryPath: $0) }
        for attempt in 0..<2 {
            guard let (archivePath, expectedVersion) = snapshot else { return nil }
            let currentIdentity = sourceIdentityProvider(archivePath)
            let outcome = lock.withLock { state -> (ResolvedSession?, (String, SessionVersion)?) in
                guard let session = state.sessions[archiveId] else { return (nil, nil) }
                if session.sourceIdentity == currentIdentity {
                    let cached = cacheKey.flatMap { session.cachedKeys.contains($0) ? state.cache.get($0) : nil }
                    return (
                        ResolvedSession(
                            session: session,
                            cachedData: cached,
                            knownEntrySize: entryPath.flatMap { session.entrySizes[$0] }
                        ),
                        nil
                    )
                }
                if session.version == expectedVersion {
                    let updated = Self.advanceSessionIdentityIfMatching(
                        archiveId: archiveId,
                        expectedVersion: expectedVersion,
                        to: currentIdentity,
                        in: &state
                    )
                    return (updated.map { ResolvedSession(session: $0) }, nil)
                }
                return attempt == 0
                    ? (nil, (session.archivePath, session.version))
                    : (ResolvedSession(session: session), nil)
            }
            if let next = outcome.1 {
                snapshot = next
                continue
            }
            return outcome.0
        }
        return nil
    }
    
    // MARK: - Session Registration & Lease Management
    
    /// Registers or retrieves an archive session ID for VFS streaming and increments its lease reference count.
    @discardableResult
    public func registerSession(archiveURL: URL, password: String? = nil) -> String {
        registerArchive(archivePath: archiveURL.path, password: password)
    }
    
    /// Registers or retrieves an archive session ID for VFS streaming and increments its lease reference count.
    @discardableResult
    public func registerArchive(archivePath: String, password: String? = nil) -> String {
        acquireSession(archivePath: archivePath, password: password).archiveId
    }

    func acquireSession(archivePath: String, password: String? = nil) -> SessionHandle {
        ensureSession(archivePath: archivePath, password: password, retainExisting: true)
    }

    private func ensureSession(
        archivePath: String,
        password: String?,
        retainExisting: Bool
    ) -> SessionHandle {
        let archiveId = Self.makeArchiveId(from: archivePath)
        let priorVersion = lock.withLock { $0.sessions[archiveId]?.version }
        let currentIdentity = sourceIdentityProvider(archivePath)
        return lock.withLock { state in
            let session: ArchiveSession
            if let existing = state.sessions[archiveId] {
                if let priorVersion, existing.version == priorVersion,
                   let updated = Self.advanceSessionIdentityIfMatching(
                       archiveId: archiveId,
                       expectedVersion: priorVersion,
                       to: currentIdentity,
                       in: &state
                   ) {
                    session = updated
                } else {
                    session = existing
                }
                if retainExisting {
                    state.sessionRefCounts[archiveId, default: 0] += 1
                }
            } else {
                let created = ArchiveSession(
                    archivePath: archivePath,
                    password: password,
                    sourceIdentity: currentIdentity,
                    cachedKeys: [],
                    entrySizes: [:]
                )
                state.sessions[archiveId] = created
                state.sessionRefCounts[archiveId] = 1
                session = created
            }
            return SessionHandle(archiveId: archiveId, generation: session.generation)
        }
    }
    
    /// Increments the lease reference count for an existing active archive session.
    @discardableResult
    public func retainSession(archiveId: String) -> Bool {
        retainSession(archiveId: archiveId, generation: nil)
    }

    func retainSession(_ handle: SessionHandle) -> Bool {
        retainSession(archiveId: handle.archiveId, generation: handle.generation)
    }

    private func retainSession(archiveId: String, generation: UUID?) -> Bool {
        lock.withLock { state in
            guard let session = state.sessions[archiveId],
                  generation == nil || session.generation == generation else { return false }
            state.sessionRefCounts[archiveId, default: 0] += 1
            return true
        }
    }
    
    /// Returns the current lease reference count for an archive session.
    public func sessionReferenceCount(archiveId: String) -> Int {
        lock.withLock { state in
            state.sessionRefCounts[archiveId] ?? 0
        }
    }
    
    /// Checks whether an archive session is currently active.
    public func isSessionActive(archiveId: String) -> Bool {
        lock.withLock { state in
            state.sessions[archiveId] != nil
        }
    }

    func isSessionActive(_ handle: SessionHandle) -> Bool {
        lock.withLock { state in
            state.sessions[handle.archiveId]?.generation == handle.generation
        }
    }

    func sessionIdentityEpoch(archiveId: String) -> UInt64? {
        lock.withLock { $0.sessions[archiveId]?.identityEpoch }
    }
    
    /// Decrements the lease reference count for an archive session; closes and purges cache only when count reaches zero.
    @discardableResult
    public func releaseSession(archiveId: String) -> Int {
        releaseSession(archiveId: archiveId, generation: nil) ?? 0
    }

    func releaseSession(_ handle: SessionHandle) -> Int? {
        releaseSession(archiveId: handle.archiveId, generation: handle.generation)
    }

    private func releaseSession(archiveId: String, generation: UUID?) -> Int? {
        lock.withLock { state in
            if let generation, let session = state.sessions[archiveId], session.generation != generation {
                return nil
            }
            let current = state.sessionRefCounts[archiveId] ?? 0
            let next = current - 1
            if next <= 0 {
                state.sessionRefCounts.removeValue(forKey: archiveId)
                if let session = state.sessions.removeValue(forKey: archiveId) {
                    for key in session.cachedKeys {
                        state.cache.remove(key)
                    }
                }
                return 0
            } else {
                state.sessionRefCounts[archiveId] = next
                return next
            }
        }
    }
    
    /// Forcefully closes an archive session regardless of lease reference count and purges associated cache entries.
    public func closeSession(archiveId: String) {
        lock.withLock { state in
            state.sessionRefCounts.removeValue(forKey: archiveId)
            guard let session = state.sessions.removeValue(forKey: archiveId) else { return }
            for key in session.cachedKeys {
                state.cache.remove(key)
            }
        }
    }
    
    /// Pre-populates in-memory entry data for an archive with bounded LRU storage.
    public func cacheEntryData(archiveId: String, entryPath: String, data: Data) {
        guard let snapshot = lock.withLock({ state -> (String, SessionVersion)? in
            state.sessions[archiveId].map { ($0.archivePath, $0.version) }
        }) else {
            return
        }
        cacheEntryDataIfSourceUnchanged(
            archiveId: archiveId,
            archivePath: snapshot.0,
            entryPath: entryPath,
            data: data,
            expectedVersion: snapshot.1
        )
    }

    func cacheEntryDataIfSourceUnchanged(
        archiveId: String,
        archivePath: String,
        entryPath: String,
        data: Data,
        expectedVersion: SessionVersion
    ) {
        let postIdentity = sourceIdentityProvider(archivePath)
        let normalizedPath = Self.normalizePath(entryPath)
        let key = Self.cacheKey(archiveId: archiveId, entryPath: normalizedPath)
        lock.withLock { state in
            if postIdentity != expectedVersion.sourceIdentity {
                _ = Self.advanceSessionIdentityIfMatching(
                    archiveId: archiveId,
                    expectedVersion: expectedVersion,
                    to: postIdentity,
                    in: &state
                )
                return
            }
            guard var session = state.sessions[archiveId],
                  session.version == expectedVersion else {
                return
            }
            state.cache.set(key, data: data)
            session.cachedKeys.insert(key)
            session.entrySizes[normalizedPath] = Int64(data.count)
            state.sessions[archiveId] = session
        }
    }

    func persistResolvedEntrySizesIfMatching(
        archiveId: String,
        archivePath: String,
        expectedVersion: SessionVersion,
        normalizedEntries: [(String, Int64)]
    ) {
        let postIdentity = sourceIdentityProvider(archivePath)
        lock.withLock { state in
            if postIdentity != expectedVersion.sourceIdentity {
                _ = Self.advanceSessionIdentityIfMatching(
                    archiveId: archiveId,
                    expectedVersion: expectedVersion,
                    to: postIdentity,
                    in: &state
                )
                return
            }
            guard var activeSession = state.sessions[archiveId],
                  activeSession.version == expectedVersion else {
                return
            }
            for (norm, size) in normalizedEntries {
                activeSession.entrySizes[norm] = size
            }
            state.sessions[archiveId] = activeSession
        }
    }
    
    /// Synchronously retrieves cached in-memory entry data if present in bounded cache.
    public func cachedData(for uri: String) -> Data? {
        guard let (archiveId, entryPath) = parseVfsUri(uri) else { return nil }
        return reconciledSession(archiveId: archiveId, entryPath: entryPath)?.cachedData
    }
    
    /// Reads entry data from an active archive session by archiveId and relative entry path.
    public func readEntryData(archiveId: String, entryPath: String) async throws -> Data? {
        let vfsURI = makeVfsURL(archiveId: archiveId, entryPath: entryPath).absoluteString
        return try await loadResource(uri: vfsURI)?.data
    }
    
    /// Builds a canonical `ttzip-vfs://` URL for an archive entry without mutating existing session lease counts.
    public func vfsURL(archivePath: String, password: String? = nil, entryPath: String) -> URL {
        let handle = ensureSession(archivePath: archivePath, password: password, retainExisting: false)
        return makeVfsURL(archiveId: handle.archiveId, entryPath: entryPath)
    }
    
    /// Builds a `ttzip-vfs://` URL given an archive ID and entry path.
    public func makeVfsURL(archiveId: String, entryPath: String) -> URL {
        let unescaped = entryPath.removingPercentEncoding ?? entryPath
        let cleanPath = Self.normalizePath(unescaped)
        let encodedPath = cleanPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanPath
        let urlString = "\(ArchiveVfs.scheme)://\(archiveId)/\(encodedPath)"
        return URL(string: urlString) ?? URL(string: "\(ArchiveVfs.scheme)://\(archiveId)")!
    }
    
    /// Releases one lease reference for the archive session, or unregisters when reaching zero.
    public func unregisterArchive(archiveId: String) {
        _ = releaseSession(archiveId: archiveId)
    }
    
    // MARK: - TTZipVfsResourceProvider Conformance
    
    public func loadResource(uri: String) async throws -> (data: Data, mimeType: String)? {
        guard let (archiveId, entryPath) = parseVfsUri(uri) else { return nil }
        let mimeType = Self.mimeType(for: entryPath)

        guard let resolved = reconciledSession(archiveId: archiveId, entryPath: entryPath) else {
            return nil
        }
        if let data = resolved.cachedData {
            return (data, mimeType)
        }

        if let data = try await readAccess.readEntry(resolved.archivePath, entryPath, resolved.password) {
            cacheEntryDataIfSourceUnchanged(
                archiveId: archiveId,
                archivePath: resolved.archivePath,
                entryPath: entryPath,
                data: data,
                expectedVersion: resolved.version
            )
            return (data, mimeType)
        }

        return nil
    }
}
