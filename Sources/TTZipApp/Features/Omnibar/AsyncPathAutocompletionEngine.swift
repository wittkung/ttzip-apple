// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import TTZipCore
import AppKit
import TTZipUI
import TTZipPreviewKit

/// Observable service providing asynchronous directory item autocompletion with LRU micro-caching.
@Observable
@MainActor
public final class AsyncPathAutocompletionEngine {
    
    /// List of autocompleted path suggestions.
    public var suggestions: [AddressBarSuggestionItem] = []
    
    /// Indicates whether a directory scan or autocompletion query is actively in progress.
    public var isLoading: Bool = false
    
    /// In-memory LRU cache storing directory contents keyed by parent POSIX directory path.
    public let cache: ExplorerLRUCache<String, [DiskItemInfo]>
    
    /// Currently running background query task.
    private var activeTask: Task<Void, Never>?

    /// Monotonically increasing generation counter preventing cancelled queries from mutating state.
    private var queryGeneration: UInt64 = 0
    
    /// Maximum number of autocompletion suggestions returned to the UI.
    public static let maxSuggestionsCount: Int = 15
    
    /// Initializes the autocompletion engine with an optional LRU cache capacity (default 128).
    public init(cacheCapacity: Int = 128) {
        self.cache = ExplorerLRUCache<String, [DiskItemInfo]>(capacity: cacheCapacity)
    }
    
    /// Initiates an asynchronous query for matching directory and file items.
    ///
    /// - Parameters:
    ///   - rawInput: The user's typed path input.
    ///   - baseDirectory: Base directory URL used to resolve relative paths.
    public func query(rawInput: String, baseDirectory: URL) {
        activeTask?.cancel()
        activeTask = nil
        queryGeneration &+= 1
        let generation = queryGeneration

        let trimmed = rawInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            self.suggestions = []
            self.isLoading = false
            return
        }

        let (parentDir, prefix) = POSIXPathSanitizer.extractParentAndPrefix(rawInput: trimmed, relativeTo: baseDirectory)
        self.isLoading = true

        let localCache = self.cache
        let maxCount = Self.maxSuggestionsCount

        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            guard let items = Self.loadOrFetchDirectoryItems(parentDir: parentDir, cache: localCache) else {
                guard !Task.isCancelled else { return }
                await self?.finishQuery(suggestions: [], isLoading: false, generation: generation)
                return
            }
            guard !Task.isCancelled else { return }
            let mapped = Self.buildSuggestions(
                from: items,
                parentDir: parentDir,
                prefix: prefix,
                maxCount: maxCount
            )
            guard !Task.isCancelled else { return }
            await self?.finishQuery(suggestions: mapped, isLoading: false, generation: generation)
        }
    }

    nonisolated private static func loadOrFetchDirectoryItems(
        parentDir: String,
        cache: ExplorerLRUCache<String, [DiskItemInfo]>
    ) -> [DiskItemInfo]? {
        if let cached = cache.get(parentDir) {
            return cached
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentDir, isDirectory: &isDir), isDir.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: URL(fileURLWithPath: parentDir),
                  includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                  options: [.skipsPackageDescendants]
              ),
              !Task.isCancelled else {
            return nil
        }
        let scanned = contents.map { itemURL -> DiskItemInfo in
            let resValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            let isDir = resValues?.isDirectory ?? false
            let itemName = resValues?.name ?? itemURL.lastPathComponent
            return DiskItemInfo(url: itemURL, isDirectory: isDir, name: itemName)
        }
        cache.set(parentDir, value: scanned)
        return scanned
    }

    nonisolated private static func buildSuggestions(
        from items: [DiskItemInfo],
        parentDir: String,
        prefix: String,
        maxCount: Int
    ) -> [AddressBarSuggestionItem] {
        let isDotQuery = prefix.hasPrefix(".")
        let lowerPrefix = prefix.lowercased()
        let filtered = items.filter { item in
            guard isDotQuery || !item.name.hasPrefix(".") else { return false }
            return prefix.isEmpty || item.name.lowercased().hasPrefix(lowerPrefix)
        }
        let sorted = filtered.sorted { a, b in
            let rankA = a.isDirectory ? 0 : (a.isArchive ? 1 : 2)
            let rankB = b.isDirectory ? 0 : (b.isArchive ? 1 : 2)
            guard rankA == rankB else { return rankA < rankB }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return sorted.prefix(maxCount).map { item in
            makeSuggestionItem(for: item, parentDir: parentDir, prefix: prefix, lowerPrefix: lowerPrefix)
        }
    }

    nonisolated private static func makeSuggestionItem(
        for item: DiskItemInfo,
        parentDir: String,
        prefix: String,
        lowerPrefix: String
    ) -> AddressBarSuggestionItem {
        let iconName = item.isDirectory ? "folder.fill" : (item.isArchive ? "archivebox.fill" : "doc.fill")
        let hasPrefixMatch = !prefix.isEmpty && item.name.lowercased().hasPrefix(lowerPrefix)
        let highlightRange = hasPrefixMatch ? [0, prefix.count] : [0, 0]
        return AddressBarSuggestionItem(
            id: item.path,
            path: item.path,
            displayName: item.name,
            parentPath: parentDir,
            isDirectory: item.isDirectory,
            isArchive: item.isArchive,
            systemIconName: iconName,
            matchHighlightRange: highlightRange
        )
    }
    
    /// Asynchronously awaits completion of an autocompletion query and returns the resulting suggestions.
    @discardableResult
    public func queryAsync(rawInput: String, baseDirectory: URL) async -> [AddressBarSuggestionItem] {
        query(rawInput: rawInput, baseDirectory: baseDirectory)
        if let task = activeTask {
            _ = await task.value
        }
        return self.suggestions
    }
    
    /// Clears any active query task and resets suggestion state.
    public func clear() {
        activeTask?.cancel()
        activeTask = nil
        queryGeneration &+= 1
        self.suggestions = []
        self.isLoading = false
    }
    
    // MARK: - Private Helpers
    
    private func finishQuery(suggestions: [AddressBarSuggestionItem], isLoading: Bool, generation: UInt64) {
        guard !Task.isCancelled, self.queryGeneration == generation else { return }
        self.suggestions = suggestions
        self.isLoading = isLoading
    }
}
