// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import AppKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Native macOS disk directory browser with Miller Columns navigation.
public struct DiskDirectoryBrowserView: View {
    public var viewModel: AppViewState? = nil
    @Environment(AppViewState.self) private var envViewModel: AppViewState?
    private var activeViewModel: AppViewState? { viewModel ?? envViewModel }
    
    let rootDirectory: URL
    let onSelectArchive: ((String) -> Void)?
    let onCompressPath: ((String) -> Void)?
    let onPreviewFile: ((String) -> Void)?
    let onSelectItem: ((DiskItemInfo) -> Void)?
    
    @State private var currentDirectory: URL
    @State private var searchQuery: String = ""
    @State private var searchService = SpotlightSearchService()
    @State private var sortOption: DiskSortOption = .nameAsc
    @State private var targetSelectedPath: String? = nil
    @State private var selectedItem: DiskItemInfo? = nil
    public let isActive: Bool
    
    public init(
        viewModel: AppViewState? = nil,
        rootDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()),
        isActive: Bool = true
    ) {
        self.viewModel = viewModel
        self.rootDirectory = rootDirectory
        self.isActive = isActive
        self._currentDirectory = State(initialValue: rootDirectory)
        self.onSelectArchive = nil
        self.onCompressPath = nil
        self.onPreviewFile = nil
        self.onSelectItem = nil
    }
    
    public init(
        rootDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()),
        isActive: Bool = true,
        onSelectArchive: @escaping (String) -> Void,
        onCompressPath: @escaping (String) -> Void,
        onPreviewFile: @escaping (String) -> Void,
        onSelectItem: @escaping (DiskItemInfo) -> Void = { _ in }
    ) {
        self.viewModel = nil
        self.rootDirectory = rootDirectory
        self.isActive = isActive
        self._currentDirectory = State(initialValue: rootDirectory)
        self.onSelectArchive = onSelectArchive
        self.onCompressPath = onCompressPath
        self.onPreviewFile = onPreviewFile
        self.onSelectItem = onSelectItem
    }
    
    nonisolated public static func sortItems(_ items: [DiskItemInfo], option: DiskSortOption) -> [DiskItemInfo] {
        return DiskItemSorter.sort(items, by: option)
    }
    
    public var body: some View {
        FinderMillerColumnsView(
            viewModel: activeViewModel,
            rootDirectory: currentDirectory,
            initialSelectedPath: targetSelectedPath,
            sortOption: sortOption,
            isActive: isActive,
            onNavigateUp: canNavigateUp ? { navigateUp() } : nil,
            onSelectArchive: onSelectArchive,
            onCompressPath: onCompressPath,
            onPreviewFile: onPreviewFile,
            onSelectItem: { item in
                self.selectedItem = item
                self.targetSelectedPath = item.path
                if let onSelectItem = self.onSelectItem {
                    onSelectItem(item)
                } else {
                    activeViewModel?.selectionState.select(item)
                }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: rootDirectory) { _, newRoot in
            self.currentDirectory = newRoot
        }
    }
    
    private var canNavigateUp: Bool { currentDirectory.path != "/" && currentDirectory.pathComponents.count > 1 }
    
    private func navigateUp() {
        guard canNavigateUp else { return }
        let prevPath = currentDirectory.path
        targetSelectedPath = prevPath
        currentDirectory = currentDirectory.deletingLastPathComponent()
    }
    
    private func reloadCurrentDirectory() {
        let dir = currentDirectory
        currentDirectory = dir
    }
    
    private func previewFile(path: String) {
        if let onPreviewFile {
            onPreviewFile(path)
        }
    }
}
