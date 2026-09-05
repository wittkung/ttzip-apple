// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import CryptoKit
import AppKit
import TTZipCore

/// Thread-safe sandbox LRU temporary media cache pool for libmpv & CoreAudio playback.
/// Provides concrete POSIX filesystem URLs for archive media entries with zero disk leak.
public final class ArchiveMediaCachePool: @unchecked Sendable {
    
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
        var lastAccessTime: Date
    }
    
    // MARK: - Private State
    
    private let lock = NSLock()
    private let cacheRootDirectory: URL
    private var entries: [String: CacheEntry] = [:]
    private var inflightTasks: [String: Task<URL, Error>] = [:]
    private var terminateObserver: (any NSObjectProtocol)?
    
    // MARK: - Initialization
    
    public init(
        maxQuotaBytes: Int64 = 1024 * 1024 * 1024,
        maxItemCount: Int = 30,
        customRootDirectory: URL? = nil
    ) {
        self.maxQuotaBytes = maxQuotaBytes
        self.maxItemCount = maxItemCount
        
        let root = customRootDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipMediaCache", isDirectory: true)
        self.cacheRootDirectory = root
        
        setupCacheDirectory()
        cleanupOldSessions()
        registerLifecycleObservers()
    }
    
    deinit {
        if let observer = terminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Public API
    
    /// Returns a concrete POSIX file URL for an archive media entry, extracting it into the LRU cache if needed.
    /// Deduplicates simultaneous requests for the same media key.
    public func getOrExtractMedia(
        archivePath: String,
        entryPath: String,
        uncompressedSize: Int64,
        crc32: UInt32 = 0,
        password: String? = nil
    ) async throws -> URL {
        let key = Self.computeCacheKey(
            archivePath: archivePath,
            entryPath: entryPath,
            uncompressedSize: uncompressedSize,
            crc32: crc32
        )
        
        // 1. Fast Path: Check if entry is already cached and valid on disk
        if let existingURL = getCachedURLIfValid(key: key) {
            return existingURL
        }
        
        // 2. Concurrency Deduplication: Join existing inflight extraction task
        if let ongoingTask = getExistingInflightTask(key: key) {
            return try await ongoingTask.value
        }
        
        // 3. Slow Path: Spawn new extraction task
        let task = Task<URL, Error> {
            do {
                let sanitizedName = Self.sanitizeFileName(entryPath)
                let itemDir = self.cacheRootDirectory.appendingPathComponent(key, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: itemDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                
                let targetFileURL = itemDir.appendingPathComponent(sanitizedName)
                
                // Attempt direct selective extraction via TTZipEngineFacade
                var extracted = false
                if let _ = try? await TTZipEngineFacade.shared.extractSingleEntry(
                    archivePath: archivePath,
                    entryPath: entryPath,
                    destinationDir: itemDir.path,
                    password: password
                ) {
                    if let foundURL = Self.locateExtractedFile(in: itemDir, expectedName: sanitizedName) {
                        if foundURL.path != targetFileURL.path {
                            try? FileManager.default.removeItem(at: targetFileURL)
                            try? FileManager.default.moveItem(at: foundURL, to: targetFileURL)
                        }
                        extracted = FileManager.default.fileExists(atPath: targetFileURL.path)
                    }
                }
                
                // Fallback: in-memory selective extractor into target file
                if !extracted {
                    if let data = try await ArchiveSelectiveExtractor.shared.extractSingleEntryData(
                        archivePath: archivePath,
                        entryPath: entryPath,
                        password: password
                    ) {
                        try data.write(to: targetFileURL, options: .atomic)
                        extracted = true
                    }
                }
                
                guard extracted && FileManager.default.fileExists(atPath: targetFileURL.path) else {
                    throw ArchiveError.fileNotFound
                }
                
                // Set restrictive POSIX permissions 0o600
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetFileURL.path)
                
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: targetFileURL.path)[.size] as? Int64) ?? uncompressedSize
                
                let newEntry = CacheEntry(
                    key: key,
                    fileURL: targetFileURL,
                    directoryURL: itemDir,
                    size: fileSize,
                    lastAccessTime: Date()
                )
                self.recordExtractedEntry(key: key, entry: newEntry)
                
                return targetFileURL
            } catch {
                self.clearInflightTask(key: key)
                throw error
            }
        }
        
        registerInflightTask(key: key, task: task)
        return try await task.value
    }
    
    /// Stages in-memory Data into a sandboxed cache file preserving extension, returning a concrete file URL.
    public func stageData(_ data: Data, fileName: String, sourceURL: URL? = nil) throws -> URL {
        let sanitizedName = Self.sanitizeFileName(fileName)
        let rawKeySource = "\(sourceURL?.absoluteString ?? fileName):\(data.count):\(data.prefix(64).base64EncodedString())"
        let key = Self.sha256Hex(rawKeySource)
        
        if let existingURL = getCachedURLIfValid(key: key) {
            return existingURL
        }
        
        let itemDir = cacheRootDirectory
            .appendingPathComponent("staged", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        
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
            lastAccessTime: Date()
        )
        
        lock.withLock {
            entries[key] = entry
            evictIfNeededLocked()
        }
        
        return targetFileURL
    }
    
    /// Purges all cached media files and removes the cache root directory.
    public func purgeAll() {
        lock.withLock {
            inflightTasks.removeAll()
            entries.removeAll()
        }
        try? FileManager.default.removeItem(at: cacheRootDirectory)
        setupCacheDirectory()
    }
    
    /// Cleans up orphaned or outdated cache sessions from previous application launches.
    public func cleanupOldSessions() {
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: cacheRootDirectory,
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
    
    // MARK: - Inspection Accessors
    
    /// Total number of active cached media items.
    public var cachedItemCount: Int {
        lock.withLock { entries.count }
    }
    
    /// Total cumulative byte size of cached media files.
    public var totalCacheSizeBytes: Int64 {
        lock.withLock { entries.values.reduce(0) { $0 + $1.size } }
    }
    
    /// Root directory of the media cache.
    public var cacheDirectoryURL: URL {
        return cacheRootDirectory
    }
    
    // MARK: - Synchronous Lock Helpers
    
    private func getCachedURLIfValid(key: String) -> URL? {
        lock.withLock {
            if var existing = entries[key] {
                if FileManager.default.fileExists(atPath: existing.fileURL.path) {
                    existing.lastAccessTime = Date()
                    entries[key] = existing
                    return existing.fileURL
                } else {
                    entries.removeValue(forKey: key)
                }
            }
            return nil
        }
    }
    
    private func getExistingInflightTask(key: String) -> Task<URL, Error>? {
        lock.withLock {
            inflightTasks[key]
        }
    }
    
    private func registerInflightTask(key: String, task: Task<URL, Error>) {
        lock.withLock {
            inflightTasks[key] = task
        }
    }
    
    private func recordExtractedEntry(key: String, entry: CacheEntry) {
        lock.withLock {
            entries[key] = entry
            _ = inflightTasks.removeValue(forKey: key)
            evictIfNeededLocked()
        }
    }
    
    private func clearInflightTask(key: String) {
        lock.withLock {
            _ = inflightTasks.removeValue(forKey: key)
        }
    }
    
    // MARK: - Private Helpers
    
    private func setupCacheDirectory() {
        try? FileManager.default.createDirectory(
            at: cacheRootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
    
    private func registerLifecycleObservers() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.purgeAll()
        }
    }
    
    private func evictIfNeededLocked() {
        var currentSize = entries.values.reduce(0) { $0 + $1.size }
        var currentCount = entries.count
        
        guard currentSize > maxQuotaBytes || currentCount > maxItemCount else { return }
        
        let sortedEntries = entries.values.sorted { $0.lastAccessTime < $1.lastAccessTime }
        
        for entry in sortedEntries {
            guard currentSize > maxQuotaBytes || currentCount > maxItemCount else { break }
            
            try? FileManager.default.removeItem(at: entry.directoryURL)
            entries.removeValue(forKey: entry.key)
            currentSize -= entry.size
            currentCount -= 1
        }
    }
    
    public static func computeCacheKey(
        archivePath: String,
        entryPath: String,
        uncompressedSize: Int64,
        crc32: UInt32
    ) -> String {
        let descriptor = "\(archivePath):\(entryPath):\(uncompressedSize):\(crc32)"
        return sha256Hex(descriptor)
    }
    
    public static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    public static func sanitizeFileName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        let base = (last as NSString).deletingPathExtension
        let ext = (last as NSString).pathExtension
        
        let invalidChars = CharacterSet(charactersIn: "/\\?%*|\"<>:;\0")
        let cleanedBase = base.components(separatedBy: invalidChars).joined(separator: "_")
        let safeBase = cleanedBase.isEmpty ? "media_item" : cleanedBase
        
        if ext.isEmpty {
            return safeBase
        } else {
            return "\(safeBase).\(ext)"
        }
    }
    
    private static func locateExtractedFile(in directory: URL, expectedName: String) -> URL? {
        let direct = directory.appendingPathComponent(expectedName)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        
        for case let fileURL as URL in enumerator {
            let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if isFile {
                return fileURL
            }
        }
        return nil
    }
}
