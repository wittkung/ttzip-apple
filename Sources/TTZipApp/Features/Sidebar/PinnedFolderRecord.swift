// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Persistent record for custom-pinned sidebar shortcuts with security-scoped bookmark tracking and health state.
public struct PinnedFolderRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var path: String
    public var customName: String?
    public var bookmarkData: Data?
    public var identity: FileIdentity
    public var volumeUUID: String?
    public var volumeName: String?
    public var lastKnownHealthState: SidebarItemHealthState

    public init(
        id: UUID = UUID(),
        path: String,
        customName: String? = nil,
        bookmarkData: Data? = nil,
        identity: FileIdentity? = nil,
        volumeUUID: String? = nil,
        volumeName: String? = nil,
        lastKnownHealthState: SidebarItemHealthState = .accessible
    ) {
        self.id = id
        self.path = path
        self.customName = customName
        self.bookmarkData = bookmarkData
        self.identity = identity ?? FileIdentity(path: path)
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.lastKnownHealthState = lastKnownHealthState
    }

    /// Fast display title derived in pure Swift without Objective-C NSString bridging overhead.
    public var displayName: String {
        if let customName, !customName.isEmpty {
            return customName
        }
        if let lastSlash = path.lastIndex(of: "/") {
            let nextIndex = path.index(after: lastSlash)
            if nextIndex < path.endIndex {
                return String(path[nextIndex...])
            }
        }
        return path
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, customName, bookmarkData, identity, volumeUUID, volumeName, lastKnownHealthState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.path = try container.decode(String.self, forKey: .path)
        self.customName = try container.decodeIfPresent(String.self, forKey: .customName)
        self.bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        self.identity = try container.decodeIfPresent(FileIdentity.self, forKey: .identity) ?? FileIdentity(path: self.path)
        self.volumeUUID = try container.decodeIfPresent(String.self, forKey: .volumeUUID)
        self.volumeName = try container.decodeIfPresent(String.self, forKey: .volumeName)
        self.lastKnownHealthState = try container.decodeIfPresent(SidebarItemHealthState.self, forKey: .lastKnownHealthState) ?? .accessible
    }
}
