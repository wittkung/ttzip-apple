// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CryptoKit
import os

/// Persisted playback checkpoint record capturing timeline position, media dimensions, and track preferences.
public struct PlaybackRecord: Codable, Sendable, Equatable {
    public var url: URL
    public var lastPosition: Double
    public var duration: Double
    public var lastPlayedDate: Date
    public var audioTrackId: Int32?
    public var subtitleTrackId: Int32?
    public var volume: Double?
    public var fileSize: Int64
    
    public init(
        url: URL,
        lastPosition: Double,
        duration: Double,
        lastPlayedDate: Date = Date(),
        audioTrackId: Int32? = nil,
        subtitleTrackId: Int32? = nil,
        volume: Double? = nil,
        fileSize: Int64 = 0
    ) {
        self.url = url
        self.lastPosition = lastPosition
        self.duration = duration
        self.lastPlayedDate = lastPlayedDate
        self.audioTrackId = audioTrackId
        self.subtitleTrackId = subtitleTrackId
        self.volume = volume
        self.fileSize = fileSize
    }
}

/// Metadata payload representing a saved playback milestone for resume-from-last-position prompts.
public struct PlaybackResumeInfo: Sendable, Equatable {
    public let url: URL
    public let savedTime: Double
    public let duration: Double
    
    public init(url: URL, savedTime: Double, duration: Double) {
        self.url = url
        self.savedTime = savedTime
        self.duration = duration
    }
    
    public var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(savedTime / duration, 0.0), 1.0)
    }
    
    public var formattedTime: String {
        let totalSeconds = Int(max(0, savedTime))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

/// Thread-safe media playback history coordinator managing resume checkpoints,
/// aligned with IINA's `PlaybackHistory.swift` architecture and persisted to disk.
public final class PlaybackHistoryStore: @unchecked Sendable {
    public static let shared = PlaybackHistoryStore()
    
    public static let maxRecordLimit: Int = 500
    public static let storageFileName = "PlaybackHistory.json"
    
    public static let defaultStorageDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("com.metastudyline.ttmedia", isDirectory: true)
    }()
    
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "PlaybackHistoryStore")
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.metastudyline.ttmedia.history.io", qos: .utility)
    private let userDefaultsKey = "com.metastudyline.ttmedia.playback_history"
    private var inMemoryCache: [String: PlaybackRecord] = [:]
    
    private var storageFileURL: URL {
        Self.defaultStorageDirectory.appendingPathComponent(Self.storageFileName)
    }
    
    private init() {
        loadHistory()
    }
    
    // MARK: - SHA-256 Key Derivation
    
    /// Generates a deterministic SHA-256 key from file canonical path and byte size.
    public func cacheKey(for url: URL) -> String {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        let size = (try? FileManager.default.attributesOfItem(atPath: canonical)[.size] as? Int64) ?? 0
        return cacheKey(path: canonical, size: size)
    }
    
    /// Computes SHA-256 digest of normalized path concatenated with file size.
    public func cacheKey(path: String, size: Int64) -> String {
        let raw = "\(path)#\(size)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Checkpoint Recording
    
    /// Records current playback checkpoint with extended track and volume metadata.
    /// Progress below 5 seconds or above 95% is automatically purged as unstarted or completed.
    public func recordCheckpoint(
        url: URL,
        currentTime: Double,
        duration: Double,
        audioTrackId: Int32? = nil,
        subtitleTrackId: Int32? = nil,
        volume: Double? = nil
    ) {
        guard duration > 10.0 else { return }
        let progress = currentTime / duration
        let k = cacheKey(for: url)
        
        lock.lock()
        if progress < 0.02 || currentTime < 5.0 || progress > 0.95 {
            inMemoryCache.removeValue(forKey: k)
            lock.unlock()
            scheduleDiskPersistence()
            return
        }
        
        let canonical = url.standardizedFileURL
        let record = PlaybackRecord(
            url: canonical,
            lastPosition: currentTime,
            duration: duration,
            lastPlayedDate: Date(),
            audioTrackId: audioTrackId,
            subtitleTrackId: subtitleTrackId,
            volume: volume,
            fileSize: 0
        )
        
        inMemoryCache[k] = record
        if inMemoryCache.count > Self.maxRecordLimit {
            evictOldestRecordsUnderLock()
        }
        lock.unlock()
        
        scheduleDiskPersistence()
    }
    
    /// Queries the full saved record for a file.
    public func queryRecord(for url: URL) -> PlaybackRecord? {
        let k = cacheKey(for: url)
        lock.lock()
        defer { lock.unlock() }
        return inMemoryCache[k]
    }
    
    /// Queries resume milestone for prompt display.
    public func queryResumeInfo(for url: URL) -> PlaybackResumeInfo? {
        guard let record = queryRecord(for: url) else { return nil }
        guard record.duration > 10.0 else { return nil }
        let progress = record.lastPosition / record.duration
        guard progress >= 0.02 && progress <= 0.95 && record.lastPosition >= 5.0 else { return nil }
        return PlaybackResumeInfo(url: url, savedTime: record.lastPosition, duration: record.duration)
    }
    
    /// Clears checkpoint for a specific file.
    public func clearCheckpoint(for url: URL) {
        let k = cacheKey(for: url)
        lock.lock()
        inMemoryCache.removeValue(forKey: k)
        lock.unlock()
        scheduleDiskPersistence()
    }
    
    /// Clears all recorded checkpoints from memory and disk.
    public func clearAllHistory() {
        lock.lock()
        inMemoryCache.removeAll()
        lock.unlock()
        scheduleDiskPersistence()
    }
    
    // MARK: - Eviction & Persistence
    
    private func evictOldestRecordsUnderLock() {
        let excess = inMemoryCache.count - Self.maxRecordLimit
        guard excess > 0 else { return }
        let sorted = inMemoryCache.sorted { $0.value.lastPlayedDate < $1.value.lastPlayedDate }
        for i in 0..<excess {
            inMemoryCache.removeValue(forKey: sorted[i].key)
        }
    }
    
    private func scheduleDiskPersistence() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let snapshot = self.inMemoryCache
            self.lock.unlock()
            
            do {
                let dir = Self.defaultStorageDirectory
                if !FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(snapshot)
                try data.write(to: self.storageFileURL, options: .atomic)
            } catch {
                self.logger.error("Failed to persist playback history: \(error.localizedDescription)")
            }
        }
    }
    
    private func loadHistory() {
        let file = storageFileURL
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([String: PlaybackRecord].self, from: data)
            lock.lock()
            inMemoryCache = loaded
            lock.unlock()
            logger.info("Loaded \(loaded.count) playback history checkpoints from disk")
        } catch {
            logger.warning("Failed to parse playback history from disk: \(error.localizedDescription)")
        }
    }
}
