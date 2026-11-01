// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

import TTZipCore

/// Typealias maintaining source compatibility for cross-process FinderSync actions.
public typealias FinderSyncSpoolPayload = TTZipSpoolJob

/// Spooler managing App Group and disk-backed job token serialization for FinderSync.
public final class AppGroupSpooler: Sendable {
    public static let shared = AppGroupSpooler()
    public static let appGroupId = "group.com.metastudyline.ttzip"
    
    public init() {}
    
    private var containerURL: URL? {
        if let testTmp = ProcessInfo.processInfo.environment["TEST_TMPDIR"], !testTmp.isEmpty {
            return URL(fileURLWithPath: testTmp, isDirectory: true).appendingPathComponent("AppGroupSpool", isDirectory: true)
        }
        if ProcessInfo.processInfo.processName.contains("xctest") || NSClassFromString("XCTestCase") != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("AppGroupSpool", isDirectory: true)
        }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId)
    }
    
    public var spoolDirectoryURL: URL? {
        guard let container = containerURL else { return nil }
        let dir = container.appendingPathComponent("spool", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dir.path) {
                return dir
            }
        } catch {
            return nil
        }
        return nil
    }
    
    /// Serializes a batch file selection into an App Group token job file.
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
            throw NSError(
                domain: "TTZipAppGroup",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container is unprovisioned or inaccessible"]
            )
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
        
        let payload = TTZipSpoolJob(
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
