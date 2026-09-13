// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: macOS Native Archiving & Compression Application.

import Foundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Structured job payload exchanged between Finder extension and TTZipApp via App Group spooling.
public struct TTZipSpoolJob: Codable, Sendable {
    public let jobId: UUID
    public let createdAt: Date
    public let action: String
    public let targetFormat: String?
    public let sourcePaths: [String]
    public let sourceBookmarks: [Data]
    public let destinationDirectoryBookmark: Data?
    public let compressionLevel: Int?
    public let password: String?
    
    public init(
        jobId: UUID = UUID(),
        createdAt: Date = Date(),
        action: String,
        targetFormat: String? = nil,
        sourcePaths: [String] = [],
        sourceBookmarks: [Data] = [],
        destinationDirectoryBookmark: Data? = nil,
        compressionLevel: Int? = nil,
        password: String? = nil
    ) {
        self.jobId = jobId
        self.createdAt = createdAt
        self.action = action
        self.targetFormat = targetFormat
        self.sourcePaths = sourcePaths
        self.sourceBookmarks = sourceBookmarks
        self.destinationDirectoryBookmark = destinationDirectoryBookmark
        self.compressionLevel = compressionLevel
        self.password = password
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try container.decode(UUID.self, forKey: .jobId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        action = try container.decode(String.self, forKey: .action)
        targetFormat = try container.decodeIfPresent(String.self, forKey: .targetFormat)
        sourcePaths = try container.decodeIfPresent([String].self, forKey: .sourcePaths) ?? []
        sourceBookmarks = try container.decodeIfPresent([Data].self, forKey: .sourceBookmarks) ?? []
        destinationDirectoryBookmark = try container.decodeIfPresent(Data.self, forKey: .destinationDirectoryBookmark)
        compressionLevel = try container.decodeIfPresent(Int.self, forKey: .compressionLevel)
        password = try container.decodeIfPresent(String.self, forKey: .password)
    }
}

/// Manages App Group container directory for atomic cross-process task spooling and bookmark resolution.
public final class AppGroupSpoolManager: Sendable {
    public static let shared = AppGroupSpoolManager()
    public static let appGroupId = "group.com.metastudyline.ttzip"
    
    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId)
    }
    
    public var spoolDirectoryURL: URL? {
        if let container = containerURL {
            let dir = container.appendingPathComponent("spool", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dir.path) {
                    return dir
                }
            } catch {
                // Group Container is unprovisioned or inaccessible; proceed to disk-backed fallback
            }
        }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("com.metastudyline.ttzip/spool", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
    
    /// Writes a spool job atomically into the App Group container or disk fallback.
    @discardableResult
    public func writeJob(_ job: TTZipSpoolJob) throws -> URL {
        guard let spoolDir = spoolDirectoryURL else {
            throw NSError(domain: "TTZipAppGroup", code: -1, userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable"])
        }
        let fileURL = spoolDir.appendingPathComponent("\(job.jobId.uuidString).ttzipjob")
        let data = try JSONEncoder().encode(job)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
    
    /// Reads and atomically consumes (deletes) a spool job by ID from App Group or disk fallback.
    public func consumeJob(id: UUID) -> TTZipSpoolJob? {
        var candidateDirs: [URL] = []
        if let spoolDir = spoolDirectoryURL {
            candidateDirs.append(spoolDir)
        }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("com.metastudyline.ttzip/spool", isDirectory: true)
        if !candidateDirs.contains(fallback) {
            candidateDirs.append(fallback)
        }
        
        for dir in candidateDirs {
            let fileURL = dir.appendingPathComponent("\(id.uuidString).ttzipjob")
            if FileManager.default.fileExists(atPath: fileURL.path),
               let data = try? Data(contentsOf: fileURL),
               let job = try? JSONDecoder().decode(TTZipSpoolJob.self, from: data) {
                try? FileManager.default.removeItem(at: fileURL)
                return job
            }
        }
        return nil
    }
    
    /// Resolves security-scoped bookmarks into active accessible file URLs.
    public func resolveBookmarks(_ bookmarks: [Data]) -> [URL] {
        var resolved: [URL] = []
        for data in bookmarks {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if url.startAccessingSecurityScopedResource() {
                    resolved.append(url)
                }
            }
        }
        return resolved
    }
    
    /// Stops accessing security-scoped resources previously resolved.
    public func stopAccessing(urls: [URL]) {
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    /// Safely executes a closure with resolved security-scoped URLs and guarantees resource cleanup.
    public func withSecurityScopedURLs<R>(_ bookmarks: [Data], perform: ([URL]) throws -> R) rethrows -> R {
        let urls = resolveBookmarks(bookmarks)
        defer {
            stopAccessing(urls: urls)
        }
        return try perform(urls)
    }
    
    /// Safely executes an async closure with resolved security-scoped URLs and guarantees resource cleanup.
    public func withSecurityScopedURLs<R>(_ bookmarks: [Data], perform: ([URL]) async throws -> R) async rethrows -> R {
        let urls = resolveBookmarks(bookmarks)
        defer {
            stopAccessing(urls: urls)
        }
        return try await perform(urls)
    }
}

/// Typealias providing AppGroupSpooler naming parity across targets.
public typealias AppGroupSpooler = AppGroupSpoolManager

