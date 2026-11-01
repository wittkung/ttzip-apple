// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

extension FinderMillerColumnsView {
    
    func selectItem(item: DiskItemInfo, columnIndex: Int, isCommand: Bool = false, isShift: Bool = false, dirURL: URL? = nil) {
        hoveredColumnIndex = columnIndex
        let currentSort = perColumnSortOption[columnIndex] ?? sortOption
        let cacheKey = dirURL.map { "\($0.absoluteString)_\(currentSort.rawValue)" } ?? ""
        let items = cachedColumnItems[cacheKey] ?? []
        
        if isCommand {
            if multiSelectedPaths.contains(item.path) {
                multiSelectedPaths.remove(item.path)
            } else {
                multiSelectedPaths.insert(item.path)
            }
        } else if isShift, !items.isEmpty,
                  let lastPath = selectedPaths[columnIndex],
                  let lastIndex = items.firstIndex(where: { $0.path == lastPath }),
                  let currentIndex = items.firstIndex(where: { $0.path == item.path }) {
            let start = min(lastIndex, currentIndex)
            let end = max(lastIndex, currentIndex)
            for i in start...end {
                multiSelectedPaths.insert(items[i].path)
            }
        } else {
            multiSelectedPaths = [item.path]
        }
        
        selectedPaths[columnIndex] = item.path
        for key in selectedPaths.keys where key > columnIndex {
            selectedPaths.removeValue(forKey: key)
        }
        selectedItem = item
        activeViewModel?.selectionState.select(item)
        onSelectItem?(item)
        
        let isEncrypted = item.isEncryptedLockItem
        if isEncrypted {
            if item.kindText == "Access Authorization" {
                let (originalPath, _) = parseVirtualURL(item.path)
                let u = URL(string: originalPath) ?? URL(fileURLWithPath: originalPath)
                Task {
                    await RootFolderAccessManager.shared.requestRootAccess(for: u)
                    await MainActor.run {
                        self.refreshKey = UUID()
                    }
                }
                return
            }
            
            let (archivePath, _) = parseVirtualURL(item.path)
            NotificationCenter.default.post(name: NSNotification.Name("TTZipEncryptedArchivePromptRequired"), object: archivePath)
            return
        }
        
        if isCommand || isShift { return }
        let location = URL(string: item.path).flatMap { $0.scheme == nil ? nil : $0 }
            ?? URL(fileURLWithPath: item.path)
        let virtual = URLComponents(url: location, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "subpath" }) == true
        if !virtual, !item.isDirectory, Self.isNavigableArchiveFolder(item) {
            guard let owner = activeViewModel else {
                onSelectArchive?(item.path)
                return
            }
            if owner.explorerState.acceptedArchiveProjection(
                for: owner.navigationState.activeSessionID, archivePath: location.path
            ) == nil {
                withAnimation(Self.columnSpringAnimation) {
                    columnPaths = Array(columnPaths.prefix(columnIndex + 1))
                }
                owner.openArchiveAsFolder(url: location)
                return
            }
        }
        if virtual, let owner = activeViewModel {
            let (archivePath, subpath) = parseVirtualURL(item.path)
            owner.selectArchiveEntry(path: subpath, inArchive: archivePath)
        }

        let nextPaths = Self.nextColumnPaths(currentPaths: columnPaths, columnIndex: columnIndex, item: item)
        let openedChildColumn = nextPaths.count > columnIndex + 1 ? nextPaths.last : nil
        
        let previousColumnCount = columnPaths.count
        if nextPaths != columnPaths {
            withAnimation(Self.columnSpringAnimation) {
                columnPaths = nextPaths
            }
        }
        let fallbackDir = (URL(string: item.path)?.scheme != nil ? URL(string: item.path) : URL(fileURLWithPath: item.path))?.deletingLastPathComponent()
        let deepestDir = nextPaths.last ?? fallbackDir
        activeViewModel?.activeBrowsingDirectory = deepestDir == rootDirectory ? nil : deepestDir
        onColumnStateChanged?(columnPaths, selectedPaths, selectedItem)
        
        // Navigation owns location/history; these columns are only its presentation.
        if let target = openedChildColumn {
            activeViewModel?.navigationState.currentDirectory = target
        } else if let dirURL {
            activeViewModel?.navigationState.currentDirectory = dirURL
        }

        // Precise horizontal scroll targeting matching macOS Finder ergonomics:
        // 1. Expanding deeper to the right: reveal newly opened child column at trailing.
        // 2. Clicking an upper/earlier column: anchor clicked column to leading to maintain rock-solid stability.
        if let child = openedChildColumn, columnIndex == previousColumnCount - 1 {
            scrollTarget = HorizontalScrollTarget(id: child.absoluteString, anchor: .trailing)
        } else if columnIndex < previousColumnCount - 1 {
            if nextPaths.count <= 3 {
                scrollTarget = HorizontalScrollTarget(id: nextPaths[0].absoluteString, anchor: .leading)
            } else {
                scrollTarget = HorizontalScrollTarget(id: columnPaths[columnIndex].absoluteString, anchor: .leading)
            }
        }
    }

    /// Explicit double-click activation handler for a Miller column row.
    /// Keeps directories and navigable archives idempotent with Miller column navigation,
    /// while dispatching files and virtual archive file entries through `AppViewState.activateExplorerItem`.
    func activateItem(item: DiskItemInfo, columnIndex: Int, dirURL: URL? = nil) {
        hoveredColumnIndex = columnIndex
        if item.isEncryptedLockItem {
            selectItem(item: item, columnIndex: columnIndex, isCommand: false, isShift: false, dirURL: dirURL)
            return
        }
        let location = Self.resolvedItemLocation(for: item.path)
        let isVirtual = Self.isVirtualSubpathLocation(location)

        if item.isBrowsableDirectory {
            activateDirectoryInColumn(item: item, columnIndex: columnIndex, dirURL: dirURL)
            return
        }
        if !isVirtual, Self.isNavigableArchiveFolder(item) {
            activateNavigableArchiveInColumn(item: item, location: location, columnIndex: columnIndex, dirURL: dirURL)
            return
        }
        if selectedPaths[columnIndex] != item.path || selectedItem?.path != item.path {
            selectItem(item: item, columnIndex: columnIndex, isCommand: false, isShift: false, dirURL: dirURL)
        }
        if let owner = activeViewModel {
            Task { @MainActor in
                _ = await owner.activateExplorerItem(item)
            }
        } else if !isVirtual {
            onPreviewFile?(item.path)
        }
    }

    private func activateDirectoryInColumn(item: DiskItemInfo, columnIndex: Int, dirURL: URL?) {
        let expectedNext = Self.nextColumnPaths(currentPaths: columnPaths, columnIndex: columnIndex, item: item)
        if selectedPaths[columnIndex] != item.path || columnPaths != expectedNext {
            selectItem(item: item, columnIndex: columnIndex, isCommand: false, isShift: false, dirURL: dirURL)
        }
    }

    private func activateNavigableArchiveInColumn(
        item: DiskItemInfo,
        location: URL,
        columnIndex: Int,
        dirURL: URL?
    ) {
        if selectedPaths[columnIndex] != item.path {
            selectItem(item: item, columnIndex: columnIndex, isCommand: false, isShift: false, dirURL: dirURL)
            return
        }
        guard let owner = activeViewModel else {
            onSelectArchive?(item.path)
            return
        }
        if owner.explorerState.acceptedArchiveProjection(
            for: owner.navigationState.activeSessionID, archivePath: location.path
        ) == nil {
            owner.openArchiveAsFolder(url: location)
        }
    }

    private static func resolvedItemLocation(for rawPath: String) -> URL {
        URL(string: rawPath).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(fileURLWithPath: rawPath)
    }

    private static func isVirtualSubpathLocation(_ location: URL) -> Bool {
        URLComponents(url: location, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "subpath" }) == true
    }
    
    func selectAllInActiveColumn() {
        let targetIndex = hoveredColumnIndex ?? (columnPaths.count - 1)
        guard targetIndex < columnPaths.count else { return }
        let targetURL = columnPaths[targetIndex]
        let currentSort = perColumnSortOption[targetIndex] ?? sortOption
        let cacheKey = "\(targetURL.absoluteString)_\(currentSort.rawValue)"
        guard let items = cachedColumnItems[cacheKey], !items.isEmpty else { return }
        
        multiSelectedPaths = Set(items.map { $0.path })
        if let first = items.first {
            selectedPaths[targetIndex] = first.path
            selectedItem = first
            activeViewModel?.selectionState.select(first)
            onSelectItem?(first)
        }
    }
    
    func parseVirtualURL(_ path: String) -> (archivePath: String, subpath: String) {
        if let u = URL(string: path),
           let comp = URLComponents(url: u, resolvingAgainstBaseURL: false),
           let sub = comp.queryItems?.first(where: { $0.name == "subpath" })?.value {
            var arch = u.path
            if arch.isEmpty { arch = path }
            return (arch, sub)
        }
        return (path, "")
    }
}
