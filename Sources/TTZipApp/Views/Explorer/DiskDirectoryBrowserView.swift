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
    let rootDirectory: URL
    let onSelectArchive: (String) -> Void
    let onCompressPath: (String) -> Void
    let onPreviewFile: (String) -> Void
    let onSelectItem: (DiskItemInfo) -> Void
    
    @State private var currentDirectory: URL
    @State private var searchQuery: String = ""
    @StateObject private var searchService = SpotlightSearchService()
    @State private var sortOption: DiskSortOption = .nameAsc
    @State private var targetSelectedPath: String? = nil
    @State private var dynamicFinderFavorites: [FinderFavoriteItem] = []
    @State private var draggingFavorite: FinderFavoriteItem? = nil
    @State private var selectedItem: DiskItemInfo? = nil
    public let isActive: Bool
    
    public init(
        rootDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()),
        isActive: Bool = true,
        onSelectArchive: @escaping (String) -> Void,
        onCompressPath: @escaping (String) -> Void,
        onPreviewFile: @escaping (String) -> Void,
        onSelectItem: @escaping (DiskItemInfo) -> Void = { _ in }
    ) {
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(dynamicFinderFavorites) { fav in
                            shortcutTag(
                                label: fav.name,
                                systemImage: fav.systemImage,
                                targetURL: URL(fileURLWithPath: fav.path)
                            )
                            .onDrag {
                                self.draggingFavorite = fav
                                return NSItemProvider(object: fav.path as NSString)
                            }
                            .onDrop(of: [.text], delegate: FavoriteDropDelegate(item: fav, favorites: $dynamicFinderFavorites, draggingItem: $draggingFavorite))
                        }
                        
                        ForEach(customPinnedPaths, id: \.self) { path in
                            let url = URL(fileURLWithPath: path)
                            if !dynamicFinderFavorites.contains(where: { $0.path == path }) {
                                shortcutTag(
                                    label: url.lastPathComponent,
                                    systemImage: "folder.fill",
                                    targetURL: url,
                                    isCustom: true
                                )
                            }
                        }
                        
                        Button(action: addCustomPinnedFolder) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Color.primary.opacity(0.03))
                                .clipShape(Circle())
                                .overlay(
                                    Circle().strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Add any custom folder on Mac to shortcuts")
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .frame(height: 28)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                
                Button(action: { reloadCurrentDirectory() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(Circle())
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .help("Refresh browser contents")
            }
            .frame(height: 28)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            
            FinderMillerColumnsView(
                rootDirectory: currentDirectory,
                initialSelectedPath: targetSelectedPath,
                sortOption: sortOption,
                isActive: isActive,
                onNavigateUp: canNavigateUp ? { navigateUp() } : nil,
                onSelectArchive: onSelectArchive,
                onCompressPath: onCompressPath,
                onPreviewFile: { path in
                    previewFile(path: path)
                },
                onSelectItem: { item in
                    self.selectedItem = item
                    self.targetSelectedPath = item.path
                    onSelectItem(item)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            let favs = await Task.detached(priority: .userInitiated) {
                FinderFavoritesReader.fetchFavorites()
            }.value
            await MainActor.run {
                self.dynamicFinderFavorites = favs
            }
        }
        .onChange(of: rootDirectory) { _, newRoot in
            self.currentDirectory = newRoot
        }
    }
    
    private func shortcutTag(label: String, systemImage: String, targetURL: URL, isCustom: Bool = false) -> some View {
        Button(action: {
            currentDirectory = targetURL
        }) {
            let isSelected = currentDirectory.path == targetURL.path
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(isSelected ? TTZipTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.03))
            .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : Color.primary.opacity(0.85))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? TTZipTheme.bambooGreen.opacity(0.25) : Color.primary.opacity(0.05), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .contextMenu {
            if isCustom {
                Button("Unpin shortcut path") {
                    removeCustomPinnedFolder(path: targetURL.path)
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(targetURL.path, inFileViewerRootedAtPath: "")
            }
        }
    }
    
    @AppStorage("TTZipCustomShortcutFolderPaths") private var customPinnedPathsJSON: String = "[]"
    
    private var customPinnedPaths: [String] {
        guard let data = customPinnedPathsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return list
    }
    
    private func saveCustomPinnedPaths(_ paths: [String]) {
        if let data = try? JSONEncoder().encode(paths),
           let jsonStr = String(data: data, encoding: .utf8) {
            customPinnedPathsJSON = jsonStr
        }
    }
    
    private func addCustomPinnedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Pin Shortcut"
        panel.message = "Choose folders to pin to top shortcut bar:"
        
        if panel.runModal() == .OK {
            var current = customPinnedPaths
            for url in panel.urls {
                if !current.contains(url.path) {
                    current.append(url.path)
                }
            }
            saveCustomPinnedPaths(current)
        }
    }
    
    private func removeCustomPinnedFolder(path: String) {
        var current = customPinnedPaths
        current.removeAll { $0 == path }
        saveCustomPinnedPaths(current)
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
        onPreviewFile(path)
    }
}
