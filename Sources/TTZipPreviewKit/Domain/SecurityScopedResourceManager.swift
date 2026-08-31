// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import os.log

/// Thread-safe sandbox security-scoped resource manager utilizing reference counting.
///
/// Ensures balanced and leak-free `startAccessingSecurityScopedResource()` and
/// `stopAccessingSecurityScopedResource()` lifecycle invocations within Mac App Store (MAS)
/// sandboxed environments and hardened runtime containers.
@MainActor
public final class SecurityScopedResourceManager {
    /// Shared singleton instance for application-wide security-scoped URL management.
    public static let shared = SecurityScopedResourceManager()

    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "SecurityScopedResourceManager")
    private var accessCounts: [URL: Int] = [:]
    private var activeSecurityScopedURLs: Set<URL> = []

    public init() {}

    /// Increments reference count and begins accessing a security-scoped resource on the first reference.
    ///
    /// - Parameter url: Target local or bookmark file URL.
    /// - Returns: `true` if resource access was successfully granted or already active, `false` otherwise.
    @discardableResult
    public func startAccessing(url: URL) -> Bool {
        let key = url.standardizedFileURL
        let currentCount = accessCounts[key, default: 0]

        if currentCount > 0 {
            accessCounts[key] = currentCount + 1
            return true
        }

        let accessGranted = url.startAccessingSecurityScopedResource()
        accessCounts[key] = 1

        if accessGranted {
            activeSecurityScopedURLs.insert(key)
            logger.debug("Successfully started accessing security-scoped resource: \(key.path, privacy: .public)")
        } else {
            logger.debug("Accessing regular non-security-scoped resource: \(key.path, privacy: .public)")
        }

        return accessGranted || FileManager.default.isReadableFile(atPath: key.path)
    }

    /// Decrements reference count and stops accessing a security-scoped resource when the count drops to zero.
    ///
    /// - Parameter url: Target local or bookmark file URL.
    public func stopAccessing(url: URL) {
        let key = url.standardizedFileURL
        guard let currentCount = accessCounts[key], currentCount > 0 else {
            return
        }

        if currentCount <= 1 {
            accessCounts.removeValue(forKey: key)
            if activeSecurityScopedURLs.remove(key) != nil {
                url.stopAccessingSecurityScopedResource()
                logger.debug("Released security-scoped resource: \(key.path, privacy: .public)")
            }
        } else {
            accessCounts[key] = currentCount - 1
        }
    }

    /// Safely discovers external companion subtitle files matching the video base name.
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

        // Ensure parent directory is accessible or test individual candidates defensively
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
