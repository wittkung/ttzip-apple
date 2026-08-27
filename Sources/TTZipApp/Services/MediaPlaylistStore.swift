// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import Observation
import os.log

/// Defines the loop and repeat behavior for media playback.
public enum PlaylistRepeatMode: String, CaseIterable, Sendable {
    case off = "off"
    case one = "one"
    case all = "all"
    
    /// User-facing descriptive title.
    public var title: String {
        switch self {
        case .off:
            return "Repeat Off"
        case .one:
            return "Repeat Current"
        case .all:
            return "Repeat All"
        }
    }
    
    /// SF Symbol icon name corresponding to the mode.
    public var iconName: String {
        switch self {
        case .off:
            return "repeat"
        case .one:
            return "repeat.1"
        case .all:
            return "repeat"
        }
    }
    
    /// Cycles through repeat modes (.off -> .all -> .one -> .off).
    public mutating func toggle() {
        switch self {
        case .off:
            self = .all
        case .all:
            self = .one
        case .one:
            self = .off
        }
    }
}

/// Represents an individual media file item within a playlist.
public struct PlaylistItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let title: String
    public var duration: Double?
    public var fileSize: Int64?
    public var isCurrent: Bool
    public let format: String
    
    public init(
        id: String = UUID().uuidString,
        url: URL,
        title: String? = nil,
        duration: Double? = nil,
        fileSize: Int64? = nil,
        isCurrent: Bool = false,
        format: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.duration = duration
        self.fileSize = fileSize
        self.isCurrent = isCurrent
        self.format = format ?? url.pathExtension.lowercased()
    }
    
    public var formattedSize: String {
        guard let size = fileSize, size > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(url.standardizedFileURL.path)
    }
    
    public static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.url.standardizedFileURL.path == rhs.url.standardizedFileURL.path &&
        lhs.isCurrent == rhs.isCurrent &&
        lhs.duration == rhs.duration &&
        lhs.fileSize == rhs.fileSize
    }
}

/// Backward-compatible alias for playlist item type.
public typealias MediaPlaylistItem = PlaylistItem

/// ObservableObject state machine managing media playlist items, natural alphanumeric sorting,
/// sibling file discovery, repeat modes, track navigation, and automatic continuous playback.
@MainActor
public final class MediaPlaylistStore: ObservableObject {
    
    /// Shared singleton instance for coordinated playback across the application.
    public static let shared = MediaPlaylistStore()
    
    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MediaPlaylistStore")
    
    /// Standard multimedia file extensions supported for automatic playlist discovery.
    public static let supportedExtensions: Set<String> = [
        "mp4", "mkv", "mov", "avi", "webm", "flv", "wmv", "m4v", "ts",
        "mp3", "flac", "wav", "aac", "m4a"
    ]
    
    /// Array of items currently in the playlist.
    @Published public private(set) var items: [PlaylistItem] = []
    
    /// Index of the active item in `items`, or `nil` if the playlist is empty or no item is active.
    @Published public private(set) var currentIndex: Int? = nil
    
    /// Active playback repeat mode.
    @Published public var repeatMode: PlaylistRepeatMode = .off
    
    /// Flag controlling whether the store automatically advances to the next track on playback end.
    @Published public var isAutoPlayEnabled: Bool = true
    
    /// Callback triggered whenever a playlist item transition is requested.
    public var onPlayItemRequested: (@MainActor (PlaylistItem) -> Void)? = nil
    
    /// Public initializer.
    public init() {}
    
    // MARK: - Computed Properties
    
    /// Returns the currently active `PlaylistItem`, if available.
    public var currentItem: PlaylistItem? {
        guard let idx = currentIndex, items.indices.contains(idx) else { return nil }
        return items[idx]
    }
    
    /// URL of the currently active item, if available.
    public var currentURL: URL? {
        currentItem?.url
    }
    
    /// Total number of items in the playlist.
    public var count: Int {
        items.count
    }
    
    /// Indicates whether the playlist contains no items.
    public var isEmpty: Bool {
        items.isEmpty
    }
    
    /// Indicates whether a subsequent track is reachable given current position and repeat mode.
    public var hasNext: Bool {
        guard !items.isEmpty, let idx = currentIndex, items.indices.contains(idx) else {
            return false
        }
        switch repeatMode {
        case .off:
            return idx + 1 < items.count
        case .one:
            return true
        case .all:
            return items.count > 0
        }
    }
    
    /// Indicates whether a preceding track is reachable given current position and repeat mode.
    public var hasPrevious: Bool {
        guard !items.isEmpty, let idx = currentIndex, items.indices.contains(idx) else {
            return false
        }
        switch repeatMode {
        case .off:
            return idx > 0
        case .one:
            return true
        case .all:
            return items.count > 0
        }
    }
    
    // MARK: - Discovery & Population
    
    /// Discovers and populates playlist items around a focal media file.
    ///
    /// If `allSiblings` is provided and non-empty, items are filtered from that list.
    /// Otherwise, the parent directory of `currentURL` is queried directly.
    /// Discovered files are filtered against `supportedExtensions` and sorted via `localizedStandardCompare`.
    ///
    /// - Parameters:
    ///   - currentURL: The primary media file URL to focus and activate.
    ///   - allSiblings: Optional sibling URLs already known by the caller.
    public func populate(from currentURL: URL, allSiblings: [URL] = []) {
        var mediaURLs: [URL] = []
        
        if !allSiblings.isEmpty {
            mediaURLs = allSiblings.filter { url in
                Self.supportedExtensions.contains(url.pathExtension.lowercased())
            }
        } else {
            let parentDir = currentURL.deletingLastPathComponent()
            do {
                let fileURLs = try FileManager.default.contentsOfDirectory(
                    at: parentDir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                mediaURLs = fileURLs.filter { url in
                    Self.supportedExtensions.contains(url.pathExtension.lowercased())
                }
            } catch {
                logger.error("Failed to scan parent directory \(parentDir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                mediaURLs = [currentURL]
            }
        }
        
        let currentStandardized = currentURL.standardizedFileURL.path
        if !mediaURLs.contains(where: { $0.standardizedFileURL.path == currentStandardized }) {
            mediaURLs.append(currentURL)
        }
        
        mediaURLs.sort { lhs, rhs in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
        
        self.items = mediaURLs.map { url in
            let isCurr = (url.standardizedFileURL.path == currentStandardized)
            return PlaylistItem(
                url: url,
                isCurrent: isCurr
            )
        }
        
        self.currentIndex = self.items.firstIndex(where: { $0.url.standardizedFileURL.path == currentStandardized })
        logger.info("Populated playlist with \(self.items.count, privacy: .public) items. Current index: \(String(describing: self.currentIndex), privacy: .public)")
    }
    
    /// Convenience alias to populate playlist items from the directory of the target URL.
    public func populateFromDirectory(for url: URL) {
        populate(from: url)
    }
    
    /// Selects and activates the specified playlist item.
    public func select(item: PlaylistItem) {
        _ = playItem(item)
    }
    
    // MARK: - Navigation & Playback Flow
    
    /// Requests playback of the next track according to current position and repeat mode.
    ///
    /// - Returns: The newly activated `PlaylistItem`, or `nil` if at end with repeat disabled.
    @discardableResult
    public func playNext() -> PlaylistItem? {
        guard !items.isEmpty else { return nil }
        
        let nextIdx: Int
        if let curr = currentIndex {
            switch repeatMode {
            case .off:
                let candidate = curr + 1
                guard candidate < items.count else {
                    logger.info("Reached end of playlist with repeatMode .off")
                    return nil
                }
                nextIdx = candidate
            case .one:
                nextIdx = curr
            case .all:
                nextIdx = (curr + 1) % items.count
            }
        } else {
            nextIdx = 0
        }
        
        return playIndex(nextIdx)
    }
    
    /// Requests playback of the previous track according to current position and repeat mode.
    ///
    /// - Returns: The newly activated `PlaylistItem`, or `nil` if at beginning with repeat disabled.
    @discardableResult
    public func playPrevious() -> PlaylistItem? {
        guard !items.isEmpty else { return nil }
        
        let prevIdx: Int
        if let curr = currentIndex {
            switch repeatMode {
            case .off:
                let candidate = curr - 1
                guard candidate >= 0 else {
                    logger.info("At beginning of playlist with repeatMode .off")
                    return nil
                }
                prevIdx = candidate
            case .one:
                prevIdx = curr
            case .all:
                prevIdx = (curr - 1 + items.count) % items.count
            }
        } else {
            prevIdx = max(0, items.count - 1)
        }
        
        return playIndex(prevIdx)
    }
    
    /// Directs playback to the specified item index.
    ///
    /// - Parameter index: Zero-based item index within `items`.
    /// - Returns: The activated `PlaylistItem`, or `nil` if out of bounds.
    @discardableResult
    public func playIndex(_ index: Int) -> PlaylistItem? {
        guard items.indices.contains(index) else {
            logger.warning("playIndex out of bounds: \(index, privacy: .public), item count: \(self.items.count, privacy: .public)")
            return nil
        }
        
        for i in items.indices {
            items[i].isCurrent = (i == index)
        }
        self.currentIndex = index
        
        let targetItem = items[index]
        logger.info("Switched active playlist item [\(index, privacy: .public)]: \(targetItem.title, privacy: .public)")
        
        onPlayItemRequested?(targetItem)
        return targetItem
    }
    
    /// Directs playback to the specified `PlaylistItem`.
    ///
    /// - Parameter item: Item to locate and play.
    /// - Returns: The activated `PlaylistItem`, or `nil` if not found in the playlist.
    @discardableResult
    public func playItem(_ item: PlaylistItem) -> PlaylistItem? {
        if let idx = items.firstIndex(where: { $0.id == item.id || $0.url.standardizedFileURL.path == item.url.standardizedFileURL.path }) {
            return playIndex(idx)
        }
        return nil
    }
    
    /// Handles end-of-playback events reported by the media player engine.
    ///
    /// Automatically performs track transitions if `isAutoPlayEnabled` is active.
    ///
    /// - Returns: The next `PlaylistItem` scheduled for playback, or `nil` if auto-advance completed or is disabled.
    @discardableResult
    public func handlePlaybackEnded() -> PlaylistItem? {
        guard isAutoPlayEnabled, !items.isEmpty else {
            logger.info("handlePlaybackEnded: auto-play disabled or playlist empty")
            return nil
        }
        
        switch repeatMode {
        case .one:
            if let curr = currentIndex, items.indices.contains(curr) {
                let item = items[curr]
                onPlayItemRequested?(item)
                return item
            }
            return nil
        case .all, .off:
            return playNext()
        }
    }
    
    // MARK: - Mutation & State Management
    
    /// Replaces the playlist items and optionally sets the active index.
    public func setItems(_ newItems: [PlaylistItem], activeIndex: Int? = nil) {
        self.items = newItems
        if let activeIdx = activeIndex, newItems.indices.contains(activeIdx) {
            playIndex(activeIdx)
        } else {
            self.currentIndex = newItems.firstIndex(where: { $0.isCurrent })
        }
    }
    
    /// Appends a new item to the end of the playlist.
    public func appendItem(_ item: PlaylistItem) {
        items.append(item)
    }
    
    /// Removes an item at the given index, adjusting `currentIndex` accordingly.
    public func removeItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        let wasCurrent = (currentIndex == index)
        items.remove(at: index)
        
        if items.isEmpty {
            currentIndex = nil
        } else if wasCurrent {
            let nextIdx = min(index, items.count - 1)
            playIndex(nextIdx)
        } else if let curr = currentIndex, curr > index {
            currentIndex = curr - 1
        }
    }
    
    /// Updates the known duration for a given media URL.
    public func updateDuration(for url: URL, duration: Double) {
        let path = url.standardizedFileURL.path
        if let idx = items.firstIndex(where: { $0.url.standardizedFileURL.path == path }) {
            items[idx].duration = duration
        }
    }
    
    /// Resets and empties the playlist.
    public func clear() {
        items.removeAll()
        currentIndex = nil
    }
}
