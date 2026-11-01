// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipUI
import TTZipPreviewKit

import TTZipCore

/// Structured job payload exchanged between Finder extension and TTZipApp via App Group spooling.
public typealias TTZipSpoolJob = TTZipCore.TTZipSpoolJob

/// Manages App Group container directory for atomic cross-process task spooling and bookmark resolution.
public final class AppGroupSpoolManager: Sendable {
    public static let shared = AppGroupSpoolManager()
    public static let appGroupId = "group.com.metastudyline.ttzip"
    
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
    
    /// Writes a spool job atomically into the App Group container.
    @discardableResult
    public func writeJob(_ job: TTZipSpoolJob) throws -> URL {
        guard let spoolDir = spoolDirectoryURL else {
            throw NSError(
                domain: "TTZipAppGroup",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container is unprovisioned or inaccessible"]
            )
        }
        let fileURL = spoolDir.appendingPathComponent("\(job.jobId.uuidString).ttzipjob")
        let data = try JSONEncoder().encode(job)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
    
    /// Reads and atomically consumes (deletes) a spool job by ID from App Group container.
    public func consumeJob(id: UUID) -> TTZipSpoolJob? {
        guard let spoolDir = spoolDirectoryURL else { return nil }
        let fileURL = spoolDir.appendingPathComponent("\(id.uuidString).ttzipjob")
        
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let job = try? JSONDecoder().decode(TTZipSpoolJob.self, from: data) {
            return job
        }
        return nil
    }
    
    /// Resolves security-scoped bookmarks into an RAII-managed scope.
    public func resolveBookmarkScope(_ bookmarks: [Data]) -> SecurityScopedResourceScope {
        return SecurityScopedResourceScope.resolve(bookmarks: bookmarks)
    }
    
    /// Safely executes a closure with resolved security-scoped URLs and guarantees resource cleanup.
    public func withSecurityScopedURLs<T>(bookmarks: [Data], _ block: ([URL]) throws -> T) rethrows -> T {
        let scope = resolveBookmarkScope(bookmarks)
        defer {
            scope.cleanup()
        }
        return try block(scope.urls)
    }
    
    /// Safely executes an async closure with resolved security-scoped URLs and guarantees resource cleanup.
    public func withSecurityScopedURLs<T>(bookmarks: [Data], _ block: ([URL]) async throws -> T) async rethrows -> T {
        let scope = resolveBookmarkScope(bookmarks)
        defer {
            scope.cleanup()
        }
        return try await block(scope.urls)
    }
}

/// RAII guard managing security-scoped resource access lifecycle.
/// Guarantees that every `startAccessingSecurityScopedResource()` call is paired
/// with `stopAccessingSecurityScopedResource()` upon scope deinitialization or explicit cleanup,
/// preventing kernel vnode handle leaks and mobile disk unmount failures.
public final class SecurityScopedResourceScope: @unchecked Sendable {
    private struct ScopedHandle {
        let url: URL
        let isSecurityScoped: Bool
    }

    private let lock = NSLock()
    private var handles: [ScopedHandle]
    private var _isCleanedUp: Bool = false

    /// Indicates whether this scope has already released its security-scoped handles.
    public var isCleanedUp: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCleanedUp
    }

    /// Active resolved security-scoped file URLs managed by this scope.
    public var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return handles.map(\.url)
    }

    public init(urls: [URL] = []) {
        self.handles = urls.map { ScopedHandle(url: $0, isSecurityScoped: true) }
    }

    deinit {
        cleanup()
    }

    /// Adds an already-accessed security-scoped URL into this scope's management.
    public func add(_ url: URL, isSecurityScoped: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard !_isCleanedUp else {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
            return
        }
        handles.append(ScopedHandle(url: url, isSecurityScoped: isSecurityScoped))
    }

    /// Releases all acquired security-scoped resource handles deterministically.
    public func cleanup() {
        lock.lock()
        guard !_isCleanedUp else {
            lock.unlock()
            return
        }
        _isCleanedUp = true
        let handlesToStop = handles
        handles.removeAll()
        lock.unlock()

        for handle in handlesToStop where handle.isSecurityScoped {
            handle.url.stopAccessingSecurityScopedResource()
        }
    }

    /// Resolves security-scoped bookmarks into active URLs governed by this RAII scope.
    public static func resolve(bookmarks: [Data]) -> SecurityScopedResourceScope {
        let scope = SecurityScopedResourceScope()
        for data in bookmarks {
            var isStale = false
            let resolvedURL = (try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )) ?? (try? URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ))
            if let url = resolvedURL {
                let didStart = url.startAccessingSecurityScopedResource()
                if didStart || FileManager.default.fileExists(atPath: url.path) {
                    scope.add(url, isSecurityScoped: didStart)
                }
            }
        }
        return scope
    }
}

/// Typealias providing AppGroupSpooler naming parity across targets.
public typealias AppGroupSpooler = AppGroupSpoolManager

