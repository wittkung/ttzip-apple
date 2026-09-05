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

public struct FinderMillerColumnsView: View {
    public let rootDirectory: URL
    public var initialSelectedPath: String? = nil
    public var sortOption: DiskSortOption = .nameAsc
    public var onNavigateUp: (() -> Void)? = nil
    public let onSelectArchive: (String) -> Void
    public let onCompressPath: (String) -> Void
    public let onPreviewFile: (String) -> Void
    public let onSelectItem: (DiskItemInfo) -> Void
    public let isActive: Bool
    
    @State var columnPaths: [URL] = []
    @State var selectedPaths: [Int: String] = [:]
    @State var multiSelectedPaths: Set<String> = []
    @State var selectedItem: DiskItemInfo? = nil
    @State var cachedColumnItems: [String: [DiskItemInfo]] = [:]
    @State var refreshKey: UUID = UUID()
    @State var columnWidths: [Int: CGFloat] = [:]
    @State var perColumnSortOption: [Int: DiskSortOption] = [:]
    @State var eventMonitor: Any? = nil
    
    @State var showNewFolderAlert: Bool = false
    @State var newFolderName: String = "Untitled Folder"
    @State var targetCreateFolderDir: URL? = nil
    
    @State var showNewFileAlert: Bool = false
    @State var newFileName: String = "Untitled.txt"
    @State var targetCreateFileDir: URL? = nil
    
    public init(
        rootDirectory: URL,
        initialSelectedPath: String? = nil,
        sortOption: DiskSortOption = .nameAsc,
        isActive: Bool = true,
        onNavigateUp: (() -> Void)? = nil,
        onSelectArchive: @escaping (String) -> Void,
        onCompressPath: @escaping (String) -> Void,
        onPreviewFile: @escaping (String) -> Void,
        onSelectItem: @escaping (DiskItemInfo) -> Void
    ) {
        self.rootDirectory = rootDirectory
        self.initialSelectedPath = initialSelectedPath
        self.sortOption = sortOption
        self.isActive = isActive
        self.onNavigateUp = onNavigateUp
        self.onSelectArchive = onSelectArchive
        self.onCompressPath = onCompressPath
        self.onPreviewFile = onPreviewFile
        self.onSelectItem = onSelectItem
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(columnPaths.enumerated()), id: \.offset) { index, dirURL in
                            millerColumn(index: index, dirURL: dirURL, availableWidth: geometry.size.width)
                                .id(index)
                        }
                    }
                    .frame(minWidth: geometry.size.width, maxHeight: .infinity, alignment: .topLeading)
                    .onChange(of: columnPaths.count) { _, newCount in
                        if newCount > 0 {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                proxy.scrollTo(newCount - 1, anchor: .trailing)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {
                newFolderName = "Untitled Folder"
            }
            Button("Create") {
                let dir = targetCreateFolderDir ?? rootDirectory
                createNewFolder(in: dir, name: newFolderName)
                newFolderName = "Untitled Folder"
            }
        } message: {
            if let dir = targetCreateFolderDir {
                Text("Creating new folder in:\n\(dir.path)")
            } else {
                Text("Create a new folder")
            }
        }
        .alert("New File", isPresented: $showNewFileAlert) {
            TextField("File Name (e.g. text.txt)", text: $newFileName)
            Button("Cancel", role: .cancel) {
                newFileName = "Untitled.txt"
            }
            Button("Create") {
                let dir = targetCreateFileDir ?? rootDirectory
                createNewFile(in: dir, name: newFileName)
                newFileName = "Untitled.txt"
            }
        } message: {
            if let dir = targetCreateFileDir {
                Text("Creating new file in:\n\(dir.path)")
            } else {
                Text("Create a new empty file")
            }
        }
        .onAppear {
            if columnPaths.isEmpty {
                columnPaths = [rootDirectory]
            }
            if let target = initialSelectedPath, !target.isEmpty {
                selectedPaths[0] = target
                let targetURL = URL(fileURLWithPath: target)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue {
                    columnPaths = [rootDirectory, targetURL]
                }
            }
            
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard self.isActive else { return event }
                if let firstResponder = NSApp.keyWindow?.firstResponder {
                    if (firstResponder.isKind(of: NSTextView.self) && (firstResponder as? NSTextView)?.isFieldEditor == true) || firstResponder is NSTextField {
                        return event
                    }
                }
                
                // KeyCode 49 is Space Bar -> Trigger native QuickLook preview without intercepting media playback
                if event.keyCode == 49 {
                    if let item = selectedItem, !item.isDirectory {
                        onPreviewFile(item.path)
                        return nil
                    }
                }
                
                if event.keyCode == 51 || event.keyCode == 117 {
                    if let selected = selectedPaths[activeColumnIndex], selected.contains("?subpath=") {
                        let (archivePath, subpath) = MillerColumnItemRowView.parseVirtualURL(selected)
                        if !subpath.isEmpty {
                            let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                            Task {
                                try? await InPlaceMutationCoordinator.shared.deleteEntries(
                                    archivePath: archivePath,
                                    entryPaths: [subpath],
                                    password: pwd
                                )
                            }
                            return nil
                        }
                    }
                }
                if event.keyCode >= 123 && event.keyCode <= 126 {
                    if (event.keyCode == 123 || event.keyCode == 124) && MediaPlaybackCoordinator.shared.shouldInterceptMediaKeys() {
                        return event
                    }
                    switch event.keyCode {
                    case 123:
                        navigateSelectionLeft()
                    case 124:
                        navigateSelectionRight()
                    case 125:
                        navigateSelectionDown()
                    case 126:
                        navigateSelectionUp()
                    default:
                        break
                    }
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
        .onChange(of: rootDirectory) { _, newRoot in
            selectedPaths = [:]
            if let target = initialSelectedPath, !target.isEmpty {
                selectedPaths[0] = target
                let targetURL = URL(fileURLWithPath: target)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue {
                    columnPaths = [newRoot, targetURL]
                } else {
                    columnPaths = [newRoot]
                }
                let item = DiskItemInfo(url: targetURL)
                selectedItem = item
                onSelectItem(item)
            } else {
                columnPaths = [newRoot]
                selectedItem = nil
            }
            cachedColumnItems = [:]
            perColumnSortOption = [:]
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipArchiveUnlockedRefresh"))) { _ in
            cachedColumnItems = [:]
            refreshKey = UUID()
        }
        .overlay(
            Group {
                Button("") {
                    let targets: [URL] = {
                        if !multiSelectedPaths.isEmpty {
                            return multiSelectedPaths.map { URL(fileURLWithPath: $0) }
                        } else if let selectedPath = selectedPaths.compactMap({ $0.value }).last {
                            return [URL(fileURLWithPath: selectedPath)]
                        }
                        return []
                    }()
                    if !targets.isEmpty {
                        FileClipboardStore.shared.copy(urls: targets)
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
                
                Button("") {
                    let targets: [URL] = {
                        if !multiSelectedPaths.isEmpty {
                            return multiSelectedPaths.map { URL(fileURLWithPath: $0) }
                        } else if let selectedPath = selectedPaths.compactMap({ $0.value }).last {
                            return [URL(fileURLWithPath: selectedPath)]
                        }
                        return []
                    }()
                    if !targets.isEmpty {
                        FileClipboardStore.shared.cut(urls: targets)
                    }
                }
                .keyboardShortcut("x", modifiers: .command)
                
                Button("") {
                    let targetDir: URL = {
                        if let selectedPath = selectedPaths.compactMap({ $0.value }).last {
                            var isDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: selectedPath, isDirectory: &isDir), isDir.boolValue {
                                return URL(fileURLWithPath: selectedPath)
                            }
                        }
                        return columnPaths.last ?? rootDirectory
                    }()
                    FileClipboardStore.shared.paste(to: targetDir)
                }
                .keyboardShortcut("v", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        )
    }
    
    private let defaultColumnWidth: CGFloat = 260
    
    private func computeColumnWidth(for index: Int, availableWidth: CGFloat) -> CGFloat {
        if let custom = columnWidths[index] {
            return custom
        }
        let count = columnPaths.count
        if count <= 1 {
            // When only 1 column exists, expand to occupy the full available width (at least defaultColumnWidth)
            return max(availableWidth, defaultColumnWidth)
        } else if count == 2 {
            // When 2 columns exist, share the viewport comfortably if availableWidth allows
            let half = availableWidth / 2.0
            return max(half, defaultColumnWidth)
        } else {
            return defaultColumnWidth
        }
    }
    
    func millerColumn(index: Int, dirURL: URL, availableWidth: CGFloat) -> some View {
        let selectedPath = selectedPaths[index]
        let currentSort = perColumnSortOption[index] ?? sortOption
        let cacheKey = "\(dirURL.absoluteString)_\(currentSort.rawValue)"
        let items = cachedColumnItems[cacheKey]
        let currentWidth = computeColumnWidth(for: index, availableWidth: availableWidth)
        let canGoParent = dirURL.path != "/" && dirURL.pathComponents.count > 1
        let isColumnActive = (index == activeColumnIndex)
        
        return SingleMillerColumnView(
            index: index,
            dirURL: dirURL,
            selectedPath: selectedPath,
            currentSort: currentSort,
            items: items,
            currentWidth: currentWidth,
            canGoParent: canGoParent,
            isColumnActive: isColumnActive,
            multiSelectedPaths: multiSelectedPaths,
            onPrependParent: { prependParentColumn(for: dirURL) },
            onChangeSort: { perColumnSortOption[index] = $0 },
            onSelectArchive: onSelectArchive,
            onCompressPath: onCompressPath,
            onSelectItem: { it, idx, cmd, shift, dir in
                selectItem(item: it, columnIndex: idx, isCommand: cmd, isShift: shift, dirURL: dir)
            },
            onTriggerNewFolder: { dir in
                targetCreateFolderDir = dir
                newFolderName = "Untitled Folder"
                showNewFolderAlert = true
            },
            onTriggerNewFile: { dir in
                targetCreateFileDir = dir
                newFileName = "Untitled.txt"
                showNewFileAlert = true
            },
            onRefresh: {
                cachedColumnItems.removeAll()
                refreshKey = UUID()
            },
            onSelectAll: { selectAllInActiveColumn() },
            onWidthChanged: { w in columnWidths[index] = w }
        )
        .frame(maxHeight: .infinity)
        .task(id: "\(cacheKey)_\(refreshKey.uuidString)") {
            if cachedColumnItems[cacheKey] == nil {
                let dir = dirURL
                let sortOpt = currentSort
                let scanned = await MillerColumnDirectoryScanner.loadContentsOf(dirURL: dir)
                let sorted = DiskItemSorter.sort(scanned, by: sortOpt)
                cachedColumnItems[cacheKey] = sorted
                if cachedColumnItems.count > 64 {
                    let activeKeys = Set(columnPaths.enumerated().map { idx, path in
                        let sort = perColumnSortOption[idx] ?? sortOption
                        return "\(path.absoluteString)_\(sort.rawValue)"
                    })
                    for k in Array(cachedColumnItems.keys) where !activeKeys.contains(k) {
                        cachedColumnItems.removeValue(forKey: k)
                    }
                }
            }
        }
    }
}
