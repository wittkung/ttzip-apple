// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

public enum GlobalSearchHitType: String, Sendable, Codable, Equatable {
    case archiveFile
    case archiveEntry
    case recentArchive
    case quickAction
}

/// Canonical routing target classification for global search results.
public enum GlobalSearchTargetKind: Sendable, Equatable {
    case diskItem(path: String)
    case archiveFile(archivePath: String)
    case archiveEntry(archivePath: String, entrySubpath: String)
    case quickAction
}

public struct GlobalSearchResultItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let hitType: GlobalSearchHitType
    public let archivePath: String?
    public let entrySubpath: String?
    public let diskPath: String?
    public let targetWindowID: UUID?
    public let matchedLineStart: Int?
    public let isDirectory: Bool
    public let byteSize: Int64
    public let score: Float
    public let matchBadge: String?

    public init(
        id: String,
        title: String,
        subtitle: String,
        hitType: GlobalSearchHitType,
        archivePath: String? = nil,
        entrySubpath: String? = nil,
        diskPath: String? = nil,
        targetWindowID: UUID? = nil,
        matchedLineStart: Int? = nil,
        isDirectory: Bool = false,
        byteSize: Int64 = 0,
        score: Float = 1.0,
        matchBadge: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.hitType = hitType
        self.archivePath = archivePath
        self.entrySubpath = entrySubpath
        self.diskPath = diskPath
        self.targetWindowID = targetWindowID
        self.matchedLineStart = matchedLineStart
        self.isDirectory = isDirectory
        self.byteSize = byteSize
        self.score = score
        self.matchBadge = matchBadge
    }

    public var targetKind: GlobalSearchTargetKind {
        if let archivePath, !archivePath.isEmpty, let entrySubpath, !entrySubpath.isEmpty {
            return .archiveEntry(archivePath: archivePath, entrySubpath: entrySubpath)
        }
        if let diskPath, !diskPath.isEmpty {
            return .diskItem(path: diskPath)
        }
        if let archivePath, !archivePath.isEmpty, hitType != .quickAction {
            return .archiveFile(archivePath: archivePath)
        }
        return .quickAction
    }
}

