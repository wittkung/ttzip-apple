// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: macOS Native Archiving & Compression Application.

import Foundation

/// Structured job payload exchanged between Finder extension and TTZipApp via App Group spooling.
public struct TTZipSpoolJob: Codable, Sendable {
    public let jobId: UUID
    public let createdAt: Date
    public let action: String
    public let targetFormat: String?
    public let sourceBookmarks: [Data]
    public let destinationDirectoryBookmark: Data?
    public let compressionLevel: Int?
    public let password: String?
    
    public init(
        jobId: UUID = UUID(),
        createdAt: Date = Date(),
        action: String,
        targetFormat: String? = nil,
        sourceBookmarks: [Data],
        destinationDirectoryBookmark: Data? = nil,
        compressionLevel: Int? = nil,
        password: String? = nil
    ) {
        self.jobId = jobId
        self.createdAt = createdAt
        self.action = action
        self.targetFormat = targetFormat
        self.sourceBookmarks = sourceBookmarks
        self.destinationDirectoryBookmark = destinationDirectoryBookmark
        self.compressionLevel = compressionLevel
        self.password = password
    }
}

/// Manages App Group container directory for atomic cross-process task spooling and bookmark resolution.
public final class AppGroupSpoolManager: Sendable {
    public static let shared = AppGroupSpoolManager()
    public static let appGroupId = "group.com.metastudyline.ttzip"
    
    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId)
    }
    
    private var spoolDirectoryURL: URL? {
        guard let container = containerURL else { return nil }
        let dir = container.appendingPathComponent("spool", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// Writes a spool job atomically into the App Group container.
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
    
    /// Reads and atomically consumes (deletes) a spool job by ID.
    public func consumeJob(id: UUID) -> TTZipSpoolJob? {
        guard let spoolDir = spoolDirectoryURL else { return nil }
        let fileURL = spoolDir.appendingPathComponent("\(id.uuidString).ttzipjob")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let job = try? JSONDecoder().decode(TTZipSpoolJob.self, from: data) else {
            return nil
        }
        try? FileManager.default.removeItem(at: fileURL)
        return job
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
}
