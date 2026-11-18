// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Strongly-typed immutable descriptor for a tab in the multi-directory tab bar.
public struct DirectoryTabItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var url: URL
    public var customTitle: String?
    public var isCompressWorkspace: Bool
    public var isStorageInspector: Bool
    public var history: [URL]
    public var historyIndex: Int

    public init(
        id: UUID = UUID(),
        url: URL,
        customTitle: String? = nil,
        isCompressWorkspace: Bool = false,
        isStorageInspector: Bool = false,
        history: [URL]? = nil,
        historyIndex: Int = 0
    ) {
        self.id = id
        self.url = url
        self.customTitle = customTitle
        self.isCompressWorkspace = isCompressWorkspace
        self.isStorageInspector = isStorageInspector
        self.history = history ?? [url]
        self.historyIndex = historyIndex
    }

    public var canGoBack: Bool {
        historyIndex > 0
    }

    public var canGoForward: Bool {
        historyIndex < history.count - 1
    }

    public var canGoUp: Bool {
        url.standardizedFileURL.path != "/" && url.standardizedFileURL.pathComponents.count > 1
    }

    public mutating func pushURL(_ newURL: URL) {
        let standardized = newURL.standardizedFileURL
        guard standardized.path != url.standardizedFileURL.path else { return }
        if historyIndex + 1 < history.count {
            history = Array(history.prefix(historyIndex + 1))
        }
        history.append(standardized)
        historyIndex = history.count - 1
        url = standardized
    }

    public mutating func back() -> URL? {
        guard canGoBack else { return nil }
        historyIndex -= 1
        url = history[historyIndex]
        return url
    }

    public mutating func forward() -> URL? {
        guard canGoForward else { return nil }
        historyIndex += 1
        url = history[historyIndex]
        return url
    }

    public mutating func up() -> URL? {
        guard canGoUp else { return nil }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        pushURL(parent)
        return parent
    }
}
