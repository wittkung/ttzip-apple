// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import Foundation

/// Functional category of an Omnibar search item.
public enum OmniSearchCategory: String, CaseIterable, Hashable, Identifiable, Sendable {
    case applications
    case directories
    case files
    case commands

    public var id: String { rawValue }

    /// SF Symbol icon name representing the category.
    public var systemIconName: String {
        switch self {
        case .applications:
            return "app.badge.fill"
        case .directories:
            return "folder.fill"
        case .files:
            return "doc.fill"
        case .commands:
            return "command"
        }
    }

    /// Localized human-readable category title.
    public var localizedTitle: String {
        switch self {
        case .applications:
            return NSLocalizedString("Applications", comment: "Category title for applications")
        case .directories:
            return NSLocalizedString("Directories", comment: "Category title for directories")
        case .files:
            return NSLocalizedString("Files", comment: "Category title for files")
        case .commands:
            return NSLocalizedString("Commands", comment: "Category title for commands")
        }
    }
}

/// Action or resource payload encapsulated within an Omnibar search item.
public enum OmniItemPayload: Sendable {
    case directory(URL)
    case file(URL)
    case application(URL)
    case command(id: String, action: @Sendable @MainActor () -> Void)
}

/// Strongly-typed search item displayed within the Universal Omnibar.
@MainActor
public struct OmniSearchItem: Identifiable {
    public nonisolated let id: String
    public let category: OmniSearchCategory
    public let title: String
    public let subtitle: String
    public let systemIcon: String?
    public let customIcon: NSImage?
    public let shortcutHint: String?
    public let payload: OmniItemPayload

    public init(
        id: String = UUID().uuidString,
        category: OmniSearchCategory,
        title: String,
        subtitle: String,
        systemIcon: String? = nil,
        customIcon: NSImage? = nil,
        shortcutHint: String? = nil,
        payload: OmniItemPayload
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.systemIcon = systemIcon
        self.customIcon = customIcon
        self.shortcutHint = shortcutHint
        self.payload = payload
    }
}

extension OmniSearchItem: Equatable {
    public nonisolated static func == (lhs: OmniSearchItem, rhs: OmniSearchItem) -> Bool {
        lhs.id == rhs.id
    }
}

extension OmniSearchItem: Hashable {
    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
