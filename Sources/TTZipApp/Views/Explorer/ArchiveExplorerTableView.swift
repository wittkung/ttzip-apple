// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// High-performance archive item table view directly backed by `TTZipMetadataDirectView` and `NativeArchiveTableViewAdapter`.
///
/// Features persistent adapter lifecycle management in the NSViewRepresentable Coordinator,
/// eliminating redundant allocations on every SwiftUI state pass while maintaining smooth 60+ FPS navigation.
@MainActor
public struct ArchiveExplorerTableView: View {
    public let filteredEntriesView: ArchiveFilteredEntriesView?
    public let vfsSession: VfsSession?
    public var snapshotContext: VfsSnapshotContext?
    public let metadataView: TTZipMetadataDirectView
    public let visibleIndices: [Int]?
    public var searchQuery: String?
    @Binding public var selectedEntryID: String?
    public var currentArchivePath: String?
    public var activePassword: String?
    public let onSelectEntry: (String?) -> Void
    public var onPreviewEntry: ((ArchiveEntry) -> Void)? = nil
    public var onPreviewEntryPath: ((String) -> Void)? = nil
    public var onReplaceEntry: ((ArchiveEntry) -> Void)? = nil
    public var onDeleteEntry: ((ArchiveEntry) -> Void)? = nil
    public var onExtractEntry: ((ArchiveEntry) -> Void)? = nil
    public var onExtractEntryRef: ((ViewportEntrySnapshot) -> Void)? = nil

    @State private var navigationStack: [UInt32] = [0]

    /// Primary initializer consuming a metadata direct view and optional viewport indices.
    public init(
        metadataView: TTZipMetadataDirectView,
        vfsSession: VfsSession? = nil,
        snapshotContext: VfsSnapshotContext? = nil,
        searchQuery: String? = nil,
        visibleIndices: [Int]? = nil,
        selectedEntryID: Binding<String?>,
        currentArchivePath: String? = nil,
        activePassword: String? = nil,
        onSelectEntry: @escaping (String?) -> Void,
        onPreviewEntry: ((ArchiveEntry) -> Void)? = nil,
        onPreviewEntryPath: ((String) -> Void)? = nil,
        onReplaceEntry: ((ArchiveEntry) -> Void)? = nil,
        onDeleteEntry: ((ArchiveEntry) -> Void)? = nil,
        onExtractEntry: ((ArchiveEntry) -> Void)? = nil,
        onExtractEntryRef: ((ViewportEntrySnapshot) -> Void)? = nil
    ) {
        self.filteredEntriesView = nil
        self.vfsSession = vfsSession
        self.snapshotContext = snapshotContext
        self.searchQuery = searchQuery
        self.metadataView = metadataView
        self.visibleIndices = visibleIndices
        self._selectedEntryID = selectedEntryID
        self.currentArchivePath = currentArchivePath
        self.activePassword = activePassword
        self.onSelectEntry = onSelectEntry
        self.onPreviewEntry = onPreviewEntry
        self.onPreviewEntryPath = onPreviewEntryPath
        self.onReplaceEntry = onReplaceEntry
        self.onDeleteEntry = onDeleteEntry
        self.onExtractEntry = onExtractEntry
        self.onExtractEntryRef = onExtractEntryRef
    }

    /// Primary initializer consuming zero-copy `ArchiveFilteredEntriesView`.
    public init(
        filteredEntries: ArchiveFilteredEntriesView,
        vfsSession: VfsSession? = nil,
        snapshotContext: VfsSnapshotContext? = nil,
        searchQuery: String? = nil,
        selectedEntryID: Binding<String?>,
        currentArchivePath: String? = nil,
        activePassword: String? = nil,
        onSelectEntry: @escaping (String?) -> Void,
        onPreviewEntry: ((ArchiveEntry) -> Void)? = nil,
        onPreviewEntryPath: ((String) -> Void)? = nil,
        onReplaceEntry: ((ArchiveEntry) -> Void)? = nil,
        onDeleteEntry: ((ArchiveEntry) -> Void)? = nil,
        onExtractEntry: ((ArchiveEntry) -> Void)? = nil
    ) {
        self.filteredEntriesView = filteredEntries
        self.vfsSession = vfsSession
        self.snapshotContext = snapshotContext
        self.searchQuery = searchQuery
        self.metadataView = .empty
        self.visibleIndices = nil
        self._selectedEntryID = selectedEntryID
        self.currentArchivePath = currentArchivePath
        self.activePassword = activePassword
        self.onSelectEntry = onSelectEntry
        self.onPreviewEntry = onPreviewEntry
        self.onPreviewEntryPath = onPreviewEntryPath
        self.onReplaceEntry = onReplaceEntry
        self.onDeleteEntry = onDeleteEntry
        self.onExtractEntry = onExtractEntry
        self.onExtractEntryRef = nil
    }

    /// Backward-compatibility initializer accepting legacy array of `ArchiveEntry`.
    public init(
        filteredEntries: [ArchiveEntry],
        vfsSession: VfsSession? = nil,
        snapshotContext: VfsSnapshotContext? = nil,
        searchQuery: String? = nil,
        selectedEntryID: Binding<String?>,
        currentArchivePath: String? = nil,
        activePassword: String? = nil,
        onSelectEntry: @escaping (String?) -> Void,
        onPreviewEntry: ((ArchiveEntry) -> Void)? = nil,
        onPreviewEntryPath: ((String) -> Void)? = nil,
        onReplaceEntry: ((ArchiveEntry) -> Void)? = nil,
        onDeleteEntry: ((ArchiveEntry) -> Void)? = nil,
        onExtractEntry: ((ArchiveEntry) -> Void)? = nil
    ) {
        self.init(
            filteredEntries: ArchiveFilteredEntriesView(source: filteredEntries),
            vfsSession: vfsSession,
            snapshotContext: snapshotContext,
            searchQuery: searchQuery,
            selectedEntryID: selectedEntryID,
            currentArchivePath: currentArchivePath,
            activePassword: activePassword,
            onSelectEntry: onSelectEntry,
            onPreviewEntry: onPreviewEntry,
            onPreviewEntryPath: onPreviewEntryPath,
            onReplaceEntry: onReplaceEntry,
            onDeleteEntry: onDeleteEntry,
            onExtractEntry: onExtractEntry
        )
    }

    @ViewBuilder
    public var body: some View {
        ArchiveExplorerTableViewRepresentable(
            vfsSession: vfsSession,
            snapshotContext: snapshotContext,
            filteredEntriesView: filteredEntriesView,
            metadataView: metadataView,
            visibleIndices: visibleIndices,
            searchQuery: searchQuery,
            selectedEntryID: $selectedEntryID,
            parentId: navigationStack.last ?? 0,
            onNavigateToDirectory: { newParentId in
                navigationStack.append(newParentId)
                selectedEntryID = nil
                onSelectEntry(nil)
            },
            onNavigateParent: {
                if navigationStack.count > 1 {
                    navigationStack.removeLast()
                    selectedEntryID = nil
                    onSelectEntry(nil)
                }
            },
            onSelectEntry: onSelectEntry,
            onPreviewEntry: onPreviewEntry,
            onPreviewEntryPath: onPreviewEntryPath,
            onExtractEntry: onExtractEntry
        )
        .background(Color.clear)
    }
}

/// NSViewRepresentable hosting AppKit NSTableView with persistent adapter lifecycle.
public struct ArchiveExplorerTableViewRepresentable: NSViewRepresentable {
    public let vfsSession: VfsSession?
    public let snapshotContext: VfsSnapshotContext?
    public let filteredEntriesView: ArchiveFilteredEntriesView?
    public let metadataView: TTZipMetadataDirectView
    public let visibleIndices: [Int]?
    public let searchQuery: String?
    @Binding public var selectedEntryID: String?
    public let parentId: UInt32
    public let onNavigateToDirectory: (UInt32) -> Void
    public let onNavigateParent: () -> Void
    public let onSelectEntry: (String?) -> Void
    public let onPreviewEntry: ((ArchiveEntry) -> Void)?
    public let onPreviewEntryPath: ((String) -> Void)?
    public let onExtractEntry: ((ArchiveEntry) -> Void)?

    public init(
        vfsSession: VfsSession?,
        snapshotContext: VfsSnapshotContext?,
        filteredEntriesView: ArchiveFilteredEntriesView?,
        metadataView: TTZipMetadataDirectView,
        visibleIndices: [Int]?,
        searchQuery: String?,
        selectedEntryID: Binding<String?>,
        parentId: UInt32,
        onNavigateToDirectory: @escaping (UInt32) -> Void,
        onNavigateParent: @escaping () -> Void,
        onSelectEntry: @escaping (String?) -> Void,
        onPreviewEntry: ((ArchiveEntry) -> Void)? = nil,
        onPreviewEntryPath: ((String) -> Void)? = nil,
        onExtractEntry: ((ArchiveEntry) -> Void)? = nil
    ) {
        self.vfsSession = vfsSession
        self.snapshotContext = snapshotContext
        self.filteredEntriesView = filteredEntriesView
        self.metadataView = metadataView
        self.visibleIndices = visibleIndices
        self.searchQuery = searchQuery
        self._selectedEntryID = selectedEntryID
        self.parentId = parentId
        self.onNavigateToDirectory = onNavigateToDirectory
        self.onNavigateParent = onNavigateParent
        self.onSelectEntry = onSelectEntry
        self.onPreviewEntry = onPreviewEntry
        self.onPreviewEntryPath = onPreviewEntryPath
        self.onExtractEntry = onExtractEntry
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.setupAdapter(from: self)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let tableView = NativeArchiveNSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 140
        nameCol.width = 240
        nameCol.resizingMask = [.autoresizingMask, .userResizingMask]
        tableView.addTableColumn(nameCol)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Size"
        sizeCol.minWidth = 65
        sizeCol.width = 75
        sizeCol.resizingMask = [.userResizingMask]
        tableView.addTableColumn(sizeCol)

        let kindCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindCol.title = "Kind"
        kindCol.minWidth = 55
        kindCol.width = 65
        kindCol.resizingMask = [.userResizingMask]
        tableView.addTableColumn(kindCol)

        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "Date Modified"
        dateCol.minWidth = 95
        dateCol.width = 115
        dateCol.resizingMask = [.userResizingMask]
        tableView.addTableColumn(dateCol)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.onTableDoubleClicked(_:))

        tableView.onSpacePreview = { [weak coordinator = context.coordinator] in
            coordinator?.handleSpacePreview()
        }
        tableView.onPrimaryAction = { [weak coordinator = context.coordinator] in
            coordinator?.handlePrimary()
        }
        tableView.onTypeToFilter = { _ in }
        tableView.onNavigateParent = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onNavigateParent()
        }
        tableView.onRowSelected = { [weak coordinator = context.coordinator] row in
            coordinator?.handleRowSelected(row)
        }

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView

        context.coordinator.bindAdapterBatchLoader()

        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NativeArchiveNSTableView else { return }
        context.coordinator.parent = self
        context.coordinator.updateAdapter(from: self, tableView: tableView)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ArchiveExplorerTableViewRepresentable
        public var adapter: NativeArchiveTableViewAdapter?
        weak var tableView: NativeArchiveNSTableView?

        private var currentSortKey: SortKey = .name
        private var currentSortDirection: SortDirection = .ascending
        private var currentParentId: UInt32 = 0
        private var currentSearchQuery: String? = nil
        private weak var currentSnapshotContext: VfsSnapshotContext? = nil
        private var currentVfsSession: VfsSession? = nil

        init(_ parent: ArchiveExplorerTableViewRepresentable) {
            self.parent = parent
            self.currentParentId = parent.parentId
            self.currentSearchQuery = parent.searchQuery
            self.currentSnapshotContext = parent.snapshotContext
            self.currentVfsSession = parent.vfsSession
        }

        func setupAdapter(from rep: ArchiveExplorerTableViewRepresentable) {
            self.adapter = createAdapter(from: rep)
            self.currentParentId = rep.parentId
            self.currentSearchQuery = rep.searchQuery
            self.currentSnapshotContext = rep.snapshotContext
            self.currentVfsSession = rep.vfsSession
        }

        func createAdapter(from rep: ArchiveExplorerTableViewRepresentable) -> NativeArchiveTableViewAdapter {
            let ad: NativeArchiveTableViewAdapter
            if let ctx = rep.snapshotContext {
                ad = NativeArchiveTableViewAdapter(
                    snapshotContext: ctx,
                    parentId: rep.parentId,
                    sortKey: currentSortKey,
                    sortDirection: currentSortDirection
                )
            } else if let session = rep.vfsSession {
                ad = NativeArchiveTableViewAdapter(
                    session: session,
                    parentId: rep.parentId,
                    sortKey: currentSortKey,
                    sortDirection: currentSortDirection
                )
            } else if let entriesView = rep.filteredEntriesView {
                ad = NativeArchiveTableViewAdapter(
                    entries: Array(entriesView),
                    sortKey: currentSortKey,
                    sortDirection: currentSortDirection
                )
            } else if let indices = rep.visibleIndices {
                let entries = indices.compactMap { rep.metadataView.entry(at: $0)?.toArchiveEntry() }
                ad = NativeArchiveTableViewAdapter(
                    entries: entries,
                    sortKey: currentSortKey,
                    sortDirection: currentSortDirection
                )
            } else {
                let count = rep.metadataView.count
                let entries = (0..<count).compactMap { rep.metadataView.entry(at: $0)?.toArchiveEntry() }
                ad = NativeArchiveTableViewAdapter(
                    entries: entries,
                    sortKey: currentSortKey,
                    sortDirection: currentSortDirection
                )
            }
            if let query = rep.searchQuery, !query.isEmpty {
                ad.setSearchQuery(query: query)
            }
            return ad
        }

        func bindAdapterBatchLoader() {
            adapter?.onDataBatchLoaded = { [weak tableView] indices in
                tableView?.reloadData(forRowIndexes: indices, columnIndexes: IndexSet(integersIn: 0..<4))
            }
        }

        func updateAdapter(from rep: ArchiveExplorerTableViewRepresentable, tableView: NativeArchiveNSTableView) {
            let contextChanged = (rep.snapshotContext !== currentSnapshotContext)
            let sessionChanged = (rep.vfsSession !== currentVfsSession)

            if adapter == nil || contextChanged || sessionChanged {
                setupAdapter(from: rep)
                bindAdapterBatchLoader()
                tableView.reloadData()
                syncSelection(tableView: tableView)
                return
            }

            guard let ad = adapter else { return }

            var needsReload = false
            if rep.parentId != currentParentId {
                currentParentId = rep.parentId
                ad.navigateToDirectory(parentId: rep.parentId)
                needsReload = true
            }

            if rep.searchQuery != currentSearchQuery {
                currentSearchQuery = rep.searchQuery
                ad.setSearchQuery(query: rep.searchQuery)
                needsReload = true
            }

            if needsReload || tableView.numberOfRows != ad.totalRowCount {
                tableView.reloadData()
            }

            syncSelection(tableView: tableView)
        }

        func syncSelection(tableView: NativeArchiveNSTableView) {
            guard let ad = adapter else { return }
            if let selectedPath = parent.selectedEntryID,
               let targetIndex = ad.entryIndex(forPath: selectedPath),
               targetIndex >= 0 && targetIndex < ad.totalRowCount {
                if tableView.selectedRow != targetIndex {
                    tableView.selectRowIndexes(IndexSet(integer: targetIndex), byExtendingSelection: false)
                }
            } else if parent.selectedEntryID == nil && tableView.selectedRow >= 0 {
                tableView.deselectAll(nil)
            }
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            adapter?.totalRowCount ?? 0
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let col = tableColumn else { return nil }
            let identifier = col.identifier

            var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeArchiveTableCellView
            if cell == nil {
                cell = NativeArchiveTableCellView(frame: .zero)
                cell?.identifier = identifier
            }

            let visibleNSRange = tableView.rows(in: tableView.visibleRect)
            if visibleNSRange.location != NSNotFound, let range = Range(visibleNSRange), !range.isEmpty {
                adapter?.ensureWindowAvailable(visibleRange: range, bufferSize: 128)
            }

            guard let entry = adapter?.entry(at: row) else {
                cell?.primaryLabel.stringValue = "..."
                cell?.iconImageView.isHidden = true
                return cell
            }

            switch identifier.rawValue {
            case "name":
                cell?.configureName(name: entry.name, isDir: entry.isDir)
            case "size":
                cell?.configureSize(size: entry.size, isDir: entry.isDir)
            case "kind":
                cell?.configureKind(name: entry.name, isDir: entry.isDir)
            case "date":
                cell?.configureDate(mtimeSecs: entry.mtimeSecs)
            default:
                break
            }

            return cell
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tv = tableView else { return }
            let row = tv.selectedRow
            handleRowSelected(row)
        }

        public func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            let key: SortKey
            switch tableColumn.identifier.rawValue {
            case "name": key = .name
            case "size": key = .size
            case "kind": key = .extension
            case "date": key = .modifiedTime
            default: return
            }

            if currentSortKey == key {
                currentSortDirection = (currentSortDirection == .ascending) ? .descending : .ascending
            } else {
                currentSortKey = key
                currentSortDirection = .ascending
            }

            for col in tableView.tableColumns {
                tableView.setIndicatorImage(nil, in: col)
            }
            let indicator = NSImage(
                systemSymbolName: (currentSortDirection == .ascending) ? "chevron.up" : "chevron.down",
                accessibilityDescription: nil
            )
            tableView.setIndicatorImage(indicator, in: tableColumn)

            adapter?.setSortCriteria(key: currentSortKey, direction: currentSortDirection)
            tableView.reloadData()
        }

        @objc func onTableDoubleClicked(_ sender: AnyObject) {
            handlePrimary()
        }

        func handlePrimary() {
            guard let tv = tableView, tv.selectedRow >= 0, let ad = adapter, let item = ad.entry(at: tv.selectedRow) else { return }
            if item.isDir {
                parent.onNavigateToDirectory(item.nodeId)
            } else {
                parent.selectedEntryID = item.path
                parent.onSelectEntry(item.path)
                if let onPreview = parent.onPreviewEntryPath {
                    onPreview(item.path)
                } else if let onPreview = parent.onPreviewEntry {
                    let entry = ArchiveEntry(
                        path: item.path,
                        uncompressedSize: Int64(item.size),
                        isDirectory: item.isDir,
                        modificationDate: Date(timeIntervalSince1970: TimeInterval(item.mtimeSecs)),
                        isEncrypted: item.isEncrypted
                    )
                    onPreview(entry)
                }
            }
        }

        func handleSpacePreview() {
            if let sel = parent.selectedEntryID {
                parent.onPreviewEntryPath?(sel)
            }
        }

        func handleRowSelected(_ row: Int) {
            if row >= 0, let item = adapter?.entry(at: row) {
                parent.selectedEntryID = item.path
                parent.onSelectEntry(item.path)
            } else {
                parent.selectedEntryID = nil
                parent.onSelectEntry(nil)
            }
        }
    }
}
