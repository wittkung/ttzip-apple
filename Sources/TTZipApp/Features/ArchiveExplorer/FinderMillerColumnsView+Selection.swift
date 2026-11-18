// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

extension FinderMillerColumnsView {

    public static func resolveMultiSelectedItems(
        for multiSelectedPaths: Set<String>,
        in cachedItems: [DiskItemInfo],
        fallbackItem: DiskItemInfo? = nil
    ) -> [DiskItemInfo] {
        guard !multiSelectedPaths.isEmpty else { return [] }
        var resolved = cachedItems.filter { multiSelectedPaths.contains($0.path) }
        if resolved.count < multiSelectedPaths.count {
            let knownPaths = Set(resolved.map(\.path))
            for path in multiSelectedPaths.sorted() where !knownPaths.contains(path) {
                if let fallbackItem, fallbackItem.path == path {
                    resolved.append(fallbackItem)
                } else {
                    resolved.append(DiskItemInfo(url: URL(fileURLWithPath: path)))
                }
            }
        }
        return resolved
    }

    public static func applyColumnItemSelection(
        item: DiskItemInfo,
        columnIndex: Int,
        isCommand: Bool = false,
        isShift: Bool = false,
        cachedItems: [DiskItemInfo],
        selectedPaths: inout [Int: String],
        multiSelectedPaths: inout Set<String>,
        selectedItem: inout DiskItemInfo?,
        viewModel: AppViewState?,
        onSelectItem: ((DiskItemInfo) -> Void)? = nil
    ) {
        if isCommand {
            if multiSelectedPaths.isEmpty, let existing = selectedPaths[columnIndex] {
                multiSelectedPaths.insert(existing)
            }
            if multiSelectedPaths.contains(item.path) {
                multiSelectedPaths.remove(item.path)
            } else {
                multiSelectedPaths.insert(item.path)
            }
        } else if isShift, !cachedItems.isEmpty,
                  let lastPath = selectedPaths[columnIndex],
                  let lastIndex = cachedItems.firstIndex(where: { $0.path == lastPath }),
                  let currentIndex = cachedItems.firstIndex(where: { $0.path == item.path }) {
            let start = min(lastIndex, currentIndex)
            let end = max(lastIndex, currentIndex)
            for idx in start...end {
                multiSelectedPaths.insert(cachedItems[idx].path)
            }
        } else {
            multiSelectedPaths = [item.path]
        }

        for key in selectedPaths.keys where key > columnIndex {
            selectedPaths.removeValue(forKey: key)
        }

        let resolvedItems = resolveMultiSelectedItems(
            for: multiSelectedPaths,
            in: cachedItems,
            fallbackItem: item
        )
        if resolvedItems.count > 1 {
            selectedPaths[columnIndex] = item.path
            selectedItem = item
            onSelectItem?(item)
            viewModel?.selectionState.selectMultiple(resolvedItems)
        } else if let single = resolvedItems.first {
            selectedPaths[columnIndex] = single.path
            selectedItem = single
            onSelectItem?(single)
            viewModel?.selectionState.select(single)
        } else {
            selectedPaths.removeValue(forKey: columnIndex)
            selectedItem = nil
            viewModel?.selectionState.select(nil)
        }
    }

    public static func applyPostSelectionColumnNavigation(
        item: DiskItemInfo,
        columnIndex: Int,
        dirURL: URL?,
        rootDirectory: URL,
        columnPaths: inout [URL],
        scrollTarget: inout HorizontalScrollTarget?,
        viewModel: AppViewState?
    ) {
        let nextPaths = Self.nextColumnPaths(currentPaths: columnPaths, columnIndex: columnIndex, item: item)
        let openedChildColumn = nextPaths.count > columnIndex + 1 ? nextPaths.last : nil
        let previousColumnCount = columnPaths.count
        if nextPaths != columnPaths {
            withAnimation(Self.columnSpringAnimation) {
                columnPaths = nextPaths
            }
        }
        let fallbackDir = Self.resolvedItemLocation(for: item.path).deletingLastPathComponent()
        let deepestDir = nextPaths.last ?? fallbackDir
        let rootColumnDir = nextPaths.first ?? rootDirectory
        if let openedChildColumn {
            viewModel?.activeBrowsingDirectory = openedChildColumn
        } else {
            viewModel?.activeBrowsingDirectory = deepestDir == rootColumnDir ? nil : deepestDir
        }

        if let child = openedChildColumn, columnIndex == previousColumnCount - 1 {
            scrollTarget = HorizontalScrollTarget(id: child.absoluteString, anchor: .trailing)
        } else if columnIndex < previousColumnCount - 1 {
            if let child = openedChildColumn {
                scrollTarget = HorizontalScrollTarget(id: child.absoluteString, anchor: .trailing)
            } else if nextPaths.count <= 3 {
                scrollTarget = HorizontalScrollTarget(id: nextPaths[0].absoluteString, anchor: .leading)
            } else {
                scrollTarget = HorizontalScrollTarget(id: columnPaths[columnIndex].absoluteString, anchor: .leading)
            }
        }

        if let target = openedChildColumn {
            viewModel?.navigationState.currentDirectory = target
        } else if let dirURL {
            viewModel?.navigationState.currentDirectory = dirURL
        }
    }

    private static func isNewlyOpenedChildColumnSelection(
        existingIndex: Int,
        standardizedNewRoot: URL,
        selectedPaths: [Int: String],
        selectedItem: DiskItemInfo?
    ) -> Bool {
        guard existingIndex > 0, selectedPaths[existingIndex] == nil else { return false }
        if let item = selectedItem,
           Self.resolvedItemLocation(for: item.path).standardizedFileURL == standardizedNewRoot {
            return true
        }
        if let parentSelected = selectedPaths[existingIndex - 1],
           Self.resolvedItemLocation(for: parentSelected).standardizedFileURL == standardizedNewRoot {
            return true
        }
        return false
    }

    private static func preserveNewlyOpenedChildColumnSelection(
        existingIndex: Int,
        newRoot: URL,
        columnPaths: inout [URL],
        selectedPaths: inout [Int: String],
        multiSelectedPaths: inout Set<String>,
        selectedItem: inout DiskItemInfo?,
        scrollTarget: inout HorizontalScrollTarget?,
        viewModel: AppViewState?
    ) {
        columnPaths = Array(columnPaths.prefix(existingIndex + 1))
        for key in selectedPaths.keys where key > existingIndex {
            selectedPaths.removeValue(forKey: key)
        }
        let itemToPreserve = selectedItem ?? DiskItemInfo(url: newRoot.standardizedFileURL)
        selectedItem = itemToPreserve
        if multiSelectedPaths.isEmpty {
            multiSelectedPaths = [itemToPreserve.path]
        }
        if viewModel?.selectionState.selectedDiskItem?.path != itemToPreserve.path {
            viewModel?.selectionState.select(itemToPreserve)
        }
        viewModel?.activeBrowsingDirectory = newRoot
        scrollTarget = HorizontalScrollTarget(id: newRoot.absoluteString, anchor: .trailing)
    }

    private static func lookupCachedColumnEntries(
        for columnURL: URL,
        sort: DiskSortOption,
        in cachedColumnItems: [String: [DiskItemInfo]]
    ) -> [DiskItemInfo] {
        let cacheKey = "\(columnURL.absoluteString)_\(sort.rawValue)"
        if let entries = cachedColumnItems[cacheKey] { return entries }
        if let entries = cachedColumnItems[columnURL.path] { return entries }
        if let entries = cachedColumnItems[columnURL.standardizedFileURL.path] { return entries }
        return cachedColumnItems[columnURL.absoluteString] ?? []
    }

    private static func restoreItemFromColumnCache(
        preservedPath: String,
        columnURL: URL,
        sort: DiskSortOption,
        cachedColumnItems: [String: [DiskItemInfo]],
        currentSelected: DiskItemInfo?
    ) -> DiskItemInfo {
        let cachedItems = lookupCachedColumnEntries(for: columnURL, sort: sort, in: cachedColumnItems)
        let standardizedPreserved = Self.resolvedItemLocation(for: preservedPath).standardizedFileURL.path
        if let match = cachedItems.first(where: {
            $0.path == preservedPath || Self.resolvedItemLocation(for: $0.path).standardizedFileURL.path == standardizedPreserved
        }) {
            return match
        }
        if let currentSelected, currentSelected.path == preservedPath {
            return currentSelected
        }
        return DiskItemInfo(url: URL(fileURLWithPath: preservedPath))
    }

    public static func applyExistingColumnRootChange(
        existingIndex: Int,
        newRoot: URL,
        sortOption: DiskSortOption,
        perColumnSortOption: [Int: DiskSortOption],
        cachedColumnItems: [String: [DiskItemInfo]],
        columnPaths: inout [URL],
        selectedPaths: inout [Int: String],
        multiSelectedPaths: inout Set<String>,
        selectedItem: inout DiskItemInfo?,
        scrollTarget: inout HorizontalScrollTarget?,
        viewModel: AppViewState?,
        onSelectItem: ((DiskItemInfo) -> Void)? = nil
    ) {
        if isNewlyOpenedChildColumnSelection(
            existingIndex: existingIndex,
            standardizedNewRoot: newRoot.standardizedFileURL,
            selectedPaths: selectedPaths,
            selectedItem: selectedItem
        ) {
            preserveNewlyOpenedChildColumnSelection(
                existingIndex: existingIndex,
                newRoot: newRoot,
                columnPaths: &columnPaths,
                selectedPaths: &selectedPaths,
                multiSelectedPaths: &multiSelectedPaths,
                selectedItem: &selectedItem,
                scrollTarget: &scrollTarget,
                viewModel: viewModel
            )
            return
        }

        let previousChildPath = (existingIndex + 1 < columnPaths.count) ? columnPaths[existingIndex + 1].path : nil
        let preservedPath = selectedPaths[existingIndex] ?? previousChildPath
        columnPaths = Array(columnPaths.prefix(existingIndex + 1))
        for key in selectedPaths.keys where key > existingIndex {
            selectedPaths.removeValue(forKey: key)
        }
        if let preservedPath {
            selectedPaths[existingIndex] = preservedPath
            let sort = perColumnSortOption[existingIndex] ?? sortOption
            let restoredItem = restoreItemFromColumnCache(
                preservedPath: preservedPath,
                columnURL: newRoot,
                sort: sort,
                cachedColumnItems: cachedColumnItems,
                currentSelected: selectedItem
            )
            selectedItem = restoredItem
            multiSelectedPaths = [restoredItem.path]
            onSelectItem?(restoredItem)
            viewModel?.selectionState.select(restoredItem)
        } else {
            selectedItem = nil
            multiSelectedPaths = []
            viewModel?.selectionState.select(nil)
        }
        scrollTarget = HorizontalScrollTarget(id: newRoot.absoluteString, anchor: .leading)
        viewModel?.activeBrowsingDirectory = existingIndex == 0 ? nil : newRoot
    }

    private func applyExplicitDescendantReveal(under newRoot: URL) -> Bool {
        let explicitTarget = initialSelectedPath ?? activeViewModel?.initialSelectedFilePath
        guard let target = explicitTarget, !target.isEmpty,
              let resolved = Self.resolveValidDescendantHierarchy(for: target, under: newRoot) else {
            return false
        }
        columnPaths = resolved.columns
        selectedPaths = resolved.selected
        multiSelectedPaths = [resolved.item.path]
        selectedItem = resolved.item
        activeViewModel?.initialSelectedFilePath = nil
        onSelectItem?(resolved.item)
        activeViewModel?.selectionState.select(resolved.item)
        let anchor: UnitPoint = resolved.columns.count > 1 ? .trailing : .leading
        let targetColumnURL = resolved.columns.last ?? newRoot
        scrollTarget = HorizontalScrollTarget(id: targetColumnURL.absoluteString, anchor: anchor)
        perColumnSortOption = [:]
        activeViewModel?.activeBrowsingDirectory = resolved.columns.last == newRoot ? nil : resolved.columns.last
        onColumnStateChanged?(columnPaths, selectedPaths, selectedItem)
        return true
    }

    func handleRootDirectoryChange(oldRoot: URL, newRoot: URL) {
        guard oldRoot != newRoot else { return }
        if restoreArchiveColumns(for: newRoot) {
            onColumnStateChanged?(columnPaths, selectedPaths, selectedItem)
            return
        }
        if applyExplicitDescendantReveal(under: newRoot) {
            return
        }

        if let existingIndex = columnPaths.firstIndex(where: {
            $0 == newRoot || $0.standardizedFileURL == newRoot.standardizedFileURL
        }) {
            withAnimation(Self.columnSpringAnimation) {
                Self.applyExistingColumnRootChange(
                    existingIndex: existingIndex,
                    newRoot: newRoot,
                    sortOption: sortOption,
                    perColumnSortOption: perColumnSortOption,
                    cachedColumnItems: cachedColumnItems,
                    columnPaths: &columnPaths,
                    selectedPaths: &selectedPaths,
                    multiSelectedPaths: &multiSelectedPaths,
                    selectedItem: &selectedItem,
                    scrollTarget: &scrollTarget,
                    viewModel: activeViewModel,
                    onSelectItem: onSelectItem
                )
            }
            onColumnStateChanged?(columnPaths, selectedPaths, selectedItem)
            return
        }

        selectedPaths = [:]
        multiSelectedPaths = []
        columnPaths = [newRoot]
        selectedItem = nil
        activeViewModel?.selectionState.clear()
        scrollTarget = HorizontalScrollTarget(id: newRoot.absoluteString, anchor: .leading)
        perColumnSortOption = [:]
        activeViewModel?.activeBrowsingDirectory = nil
        onColumnStateChanged?(columnPaths, selectedPaths, selectedItem)
    }

    func selectItem(item: DiskItemInfo, columnIndex: Int, isCommand: Bool = false, isShift: Bool = false, dirURL: URL? = nil) {
        hoveredColumnIndex = columnIndex
        let effectiveDirURL = dirURL ?? (columnPaths.indices.contains(columnIndex) ? columnPaths[columnIndex] : nil)
        let items = resolveCachedColumnItems(columnIndex: columnIndex, dirURL: effectiveDirURL)

        Self.applyColumnItemSelection(
            item: item,
            columnIndex: columnIndex,
            isCommand: isCommand,
            isShift: isShift,
            cachedItems: items,
            selectedPaths: &selectedPaths,
            multiSelectedPaths: &multiSelectedPaths,
            selectedItem: &selectedItem,
            viewModel: activeViewModel,
            onSelectItem: onSelectItem
        )

        if handleEncryptedSelectionIfNeeded(item) { return }
        if isCommand || isShift {
            onColumnStateChanged?(columnPaths, selectedPaths, selectedItem)
            return
        }
        if routeArchiveOrVirtualSelectionIfNeeded(item: item, columnIndex: columnIndex) {
            return
        }

        Self.applyPostSelectionColumnNavigation(
            item: item,
            columnIndex: columnIndex,
            dirURL: effectiveDirURL,
            rootDirectory: rootDirectory,
            columnPaths: &columnPaths,
            scrollTarget: &scrollTarget,
            viewModel: activeViewModel
        )
        onColumnStateChanged?(columnPaths, selectedPaths, selectedItem)
    }

    private func resolveCachedColumnItems(columnIndex: Int, dirURL: URL?) -> [DiskItemInfo] {
        let currentSort = perColumnSortOption[columnIndex] ?? sortOption
        guard let dirURL else { return [] }
        let cacheKey = "\(dirURL.absoluteString)_\(currentSort.rawValue)"
        return cachedColumnItems[cacheKey]
            ?? cachedColumnItems[dirURL.path]
            ?? cachedColumnItems[dirURL.standardizedFileURL.path]
            ?? cachedColumnItems[dirURL.absoluteString]
            ?? []
    }

    private func routeArchiveOrVirtualSelectionIfNeeded(item: DiskItemInfo, columnIndex: Int) -> Bool {
        let location = Self.resolvedItemLocation(for: item.path)
        let virtual = Self.isVirtualSubpathLocation(location)
        if !virtual, !item.isDirectory, Self.isNavigableArchiveFolder(item) {
            guard let owner = activeViewModel else {
                onSelectArchive?(item.path)
                return true
            }
            if owner.explorerState.acceptedArchiveProjection(
                for: owner.navigationState.activeSessionID, archivePath: location.path
            ) == nil {
                withAnimation(Self.columnSpringAnimation) {
                    columnPaths = Array(columnPaths.prefix(columnIndex + 1))
                }
                owner.openArchiveAsFolder(url: location)
                return true
            }
        }
        if virtual, let owner = activeViewModel {
            let (archivePath, subpath) = parseVirtualURL(item.path)
            owner.selectArchiveEntry(path: subpath, inArchive: archivePath)
        }
        return false
    }

    private func handleEncryptedSelectionIfNeeded(_ item: DiskItemInfo) -> Bool {
        guard item.isEncryptedLockItem else { return false }
        if item.kindText == "Access Authorization" {
            let (originalPath, _) = parseVirtualURL(item.path)
            let u = URL(string: originalPath) ?? URL(fileURLWithPath: originalPath)
            Task {
                await RootFolderAccessManager.shared.requestRootAccess(for: u)
                await MainActor.run {
                    self.refreshKey = UUID()
                }
            }
            return true
        }
        let (archivePath, _) = parseVirtualURL(item.path)
        NotificationCenter.default.post(name: NSNotification.Name("TTZipEncryptedArchivePromptRequired"), object: archivePath)
        return true
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

    static func resolvedItemLocation(for rawPath: String) -> URL {
        URL(string: rawPath).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(fileURLWithPath: rawPath)
    }

    private static func isVirtualSubpathLocation(_ location: URL) -> Bool {
        URLComponents(url: location, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "subpath" }) == true
    }
    
    public static func applySelectAllInColumn(
        targetIndex: Int,
        items: [DiskItemInfo],
        selectedPaths: inout [Int: String],
        multiSelectedPaths: inout Set<String>,
        selectedItem: inout DiskItemInfo?,
        viewModel: AppViewState?,
        onSelectItem: ((DiskItemInfo) -> Void)? = nil
    ) {
        guard !items.isEmpty else { return }
        multiSelectedPaths = Set(items.map(\.path))
        for key in selectedPaths.keys where key > targetIndex {
            selectedPaths.removeValue(forKey: key)
        }
        if let first = items.first {
            selectedPaths[targetIndex] = first.path
            selectedItem = first
            onSelectItem?(first)
            if items.count > 1 {
                viewModel?.selectionState.selectMultiple(items)
            } else {
                viewModel?.selectionState.select(first)
            }
        }
    }

    func selectAllInActiveColumn() {
        let targetIndex = hoveredColumnIndex ?? (columnPaths.count - 1)
        guard targetIndex >= 0, targetIndex < columnPaths.count else { return }
        let targetURL = columnPaths[targetIndex]
        let currentSort = perColumnSortOption[targetIndex] ?? sortOption
        let cacheKey = "\(targetURL.absoluteString)_\(currentSort.rawValue)"
        let items = cachedColumnItems[cacheKey]
            ?? cachedColumnItems[targetURL.path]
            ?? cachedColumnItems[targetURL.standardizedFileURL.path]
            ?? cachedColumnItems[targetURL.absoluteString]
            ?? []
        Self.applySelectAllInColumn(
            targetIndex: targetIndex,
            items: items,
            selectedPaths: &selectedPaths,
            multiSelectedPaths: &multiSelectedPaths,
            selectedItem: &selectedItem,
            viewModel: activeViewModel,
            onSelectItem: onSelectItem
        )
        onColumnStateChanged?(columnPaths, selectedPaths, selectedItem)
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
