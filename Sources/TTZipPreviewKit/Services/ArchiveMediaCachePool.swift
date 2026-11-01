// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CryptoKit
import AppKit
import TTZipCore

/// Thread-safe sandbox LRU temporary media cache pool for native AVSampleBuffer & CoreAudio playback.
/// Provides concrete POSIX filesystem URLs for archive media entries with zero disk leak.
public actor ArchiveMediaCachePool {
    
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
    
    private let cacheRootDirectory: URL
    private var entries: [String: CacheEntry] = [:]
    private var inflightTasks: [String: Task<URL, Error>] = [:]
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    
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
        if let ongoingTask = inflightTasks[key] {
            return try await ongoingTask.value
        }
        
        // 3. Slow Path: Spawn new extraction task
        let rootDir = self.cacheRootDirectory
        let task = Task<URL, Error> {
            let sanitizedName = Self.sanitizeFileName(entryPath)
            let itemDir = rootDir.appendingPathComponent(key, isDirectory: true)
            try FileManager.default.createDirectory(
                at: itemDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            
            let targetFileURL = itemDir.appendingPathComponent(sanitizedName)
            
            // Attempt direct selective extraction via TTZipEngineFacade
            var extracted = false
            // App-private cache dir: Replace keeps the expected file name instead of a " 2" sibling; never prompts.
            if let _ = try? await TTZipEngineFacade.shared.extractSingleEntry(
                archivePath: archivePath,
                entryPath: entryPath,
                destinationDir: itemDir.path,
                password: password,
                handling: .policy(.replace)
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
            return targetFileURL
        }
        
        inflightTasks[key] = task
        do {
            let targetFileURL = try await task.value
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: targetFileURL.path)[.size] as? Int64) ?? uncompressedSize
            let itemDir = targetFileURL.deletingLastPathComponent()
            let newEntry = CacheEntry(
                key: key,
                fileURL: targetFileURL,
                directoryURL: itemDir,
                size: fileSize,
                lastAccessTime: Date()
            )
            entries[key] = newEntry
            inflightTasks.removeValue(forKey: key)
            evictIfNeeded()
            return targetFileURL
        } catch {
            inflightTasks.removeValue(forKey: key)
            throw error
        }
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
        
        entries[key] = entry
        evictIfNeeded()
        
        return targetFileURL
    }
    
    /// Purges all cached media files and removes the cache root directory.
    public func purgeAll() {
        inflightTasks.removeAll()
        entries.removeAll()
        try? FileManager.default.removeItem(at: cacheRootDirectory)
        setupCacheDirectory()
    }
    
    /// Evicts oldest accessed media cache items until entries count and size match retention ratio.
    public func purgeIdleEntries(retentionRatio: Double = 0.5) {
        guard !entries.isEmpty else { return }
        let clampedRatio = max(0.0, min(1.0, retentionRatio))
        let targetCount = Int(Double(entries.count) * clampedRatio)
        let sortedEntries = entries.values.sorted { $0.lastAccessTime < $1.lastAccessTime }
        let evictCount = entries.count - targetCount
        
        for entry in sortedEntries.prefix(evictCount) {
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
    
    /// Root directory of the media cache.
    public nonisolated var cacheDirectoryURL: URL {
        return cacheRootDirectory
    }
    
    // MARK: - Private State Helpers
    
    private func getCachedURLIfValid(key: String) -> URL? {
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
    
    // MARK: - Private Helpers
    
    private nonisolated static func setupCacheDirectory(at root: URL) {
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
    
    private nonisolated func setupCacheDirectory() {
        Self.setupCacheDirectory(at: cacheRootDirectory)
    }
    
    private func evictIfNeeded() {
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
    
    public nonisolated static func computeCacheKey(
        archivePath: String,
        entryPath: String,
        uncompressedSize: Int64,
        crc32: UInt32
    ) -> String {
        let descriptor = "\(archivePath):\(entryPath):\(uncompressedSize):\(crc32)"
        return sha256Hex(descriptor)
    }
    
    public nonisolated static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    public nonisolated static func sanitizeFileName(_ path: String) -> String {
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
    
    private nonisolated static func isRegularNonSymlinkFile(at path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    private nonisolated static func isSymbolicLink(at path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private nonisolated static func isCandidateWithinDirectory(_ fileURL: URL, directory: URL) -> Bool {
        guard !isSymbolicLink(at: directory.path),
              isRegularNonSymlinkFile(at: fileURL.path) else {
            return false
        }
        let dirStandard = directory.standardizedFileURL.path
        let fileStandard = fileURL.standardizedFileURL.path
        let dirStandardPrefix = dirStandard.hasSuffix("/") ? dirStandard : dirStandard + "/"
        guard fileStandard.hasPrefix(dirStandardPrefix) else { return false }

        let relTail = String(fileStandard.dropFirst(dirStandardPrefix.count))
        var stepURL = URL(fileURLWithPath: dirStandard, isDirectory: true)
        for seg in relTail.split(separator: "/").map(String.init) {
            if seg.isEmpty || seg == "." || seg == ".." { return false }
            stepURL.appendPathComponent(seg)
            if isSymbolicLink(at: stepURL.path) { return false }
        }

        let dirResolved = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let fileResolved = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let dirResolvedPrefix = dirResolved.hasSuffix("/") ? dirResolved : dirResolved + "/"
        return fileResolved.hasPrefix(dirResolvedPrefix)
    }

    private nonisolated static func locateExtractedFile(in directory: URL, expectedName: String) -> URL? {
        let direct = directory.appendingPathComponent(expectedName)
        if isCandidateWithinDirectory(direct, directory: directory) {
            return direct
        }
        
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        
        for case let fileURL as URL in enumerator {
            guard sanitizeFileName(fileURL.lastPathComponent) == expectedName || fileURL.lastPathComponent == expectedName else {
                continue
            }
            if isCandidateWithinDirectory(fileURL, directory: directory) {
                return fileURL
            }
        }
        return nil
    }
}
