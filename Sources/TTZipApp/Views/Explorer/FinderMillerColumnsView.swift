// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import AppKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
import TTMediaKit

public struct FinderMillerColumnsView: View {
    public var viewModel: AppViewState? = nil
    @Environment(AppViewState.self) private var envViewModel: AppViewState?
    var activeViewModel: AppViewState? { viewModel ?? envViewModel }
    
    public let rootDirectory: URL
    public var initialSelectedPath: String? = nil
    public var sortOption: DiskSortOption = .nameAsc
    public var onNavigateUp: (() -> Void)? = nil
    public var onSelectArchive: ((String) -> Void)? = nil
    public var onCompressPath: ((String) -> Void)? = nil
    public var onPreviewFile: ((String) -> Void)? = nil
    public var onSelectItem: ((DiskItemInfo) -> Void)? = nil
    public let isActive: Bool
    
    public static func isNavigableArchiveFolder(_ item: DiskItemInfo) -> Bool {
        item.taxonomy.isNavigableContainer
    }
    
    public static func nextColumnPaths(
        currentPaths: [URL],
        columnIndex: Int,
        item: DiskItemInfo
    ) -> [URL] {
        var nextPaths = Array(currentPaths.prefix(columnIndex + 1))
        let isVirtual = URL(string: item.path).flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
        }?.contains(where: { $0.name == "subpath" }) == true
        if item.isBrowsableDirectory || (isNavigableArchiveFolder(item) && !isVirtual) {
            let targetURL: URL
            if let u = URL(string: item.path), u.scheme != nil {
                targetURL = u
            } else {
                targetURL = URL(fileURLWithPath: item.path)
            }
            if isNavigableArchiveFolder(item), !item.isBrowsableDirectory {
                nextPaths.append(AppViewState.makeArchiveEntryVirtualURL(
                    archivePath: targetURL.path, entrySubpath: ""
                ) ?? targetURL)
            } else {
                nextPaths.append(targetURL)
            }
        }
        return nextPaths
    }
    
    public static let columnSpringAnimation = Animation.spring(response: 0.3, dampingFraction: 0.85)
    
    @State var columnPaths: [URL] = []
    @State var selectedPaths: [Int: String] = [:]
    @State var multiSelectedPaths: Set<String> = []
    @State var selectedItem: DiskItemInfo? = nil
    @State var cachedColumnItems: [String: [DiskItemInfo]] = [:]
    @State var refreshKey: UUID = UUID()
    @State var columnWidths: [Int: CGFloat] = [:]
    @State var perColumnSortOption: [Int: DiskSortOption] = [:]
    @State var eventMonitor: Any? = nil
    @State var hostWindowNumber: Int? = nil
    @State var scrollTarget: HorizontalScrollTarget? = nil
    
    @State var showNewFolderAlert: Bool = false
    @State var newFolderName: String = "Untitled Folder"
    @State var targetCreateFolderDir: URL? = nil
    
    @State var showNewFileAlert: Bool = false
    @State var newFileName: String = "Untitled.txt"
    @State var targetCreateFileDir: URL? = nil
    /// Optional callback invoked in tests or parent views whenever `columnPaths` or `selectedPaths` changes.
    var onColumnStateChanged: (([URL], [Int: String], DiskItemInfo?) -> Void)? = nil
    private var l10n: AppLocalizationState { AppLocalizationState.shared }
    
    public init(
        viewModel: AppViewState? = nil,
        rootDirectory: URL,
        initialSelectedPath: String? = nil,
        sortOption: DiskSortOption = .nameAsc,
        isActive: Bool = true,
        onNavigateUp: (() -> Void)? = nil,
        onSelectArchive: ((String) -> Void)? = nil,
        onCompressPath: ((String) -> Void)? = nil,
        onPreviewFile: ((String) -> Void)? = nil,
        onSelectItem: ((DiskItemInfo) -> Void)? = nil,
        onColumnStateChanged: (([URL], [Int: String], DiskItemInfo?) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.rootDirectory = rootDirectory
        self.initialSelectedPath = initialSelectedPath
        self.sortOption = sortOption
        self.isActive = isActive
        self.onNavigateUp = onNavigateUp
        self.onSelectArchive = onSelectArchive
        self.onCompressPath = onCompressPath
        self.onPreviewFile = onPreviewFile
        self.onSelectItem = onSelectItem
        self.onColumnStateChanged = onColumnStateChanged
    }
    
    public var body: some View {
        GeometryReader { geometry in
            AppKitHorizontalScrollView(
                scrollToTrailingTrigger: columnPaths.count,
                scrollTarget: scrollTarget
            ) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(columnPaths.enumerated()), id: \.element.absoluteString) { index, dirURL in
                        millerColumn(index: index, dirURL: dirURL, availableWidth: geometry.size.width)
                            .id(dirURL.absoluteString)
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .identity
                            ))
                    }
                }
                .frame(minWidth: geometry.size.width, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .alert(l10n.t(L10n.Common.newFolder), isPresented: $showNewFolderAlert) {
            TextField(l10n.uiString(zh: "文件夹名称", en: "Folder Name"), text: $newFolderName)
            Button(l10n.t(L10n.Common.cancel), role: .cancel) {
                newFolderName = "Untitled Folder"
            }
            Button(l10n.uiString(zh: "创建", en: "Create")) {
                let dir = targetCreateFolderDir ?? rootDirectory
                createNewFolder(in: dir, name: newFolderName)
                newFolderName = "Untitled Folder"
            }
        } message: {
            if let dir = targetCreateFolderDir {
                Text(l10n.uiString(zh: "将在以下位置创建新文件夹：\n\(dir.path)", en: "Creating new folder in:\n\(dir.path)"))
            } else {
                Text(l10n.uiString(zh: "新建文件夹", en: "Create a new folder"))
            }
        }
        .alert(l10n.uiString(zh: "新建文件", en: "New File"), isPresented: $showNewFileAlert) {
            TextField(l10n.uiString(zh: "文件名（如 text.txt）", en: "File Name (e.g. text.txt)"), text: $newFileName)
            Button(l10n.t(L10n.Common.cancel), role: .cancel) {
                newFileName = "Untitled.txt"
            }
            Button(l10n.uiString(zh: "创建", en: "Create")) {
                let dir = targetCreateFileDir ?? rootDirectory
                createNewFile(in: dir, name: newFileName)
                newFileName = "Untitled.txt"
            }
        } message: {
            if let dir = targetCreateFileDir {
                Text(l10n.uiString(zh: "将在以下位置创建新文件：\n\(dir.path)", en: "Creating new file in:\n\(dir.path)"))
            } else {
                Text(l10n.uiString(zh: "创建空白文件", en: "Create a new empty file"))
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            guard isActive else { return .ignored }
            navigateSelectionUp()
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard isActive else { return .ignored }
            navigateSelectionDown()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard isActive else { return .ignored }
            let winNum = activeViewModel.flatMap { BrowserWindowRegistry.shared.nsWindow(for: $0.windowID)?.windowNumber } ?? NSApp.keyWindow?.windowNumber
            let query = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(windowNumber: winNum)
            if query.ownsHorizontalArrowKeys || query.isTextInputActive {
                _ = TTPreviewKeyboardOwnershipCoordinator.shared.performHorizontalArrowStepIfOwned(
                    isRightArrow: false,
                    windowNumber: winNum
                )
                return .handled
            }
            if !MediaPlaybackCoordinator.shared.shouldInterceptMediaKeys() {
                navigateSelectionLeft()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.rightArrow) {
            guard isActive else { return .ignored }
            let winNum = activeViewModel.flatMap { BrowserWindowRegistry.shared.nsWindow(for: $0.windowID)?.windowNumber } ?? NSApp.keyWindow?.windowNumber
            let query = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(windowNumber: winNum)
            if query.ownsHorizontalArrowKeys || query.isTextInputActive {
                _ = TTPreviewKeyboardOwnershipCoordinator.shared.performHorizontalArrowStepIfOwned(
                    isRightArrow: true,
                    windowNumber: winNum
                )
                return .handled
            }
            if !MediaPlaybackCoordinator.shared.shouldInterceptMediaKeys() {
                navigateSelectionRight()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.space) {
            guard isActive else { return .ignored }
            if let item = selectedItem, !item.isDirectory {
                if let preview = onPreviewFile {
                    preview(item.path)
                } else {
                    activeViewModel?.openImmersiveMedia(for: item)
                }
                return .handled
            }
            return .ignored
        }
        .onDeleteCommand {
            guard isActive else { return }
            deleteSelectedVirtualEntry()
        }
        .onAppear {
            if restoreArchiveColumns(for: rootDirectory) {
                // Column state is a presentation of the owner location and accepted catalog.
            } else if let target = initialSelectedPath, !target.isEmpty,
               let resolved = resolveValidDescendantHierarchy(for: target, under: rootDirectory) {
                columnPaths = resolved.columns
                selectedPaths = resolved.selected
                selectedItem = resolved.item
                activeViewModel?.selectionState.select(resolved.item)
                if let deepest = resolved.columns.last, deepest != rootDirectory {
                    activeViewModel?.activeBrowsingDirectory = deepest
                }
            } else {
                columnPaths = [rootDirectory]
                selectedPaths = [:]
                multiSelectedPaths = []
                selectedItem = nil
                activeViewModel?.activeBrowsingDirectory = nil
            }
            onColumnStateChanged?(columnPaths, selectedPaths, selectedItem)
            
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let myWindow = activeViewModel.flatMap { BrowserWindowRegistry.shared.nsWindow(for: $0.windowID) } ?? NSApp.keyWindow
                guard self.isActive, event.window === NSApp.keyWindow, event.window === myWindow else { return event }
                if activeViewModel?.showImmersiveMediaBrowser == true {
                    return event
                }
                if (activeViewModel?.presentationCoordinator ?? PresentationCoordinator.shared).isModalActive {
                    return event
                }
                if TTPreviewHorizontalKeyPolicy.isWindowTextInputActive(event.window) {
                    return event
                }
                
                // Command shortcuts for file operations (Copy, Cut, Paste) with FirstResponder protection
                let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
                if modifiers == .command {
                    let char = event.charactersIgnoringModifiers?.lowercased()
                    if char == "c" || event.keyCode == 8 {
                        copySelectedFiles()
                        return nil
                    } else if char == "x" || event.keyCode == 7 {
                        cutSelectedFiles()
                        return nil
                    } else if char == "v" || event.keyCode == 9 {
                        pasteFiles()
                        return nil
                    }
                }
                
                // Return / Enter key triggers inline rename per macOS Finder ergonomics
                if modifiers.isEmpty && (event.keyCode == 36 || event.keyCode == 76) {
                    if let item = selectedItem, multiSelectedPaths.count <= 1, !item.path.contains("?subpath=") {
                        NotificationCenter.default.post(name: NSNotification.Name("TTZipStartInlineRenameNotification"), object: item.path)
                        return nil
                    }
                }
                
                // KeyCode 49 is Space Bar -> Trigger native QuickLook preview without intercepting media playback
                if event.keyCode == 49 {
                    if let item = selectedItem, !item.isDirectory {
                        if let preview = onPreviewFile {
                            preview(item.path)
                        } else {
                            activeViewModel?.openImmersiveMedia(for: item)
                        }
                        return nil
                    }
                }
                
                if event.keyCode == 51 || event.keyCode == 117 {
                    deleteSelectedVirtualEntry()
                    return nil
                }
                if event.keyCode >= 123 && event.keyCode <= 126 {
                    if event.keyCode == 123 || event.keyCode == 124 {
                        let disposition = TTPreviewKeyboardOwnershipCoordinator.shared.handleOrBlockOuterHorizontalArrow(event: event)
                        if disposition == .consumedByPreviewOwner {
                            return nil
                        }
                        if disposition == .yieldToTextInput {
                            return event
                        }
                        if MediaPlaybackCoordinator.shared.shouldInterceptMediaKeys() {
                            return event
                        }
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
        .background(TTPreviewHostWindowNumberReader(windowNumber: $hostWindowNumber))
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
            TTPreviewHorizontalKeyPolicy.releaseFileListKeyboardFocus(windowNumber: hostWindowNumber)
        }
        .onChange(of: rootDirectory) { oldRoot, newRoot in
            guard oldRoot != newRoot else { return }
            if restoreArchiveColumns(for: newRoot) { return }

            let explicitTarget = initialSelectedPath ?? activeViewModel?.initialSelectedFilePath
            if let target = explicitTarget, !target.isEmpty,
               let resolved = resolveValidDescendantHierarchy(for: target, under: newRoot) {
                selectedPaths = [:]
                multiSelectedPaths = []
                columnPaths = resolved.columns
                selectedPaths = resolved.selected
                selectedItem = resolved.item
                activeViewModel?.initialSelectedFilePath = nil
                activeViewModel?.selectionState.select(resolved.item)
                onSelectItem?(resolved.item)
                scrollTarget = HorizontalScrollTarget(id: newRoot.absoluteString, anchor: .leading)
                perColumnSortOption = [:]
                activeViewModel?.activeBrowsingDirectory = resolved.columns.last == newRoot ? nil : resolved.columns.last
                return
            }

            // 1. If newRoot already exists in current columnPaths, truncate down to it smoothly
            if let existingIndex = columnPaths.firstIndex(of: newRoot) {
                withAnimation(Self.columnSpringAnimation) {
                    columnPaths = Array(columnPaths.prefix(existingIndex + 1))
                    for key in selectedPaths.keys where key >= existingIndex {
                        selectedPaths.removeValue(forKey: key)
                    }
                    let sort = perColumnSortOption[existingIndex] ?? sortOption
                    let key = "\(newRoot.absoluteString)_\(sort.rawValue)"
                    if let item = selectedItem, cachedColumnItems[key]?.contains(where: { $0.path == item.path }) == true {
                        selectedPaths[existingIndex] = item.path
                    } else {
                        selectedItem = nil
                        activeViewModel?.selectionState.select(nil)
                    }
                    scrollTarget = HorizontalScrollTarget(id: newRoot.absoluteString, anchor: .leading)
                    activeViewModel?.activeBrowsingDirectory = nil
                }
                return
            }

            // 2. Direct root directory navigation (including sidebar clicks to ancestor/sibling folders)
            selectedPaths = [:]
            multiSelectedPaths = []
            columnPaths = [newRoot]
            selectedItem = nil
            activeViewModel?.selectionState.clear()
            scrollTarget = HorizontalScrollTarget(id: newRoot.absoluteString, anchor: .leading)
            perColumnSortOption = [:]
            activeViewModel?.activeBrowsingDirectory = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipArchiveUnlockedRefresh"))) { _ in
            cachedColumnItems = [:]
            refreshKey = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipRevealDescendantInMillerColumns"))) { notif in
            if let notifWindowID = notif.userInfo?["windowID"] as? UUID,
               let myWindowID = activeViewModel?.windowID,
               notifWindowID != myWindowID {
                return
            }
            guard let targetPath = (notif.object as? String) ?? activeViewModel?.initialSelectedFilePath,
                  !targetPath.isEmpty,
                  let resolved = Self.resolveValidDescendantHierarchy(for: targetPath, under: rootDirectory) else {
                return
            }
            selectedPaths = [:]
            multiSelectedPaths = []
            columnPaths = resolved.columns
            selectedPaths = resolved.selected
            selectedItem = resolved.item
            activeViewModel?.initialSelectedFilePath = nil
            activeViewModel?.selectionState.select(resolved.item)
            onSelectItem?(resolved.item)
            if let deepest = resolved.columns.last {
                scrollTarget = HorizontalScrollTarget(id: deepest.absoluteString, anchor: .trailing)
                activeViewModel?.activeBrowsingDirectory = deepest == rootDirectory ? nil : deepest
            }
            onColumnStateChanged?(columnPaths, selectedPaths, selectedItem)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipItemRenamedNotification"))) { notif in
            let newURL: URL? = (notif.object as? URL)
                ?? (notif.userInfo?["newURL"] as? URL)
                ?? (notif.object as? String).flatMap { URL(fileURLWithPath: $0) }
                ?? (notif.userInfo?["newPath"] as? String).flatMap { URL(fileURLWithPath: $0) }
            guard let newURL else { return }
            let oldURL: URL? = (notif.userInfo?["oldURL"] as? URL)
                ?? (notif.userInfo?["oldPath"] as? String).flatMap { URL(fileURLWithPath: $0) }
                ?? selectedItem.flatMap { URL(fileURLWithPath: $0.path) }
            
            for (colIdx, path) in selectedPaths {
                if let old = oldURL, path == old.path || path == old.absoluteString {
                    selectedPaths[colIdx] = newURL.path
                } else if path == selectedItem?.path {
                    selectedPaths[colIdx] = newURL.path
                }
            }
            
            if let old = oldURL {
                columnPaths = columnPaths.map { colURL in
                    if colURL == old {
                        return newURL
                    } else if colURL.path.hasPrefix(old.path + "/") {
                        let rel = String(colURL.path.dropFirst(old.path.count))
                        return URL(fileURLWithPath: newURL.path + rel)
                    }
                    return colURL
                }
            }
            
            let newItem = DiskItemInfo(url: newURL)
            selectedItem = newItem
            activeViewModel?.selectionState.select(newItem)
            onSelectItem?(newItem)
            Task {
                await DiskDirectoryScanner.shared.invalidateAllCache()
            }
            cachedColumnItems = [:]
            refreshKey = UUID()
        }
    }
    
    private let defaultColumnWidth: CGFloat = 260
    
    // MARK: - Viewport Column Geometry Engine
    
    public static func computeColumnWidth(
        for index: Int,
        totalColumns: Int,
        availableWidth: CGFloat,
        columnWidths: [Int: CGFloat] = [:],
        defaultColumnWidth: CGFloat = SingleMillerColumnView.defaultWidth,
        minComfortableWidth: CGFloat = SingleMillerColumnView.minComfortableWidth
    ) -> CGFloat {
        guard totalColumns > 0, index >= 0, index < totalColumns else {
            return defaultColumnWidth
        }
        
        let preferredWidth: (Int) -> CGFloat = { idx in
            if let custom = columnWidths[idx] {
                return max(custom, minComfortableWidth)
            }
            return defaultColumnWidth
        }
        
        let totalPreferredWidth = (0..<totalColumns).reduce(CGFloat(0)) { $0 + preferredWidth($1) }
        
        // Underflow mode: expand the active leaf column to flush against the inspector divider
        if totalPreferredWidth < availableWidth {
            if index == totalColumns - 1 {
                let precedingSum = (0..<(totalColumns - 1)).reduce(CGFloat(0)) { $0 + preferredWidth($1) }
                return max(preferredWidth(index), availableWidth - precedingSum)
            } else {
                return preferredWidth(index)
            }
        }
        
        // 3-Column Elastic Fit rule:
        // When totalColumns >= 3, availableWidth >= minComfortableWidth * 3.0 (600pt),
        // and availableWidth < defaultColumnWidth * 3.0 (780pt):
        if totalColumns >= 3 && availableWidth >= minComfortableWidth * 3.0 && availableWidth < defaultColumnWidth * 3.0 {
            let hasExceedingCustomWidth = columnWidths.values.contains(where: { $0 > availableWidth })
            if totalColumns == 3 && !hasExceedingCustomWidth {
                if let custom = columnWidths[index] {
                    return max(custom, minComfortableWidth)
                }
                if columnWidths.isEmpty {
                    return index == 2 ? (availableWidth - 2 * floor(availableWidth / 3.0)) : floor(availableWidth / 3.0)
                }
                return floor(availableWidth / 3.0)
            } else if totalColumns > 3 {
                if let custom = columnWidths[index] {
                    return max(custom, minComfortableWidth)
                }
                return floor(availableWidth / 3.0)
            }
        }
        
        // Overflow mode: preserve preferred widths and allow horizontal scrolling
        return preferredWidth(index)
    }

    private func computeColumnWidth(for index: Int, availableWidth: CGFloat) -> CGFloat {
        Self.computeColumnWidth(
            for: index,
            totalColumns: columnPaths.count,
            availableWidth: availableWidth,
            columnWidths: columnWidths,
            defaultColumnWidth: defaultColumnWidth,
            minComfortableWidth: SingleMillerColumnView.minComfortableWidth
        )
    }
    
    private func deleteSelectedVirtualEntry() {
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
            }
        }
    }

    private func resolveValidDescendantHierarchy(for targetPath: String, under rootURL: URL) -> (columns: [URL], selected: [Int: String], item: DiskItemInfo)? {
        Self.resolveValidDescendantHierarchy(for: targetPath, under: rootURL)
    }

    public static func resolveValidDescendantHierarchy(for targetPath: String, under rootURL: URL) -> (columns: [URL], selected: [Int: String], item: DiskItemInfo)? {
        let standardizedTarget = URL(fileURLWithPath: targetPath).standardizedFileURL
        let standardizedRoot = rootURL.standardizedFileURL
        
        guard standardizedTarget.path != standardizedRoot.path else { return nil }
        
        let rootPrefix = standardizedRoot.path.hasSuffix("/") ? standardizedRoot.path : (standardizedRoot.path + "/")
        guard standardizedTarget.path.hasPrefix(rootPrefix) else {
            return nil
        }
        
        if standardizedTarget.deletingLastPathComponent().path == standardizedRoot.path {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: standardizedTarget.path, isDirectory: &isDir)
            guard exists else { return nil }
            
            let cols = isDir.boolValue ? [standardizedRoot, standardizedTarget] : [standardizedRoot]
            let selected = [0: standardizedTarget.path]
            let item = DiskItemInfo(url: standardizedTarget)
            return (cols, selected, item)
        }
        
        let relative = String(standardizedTarget.path.dropFirst(rootPrefix.count))
        let segments = relative.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return nil }
        
        var chain: [URL] = [standardizedRoot]
        var curr = standardizedRoot
        var selected: [Int: String] = [:]
        
        for (idx, seg) in segments.enumerated() {
            curr.appendPathComponent(seg)
            let stepURL = curr.standardizedFileURL
            selected[idx] = stepURL.path
            
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: stepURL.path, isDirectory: &isDir), isDir.boolValue {
                chain.append(stepURL)
            }
        }
        
        let leafItem = DiskItemInfo(url: standardizedTarget)
        return (chain, selected, leafItem)
    }

    func millerColumn(index: Int, dirURL: URL, availableWidth: CGFloat) -> some View {
        let selectedPath = selectedPaths[index]
        let currentSort = perColumnSortOption[index] ?? sortOption
        let cacheKey = "\(dirURL.absoluteString)_\(currentSort.rawValue)"
        let rawItems = cachedColumnItems[cacheKey]
        let query = viewModel?.explorerState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let items: [DiskItemInfo]? = {
            guard let raw = rawItems else { return nil }
            guard !query.isEmpty else { return raw }
            return raw.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }()
        let currentWidth = computeColumnWidth(for: index, availableWidth: availableWidth)
        let canGoParent = dirURL.path != "/" && dirURL.pathComponents.count > 1
        let isColumnActive = (index == activeColumnIndex)
        
        let isLeaf = (index == columnPaths.count - 1)
        let totalPreferred = (0..<columnPaths.count).reduce(CGFloat(0)) { sum, idx in
            let w = columnWidths[idx].map { max($0, SingleMillerColumnView.minComfortableWidth) } ?? defaultColumnWidth
            return sum + w
        }
        let isUnderflow = totalPreferred < availableWidth
        let showTrailingDivider = !isLeaf || !isUnderflow
        
        return SingleMillerColumnView(
            index: index,
            dirURL: dirURL,
            selectedPath: selectedPath,
            currentSort: currentSort,
            items: items,
            currentWidth: currentWidth,
            showTrailingDivider: showTrailingDivider,
            canGoParent: canGoParent,
            isColumnActive: isColumnActive,
            multiSelectedPaths: multiSelectedPaths,
            activeSearchQuery: query,
            onClearSearchQuery: { activeViewModel?.explorerState.searchQuery = "" },
            onPrependParent: { prependParentColumn(for: dirURL) },
            onChangeSort: { perColumnSortOption[index] = $0 },
            onSelectArchive: onSelectArchive ?? { _ in },
            onCompressPath: onCompressPath ?? { _ in },
            onSelectItem: { it, idx, cmd, shift, dir in
                handleFileListClickForKeyboardOwnership(clickedItem: it)
                selectItem(item: it, columnIndex: idx, isCommand: cmd, isShift: shift, dirURL: dir)
            },
            onActivateItem: { it, idx, dir in
                handleFileListClickForKeyboardOwnership(clickedItem: it)
                activateItem(item: it, columnIndex: idx, dirURL: dir)
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
                if isArchiveLocation(dirURL) {
                    Task { await activeViewModel?.refreshAcceptedArchive(at: dirURL) }
                } else {
                    Task { await DiskDirectoryScanner.shared.invalidateAllCache() }
                    cachedColumnItems.removeAll()
                    refreshKey = UUID()
                }
            },
            onSelectAll: { selectAllInActiveColumn() },
            onWidthChanged: { w in columnWidths[index] = w }
        )
        .frame(maxHeight: .infinity)
        .task(id: "\(cacheKey)_\(refreshKey.uuidString)") {
            await loadColumnContents(index: index, dirURL: dirURL, currentSort: currentSort, cacheKey: cacheKey)
        }
    }

    public static func returnKeyboardFocusToFileList(windowNumber: Int?) {
        TTPreviewHorizontalKeyPolicy.returnKeyboardFocusToFileList(windowNumber: windowNumber)
    }

    private func handleFileListClickForKeyboardOwnership(clickedItem: DiskItemInfo?) {
        let winNum = hostWindowNumber
            ?? activeViewModel.flatMap { BrowserWindowRegistry.shared.nsWindow(for: $0.windowID)?.windowNumber }
            ?? NSApp.keyWindow?.windowNumber
        if let clickedItem,
           selectedItem?.path != clickedItem.path,
           TTPreviewHorizontalKeyPolicy.ownsHorizontalArrowKeys(
               previewType: nil,
               url: URL(fileURLWithPath: clickedItem.path),
               fileName: clickedItem.name
           ) {
            TTPreviewHorizontalKeyPolicy.releaseFileListKeyboardFocus(windowNumber: winNum)
        } else {
            TTPreviewHorizontalKeyPolicy.returnKeyboardFocusToFileList(windowNumber: winNum)
        }
    }
}
