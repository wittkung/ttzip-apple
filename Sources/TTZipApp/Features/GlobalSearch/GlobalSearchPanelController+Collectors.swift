// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import TTZipSearchKit
import Foundation
import TTZipCore

@MainActor
extension GlobalSearchPanelController {
    func collectRegisteredSessionSearchHits(
        query: String,
        lowerQuery: String,
        seenArchivePaths: inout Set<String>,
        seenEntryKeys: inout Set<String>
    ) -> [GlobalSearchResultItem] {
        var hits: [GlobalSearchResultItem] = []
        for session in AppIntentDispatcher.shared.allSessions {
            guard let path = session.currentArchivePath, !path.isEmpty, !session.isClosed else { continue }
            let canonicalArchive = Self.canonicalPath(path)
            let archiveName = (path as NSString).lastPathComponent
            let preferredWindowID = session.id

            if archiveName.lowercased().contains(lowerQuery),
               seenArchivePaths.insert(canonicalArchive).inserted {
                hits.append(Self.makeArchiveFileHit(
                    idPrefix: "archive",
                    path: path,
                    archiveName: archiveName,
                    hitType: .archiveFile,
                    byteSize: 0,
                    score: 1.0,
                    targetWindowID: preferredWindowID
                ))
            }

            if let vfs = session.vfsTree {
                for match in vfs.search(query: query, maxResults: 30) {
                    let entryKey = Self.entryDedupKey(canonicalArchive: canonicalArchive, subpath: match.path)
                    guard seenEntryKeys.insert(entryKey).inserted else { continue }
                    hits.append(Self.makeArchiveEntryHit(
                        archivePath: path,
                        archiveName: archiveName,
                        entryPath: match.path,
                        entryName: match.name,
                        isDirectory: match.isDirectory,
                        byteSize: Int64(match.size),
                        score: 0.95,
                        targetWindowID: preferredWindowID
                    ))
                }
            } else if !session.currentEntries.isEmpty {
                var count = 0
                for entry in session.currentEntries {
                    guard entry.name.lowercased().contains(lowerQuery) || entry.path.lowercased().contains(lowerQuery) else {
                        continue
                    }
                    let entryKey = Self.entryDedupKey(canonicalArchive: canonicalArchive, subpath: entry.path)
                    guard seenEntryKeys.insert(entryKey).inserted else { continue }
                    hits.append(Self.makeArchiveEntryHit(
                        archivePath: path,
                        archiveName: archiveName,
                        entryPath: entry.path,
                        entryName: entry.name,
                        isDirectory: entry.isDirectory,
                        byteSize: entry.uncompressedSize,
                        score: 0.85,
                        targetWindowID: preferredWindowID
                    ))
                    count += 1
                    if count >= 30 { break }
                }
            }
        }
        return hits
    }

    func collectCachedHierarchySearchHits(
        query: String,
        lowerQuery: String,
        seenArchivePaths: inout Set<String>,
        seenEntryKeys: inout Set<String>
    ) async -> [GlobalSearchResultItem] {
        var hits: [GlobalSearchResultItem] = []
        let cachedPaths = await ArchiveHierarchySessionCache.shared.cachedArchivePaths()
        for path in cachedPaths {
            guard let cached = await ArchiveHierarchySessionCache.shared.cachedSession(for: path) else { continue }
            let canonicalArchive = Self.canonicalPath(path)
            let archiveName = (path as NSString).lastPathComponent

            if archiveName.lowercased().contains(lowerQuery),
               seenArchivePaths.insert(canonicalArchive).inserted {
                hits.append(Self.makeArchiveFileHit(
                    idPrefix: "archive",
                    path: path,
                    archiveName: archiveName,
                    hitType: .archiveFile,
                    byteSize: cached.fileByteSize,
                    score: 0.95,
                    targetWindowID: nil
                ))
            }

            if let vfs = cached.vfsTree {
                for match in vfs.search(query: query, maxResults: 20) {
                    let entryKey = Self.entryDedupKey(canonicalArchive: canonicalArchive, subpath: match.path)
                    guard seenEntryKeys.insert(entryKey).inserted else { continue }
                    hits.append(Self.makeArchiveEntryHit(
                        archivePath: path,
                        archiveName: archiveName,
                        entryPath: match.path,
                        entryName: match.name,
                        isDirectory: match.isDirectory,
                        byteSize: Int64(match.size),
                        score: 0.90,
                        targetWindowID: nil
                    ))
                }
            }
        }
        return hits
    }

    func collectRecentArchiveSearchHits(
        lowerQuery: String,
        seenArchivePaths: inout Set<String>
    ) -> [GlobalSearchResultItem] {
        guard let data = UserDefaults.standard.data(forKey: "TTZipRecentArchivesKey"),
              let records = try? JSONDecoder().decode([RecentArchiveRecord].self, from: data) else {
            return []
        }
        var hits: [GlobalSearchResultItem] = []
        for rec in records {
            let canonicalArchive = Self.canonicalPath(rec.path)
            guard !seenArchivePaths.contains(canonicalArchive) else { continue }
            guard rec.name.lowercased().contains(lowerQuery) || rec.path.lowercased().contains(lowerQuery) else {
                continue
            }
            guard FileManager.default.fileExists(atPath: rec.path) else { continue }
            seenArchivePaths.insert(canonicalArchive)
            hits.append(Self.makeArchiveFileHit(
                idPrefix: "recent",
                path: rec.path,
                archiveName: rec.name,
                hitType: .recentArchive,
                byteSize: 0,
                score: 0.70,
                targetWindowID: nil
            ))
        }
        return hits
    }

    static func makeArchiveFileHit(
        idPrefix: String,
        path: String,
        archiveName: String,
        hitType: GlobalSearchHitType,
        byteSize: Int64,
        score: Float,
        targetWindowID: UUID?
    ) -> GlobalSearchResultItem {
        GlobalSearchResultItem(
            id: "\(idPrefix):\(path)",
            title: archiveName,
            subtitle: path,
            hitType: hitType,
            archivePath: path,
            targetWindowID: targetWindowID,
            isDirectory: false,
            byteSize: byteSize,
            score: score,
            matchBadge: nil
        )
    }

    static func makeArchiveEntryHit(
        archivePath: String,
        archiveName: String,
        entryPath: String,
        entryName: String,
        isDirectory: Bool,
        byteSize: Int64,
        score: Float,
        targetWindowID: UUID?
    ) -> GlobalSearchResultItem {
        GlobalSearchResultItem(
            id: "entry:\(archivePath):\(entryPath)",
            title: entryName,
            subtitle: "\(archiveName) → \(entryPath)",
            hitType: .archiveEntry,
            archivePath: archivePath,
            entrySubpath: entryPath,
            targetWindowID: targetWindowID,
            isDirectory: isDirectory,
            byteSize: byteSize,
            score: score,
            matchBadge: nil
        )
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func entryDedupKey(canonicalArchive: String, subpath: String) -> String {
        let normalized = ArchivePasswordProbePolicy.normalizeEntryPath(subpath)
        return "\(canonicalArchive)::\(normalized)"
    }
}
