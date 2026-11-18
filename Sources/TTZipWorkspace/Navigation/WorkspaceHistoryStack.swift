// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Dual-stack navigation history manager providing lossless traversal across back and forward stacks.
public struct WorkspaceHistoryStack: Equatable, Sendable {
    public private(set) var backStack: [URL]
    public private(set) var current: URL
    public private(set) var forwardStack: [URL]

    public init(
        current: URL,
        backStack: [URL] = [],
        forwardStack: [URL] = []
    ) {
        self.current = current
        self.backStack = backStack
        self.forwardStack = forwardStack
    }

    public var canGoBack: Bool {
        !backStack.isEmpty
    }

    public var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    public var canGoUp: Bool {
        Self.parentLocation(current) != nil
    }

    public var backList: [URL] {
        Array(backStack.reversed())
    }

    public var forwardList: [URL] {
        Array(forwardStack.reversed())
    }

    @discardableResult
    public mutating func push(_ newURL: URL) -> Bool {
        guard !Self.sameLocation(newURL, current) else { return false }
        backStack.append(current)
        current = newURL
        forwardStack.removeAll()
        return true
    }

    @discardableResult
    public mutating func goBack() -> URL? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = previous
        return current
    }

    @discardableResult
    public mutating func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return current
    }

    @discardableResult
    public mutating func goUp() -> URL? {
        guard let parent = Self.parentLocation(current) else { return nil }
        if push(parent) {
            return current
        }
        return nil
    }

    @discardableResult
    public mutating func navigateToHistoryItem(_ targetURL: URL) -> Bool {
        guard !Self.sameLocation(targetURL, current) else { return false }

        if let backIdx = backStack.lastIndex(where: { Self.sameLocation($0, targetURL) }) {
            let itemsToMove = backStack.suffix(from: backIdx + 1)
            forwardStack.append(current)
            forwardStack.append(contentsOf: itemsToMove.reversed())
            current = backStack[backIdx]
            backStack.removeSubrange(backIdx...)
            return true
        }

        if let forwardIdx = forwardStack.lastIndex(where: { Self.sameLocation($0, targetURL) }) {
            let itemsToMove = forwardStack.suffix(from: forwardIdx + 1)
            backStack.append(current)
            backStack.append(contentsOf: itemsToMove.reversed())
            current = forwardStack[forwardIdx]
            forwardStack.removeSubrange(forwardIdx...)
            return true
        }

        return push(targetURL)
    }
    /// Standardizes the physical path without dropping authority, query, or fragment.
    public static func standardizedLocation(_ url: URL) -> URL {
        guard url.isFileURL,
              var source = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let physical = URLComponents(url: url.standardizedFileURL, resolvingAgainstBaseURL: false) else {
            return url
        }
        source.percentEncodedPath = physical.percentEncodedPath
        return source.url ?? url
    }

    private static func normalizedArchiveSubpath(_ value: String) -> String {
        value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    private static func identityLocation(_ url: URL) -> URL {
        let location = standardizedLocation(url)
        guard location.isFileURL,
              var components = URLComponents(url: location, resolvingAgainstBaseURL: false) else {
            return location
        }
        // A trailing physical directory separator does not create another browsing location.
        if components.percentEncodedPath.count > 1 && components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        var items = components.queryItems ?? []
        let indices = items.indices.filter { items[$0].name == "subpath" }
        // Preserve ambiguous/unknown query representations rather than choosing a silent winner.
        guard indices.count == 1, let value = items[indices[0]].value else {
            return components.url ?? location
        }
        let subpath = normalizedArchiveSubpath(value)
        if subpath.isEmpty {
            items.remove(at: indices[0])
        } else {
            items[indices[0]] = URLQueryItem(name: "subpath", value: subpath)
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url ?? location
    }

    package static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        identityLocation(lhs) == identityLocation(rhs)
    }

    private static func parentLocation(_ url: URL) -> URL? {
        let location = standardizedLocation(url)
        guard location.isFileURL,
              var components = URLComponents(url: location, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        let indices = items.indices.filter { items[$0].name == "subpath" }
        guard indices.count <= 1 else { return nil }
        if let index = indices.first {
            guard let value = items[index].value else { return nil }
            let subpath = normalizedArchiveSubpath(value)
            if !subpath.isEmpty {
                let parent = (subpath as NSString).deletingLastPathComponent
                if parent.isEmpty {
                    items.remove(at: index)
                } else {
                    items[index] = URLQueryItem(name: "subpath", value: parent)
                }
                components.queryItems = items.isEmpty ? nil : items
                return components.url
            }
            items.remove(at: index)
            components.queryItems = items.isEmpty ? nil : items
        }
        guard location.path != "/", location.pathComponents.count > 1,
              let physical = components.url else { return nil }
        return standardizedLocation(physical.deletingLastPathComponent())
    }

}
