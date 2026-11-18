// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import os
import TTZipArchiveContract

/// Thread-safe in-memory Virtual File System (VFS) resource provider for archive contents.
/// Resolves `ttzip-vfs://<archiveId>/<entryPath>` URIs without extracting files to disk.
public final class TTZipArchiveVfsProvider: TTZipVfsResourceProvider, Sendable {
    
    public static let shared = TTZipArchiveVfsProvider()
    
    /// Maximum slice size served in a single partial byte range response (4MB limit to prevent memory bloat).
    public static let maxRangeSliceSize: Int = 4 * 1024 * 1024
    
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

    private struct ArchiveSession: Sendable {
        let generation = UUID()
        let archivePath: String
        let password: String?
        var cachedKeys: Set<String>
        var entrySizes: [String: Int64]
    }
    
    private enum MediaCacheSource: Sendable {
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

    private var readAccess: ReadAccess {
        lock.withLock { $0.hostedReadAccess } ?? .archiveRuntime
    }

    @MainActor
    public func installMediaCacheExtraction(_ extraction: ArchiveMediaCachePool.Extraction) {
        lock.withLock { state in
            guard case .standalone = state.mediaCacheSource else { return }
            state.mediaCacheSource = .hosted(extraction)
        }
    }
    
    private let lock: OSAllocatedUnfairLock<VfsProviderState>
    
    public init() {
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
        let archiveId = Self.makeArchiveId(from: archivePath)
        return lock.withLock { state in
            let session = state.sessions[archiveId] ?? ArchiveSession(
                archivePath: archivePath,
                password: password,
                cachedKeys: [],
                entrySizes: [:]
            )
            state.sessions[archiveId] = session
            state.sessionRefCounts[archiveId, default: 0] += 1
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
        let normalizedPath = Self.normalizePath(entryPath)
        let key = Self.cacheKey(archiveId: archiveId, entryPath: normalizedPath)
        lock.withLock { state in
            state.cache.set(key, data: data)
            state.sessions[archiveId]?.cachedKeys.insert(key)
            state.sessions[archiveId]?.entrySizes[normalizedPath] = Int64(data.count)
        }
    }
    
    /// Synchronously retrieves cached in-memory entry data if present in bounded cache.
    public func cachedData(for uri: String) -> Data? {
        guard let (archiveId, entryPath) = parseVfsUri(uri),
              lock.withLock({ $0.sessions[archiveId] != nil }) else { return nil }
        let key = Self.cacheKey(archiveId: archiveId, entryPath: entryPath)
        return lock.withLock { state in
            state.cache.get(key)
        }
    }
    
    /// Reads entry data from an active archive session by archiveId and relative entry path.
    public func readEntryData(archiveId: String, entryPath: String) async throws -> Data? {
        let vfsURI = makeVfsURL(archiveId: archiveId, entryPath: entryPath).absoluteString
        return try await loadResource(uri: vfsURI)?.data
    }
    
    /// Builds a canonical `ttzip-vfs://` URL for an archive entry without mutating existing session lease counts.
    public func vfsURL(archivePath: String, password: String? = nil, entryPath: String) -> URL {
        let archiveId = Self.makeArchiveId(from: archivePath)
        lock.withLock { state in
            if state.sessions[archiveId] == nil {
                state.sessions[archiveId] = ArchiveSession(
                    archivePath: archivePath,
                    password: password,
                    cachedKeys: [],
                    entrySizes: [:]
                )
                state.sessionRefCounts[archiveId] = 1
            }
        }
        return makeVfsURL(archiveId: archiveId, entryPath: entryPath)
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
        
        let (archivePath, password, isRegistered) = lock.withLock { state -> (String?, String?, Bool) in
            guard let session = state.sessions[archiveId] else { return (nil, nil, false) }
            return (session.archivePath, session.password, true)
        }
        guard isRegistered else { return nil }
        
        // 1. Check bounded in-memory session cache
        if let data = cachedData(for: uri) {
            return (data, mimeType)
        }
        
        guard let validArchivePath = archivePath else { return nil }
        
        if let data = try await readAccess.readEntry(validArchivePath, entryPath, password) {
            cacheEntryData(archiveId: archiveId, entryPath: entryPath, data: data)
            return (data, mimeType)
        }
        
        return nil
    }

    private func extractSmallEntryForRange(
        archiveId: String,
        archivePath: String,
        entryPath: String,
        password: String?,
        byteRange: ClosedRange<Int>?,
        mimeType: String
    ) async throws -> (data: Data, fullSize: Int64, mimeType: String)? {
        guard let fullData = try await readAccess.readEntry(archivePath, entryPath, password) else { return nil }
        cacheEntryData(archiveId: archiveId, entryPath: entryPath, data: fullData)
        return Self.sliceRange(from: fullData, byteRange: byteRange, mimeType: mimeType)
    }
    
    private static func sliceRange(from data: Data, byteRange: ClosedRange<Int>?, mimeType: String) -> (data: Data, fullSize: Int64, mimeType: String) {
        let fullSize = Int64(data.count)
        guard let range = byteRange else {
            return (data, fullSize, mimeType)
        }
        let bounds = boundedReadRange(range, fullSize: fullSize)
        let slice = data.subdata(in: Int(bounds.lowerBound)..<Int(bounds.upperBound))
        return (slice, fullSize, mimeType)
    }

    private static func boundedReadRange(_ range: ClosedRange<Int>?, fullSize: Int64) -> Range<Int64> {
        let start = max(0, min(Int64(range?.lowerBound ?? 0), fullSize))
        guard start < fullSize else { return start..<start }

        let lastByte = min(Int64(range?.upperBound ?? Int.max), fullSize - 1)
        guard lastByte >= start else { return start..<start }
        let length = min(lastByte - start + 1, Int64(maxRangeSliceSize))
        return start..<(start + length)
    }

    private func resolveSessionEntry(archiveId: String, entryPath: String) -> (archivePath: String, password: String?, entrySize: Int64)? {
        let (archivePath, password, knownSize) = lock.withLock { state -> (String?, String?, Int64?) in
            guard let session = state.sessions[archiveId] else { return (nil, nil, nil) }
            return (session.archivePath, session.password, session.entrySizes[entryPath])
        }
        guard let validArchivePath = archivePath else { return nil }
        if let size = knownSize {
            return (validArchivePath, password, size)
        }
        let entries = (try? readAccess.listEntrySizes(validArchivePath, password)) ?? []
        let matchedSize = lock.withLock { state -> Int64 in
            var found: Int64 = 0
            for entry in entries {
                let norm = Self.normalizePath(entry.path)
                state.sessions[archiveId]?.entrySizes[norm] = Int64(entry.size)
                if norm == entryPath || norm.hasSuffix("/" + entryPath) {
                    found = Int64(entry.size)
                }
            }
            return found
        }
        return (validArchivePath, password, matchedSize)
    }

    private func materializeMedia(
        archivePath: String,
        entryPath: String,
        uncompressedSize: Int64,
        password: String?
    ) async throws -> URL {
        switch lock.withLock({ $0.mediaCacheSource }) {
        case .standalone:
            return try await ArchiveMediaCachePool.shared.getOrExtractMedia(
                archivePath: archivePath,
                entryPath: entryPath,
                uncompressedSize: uncompressedSize,
                password: password
            )
        case .hosted(let extraction):
            return try await ArchiveMediaCachePool.shared.getOrExtractMedia(
                archivePath: archivePath,
                entryPath: entryPath,
                uncompressedSize: uncompressedSize,
                password: password,
                extraction: extraction
            )
        }
    }

    private func readMediaCacheSlice(
        archivePath: String,
        entryPath: String,
        entrySize: Int64,
        password: String?,
        byteRange: ClosedRange<Int>?,
        mimeType: String
    ) async throws -> (data: Data, fullSize: Int64, mimeType: String)? {
        guard let mediaURL = try? await materializeMedia(
            archivePath: archivePath,
            entryPath: entryPath,
            uncompressedSize: entrySize,
            password: password
        ), let fileHandle = try? FileHandle(forReadingFrom: mediaURL) else {
            return nil
        }
        defer { try? fileHandle.close() }

        let diskSize = (try? FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size] as? Int64) ?? 0
        let actualFullSize = entrySize > 0 ? entrySize : diskSize
        let bounds = Self.boundedReadRange(byteRange, fullSize: actualFullSize)
        guard !bounds.isEmpty else { return (Data(), actualFullSize, mimeType) }
        try fileHandle.seek(toOffset: UInt64(bounds.lowerBound))
        let sliceData = (try fileHandle.read(upToCount: Int(bounds.count))) ?? Data()
        return (sliceData, actualFullSize, mimeType)
    }

    public func loadResourceRange(uri: String, byteRange: ClosedRange<Int>?) async throws -> (data: Data, fullSize: Int64, mimeType: String)? {
        guard let (archiveId, entryPath) = parseVfsUri(uri) else { return nil }
        let mimeType = Self.mimeType(for: entryPath)

        if let cached = cachedData(for: uri) {
            return Self.sliceRange(from: cached, byteRange: byteRange, mimeType: mimeType)
        }

        guard let resolved = resolveSessionEntry(archiveId: archiveId, entryPath: entryPath) else {
            return nil
        }

        if resolved.entrySize > 0 && resolved.entrySize <= 8 * 1024 * 1024,
           let sliced = try await extractSmallEntryForRange(
               archiveId: archiveId,
               archivePath: resolved.archivePath,
               entryPath: entryPath,
               password: resolved.password,
               byteRange: byteRange,
               mimeType: mimeType
           ) {
            return sliced
        }

        if let mediaSlice = try await readMediaCacheSlice(
            archivePath: resolved.archivePath,
            entryPath: entryPath,
            entrySize: resolved.entrySize,
            password: resolved.password,
            byteRange: byteRange,
            mimeType: mimeType
        ) {
            return mediaSlice
        }

        guard let (fullData, fallbackMime) = try await loadResource(uri: uri) else { return nil }
        return Self.sliceRange(from: fullData, byteRange: byteRange, mimeType: fallbackMime)
    }
    
    // MARK: - URI Parsing & Path Normalization
    
    public func parseVfsUri(_ uri: String) -> (archiveId: String, entryPath: String)? {
        guard let url = URL(string: uri), url.scheme == ArchiveVfs.scheme else {
            return nil
        }
        
        guard let rawHost = url.host, !rawHost.isEmpty else { return nil }
        let host = (rawHost.removingPercentEncoding ?? rawHost).lowercased()
        let rawPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        let normalizedPath = Self.normalizePath(decodedPath)
        return (host, normalizedPath)
    }
    
    public static func makeArchiveId(from archivePath: String) -> String {
        let digest = SHA256.hash(data: Data(archivePath.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        
        let lastComponent = (archivePath as NSString).lastPathComponent
        var asciiScalars = String.UnicodeScalarView()
        for scalar in lastComponent.unicodeScalars where scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
            asciiScalars.append(scalar)
        }
        let rawPrefix = String(asciiScalars).prefix(12)
        let prefix = rawPrefix.isEmpty ? "arc" : String(rawPrefix)
        
        return "\(prefix)_\(hex)".lowercased()
    }
    
    public static func normalizePath(_ path: String) -> String {
        var clean = path.replacingOccurrences(of: "\\", with: "/")
        while clean.hasPrefix("/") { clean.removeFirst() }
        var parts: [String] = []
        for segment in clean.split(separator: "/") {
            if segment == "." || segment.isEmpty { continue }
            if segment == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(segment))
            }
        }
        return parts.joined(separator: "/")
    }
    
    // MARK: - MIME Sniffing
    
    private static let mimeTypeByExtension: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "xhtml": "application/xhtml+xml; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "application/javascript; charset=utf-8",
        "mjs": "application/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "xml": "application/xml; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "pdf": "application/pdf",
        "epub": "application/epub+zip",
        "mp4": "video/mp4",
        "webm": "video/webm",
        "mov": "video/quicktime",
        "mkv": "video/x-matroska",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "m4a": "audio/mp4",
        "aac": "audio/mp4",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "txt": "text/plain; charset=utf-8",
        "md": "text/plain; charset=utf-8"
    ]

    public static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return mimeTypeByExtension[ext] ?? "application/octet-stream"
    }
}
