// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

/// Lightweight data transfer payload serialized to disk for cross-process FinderSync actions.
public struct FinderSyncSpoolPayload: Codable, Sendable {
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
        sourcePaths: [String],
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
}

/// Spooler managing App Group and disk-backed job token serialization for FinderSync.
public final class AppGroupSpooler: Sendable {
    public static let shared = AppGroupSpooler()
    public static let appGroupId = "group.com.metastudyline.ttzip"
    
    public init() {}
    
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
        // Fallback to disk-backed temporary directory when running without AppGroup provisioning
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("com.metastudyline.ttzip/spool", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
    
    /// Serializes a batch file selection into an App Group or disk-backed token job file.
    @discardableResult
    public func spoolJob(
        action: String,
        paths: [String],
        urls: [URL]? = nil,
        targetFormat: String? = nil,
        compressionLevel: Int? = nil,
        password: String? = nil
    ) throws -> UUID {
        guard let spoolDir = spoolDirectoryURL else {
            throw NSError(domain: "TTZipAppGroup", code: -1, userInfo: [NSLocalizedDescriptionKey: "Spool directory unavailable"])
        }
        
        let jobId = UUID()
        let resolvedURLs = urls ?? paths.map { URL(fileURLWithPath: $0) }
        
        // Best-effort security scoped bookmark creation
        var bookmarks: [Data] = []
        for url in resolvedURLs {
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks.append(bookmark)
            }
        }
        
        let payload = FinderSyncSpoolPayload(
            jobId: jobId,
            action: action,
            targetFormat: targetFormat,
            sourcePaths: paths,
            sourceBookmarks: bookmarks,
            compressionLevel: compressionLevel,
            password: password
        )
        
        let fileURL = spoolDir.appendingPathComponent("\(jobId.uuidString).ttzipjob")
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fileURL, options: .atomic)
        
        return jobId
    }
}
