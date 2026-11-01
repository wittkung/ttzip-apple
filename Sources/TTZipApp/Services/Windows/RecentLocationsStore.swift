// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import TTZipCore
import TTZipUI

/// Single source of truth managing recently visited folders and recently opened archives
/// for the native Dock menu ("Recent Items") and unified application menus.
///
/// Design Invariants:
/// - Never performs blocking disk or network I/O during snapshot reads (`dockMenuSnapshot()`).
/// - Deduplicates items by canonical physical identity (`FileIdentity`) rather than display name.
/// - Disambiguates items sharing the same basename by appending parent directory context.
/// - Supports custom `UserDefaults` injection so unit tests never mutate real user defaults.
@Observable
@MainActor
public final class RecentLocationsStore {
    public static let shared = RecentLocationsStore()

    public static let storageKey = "com.metastudyline.ttzip.recent_locations.v1"
    public static let legacyArchivesKey = "TTZipRecentArchivesKey"
    public static let maxItems: Int = 12

    public private(set) var items: [RecentLocationItem] = []
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard, loadOnInit: Bool = true) {
        self.userDefaults = userDefaults
        if loadOnInit {
            loadFromStorage()
        }
    }

    // MARK: - Recording & Mutation

    public func recordDirectory(url: URL, date: Date = Date()) {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty,
              !standardized.absoluteString.hasPrefix("ttzip://"),
              URLComponents(url: standardized, resolvingAgainstBaseURL: false)?.queryItems == nil else {
            return
        }
        let bookmark = RootFolderAccessManager.shared.persistBookmark(for: standardized)
            ?? items.first(where: { $0.canonicalPath == standardized.path || $0.path == path })?.bookmarkData
        let identity = FileIdentity(path: path)
        let entry = RecentLocationItem(
            path: path,
            kind: .directory,
            lastAccessedAt: date,
            bookmarkData: bookmark,
            identity: identity
        )
        upsert(entry)
    }

    public func recordArchive(url: URL, bookmarkData: Data? = nil, date: Date = Date()) {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty else { return }
        let resolvedBookmark = bookmarkData
            ?? RootFolderAccessManager.shared.persistBookmark(for: standardized)
            ?? RootFolderAccessManager.shared.persistBookmark(for: standardized.deletingLastPathComponent())
            ?? items.first(where: { $0.canonicalPath == standardized.path || $0.path == path })?.bookmarkData
        let identity = FileIdentity(path: path)
        let entry = RecentLocationItem(
            path: path,
            kind: .archive,
            lastAccessedAt: date,
            bookmarkData: resolvedBookmark,
            identity: identity
        )
        upsert(entry)
    }

    public func remove(path: String) {
        let canonical = FileIdentity(path: path).canonicalPath
        items.removeAll { $0.path == path || $0.canonicalPath == canonical }
        saveToStorage()
    }

    public func clearAll() {
        items.removeAll()
        userDefaults.removeObject(forKey: Self.storageKey)
    }

    private func upsert(_ item: RecentLocationItem) {
        var updated = items.filter { existing in
            if existing.kind != item.kind { return true }
            if existing.identity == item.identity { return false }
            return existing.canonicalPath != item.canonicalPath && existing.path != item.path
        }
        updated.insert(item, at: 0)
        if updated.count > Self.maxItems {
            updated = Array(updated.prefix(Self.maxItems))
        }
        items = updated
        saveToStorage()
    }

    // MARK: - Persistence & Legacy Migration

    public func loadFromStorage() {
        var loaded = decodeStoredItems()
        mergeLegacyArchives(into: &loaded)
        loaded.sort { $0.lastAccessedAt > $1.lastAccessedAt }
        if loaded.count > Self.maxItems {
            loaded = Array(loaded.prefix(Self.maxItems))
        }
        for item in loaded {
            if let bm = item.bookmarkData {
                RootFolderAccessManager.shared.registerSecurityScopedBookmark(bm, for: item.path)
            }
        }
        items = loaded
    }

    private func decodeStoredItems() -> [RecentLocationItem] {
        guard let data = userDefaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([RecentLocationItem].self, from: data) else {
            return []
        }
        return decoded
    }

    private func mergeLegacyArchives(into loaded: inout [RecentLocationItem]) {
        guard let legacyData = userDefaults.data(forKey: Self.legacyArchivesKey),
              let legacyRecords = try? JSONDecoder().decode([RecentArchiveRecord].self, from: legacyData) else {
            return
        }
        for record in legacyRecords {
            let identity = FileIdentity(path: record.path)
            let alreadyPresent = loaded.contains {
                $0.kind == .archive && isSameLocation($0, identity: identity, rawPath: record.path)
            }
            if !alreadyPresent {
                loaded.append(
                    RecentLocationItem(
                        path: record.path,
                        displayName: record.name,
                        kind: .archive,
                        lastAccessedAt: record.date,
                        bookmarkData: record.bookmarkData,
                        identity: identity
                    )
                )
            }
        }
    }

    private func isSameLocation(_ item: RecentLocationItem, identity: FileIdentity, rawPath: String) -> Bool {
        item.identity == identity || item.canonicalPath == identity.canonicalPath || item.path == rawPath
    }

    public func saveToStorage() {
        if let data = try? JSONEncoder().encode(items) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Zero-I/O Dock Menu Snapshot & Name Disambiguation

    /// Builds a pure in-memory snapshot for the Dock menu without touching disk or network.
    public func dockMenuSnapshot(limit: Int = 10) -> [DockMenuRecentEntry] {
        let slice = Array(items.prefix(max(0, limit)))
        var nameCounts: [String: Int] = [:]
        for item in slice {
            nameCounts[item.displayName, default: 0] += 1
        }

        return slice.map { item in
            let needsDisambiguation = (nameCounts[item.displayName] ?? 0) > 1
            let title = Self.formatMenuTitle(
                baseTitle: item.displayName,
                fullPath: item.path,
                disambiguateWithParent: needsDisambiguation
            )
            let icon = item.kind == .archive ? "doc.zipper" : "folder"
            return DockMenuRecentEntry(
                item: item,
                disambiguatedTitle: title,
                systemImage: icon
            )
        }
    }

    /// Formats a menu item title with middle truncation for long names and parent folder suffix when duplicate names exist.
    public nonisolated static func formatMenuTitle(
        baseTitle: String,
        fullPath: String,
        disambiguateWithParent: Bool,
        maxCharacters: Int = 56
    ) -> String {
        let truncatedBase = middleTruncate(baseTitle, maxCharacters: maxCharacters)
        guard disambiguateWithParent else {
            return truncatedBase
        }
        let parentContext = abbreviatedParentPath(for: fullPath)
        guard !parentContext.isEmpty else {
            return truncatedBase
        }
        return "\(truncatedBase) — \(parentContext)"
    }

    public nonisolated static func abbreviatedParentPath(for fullPath: String) -> String {
        let parent = (fullPath as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return "" }
        let home = NSHomeDirectory()
        if parent == home {
            return "~"
        }
        if parent.hasPrefix(home + "/") {
            let relative = String(parent.dropFirst(home.count))
            let parentName = (relative as NSString).lastPathComponent
            if !parentName.isEmpty && parentName != "/" {
                return "~/…/\(parentName)"
            }
            return "~" + relative
        }
        let lastParent = (parent as NSString).lastPathComponent
        if !lastParent.isEmpty && lastParent != "/" && parent != "/\(lastParent)" {
            return "…/\(lastParent)"
        }
        return parent
    }

    public nonisolated static func middleTruncate(_ text: String, maxCharacters: Int = 56) -> String {
        guard maxCharacters >= 12, text.count > maxCharacters else {
            return text
        }
        let headCount = (maxCharacters - 1) / 2
        let tailCount = maxCharacters - 1 - headCount
        let head = text.prefix(headCount)
        let tail = text.suffix(tailCount)
        return "\(head)…\(tail)"
    }
}
