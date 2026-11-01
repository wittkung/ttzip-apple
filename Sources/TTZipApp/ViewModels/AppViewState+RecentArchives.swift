// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
#if canImport(TTZipAppServices)
#endif

extension AppViewState {
    // MARK: - Recent Archive Persistence & Bookmark Recovery

    public func recordRecentArchive(url: URL) {
        let normalizedURL = RootFolderAccessManager.shared.canonicalDirectoryURL(for: url)
        let path = normalizedURL.path
        let bookmark = RootFolderAccessManager.shared.persistBookmark(for: normalizedURL)
            ?? RootFolderAccessManager.shared.persistBookmark(for: normalizedURL.deletingLastPathComponent())
            ?? recentArchives.first(where: { $0.path == path || $0.path == url.path })?.bookmarkData
        let record = RecentArchiveRecord(path: url.path, bookmarkData: bookmark)
        var updated = recentArchives.filter { $0.path != url.path && $0.path != path }
        updated.insert(record, at: 0)
        if updated.count > 12 {
            updated = Array(updated.prefix(12))
        }
        recentArchives = updated
        saveRecentArchivesToStorage()
        RecentLocationsStore.shared.recordArchive(url: normalizedURL, bookmarkData: bookmark)
    }

    public func addRecentArchive(path: String) {
        recordRecentArchive(url: URL(fileURLWithPath: path))
    }

    public func removeRecentArchive(path: String) {
        recentArchives.removeAll { $0.path == path }
        saveRecentArchivesToStorage()
        RecentLocationsStore.shared.remove(path: path)
    }

    func loadRecentArchivesFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: recentArchivesKey),
              let records = try? JSONDecoder().decode([RecentArchiveRecord].self, from: data) else {
            return
        }
        for record in records {
            if let bm = record.bookmarkData {
                RootFolderAccessManager.shared.registerSecurityScopedBookmark(bm, for: record.path)
            }
        }
        recentArchives = records
    }

    func saveRecentArchivesToStorage() {
        if let data = try? JSONEncoder().encode(recentArchives) {
            UserDefaults.standard.set(data, forKey: recentArchivesKey)
        }
    }
}
