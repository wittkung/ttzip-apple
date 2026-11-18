// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Discriminated section kind for sidebar navigation and focus state machines.
public enum SidebarSection: String, Hashable, Equatable, Sendable, Codable {
    case pinned
    case favorites
    case locations
}

/// Composite identifier uniquely distinguishing a sidebar row across distinct sections.
/// Eliminates ambiguous navigation, circular focus deadlocks, and scroll-to conflicts
/// when the same filesystem path exists in multiple sections (e.g. pinned and favorites).
public struct SidebarRowIdentifier: Hashable, Equatable, Sendable, Codable, CustomStringConvertible {
    public let section: SidebarSection
    public let id: String

    public init(section: SidebarSection, id: String) {
        self.section = section
        self.id = id
    }

    public var description: String {
        "\(section.rawValue):\(id)"
    }
}
