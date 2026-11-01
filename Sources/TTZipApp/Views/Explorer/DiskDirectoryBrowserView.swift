// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

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
    @State private var sortOption: DiskSortOption = .nameAsc
    @State private var targetSelectedPath: String? = nil
    @State private var selectedItem: DiskItemInfo? = nil
    public let isActive: Bool
    var injectedSearchCoordinator: UnifiedExplorerSearchCoordinator? = nil
    var onMillerColumnStateChanged: (([URL], [Int: String], DiskItemInfo?) -> Void)? = nil
    @State private var treemapViewModel = StorageInspectorViewModel()
    @State private var searchCoordinator: UnifiedExplorerSearchCoordinator? = nil
    @AppStorage("TTZip_ActiveExplorerViewMode") private var viewModeRaw: String = ExplorerViewMode.column.rawValue
    
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
    
    private var displayedDirectory: URL {
        activeViewModel?.navigationState.currentDirectory ?? currentDirectory
    }

    private var showsArchiveColumns: Bool {
        let location = displayedDirectory
        guard AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(location) else { return false }
        if URLComponents(url: location, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "subpath" }) == true { return true }
        guard let owner = activeViewModel else { return false }
        return owner.navigationState.activeTabSession?.archivePath == location.path
            || owner.explorerState.acceptedArchiveProjection(
            for: owner.navigationState.activeSessionID, archivePath: location.path
        ) != nil
    }

    public var body: some View {
        Group {
            if viewModeRaw == ExplorerViewMode.treemap.rawValue && !showsArchiveColumns {
                StorageInspectorView(isPresented: .constant(true), viewModel: treemapViewModel)
                    .onAppear {
                        treemapViewModel.setDirectory(displayedDirectory)
                    }
                    .onChange(of: displayedDirectory) { _, newDir in
                        treemapViewModel.setDirectory(newDir)
                    }
                    .onDisappear {
                        treemapViewModel.cancelScan()
                    }
            } else {
                ZStack {
                    FinderMillerColumnsView(
                        viewModel: activeViewModel,
                        rootDirectory: displayedDirectory,
                        initialSelectedPath: targetSelectedPath,
                        sortOption: sortOption,
                        isActive: isActive && !isUnifiedSearchActive,
                        onNavigateUp: canNavigateUp ? { navigateUp() } : nil,
                        onSelectArchive: onSelectArchive,
                        onCompressPath: onCompressPath,
                        onPreviewFile: onPreviewFile,
                        onSelectItem: { item in
                            self.selectedItem = item
                            if let onSelectItem = self.onSelectItem {
                                onSelectItem(item)
                            } else {
                                activeViewModel?.selectionState.select(item)
                            }
                        },
                        onColumnStateChanged: onMillerColumnStateChanged
                    )
                    .id(activeViewModel?.navigationState.activeSessionID)
                    .opacity(isUnifiedSearchActive ? 0 : 1)
                    .allowsHitTesting(!isUnifiedSearchActive)

                    if isUnifiedSearchActive,
                       let vm = activeViewModel,
                       let coordinator = searchCoordinator {
                        UnifiedExplorerSearchResultsView(
                            coordinator: coordinator,
                            viewModel: vm
                        )
                        .transition(.opacity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            syncUnifiedSearchIfNeeded()
        }
        .onChange(of: activeViewModel?.explorerState.searchQuery ?? "") { _, _ in
            syncUnifiedSearchIfNeeded()
        }
        .onChange(of: activeViewModel?.effectiveDisplayDirectory) { _, _ in
            syncUnifiedSearchIfNeeded()
        }
        .onChange(of: activeViewModel?.explorerState.currentArchivePath) { _, _ in
            syncUnifiedSearchIfNeeded()
        }
        .onChange(of: activeViewModel?.navigationState.activeSessionID) { _, _ in
            syncUnifiedSearchIfNeeded()
        }
        .onDisappear {
            searchCoordinator?.clearSearch()
        }
        .onChange(of: rootDirectory) { oldRoot, newRoot in
            guard oldRoot != newRoot else { return }
            self.currentDirectory = newRoot
            if activeViewModel != nil || showsArchiveColumns {
                targetSelectedPath = nil
                return
            }
            if let target = targetSelectedPath {
                let targetURL = URL(fileURLWithPath: target).standardizedFileURL
                let newRootURL = newRoot.standardizedFileURL
                let newRootPrefix = newRootURL.path.hasSuffix("/") ? newRootURL.path : (newRootURL.path + "/")
                let isDirectChild = targetURL.deletingLastPathComponent().path == newRootURL.path
                let isDescendant = targetURL.path.hasPrefix(newRootPrefix)
                if !isDirectChild && !isDescendant {
                    self.targetSelectedPath = nil
                    self.selectedItem = nil
                    self.activeViewModel?.selectionState.clear()
                }
            } else {
                self.selectedItem = nil
                self.activeViewModel?.selectionState.clear()
            }
        }
    }
    
    private var canNavigateUp: Bool { activeViewModel?.navigationState.canGoUp ?? (currentDirectory.path != "/" && currentDirectory.pathComponents.count > 1) }
    
    private func navigateUp() {
        guard canNavigateUp else { return }
        if let owner = activeViewModel {
            owner.navigationState.goUp()
            return
        }
        let prevPath = currentDirectory.path
        targetSelectedPath = prevPath
        let parent = currentDirectory.deletingLastPathComponent()
        currentDirectory = parent
        if let vm = activeViewModel, vm.navigationState.currentDirectory != parent {
            vm.navigationState.currentDirectory = parent
        }
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

    private var isUnifiedSearchActive: Bool {
        guard let vm = activeViewModel else { return false }
        return !vm.explorerState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ensureSearchCoordinator(for vm: AppViewState) -> UnifiedExplorerSearchCoordinator {
        if let injected = injectedSearchCoordinator {
            if searchCoordinator !== injected {
                searchCoordinator = injected
            }
            return injected
        }
        if let existing = searchCoordinator, existing.windowID == vm.windowID {
            return existing
        }
        let created = UnifiedExplorerSearchCoordinator(windowID: vm.windowID)
        searchCoordinator = created
        return created
    }

    private func syncUnifiedSearchIfNeeded() {
        guard let vm = activeViewModel else {
            searchCoordinator?.clearSearch()
            return
        }
        let trimmed = vm.explorerState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchCoordinator?.clearSearch()
            return
        }
        let coordinator = ensureSearchCoordinator(for: vm)
        let scope = UnifiedExplorerSearchCoordinator.classifyScope(for: vm)
        coordinator.updateSearch(query: trimmed, scope: scope, in: vm)
    }
}
