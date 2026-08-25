// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore
import AppKit

/// Observable service providing asynchronous directory item autocompletion with LRU micro-caching.
@MainActor
public final class AsyncPathAutocompletionEngine: ObservableObject {
    
    /// Published list of autocompleted path suggestions.
    @Published public var suggestions: [PathSuggestionItem] = []
    
    /// Indicates whether a directory scan or autocompletion query is actively in progress.
    @Published public var isLoading: Bool = false
    
    /// In-memory LRU cache storing directory contents keyed by parent POSIX directory path.
    public let cache: ExplorerLRUCache<String, [DiskItemInfo]>
    
    /// Currently running background query task.
    private var activeTask: Task<Void, Never>?
    
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
        
        let trimmed = rawInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            self.suggestions = []
            self.isLoading = false
            return
        }
        
        let (parentDir, prefix) = POSIXPathSanitizer.extractParentAndPrefix(rawInput: trimmed, baseDirectory: baseDirectory)
        self.isLoading = true
        
        let maxCount = Self.maxSuggestionsCount
        
        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            
            let matchedPaths = autocompleteDiskPath(
                rawInput: trimmed,
                baseDirectory: baseDirectory.path,
                maxResults: UInt32(maxCount)
            )
            
            guard !Task.isCancelled else { return }
            
            let mapped = matchedPaths.map { itemPath -> PathSuggestionItem in
                let url = URL(fileURLWithPath: itemPath)
                let name = url.lastPathComponent
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir)
                let isDirectory = isDir.boolValue
                let ext = url.pathExtension.lowercased()
                let isArchive = ArchiveCompressionFormat(rawValue: ext) != nil
                
                let iconName: String
                if isDirectory {
                    iconName = "folder.fill"
                } else if isArchive {
                    iconName = "archivebox.fill"
                } else {
                    iconName = "doc.fill"
                }
                
                let highlightRange: [Int]
                if !prefix.isEmpty && name.lowercased().hasPrefix(prefix.lowercased()) {
                    highlightRange = [0, prefix.count]
                } else {
                    highlightRange = [0, 0]
                }
                
                return PathSuggestionItem(
                    id: itemPath,
                    path: itemPath,
                    displayName: name,
                    parentPath: parentDir,
                    isDirectory: isDirectory,
                    isArchive: isArchive,
                    systemIconName: iconName,
                    matchHighlightRange: highlightRange
                )
            }
            
            await self?.finishQuery(suggestions: mapped, isLoading: false)
        }
    }
    
    /// Asynchronously awaits completion of an autocompletion query and returns the resulting suggestions.
    @discardableResult
    public func queryAsync(rawInput: String, baseDirectory: URL) async -> [PathSuggestionItem] {
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
        self.suggestions = []
        self.isLoading = false
    }
    
    // MARK: - Private Helpers
    
    private func finishQuery(suggestions: [PathSuggestionItem], isLoading: Bool) {
        self.suggestions = suggestions
        self.isLoading = isLoading
    }
}
