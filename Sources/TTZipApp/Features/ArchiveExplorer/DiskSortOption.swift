// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore

public enum DiskSortOption: String, CaseIterable, Identifiable, Codable {
    case nameAsc = "Name (A-Z)"
    case nameDesc = "Name (Z-A)"
    case sizeDesc = "Size (Largest First)"
    case sizeAsc = "Size (Smallest First)"
    case dateDesc = "Date Modified (Newest)"
    case dateAsc = "Date Modified (Oldest)"
    case kind = "Kind"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .nameAsc: return "arrow.up.arrow.down"
        case .nameDesc: return "arrow.up.arrow.down"
        case .sizeDesc: return "arrow.down.circle"
        case .sizeAsc: return "arrow.up.circle"
        case .dateDesc: return "calendar.badge.clock"
        case .dateAsc: return "calendar"
        case .kind: return "square.grid.3x3.fill"
        }
    }
    
    /// Provides localized display title for sorting dropdowns across languages.
    public var localizedTitle: String {
        let lang = TTZipLocalizationManager.shared.currentLanguage
        switch lang {
        case .zhHans:
            switch self {
            case .nameAsc: return "名称 (A-Z)"
            case .nameDesc: return "名称 (Z-A)"
            case .sizeDesc: return "大小 (降序)"
            case .sizeAsc: return "大小 (升序)"
            case .dateDesc: return "修改日期 (最新优先)"
            case .dateAsc: return "修改日期 (最早优先)"
            case .kind: return "种类"
            }
        case .zhHant:
            switch self {
            case .nameAsc: return "名稱 (A-Z)"
            case .nameDesc: return "名稱 (Z-A)"
            case .sizeDesc: return "大小 (由大到小)"
            case .sizeAsc: return "大小 (由小到大)"
            case .dateDesc: return "修改日期 (由新到舊)"
            case .dateAsc: return "修改日期 (由舊到新)"
            case .kind: return "種類"
            }
        default:
            return rawValue
        }
    }
}

public struct FinderFavoriteItem: Identifiable, Hashable, Equatable, Sendable, Codable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let systemImage: String
    public let identity: FileIdentity
    public var healthState: SidebarItemHealthState
    public let bookmarkData: Data?

    public init(
        name: String,
        path: String,
        systemImage: String,
        identity: FileIdentity? = nil,
        healthState: SidebarItemHealthState = .accessible,
        bookmarkData: Data? = nil
    ) {
        self.name = name
        self.path = path
        self.systemImage = systemImage
        self.identity = identity ?? FileIdentity(path: path)
        self.healthState = healthState
        self.bookmarkData = bookmarkData
    }

    public static func == (lhs: FinderFavoriteItem, rhs: FinderFavoriteItem) -> Bool {
        lhs.path == rhs.path && lhs.name == rhs.name && lhs.systemImage == rhs.systemImage && lhs.healthState == rhs.healthState
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(healthState)
    }

    private enum CodingKeys: String, CodingKey {
        case name, path, systemImage, identity, healthState, bookmarkData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.path = try container.decode(String.self, forKey: .path)
        self.systemImage = try container.decode(String.self, forKey: .systemImage)
        self.identity = try container.decodeIfPresent(FileIdentity.self, forKey: .identity) ?? FileIdentity(path: self.path)
        self.healthState = try container.decodeIfPresent(SidebarItemHealthState.self, forKey: .healthState) ?? .accessible
        self.bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
    }
}
