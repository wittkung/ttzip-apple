// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os

/// Thread-safe sandbox security-scoped resource manager utilizing reference counting.
///
/// Ensures balanced and leak-free `startAccessingSecurityScopedResource()` and
/// `stopAccessingSecurityScopedResource()` lifecycle invocations within Mac App Store
/// sandboxed environments and hardened runtime containers.
public final class TTSecurityScopedResourceManager: @unchecked Sendable {
    /// Shared singleton instance for application-wide security-scoped URL management.
    public static let shared = TTSecurityScopedResourceManager()

    private struct ScopedEntry: Sendable {
        var url: URL
        var count: Int
        var isSecurityScoped: Bool
    }

    private struct State: Sendable {
        var entries: [String: ScopedEntry] = [:]
    }

    private let logger = TTMediaLogger.security
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Increments reference count and begins accessing a security-scoped resource on the first reference.
    ///
    /// - Parameter url: Target local or bookmark file URL.
    /// - Returns: `true` if resource access was successfully granted or already active, `false` otherwise.
    @discardableResult
    public func acquireAccess(for url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        let key = standardizedURL.path
        return state.withLock { s in
            if var existing = s.entries[key], existing.count > 0 {
                existing.count += 1
                s.entries[key] = existing
                return true
            }

            let accessed = url.startAccessingSecurityScopedResource()
            let isReadable = accessed || FileManager.default.isReadableFile(atPath: standardizedURL.path)

            guard accessed || isReadable else {
                logger.debug("Resource access denied and unreadable: \(key)")
                return false
            }

            s.entries[key] = ScopedEntry(
                url: url,
                count: 1,
                isSecurityScoped: accessed
            )

            if accessed {
                logger.debug("Successfully started accessing security-scoped resource: \(key)")
            } else {
                logger.debug("Accessing regular non-security-scoped resource: \(key)")
            }

            return true
        }
    }

    /// Increments reference count and begins accessing a security-scoped resource on the first reference.
    @discardableResult
    public func startAccessing(url: URL) -> Bool {
        acquireAccess(for: url)
    }

    /// Decrements reference count and stops accessing a security-scoped resource when the count drops to zero.
    ///
    /// - Parameter url: Target local or bookmark file URL.
    public func releaseAccess(for url: URL) {
        let standardizedURL = url.standardizedFileURL
        let key = standardizedURL.path
        let scopedURLToStop: URL? = state.withLock { s in
            guard var entry = s.entries[key], entry.count > 0 else {
                return nil
            }

            if entry.count <= 1 {
                s.entries.removeValue(forKey: key)
                return entry.isSecurityScoped ? entry.url : nil
            } else {
                entry.count -= 1
                s.entries[key] = entry
                return nil
            }
        }

        if let scopedURL = scopedURLToStop {
            scopedURL.stopAccessingSecurityScopedResource()
            logger.debug("Released security-scoped resource: \(key)")
        }
    }

    /// Decrements reference count and stops accessing a security-scoped resource when the count drops to zero.
    public func stopAccessing(url: URL) {
        releaseAccess(for: url)
    }

    /// Returns the current active reference count for the specified URL.
    public func activeAccessCount(for url: URL) -> Int {
        let key = url.standardizedFileURL.path
        return state.withLock { s in
            s.entries[key]?.count ?? 0
        }
    }

    /// Returns whether the active entry for the specified URL owns a kernel security scope.
    public func isSecurityScopedAccessActive(for url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        return state.withLock { s in
            s.entries[key]?.isSecurityScoped ?? false
        }
    }

    /// Scoped closure wrapper ensuring balanced lifecycle invocation across synchronous operations.
    public func withAccess<T>(to url: URL, _ block: (URL) throws -> T) rethrows -> T {
        let accessed = startAccessing(url: url)
        defer {
            if accessed {
                stopAccessing(url: url)
            }
        }
        return try block(url)
    }

    /// Scoped closure wrapper ensuring balanced lifecycle invocation across asynchronous tasks.
    public func withAccessAsync<T>(to url: URL, _ block: (URL) async throws -> T) async rethrows -> T {
        let accessed = startAccessing(url: url)
        defer {
            if accessed {
                stopAccessing(url: url)
            }
        }
        return try await block(url)
    }

    /// Safely discovers external companion subtitle files matching the media base name.
    ///
    /// Implements defensive sandbox authorization and exception guards to prevent crashes or sandbox
    /// violation traps under Mac App Store sandboxed runtimes.
    ///
    /// - Parameter videoURL: The media file URL whose companion subtitles are being discovered.
    /// - Returns: Array of discovered, accessible subtitle file URLs.
    public func safeDiscoverCompanionSubtitles(for videoURL: URL) -> [URL] {
        let standardizedVideoURL = videoURL.standardizedFileURL
        let parentDir = standardizedVideoURL.deletingLastPathComponent()
        let videoBaseName = standardizedVideoURL.deletingPathExtension().lastPathComponent

        guard !videoBaseName.isEmpty else { return [] }

        let supportedExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "lrc"]
        var discoveredURLs: [URL] = []

        // Attempt 1: Fast directory contents enumeration if directory read access is present
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: parentDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isReadableKey],
            options: [.skipsHiddenFiles]
        ) {
            for itemURL in contents {
                let itemExtension = itemURL.pathExtension.lowercased()
                guard supportedExtensions.contains(itemExtension) else { continue }

                let itemBaseName = itemURL.deletingPathExtension().lastPathComponent
                if itemBaseName.caseInsensitiveCompare(videoBaseName) == .orderedSame ||
                    itemBaseName.lowercased().hasPrefix(videoBaseName.lowercased()) {
                    if FileManager.default.isReadableFile(atPath: itemURL.path) {
                        discoveredURLs.append(itemURL)
                    }
                }
            }
        }

        // Attempt 2: Direct deterministic probing for common named companion files if directory enumeration was sandboxed
        if discoveredURLs.isEmpty {
            for ext in supportedExtensions {
                let candidateURL = parentDir.appendingPathComponent("\(videoBaseName).\(ext)")
                if FileManager.default.fileExists(atPath: candidateURL.path) &&
                    FileManager.default.isReadableFile(atPath: candidateURL.path) {
                    discoveredURLs.append(candidateURL)
                }
            }
        }

        return discoveredURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Compatibility Typealiases

public typealias SecurityScopedResourceManager = TTSecurityScopedResourceManager
