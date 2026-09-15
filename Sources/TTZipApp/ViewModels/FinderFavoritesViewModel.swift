// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import Foundation
import Observation
import SwiftUI
import TTZipCore
import TTZipUI

/// Section classifier for the Finder favorites sidebar.
public enum FinderFavoritesSidebarSection: Hashable, Sendable {
    case pinned
    case favorites
    case locations
}

/// State machine driving the Finder favorites, custom shortcuts, mounted volumes, and external devices.
@MainActor
@Observable
public final class FinderFavoritesViewModel {
    /// Shared singleton instance for unified sidebar state across windows.
    public static let shared = FinderFavoritesViewModel()
    
    /// User-pinned custom shortcuts persisted in AppStorage / UserDefaults.
    public var customPinnedPaths: [String] = []
    
    /// Dynamic Finder favorites loaded from macOS sharedfilelist or standard directories.
    public var dynamicFinderFavorites: [FinderFavoriteItem] = []
    
    /// Flag indicating whether custom SFL favorites were successfully authorized and resolved.
    public var hasResolvedCustomFavorites: Bool = false
    
    /// Currently hovered sidebar item path for micro-interaction states.
    public var hoveredItemPath: String? = nil
    
    /// Currently active navigation section.
    public var activeSection: FinderFavoritesSidebarSection? = nil
    
    /// State toggle for folder drag-and-drop targeting.
    public var isDropTargeted: Bool = false
    
    /// Controls presentation of the wireless Android discovery sheet.
    public var showWirelessDiscoverySheet: Bool = false
    
    /// Loading indicator state.
    public var isLoading: Bool = false
    
    private let storageKey = "TTZipCustomShortcutFolderPaths"
    
    public init() {
        loadCustomPinnedPaths()
        // Synchronous initial load to prevent empty frames / race condition on view mount
        let initialResult = FinderFavoritesReader.fetchFavoritesResult()
        self.dynamicFinderFavorites = initialResult.items
        self.hasResolvedCustomFavorites = initialResult.hasResolvedCustomFavorites
    }
    
    // MARK: - Favorites Loading
    
    /// Refreshes macOS Finder favorites asynchronously on a background utility queue and publishes to MainActor.
    public func loadFavorites() {
        isLoading = true
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                FinderFavoritesReader.fetchFavoritesResult()
            }.value
            self.dynamicFinderFavorites = result.items
            self.hasResolvedCustomFavorites = result.hasResolvedCustomFavorites
            self.isLoading = false
        }
    }
    
    // MARK: - Custom Pinned Paths Management
    
    private func loadCustomPinnedPaths() {
        guard let jsonStr = UserDefaults.standard.string(forKey: storageKey),
              let data = jsonStr.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            self.customPinnedPaths = []
            return
        }
        self.customPinnedPaths = list
    }
    
    public func saveCustomPinnedPaths(_ paths: [String]) {
        self.customPinnedPaths = paths
        if let data = try? JSONEncoder().encode(paths),
           let jsonStr = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(jsonStr, forKey: storageKey)
        }
    }
    
    public func addCustomFolder(urls: [URL]) {
        var current = customPinnedPaths
        for url in urls {
            let canonical = url.standardizedFileURL.path
            if !current.contains(canonical) {
                current.append(canonical)
            }
        }
        saveCustomPinnedPaths(current)
    }
    
    public func removeCustomPinnedFolder(path: String) {
        var current = customPinnedPaths
        current.removeAll { $0 == path }
        saveCustomPinnedPaths(current)
    }
    
    // MARK: - Selection & State Invariants
    
    public func isCurrentPath(_ path: String, currentDirectory: URL) -> Bool {
        currentDirectory.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
    }
    
    public func isRowSelected(
        path: String,
        section: FinderFavoritesSidebarSection,
        currentDirectory: URL,
        mountedVolumes: [MountedVolumeItem]
    ) -> Bool {
        guard isCurrentPath(path, currentDirectory: currentDirectory) else { return false }
        let currentNorm = currentDirectory.standardizedFileURL.path
        let inPinned = customPinnedPaths.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == currentNorm }
        let inFavorites = dynamicFinderFavorites.contains { item in
            !mountedVolumes.contains { $0.path == item.path } &&
            URL(fileURLWithPath: item.path).standardizedFileURL.path == currentNorm
        }
        if inPinned && inFavorites {
            return activeSection.map { $0 == section } ?? (section == .pinned)
        }
        return true
    }
    
    // MARK: - Finder SFL Authorization
    
    public func promptAuthorizeFinderFavorites(
        isChinese: Bool,
        completion: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = isChinese ? "同步访达个人收藏" : "Sync macOS Finder Favorites"
        alert.informativeText = isChinese
            ? "受 macOS 隐私与安全性机制保护，TTZip 需要读取您的访达共享文件列表。\n\n在接下来的系统窗口中已为您预选对应目录，请直接点击右下角「授权同步」即可完成导入。"
            : "Due to macOS privacy protections, TTZip needs access to your Finder shared file list.\n\nThe folder will be targeted in the dialog—simply click 'Authorize Sync' to import."
        alert.addButton(withTitle: isChinese ? "前往授权" : "Authorize")
        alert.addButton(withTitle: isChinese ? "取消" : "Cancel")
        alert.alertStyle = .informational
        
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        
        let home: String = {
            if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
                return FileManager.default.string(withFileSystemRepresentation: dir, length: strlen(dir))
            }
            return NSHomeDirectory()
        }()
        let sflPath = (home as NSString).appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: sflPath)
        panel.prompt = isChinese ? "授权同步" : "Authorize Sync"
        panel.message = isChinese
            ? "请直接点击右下角「授权同步」完成访达个人收藏导入："
            : "Click 'Authorize Sync' to import your macOS Finder favorites:"
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            FinderFavoritesReader.saveSecurityScopedBookmark(for: selectedURL)
            loadFavorites()
            completion()
        }
    }
}
