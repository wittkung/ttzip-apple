// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

/// Represents a categorized group of search items or default recommendations.
public struct OmniSection: Sendable, Equatable, Identifiable {
    public var id: OmniSearchCategory { category }
    public let category: OmniSearchCategory
    public let items: [OmniSearchItem]

    /// Number of items contained in this section.
    public var count: Int { items.count }

    /// Indicates whether this section contains zero items.
    public var isEmpty: Bool { items.isEmpty }

    public init(category: OmniSearchCategory, items: [OmniSearchItem]) {
        self.category = category
        self.items = items
    }
}

/// Formal algebraic state machine capturing the deterministic lifecycle of OmniSearchEngine.
public enum OmniEngineState: Sendable, Equatable {
    case idleWithRecommendations(categories: [OmniSection])
    case typingDebounce(query: String)
    case searching(query: String)
    case populated(query: String, results: [OmniSection])
    case noMatches(query: String)
    case failure(errorDescription: String)
}

extension OmniEngineState {
    /// Active search query associated with the current state.
    public var query: String {
        switch self {
        case .idleWithRecommendations:
            return ""
        case .typingDebounce(let q),
             .searching(let q),
             .populated(let q, _),
             .noMatches(let q):
            return q
        case .failure:
            return ""
        }
    }

    /// Categorized sections displayed in the current state.
    public var sections: [OmniSection] {
        switch self {
        case .idleWithRecommendations(let categories):
            return categories
        case .populated(_, let results):
            return results
        case .typingDebounce, .searching, .noMatches, .failure:
            return []
        }
    }

    /// Flattened list of all items available in the active sections.
    public var flatItems: [OmniSearchItem] {
        sections.flatMap(\.items)
    }

    /// Total count of all items across all active sections.
    public var flatItemsCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }

    /// Indicates whether the engine is in its idle state displaying default recommendations.
    public var isIdle: Bool {
        if case .idleWithRecommendations = self { return true }
        return false
    }

    /// Indicates whether an active search or debounced query is currently pending.
    public var isLoading: Bool {
        switch self {
        case .typingDebounce, .searching:
            return true
        case .idleWithRecommendations, .populated, .noMatches, .failure:
            return false
        }
    }

    /// Indicates whether matching search results are available and displayed.
    public var isPopulated: Bool {
        if case .populated = self { return true }
        return false
    }

    /// Indicates whether the search query yielded zero matches.
    public var isNoMatches: Bool {
        if case .noMatches = self { return true }
        return false
    }

    /// Indicates whether an unrecoverable failure occurred.
    public var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
