// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import Foundation

/// Fast application cataloging and search service for the Universal Omnibar.
@MainActor
public final class AppCatalogService: ObservableObject {
    /// Shared singleton instance.
    public static let shared = AppCatalogService()

    /// Discovered application metadata record.
    public struct AppEntry: Sendable {
        public let url: URL
        public let displayName: String
        public let bundleIdentifier: String?
        public let path: String

        public init(url: URL, displayName: String, bundleIdentifier: String?, path: String) {
            self.url = url
            self.displayName = displayName
            self.bundleIdentifier = bundleIdentifier
            self.path = path
        }
    }

    /// List of indexed applications.
    @Published public private(set) var apps: [AppEntry] = []

    /// High-resolution icon cache keyed by file path.
    private var iconCache: [String: NSImage] = [:]

    /// Indicates whether a catalog refresh is actively in progress.
    @Published public private(set) var isScanning: Bool = false

    /// Background scanning task.
    private var scanTask: Task<Void, Never>?

    public init() {
        refreshCatalog()
    }

    /// Triggers an asynchronous discovery scan across standard application directories.
    public func refreshCatalog() {
        scanTask?.cancel()
        isScanning = true

        scanTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .userInitiated) {
                Self.scanStandardDirectories()
            }.value

            guard !Task.isCancelled else { return }

            self?.apps = discovered
            self?.isScanning = false
        }
    }

    /// Scans standard macOS application root directories for `.app` bundles.
    private nonisolated static func scanStandardDirectories() -> [AppEntry] {
        var searchRoots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]

        let userApps = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
        if FileManager.default.fileExists(atPath: userApps.path) {
            searchRoots.append(userApps)
        }

        var discovered: [AppEntry] = []
        var seenPaths = Set<String>()

        for root in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .canonicalPathKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                if Task.isCancelled { break }

                guard fileURL.pathExtension == "app" else { continue }
                enumerator.skipDescendants()

                let canonicalPath = (try? fileURL.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath ?? fileURL.path
                if seenPaths.contains(canonicalPath) {
                    continue
                }
                seenPaths.insert(canonicalPath)

                let displayName = FileManager.default.displayName(atPath: fileURL.path)
                let bundle = Bundle(url: fileURL)
                let bundleId = bundle?.bundleIdentifier

                discovered.append(AppEntry(
                    url: fileURL,
                    displayName: displayName,
                    bundleIdentifier: bundleId,
                    path: fileURL.path
                ))
            }
        }

        discovered.sort {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        return discovered
    }

    /// Returns a cached or newly extracted high-resolution icon for the specified app path.
    public func icon(forPath path: String) -> NSImage {
        if let cached = iconCache[path] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 64, height: 64)
        iconCache[path] = icon
        return icon
    }

    /// Performs fast fuzzy search against discovered applications.
    public func searchApps(query: String) -> [OmniSearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return apps.prefix(20).map { makeSearchItem(from: $0) }
        }

        let scoredApps: [(app: AppEntry, score: Int)] = apps.compactMap { app in
            guard let score = calculateMatchScore(query: trimmed, target: app.displayName, bundleId: app.bundleIdentifier) else {
                return nil
            }
            return (app, score)
        }

        let sorted = scoredApps.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.app.displayName.localizedStandardCompare($1.app.displayName) == .orderedAscending
        }

        return sorted.prefix(20).map { makeSearchItem(from: $0.app) }
    }

    /// Calculates match score for fuzzy query against application metadata.
    private func calculateMatchScore(query: String, target: String, bundleId: String?) -> Int? {
        let q = query.lowercased()
        let t = target.lowercased()

        if t == q {
            return 1000 // Exact match
        }
        if t.hasPrefix(q) {
            return 500 + (100 - min(t.count, 100)) // Prefix match
        }
        if let range = t.range(of: q) {
            let position = t.distance(from: t.startIndex, to: range.lowerBound)
            return 300 - position // Substring match
        }

        // Word boundary acronym match (e.g., "gc" matches "Google Chrome")
        let words = t.split(separator: " ")
        if words.count > 1 {
            let initials = String(words.compactMap { $0.first })
            if initials.hasPrefix(q) {
                return 400
            }
        }

        // Subsequence match
        var qIdx = q.startIndex
        var tIdx = t.startIndex
        var consecutive = 0
        var score = 0

        while qIdx < q.endIndex && tIdx < t.endIndex {
            if q[qIdx] == t[tIdx] {
                score += 10 + (consecutive * 5)
                consecutive += 1
                qIdx = q.index(after: qIdx)
            } else {
                consecutive = 0
            }
            tIdx = t.index(after: tIdx)
        }

        if qIdx == q.endIndex {
            return score
        }

        // Bundle identifier fallback
        if let bId = bundleId?.lowercased(), bId.contains(q) {
            return 50
        }

        return nil
    }

    /// Constructs an `OmniSearchItem` from an `AppEntry`.
    private func makeSearchItem(from app: AppEntry) -> OmniSearchItem {
        let appIcon = icon(forPath: app.path)
        let prettyPath = app.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return OmniSearchItem(
            id: "app:\(app.path)",
            category: .applications,
            title: app.displayName,
            subtitle: prettyPath,
            systemIcon: "app.fill",
            customIcon: appIcon,
            shortcutHint: "⏎ 打开",
            payload: .application(app.url)
        )
    }

    /// Launches the target application using modern Swift 6 AppKit APIs.
    public func launchApp(at url: URL, completion: (@Sendable @escaping (Bool) -> Void) = { _ in }) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            let success = (error == nil && app != nil)
            Task { @MainActor in
                completion(success)
            }
        }
    }
}
