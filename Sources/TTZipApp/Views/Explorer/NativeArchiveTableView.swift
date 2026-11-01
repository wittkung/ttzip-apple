// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// AppKit TableView cell view for archive entries.
public final class NativeArchiveTableCellView: NSTableCellView {
    public let iconImageView = NSImageView()
    public let primaryLabel = NSTextField(labelWithString: "")
    public let secondaryBadge = NSTextField(labelWithString: "")
    
    private var labelLeadingWithIcon: NSLayoutConstraint!
    private var labelLeadingWithoutIcon: NSLayoutConstraint!
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    private func setupViews() {
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryBadge.translatesAutoresizingMaskIntoConstraints = false
        
        primaryLabel.font = .systemFont(ofSize: 13, weight: .regular)
        primaryLabel.lineBreakMode = .byTruncatingMiddle
        primaryLabel.textColor = .labelColor
        
        secondaryBadge.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        secondaryBadge.textColor = .secondaryLabelColor
        
        addSubview(iconImageView)
        addSubview(primaryLabel)
        addSubview(secondaryBadge)
        
        self.imageView = iconImageView
        self.textField = primaryLabel
        
        let withIcon = primaryLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8)
        let withoutIcon = primaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        labelLeadingWithIcon = withIcon
        labelLeadingWithoutIcon = withoutIcon
        
        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),
            
            withIcon,
            primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            primaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            
            secondaryBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            secondaryBadge.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    
    public func configureName(name: String, isDir: Bool) {
        iconImageView.isHidden = false
        secondaryBadge.isHidden = true
        labelLeadingWithoutIcon.isActive = false
        labelLeadingWithIcon.isActive = true
        let iconName = isDir ? "folder.fill" : Self.fileIconName(name: name)
        iconImageView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconImageView.contentTintColor = isDir ? NSColor(red: 0.17, green: 0.48, blue: 0.29, alpha: 1.0) : .labelColor
        primaryLabel.alignment = .left
        primaryLabel.textColor = .labelColor
        primaryLabel.font = .systemFont(ofSize: 13, weight: .regular)
        primaryLabel.lineBreakMode = .byTruncatingMiddle
        primaryLabel.stringValue = name
    }
    
    public func configureSize(size: UInt64, isDir: Bool) {
        iconImageView.isHidden = true
        secondaryBadge.isHidden = true
        labelLeadingWithIcon.isActive = false
        labelLeadingWithoutIcon.isActive = true
        primaryLabel.stringValue = isDir ? "--" : ByteCountFormatterCache.string(fromByteCount: Int64(size))
        primaryLabel.textColor = .secondaryLabelColor
        primaryLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        primaryLabel.lineBreakMode = .byClipping
        primaryLabel.alignment = .right
    }
    
    public func configureKind(name: String, isDir: Bool) {
        iconImageView.isHidden = true
        secondaryBadge.isHidden = true
        labelLeadingWithIcon.isActive = false
        labelLeadingWithoutIcon.isActive = true
        if isDir {
            primaryLabel.stringValue = "Folder"
        } else {
            let ext = (name as NSString).pathExtension.uppercased()
            primaryLabel.stringValue = ext.isEmpty ? "File" : ext
        }
        primaryLabel.textColor = NSColor(red: 0.17, green: 0.48, blue: 0.29, alpha: 1.0)
        primaryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.alignment = .left
    }
    
    public func configureDate(mtimeSecs: Int64) {
        iconImageView.isHidden = true
        secondaryBadge.isHidden = true
        labelLeadingWithIcon.isActive = false
        labelLeadingWithoutIcon.isActive = true
        if mtimeSecs > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(mtimeSecs))
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            primaryLabel.stringValue = formatter.string(from: date)
        } else {
            primaryLabel.stringValue = "--"
        }
        primaryLabel.textColor = .secondaryLabelColor
        primaryLabel.font = .systemFont(ofSize: 11, weight: .regular)
        primaryLabel.lineBreakMode = .byClipping
        primaryLabel.alignment = .left
    }
    
    private static func fileIconName(name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "epub", "mobi", "azw3", "cbz", "cbr": return "book.fill"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp", "tiff": return "photo.fill"
        case "mp4", "mov", "m4v", "avi", "mkv", "webm": return "film.fill"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "swift", "json", "c", "cpp", "h", "md", "py", "sh", "xml", "html", "css", "rs", "go", "ts", "js": return "doc.text.fill"
        case "txt", "rtf", "doc", "docx", "pages": return "doc.richtext.fill"
        case "xls", "xlsx", "numbers", "csv": return "tablecells.fill"
        case "ppt", "pptx", "key": return "rectangle.inset.filled.and.person.filled"
        case "zip", "7z", "tar", "gz", "bz2", "xz", "rar": return "archivebox.fill"
        case "dmg", "iso", "pkg": return "opticaldisc.fill"
        case "app": return "app.fill"
        default: return "doc.fill"
        }
    }
}

/// Custom AppKit NSTableView supporting Vim navigation, Type-to-Filter, and Space preview.
public final class NativeArchiveNSTableView: NSTableView {
    public var onSpacePreview: (() -> Void)? = nil
    public var onPrimaryAction: (() -> Void)? = nil
    public var onTypeToFilter: ((String) -> Void)? = nil
    public var onNavigateParent: (() -> Void)? = nil
    public var onRowSelected: ((Int) -> Void)? = nil
    
    private var pendingG: Bool = false
    
    public override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }
        
        // Handle Space for Preview
        if chars == " " {
            onSpacePreview?()
            return
        }
        
        // Handle Return / Enter for Primary Action (Open folder / preview)
        if event.keyCode == 36 {
            onPrimaryAction?()
            return
        }
        
        // Handle Esc to clear/navigate parent
        if event.keyCode == 53 {
            onNavigateParent?()
            return
        }
        
        // Vim Navigation Keys (without Command/Control/Option modifiers)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty || flags == .shift {
            if chars == "j" { // Move Down
                pendingG = false
                let target = min(numberOfRows - 1, selectedRow + 1)
                if target >= 0 {
                    selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
                    scrollRowToVisible(target)
                    onRowSelected?(target)
                }
                return
            } else if chars == "k" { // Move Up
                pendingG = false
                let target = max(0, selectedRow - 1)
                if target >= 0 && target < numberOfRows {
                    selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
                    scrollRowToVisible(target)
                    onRowSelected?(target)
                }
                return
            } else if chars == "h" { // Navigate Parent
                pendingG = false
                onNavigateParent?()
                return
            } else if chars == "l" { // Open / Descend
                pendingG = false
                onPrimaryAction?()
                return
            } else if chars == "G" { // Jump to Bottom
                pendingG = false
                if numberOfRows > 0 {
                    let target = numberOfRows - 1
                    selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
                    scrollRowToVisible(target)
                    onRowSelected?(target)
                }
                return
            } else if chars == "g" {
                if pendingG { // "gg" -> Jump to Top
                    pendingG = false
                    if numberOfRows > 0 {
                        selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                        scrollRowToVisible(0)
                        onRowSelected?(0)
                    }
                    return
                } else {
                    pendingG = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.pendingG = false
                    }
                    return
                }
            }
            
            // Type-to-Filter: Alphanumeric characters trigger instant search focus
            if chars.count == 1, let firstChar = chars.first, firstChar.isLetter || firstChar.isNumber || firstChar == "_" || firstChar == "-" || firstChar == "." {
                pendingG = false
                onTypeToFilter?(chars)
                return
            }
        }
        
        pendingG = false
        super.keyDown(with: event)
    }
}

/// SwiftUI NSViewRepresentable hosting NativeArchiveNSTableView with 128-row sliding window virtualization.
public struct NativeArchiveTableViewRepresentable: NSViewRepresentable {
    public let adapter: NativeArchiveTableViewAdapterProtocol
    @Binding public var selectedRowIndex: Int?
    public var onPrimaryAction: ((Int) -> Void)? = nil
    public var onSpacePreview: (() -> Void)? = nil
    public var onTypeToFilter: ((String) -> Void)? = nil
    public var onNavigateParent: (() -> Void)? = nil
    public var onContextMenuExtract: ((Int) -> Void)? = nil
    public var onContextMenuCopy: ((Int) -> Void)? = nil

    public init(
        adapter: NativeArchiveTableViewAdapterProtocol,
        selectedRowIndex: Binding<Int?>,
        onPrimaryAction: ((Int) -> Void)? = nil,
        onSpacePreview: (() -> Void)? = nil,
        onTypeToFilter: ((String) -> Void)? = nil,
        onNavigateParent: (() -> Void)? = nil,
        onContextMenuExtract: ((Int) -> Void)? = nil,
        onContextMenuCopy: ((Int) -> Void)? = nil
    ) {
        self.adapter = adapter
        self._selectedRowIndex = selectedRowIndex
        self.onPrimaryAction = onPrimaryAction
        self.onSpacePreview = onSpacePreview
        self.onTypeToFilter = onTypeToFilter
        self.onNavigateParent = onNavigateParent
        self.onContextMenuExtract = onContextMenuExtract
        self.onContextMenuCopy = onContextMenuCopy
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
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
        
        // Setup Columns
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
        
        // Wire Key Actions
        tableView.onSpacePreview = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSpacePreview?()
        }
        tableView.onPrimaryAction = { [weak coordinator = context.coordinator] in
            coordinator?.handlePrimary()
        }
        tableView.onTypeToFilter = { [weak coordinator = context.coordinator] str in
            coordinator?.parent.onTypeToFilter?(str)
        }
        tableView.onNavigateParent = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onNavigateParent?()
        }
        tableView.onRowSelected = { [weak coordinator = context.coordinator] row in
            coordinator?.parent.selectedRowIndex = row
        }
        
        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        
        // Listen to batch load events to dynamically reload sliding window rows
        adapter.onDataBatchLoaded = { [weak tableView] indices in
            tableView?.reloadData(forRowIndexes: indices, columnIndexes: IndexSet(integersIn: 0..<4))
        }
        
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NativeArchiveNSTableView else { return }
        context.coordinator.parent = self
        
        adapter.onDataBatchLoaded = { [weak tableView] indices in
            tableView?.reloadData(forRowIndexes: indices, columnIndexes: IndexSet(integersIn: 0..<4))
        }

        if tableView.numberOfRows != adapter.totalRowCount {
            tableView.reloadData()
        }
        
        if let sel = selectedRowIndex, sel >= 0 && sel < adapter.totalRowCount {
            if tableView.selectedRow != sel {
                tableView.selectRowIndexes(IndexSet(integer: sel), byExtendingSelection: false)
            }
        } else if selectedRowIndex == nil && tableView.selectedRow >= 0 {
            tableView.deselectAll(nil)
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeArchiveTableViewRepresentable
        weak var tableView: NativeArchiveNSTableView?
        private var currentSortKey: SortKey = .name
        private var currentSortDirection: SortDirection = .ascending

        init(_ parent: NativeArchiveTableViewRepresentable) {
            self.parent = parent
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            parent.adapter.totalRowCount
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let col = tableColumn else { return nil }
            let identifier = col.identifier
            
            var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeArchiveTableCellView
            if cell == nil {
                cell = NativeArchiveTableCellView(frame: .zero)
                cell?.identifier = identifier
            }
            
            // Check sliding window availability
            let visibleNSRange = tableView.rows(in: tableView.visibleRect)
            if visibleNSRange.location != NSNotFound, let range = Range(visibleNSRange), !range.isEmpty {
                parent.adapter.ensureWindowAvailable(visibleRange: range, bufferSize: 128)
            }
            
            guard let entry = parent.adapter.entry(at: row) else {
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
            parent.selectedRowIndex = row >= 0 ? row : nil
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
            
            // Update table header indicators
            for col in tableView.tableColumns {
                tableView.setIndicatorImage(nil, in: col)
            }
            let indicator = NSImage(
                systemSymbolName: (currentSortDirection == .ascending) ? "chevron.up" : "chevron.down",
                accessibilityDescription: nil
            )
            tableView.setIndicatorImage(indicator, in: tableColumn)
            
            parent.adapter.setSortCriteria(key: currentSortKey, direction: currentSortDirection)
            tableView.reloadData()
        }

        @objc func onTableDoubleClicked(_ sender: AnyObject) {
            handlePrimary()
        }

        func handlePrimary() {
            guard let tv = tableView, tv.selectedRow >= 0 else { return }
            parent.onPrimaryAction?(tv.selectedRow)
        }
    }
}
