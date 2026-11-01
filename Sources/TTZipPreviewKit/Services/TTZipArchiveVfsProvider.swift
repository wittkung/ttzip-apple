// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import os
import TTZipCore

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
    
    private struct ArchiveSession: Sendable {
        let archivePath: String
        let password: String?
        var cachedKeys: Set<String>
        var entrySizes: [String: Int64]
    }
    
    private struct VfsProviderState: Sendable {
        var sessions: [String: ArchiveSession] = [:]
        var sessionRefCounts: [String: Int] = [:]
        var cache: BoundedMemoryCache
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
        let archiveId = Self.makeArchiveId(from: archivePath)
        lock.withLock { state in
            if state.sessions[archiveId] == nil {
                state.sessions[archiveId] = ArchiveSession(
                    archivePath: archivePath,
                    password: password,
                    cachedKeys: [],
                    entrySizes: [:]
                )
            }
            state.sessionRefCounts[archiveId, default: 0] += 1
        }
        return archiveId
    }
    
    /// Increments the lease reference count for an existing active archive session.
    @discardableResult
    public func retainSession(archiveId: String) -> Bool {
        lock.withLock { state in
            guard state.sessions[archiveId] != nil else { return false }
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
    
    /// Decrements the lease reference count for an archive session; closes and purges cache only when count reaches zero.
    @discardableResult
    public func releaseSession(archiveId: String) -> Int {
        lock.withLock { state in
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
        let urlString = "\(TTZipVfsSchemeHandler.scheme)://\(archiveId)/\(encodedPath)"
        return URL(string: urlString) ?? URL(string: "\(TTZipVfsSchemeHandler.scheme)://\(archiveId)")!
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
        
        // 2. Extract from archive in-memory via ArchiveSelectiveExtractor
        if let data = try await ArchiveSelectiveExtractor.shared.extractSingleEntryData(
            archivePath: validArchivePath,
            entryPath: entryPath,
            password: password
        ) {
            cacheEntryData(archiveId: archiveId, entryPath: entryPath, data: data)
            return (data, mimeType)
        }
        
        return nil
    }
    
    public func loadResourceRange(uri: String, byteRange: ClosedRange<Int>?) async throws -> (data: Data, fullSize: Int64, mimeType: String)? {
        guard let (archiveId, entryPath) = parseVfsUri(uri) else { return nil }
        let mimeType = Self.mimeType(for: entryPath)
        
        // 1. Fast path: Memory cache hit
        if let cached = cachedData(for: uri) {
            let fullSize = Int64(cached.count)
            guard let range = byteRange else {
                return (cached, fullSize, mimeType)
            }
            let start = max(0, min(range.lowerBound, cached.count))
            let requestedLength = max(0, min(range.count, Self.maxRangeSliceSize))
            let end = min(start + requestedLength, cached.count)
            let slicedData = cached.subdata(in: start..<end)
            return (slicedData, fullSize, mimeType)
        }
        
        // 2. Slow path: Query archive session
        let (archivePath, password, knownSize) = lock.withLock { state -> (String?, String?, Int64?) in
            guard let session = state.sessions[archiveId] else { return (nil, nil, nil) }
            return (session.archivePath, session.password, session.entrySizes[entryPath])
        }
        guard let validArchivePath = archivePath else { return nil }
        
        // Resolve entry uncompressed size if missing
        let entrySize: Int64
        if let size = knownSize {
            entrySize = size
        } else {
            let entries = (try? inspectArchiveEntries(archivePath: validArchivePath, password: password)) ?? []
            let matchedSize = lock.withLock { state -> Int64 in
                var found: Int64 = 0
                for entry in entries {
                    let norm = Self.normalizePath(entry.path)
                    state.sessions[archiveId]?.entrySizes[norm] = Int64(entry.uncompressedSize)
                    if norm == entryPath || norm.hasSuffix("/" + entryPath) {
                        found = Int64(entry.uncompressedSize)
                    }
                }
                return found
            }
            entrySize = matchedSize
        }
        
        // Fast path for small entries (<= 8 MB): extract to memory, cache, and slice
        if entrySize > 0 && entrySize <= 8 * 1024 * 1024 {
            if let fullData = try await ArchiveSelectiveExtractor.shared.extractSingleEntryData(
                archivePath: validArchivePath,
                entryPath: entryPath,
                password: password
            ) {
                cacheEntryData(archiveId: archiveId, entryPath: entryPath, data: fullData)
                let fullSize = Int64(fullData.count)
                guard let range = byteRange else {
                    return (fullData, fullSize, mimeType)
                }
                let start = max(0, min(range.lowerBound, fullData.count))
                let requestedLength = max(0, min(range.count, Self.maxRangeSliceSize))
                let end = min(start + requestedLength, fullData.count)
                return (fullData.subdata(in: start..<end), fullSize, mimeType)
            }
        }
        
        // 3. Streaming/large file path (e.g. video/audio or > 8MB):
        // Stream on-demand via ArchiveMediaCachePool to avoid decompressing gigabytes into single Data
        if let mediaURL = try? await ArchiveMediaCachePool.shared.getOrExtractMedia(
            archivePath: validArchivePath,
            entryPath: entryPath,
            uncompressedSize: entrySize,
            password: password
        ) {
            guard let fileHandle = try? FileHandle(forReadingFrom: mediaURL) else { return nil }
            defer { try? fileHandle.close() }
            
            let actualFullSize = entrySize > 0 ? entrySize : (try? FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size] as? Int64) ?? 0
            let targetRange = byteRange ?? (0...max(0, Int(min(actualFullSize - 1, Int64(Self.maxRangeSliceSize - 1)))))
            let start = max(0, min(Int64(targetRange.lowerBound), actualFullSize))
            let maxEnd = min(start + Int64(Self.maxRangeSliceSize), actualFullSize)
            let requestedEnd = min(Int64(targetRange.upperBound) + 1, actualFullSize)
            let end = min(maxEnd, requestedEnd)
            let sliceLength = max(0, Int(end - start))
            
            try fileHandle.seek(toOffset: UInt64(start))
            let sliceData = (try fileHandle.read(upToCount: sliceLength)) ?? Data()
            return (sliceData, actualFullSize, mimeType)
        }
        
        // 4. Fallback for non-media entries or when media extraction is unavailable
        guard let (fullData, fallbackMime) = try await loadResource(uri: uri) else { return nil }
        let fullSize = Int64(fullData.count)
        guard let range = byteRange else {
            return (fullData, fullSize, fallbackMime)
        }
        let start = max(0, min(range.lowerBound, fullData.count))
        let requestedLength = max(0, min(range.count, Self.maxRangeSliceSize))
        let end = min(start + requestedLength, fullData.count)
        return (fullData.subdata(in: start..<end), fullSize, fallbackMime)
    }
    
    // MARK: - URI Parsing & Path Normalization
    
    public func parseVfsUri(_ uri: String) -> (archiveId: String, entryPath: String)? {
        guard let url = URL(string: uri), url.scheme == TTZipVfsSchemeHandler.scheme else {
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
    
    public static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "xhtml": return "application/xhtml+xml; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "xml": return "application/xml; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "pdf": return "application/pdf"
        case "epub": return "application/epub+zip"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "m4a", "aac": return "audio/mp4"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
