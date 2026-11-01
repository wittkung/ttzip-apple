// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Isolated transient view state associated with an individual workspace tab session.
public struct TabViewState: Equatable, Sendable {
    public var millerColumnPaths: [URL]
    public var selectedPaths: [URL]
    public var scrollTargetURL: URL?
    public var searchQuery: String

    public init(
        millerColumnPaths: [URL] = [],
        selectedPaths: [URL] = [],
        scrollTargetURL: URL? = nil,
        searchQuery: String = ""
    ) {
        self.millerColumnPaths = millerColumnPaths
        self.selectedPaths = selectedPaths
        self.scrollTargetURL = scrollTargetURL
        self.searchQuery = searchQuery
    }
}
