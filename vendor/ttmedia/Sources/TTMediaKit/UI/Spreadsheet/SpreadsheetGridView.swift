// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

// MARK: - Responsive Layout Metrics & State Probe

public enum SpreadsheetWidthTier: String, Equatable, Sendable {
    case narrow
    case regular
    case medium
    case wide
}

public struct SpreadsheetLayoutMetrics: Equatable, Sendable {
    public let width: CGFloat
    public let tier: SpreadsheetWidthTier

    public init(width: CGFloat) {
        self.width = max(0, width)
        if width < 380 {
            self.tier = .narrow
        } else if width < 500 {
            self.tier = .regular
        } else if width < 680 {
            self.tier = .medium
        } else {
            self.tier = .wide
        }
    }

    public var showsDocumentTitle: Bool { tier == .wide }
    public var showsInlineSearchField: Bool { tier == .medium || tier == .wide }
    public var showsInlineHeaderAndDelimiterControls: Bool { tier == .wide }
    public var showsInlineJumpAndPageSize: Bool { tier == .wide }
    public var showsExtendedBottomStats: Bool { tier != .narrow }
    public var searchFieldWidth: CGFloat { tier == .wide ? 136 : 84 }
}

public final class SpreadsheetPreviewStateProbeNSView: NSView {
    public var widthTier: SpreadsheetWidthTier = .narrow
    public var measuredWidth: CGFloat = 0
    public var reparseCount: Int = 0
    public var searchQuery: String = ""
    public var selectedCoordinate: SpreadsheetCellCoordinate?
    public var selectedCellContent: String?
    public var mode: SpreadsheetPreviewMode = .table
    public var useFirstRowAsHeader: Bool = false
    public var canSaveInPlace: Bool = false
    public var isPreviewTruncated: Bool = false
    public var formatBadgeTitle: String = ""
    public var selectedSheetName: String = ""
    public var availableSheets: [String] = []
    public var isSearchExpanded: Bool = false
    public var currentPageIndex: Int = 0
    public var pageSizeOption: SpreadsheetPageSizeOption = .hundred
    internal var sheetSelectionGeneration: UInt64 = 0
    internal var sheetLoadingTask: Task<Void, Never>? = nil
    public var setSearchQuery: (@MainActor (String) -> Void)?
    public var setSelectedCoordinate: (@MainActor (SpreadsheetCellCoordinate?) -> Void)?
    public var setMode: (@MainActor (SpreadsheetPreviewMode) -> Void)?
    public var toggleHeaderMode: (@MainActor () -> Void)?
    public var copySelectedCellAction: (@MainActor () -> Void)?
    public var setPageSizeOption: (@MainActor (SpreadsheetPageSizeOption) -> Void)?
    public var setCurrentPageIndex: (@MainActor (Int) -> Void)?
    public var jumpToRow: (@MainActor (Int) -> Void)?
    public var selectSheetAction: (@MainActor (String) -> Void)?
}

struct SpreadsheetPreviewStateProbeRepresentable: NSViewRepresentable {
    let metrics: SpreadsheetLayoutMetrics
    let reparseCount: Int
    let searchQuery: String
    let selectedCoordinate: SpreadsheetCellCoordinate?
    let selectedCellContent: String?
    let mode: SpreadsheetPreviewMode
    let useFirstRowAsHeader: Bool
    let canSaveInPlace: Bool
    let isPreviewTruncated: Bool
    let formatBadgeTitle: String
    let selectedSheetName: String
    let availableSheets: [String]
    let isSearchExpanded: Bool
    let currentPageIndex: Int
    let pageSizeOption: SpreadsheetPageSizeOption
    let sheetSelectionGeneration: UInt64
    let sheetLoadingTask: Task<Void, Never>?
    let setSearchQuery: @MainActor (String) -> Void
    let setSelectedCoordinate: @MainActor (SpreadsheetCellCoordinate?) -> Void
    let setMode: @MainActor (SpreadsheetPreviewMode) -> Void
    let toggleHeaderMode: @MainActor () -> Void
    let copySelectedCellAction: @MainActor () -> Void
    let setPageSizeOption: @MainActor (SpreadsheetPageSizeOption) -> Void
    let setCurrentPageIndex: @MainActor (Int) -> Void
    let jumpToRow: @MainActor (Int) -> Void
    let selectSheetAction: @MainActor (String) -> Void

    func makeNSView(context: Context) -> SpreadsheetPreviewStateProbeNSView {
        let view = SpreadsheetPreviewStateProbeNSView(frame: .zero)
        updateProbe(view)
        return view
    }

    func updateNSView(_ nsView: SpreadsheetPreviewStateProbeNSView, context: Context) {
        updateProbe(nsView)
    }

    private func updateProbe(_ view: SpreadsheetPreviewStateProbeNSView) {
        view.widthTier = metrics.tier
        view.measuredWidth = metrics.width
        view.reparseCount = reparseCount
        view.searchQuery = searchQuery
        view.selectedCoordinate = selectedCoordinate
        view.selectedCellContent = selectedCellContent
        view.mode = mode
        view.useFirstRowAsHeader = useFirstRowAsHeader
        view.canSaveInPlace = canSaveInPlace
        view.isPreviewTruncated = isPreviewTruncated
        view.formatBadgeTitle = formatBadgeTitle
        view.selectedSheetName = selectedSheetName
        view.availableSheets = availableSheets
        view.isSearchExpanded = isSearchExpanded
        view.currentPageIndex = currentPageIndex
        view.pageSizeOption = pageSizeOption
        view.sheetSelectionGeneration = sheetSelectionGeneration
        view.sheetLoadingTask = sheetLoadingTask
        view.setSearchQuery = setSearchQuery
        view.setSelectedCoordinate = setSelectedCoordinate
        view.setMode = setMode
        view.toggleHeaderMode = toggleHeaderMode
        view.copySelectedCellAction = copySelectedCellAction
        view.setPageSizeOption = setPageSizeOption
        view.setCurrentPageIndex = setCurrentPageIndex
        view.jumpToRow = jumpToRow
        view.selectSheetAction = selectSheetAction
    }
}

// MARK: - Compact AppKit NSMenu Presenter (Avoids NSPopUpButton Width Inflation)

enum SpreadsheetPopupMenuEntry {
    case sectionHeader(String)
    case separator
    case action(title: String, isChecked: Bool = false, handler: @MainActor () -> Void)
}

@MainActor
final class SpreadsheetPopupMenuInvoker: NSObject {
    static let shared = SpreadsheetPopupMenuInvoker()
    private var handlers: [Int: @MainActor () -> Void] = [:]

    func present(_ entries: [SpreadsheetPopupMenuEntry]) {
        handlers.removeAll()
        let menu = NSMenu()
        var nextTag = 1
        for entry in entries {
            switch entry {
            case .sectionHeader(let title):
                menu.addItem(.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            case .action(let title, let isChecked, let handler):
                let item = NSMenuItem(title: title, action: #selector(handleMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = nextTag
                item.state = isChecked ? .on : .off
                handlers[nextTag] = handler
                nextTag += 1
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {
        handlers[sender.tag]?()
        handlers.removeAll()
    }
}

// MARK: - Auxiliary Spreadsheet Preview Subviews

struct SpreadsheetCellDetailPopoverView: View {
    let coordinateReference: String
    let cellValue: String
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(SpreadsheetPreviewLocalization.cellDetailTitle(coordinateReference))
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                Spacer()
                Button(action: onCopy) {
                    Label(SpreadsheetPreviewLocalization.text(.copyButton), systemImage: "doc.on.doc")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(cellValue)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 240, maxWidth: 360, minHeight: 72, maxHeight: 220)
        }
        .padding(10)
    }
}

struct SpreadsheetJumpRowPopoverView: View {
    let maxRow: Int
    @Binding var jumpRowInput: String
    let onJump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SpreadsheetPreviewLocalization.text(.jumpToRowTitle))
                .font(.system(size: 11.5, weight: .bold))
            Text(SpreadsheetPreviewLocalization.jumpRowRange(maxRow: maxRow))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(SpreadsheetPreviewLocalization.text(.jumpRowPlaceholder), text: $jumpRowInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 90)
                    .onSubmit(onJump)
                Button(SpreadsheetPreviewLocalization.text(.jumpGoButton), action: onJump)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: 200)
    }
}

struct SpreadsheetPaginationControlsView: View {
    @Binding var currentPageIndex: Int
    let totalPages: Int

    var body: some View {
        HStack(spacing: 2) {
            pageButton(icon: "backward.end.fill", size: 8.5, disabled: currentPageIndex <= 0, label: SpreadsheetPreviewLocalization.text(.firstPageHelp)) {
                currentPageIndex = 0
            }
            pageButton(icon: "chevron.left", size: 9.5, weight: .bold, disabled: currentPageIndex <= 0, label: SpreadsheetPreviewLocalization.text(.previousPageHelp)) {
                if currentPageIndex > 0 { currentPageIndex -= 1 }
            }
            Text("\(currentPageIndex + 1) / \(totalPages)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .accessibilityLabel(SpreadsheetPreviewLocalization.pageIndicatorAccessibility(current: currentPageIndex + 1, total: totalPages))
            pageButton(icon: "chevron.right", size: 9.5, weight: .bold, disabled: currentPageIndex >= totalPages - 1, label: SpreadsheetPreviewLocalization.text(.nextPageHelp)) {
                if currentPageIndex < totalPages - 1 { currentPageIndex += 1 }
            }
            pageButton(icon: "forward.end.fill", size: 8.5, disabled: currentPageIndex >= totalPages - 1, label: SpreadsheetPreviewLocalization.text(.lastPageHelp)) {
                currentPageIndex = max(0, totalPages - 1)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 3)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func pageButton(icon: String, size: CGFloat, weight: Font.Weight = .regular, disabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: weight))
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct SpreadsheetCellInspectorBarView: View {
    let selectedCoordinate: SpreadsheetCellCoordinate?
    let selectedCellContent: String?
    @Binding var isCellDetailPopoverPresented: Bool
    let onCopyCell: (SpreadsheetCellCoordinate, String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "target").font(.system(size: 9)).foregroundStyle(Color.accentColor)
                Text(selectedCoordinate?.excelReference ?? SpreadsheetPreviewLocalization.text(.noCellSelected))
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(selectedCoordinate != nil ? Color.accentColor : .secondary)
            }
            .frame(minWidth: 52, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)

            Divider().frame(height: 14)

            if let cellVal = selectedCellContent {
                let singleLinePreview = cellVal
                    .replacingOccurrences(of: "\r\n", with: " ↵ ")
                    .replacingOccurrences(of: "\n", with: " ↵ ")
                    .replacingOccurrences(of: "\r", with: " ↵ ")
                Text(singleLinePreview)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail).help(cellVal)
                Spacer(minLength: 4)
                Button(action: { isCellDetailPopoverPresented.toggle() }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).help(SpreadsheetPreviewLocalization.text(.viewFullCellHelp))
                .popover(isPresented: $isCellDetailPopoverPresented, arrowEdge: .bottom) {
                    SpreadsheetCellDetailPopoverView(
                        coordinateReference: selectedCoordinate?.excelReference ?? "",
                        cellValue: cellVal,
                        onCopy: {
                            if let c = selectedCoordinate { onCopyCell(c, cellVal) }
                        }
                    )
                }
                Button(action: {
                    if let c = selectedCoordinate { onCopyCell(c, cellVal) }
                }) {
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).help(SpreadsheetPreviewLocalization.text(.copyCellTextHelp))
            } else {
                Text(SpreadsheetPreviewLocalization.text(.inspectCellPrompt))
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.tail).foregroundStyle(.tertiary)
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4).frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}

struct SpreadsheetBottomStatusBarView: View {
    let metrics: SpreadsheetLayoutMetrics
    let tableState: SpreadsheetTableState
    let fileSizeString: String
    let isPreviewTruncated: Bool
    let maxPreviewRows: Int
    @Binding var pageSizeOption: SpreadsheetPageSizeOption
    @Binding var currentPageIndex: Int
    @Binding var isJumpPopoverPresented: Bool
    @Binding var jumpRowInput: String
    let onJump: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if tableState.isFiltered {
                    Text(SpreadsheetPreviewLocalization.filteredRowStatus(filtered: tableState.filteredRowCount, total: tableState.effectiveRowCount))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(SpreadsheetPreviewLocalization.rowCount(tableState.effectiveRowCount))
                }
                Text("•")
                Text(SpreadsheetPreviewLocalization.columnCount(tableState.maxColumnCount))
                if metrics.showsExtendedBottomStats {
                    Text("•")
                    Text(SpreadsheetPreviewLocalization.cellCount(tableState.totalCellCount))
                    Text("•")
                    Text(fileSizeString)
                }
                if isPreviewTruncated {
                    Text("•")
                    Text(SpreadsheetPreviewLocalization.truncatedStatus(maxRows: maxPreviewRows)).foregroundStyle(Color.orange)
                }
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)

            Spacer(minLength: 4)

            if metrics.showsInlineJumpAndPageSize {
                jumpButton
                pageSizeButton
            }
            if pageSizeOption.rawValue != -1 && tableState.totalPages(for: pageSizeOption) > 1 {
                SpreadsheetPaginationControlsView(currentPageIndex: $currentPageIndex, totalPages: tableState.totalPages(for: pageSizeOption))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5).frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var jumpButton: some View {
        Button(action: { isJumpPopoverPresented.toggle() }) {
            Label(SpreadsheetPreviewLocalization.text(.jumpButton), systemImage: "arrow.right.to.line.compact")
                .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 6).frame(height: 24)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .popover(isPresented: $isJumpPopoverPresented, arrowEdge: .bottom) {
            SpreadsheetJumpRowPopoverView(maxRow: tableState.effectiveRowCount, jumpRowInput: $jumpRowInput, onJump: onJump)
        }
    }

    private var pageSizeButton: some View {
        Button(action: {
            let entries = SpreadsheetPageSizeOption.allCases.map { opt in
                SpreadsheetPopupMenuEntry.action(title: opt.localizedDisplayName, isChecked: pageSizeOption == opt) {
                    pageSizeOption = opt
                    currentPageIndex = 0
                }
            }
            SpreadsheetPopupMenuInvoker.shared.present(entries)
        }) {
            Label(SpreadsheetPreviewLocalization.pageSizeMenu(pageSizeOption.localizedDisplayName), systemImage: "slider.horizontal.3")
                .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 6).frame(height: 24)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
    }
}

struct SpreadsheetExpandableSearchRowView: View {
    @Binding var searchQuery: String
    let onQueryChanged: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(.secondary)
            TextField(SpreadsheetPreviewLocalization.text(.filterCellsPlaceholder), text: $searchQuery)
                .textFieldStyle(.plain).font(.system(size: 11)).frame(maxWidth: .infinity)
                .onChange(of: searchQuery) { _, newQuery in onQueryChanged(newQuery) }
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = ""; onQueryChanged("") }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.65))
    }
}

struct SpreadsheetToastOverlayView: View {
    let message: String

    var body: some View {
        VStack {
            Spacer()
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.85)))
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                .transition(.move(edge: .bottom).combined(with: .opacity)).padding(.bottom, 16)
        }
    }
}

struct SpreadsheetFormatBadgeView: View {
    let badgeTitle: String

    init(badgeTitle: String) {
        self.badgeTitle = badgeTitle
    }

    init(isWorkbook: Bool, delimiterShortName: String) {
        self.badgeTitle = isWorkbook ? "XLSX" : delimiterShortName
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tablecells.fill")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.accentColor)
            Text(badgeTitle)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct SpreadsheetStatusBadgeView: View {
    let metrics: SpreadsheetLayoutMetrics
    let isPreviewTruncated: Bool
    let canSaveInPlace: Bool
    let isEdited: Bool

    private var isCompactIconTier: Bool {
        metrics.tier == .narrow || metrics.tier == .regular
    }

    var body: some View {
        if isPreviewTruncated {
            let label = metrics.tier == .wide
                ? SpreadsheetPreviewLocalization.text(.previewCappedReadOnly)
                : SpreadsheetPreviewLocalization.text(.readOnlyBadge)
            if isCompactIconTier {
                compactIconPill(icon: "exclamationmark.triangle.fill", helpText: label, foreground: .orange, background: Color.orange.opacity(0.12))
            } else {
                badgePill(text: label, foreground: .orange, background: Color.orange.opacity(0.12))
            }
        } else if !canSaveInPlace {
            let label = SpreadsheetPreviewLocalization.text(.readOnlyBadge)
            if isCompactIconTier {
                compactIconPill(icon: "lock.fill", helpText: label, foreground: .secondary, background: Color.primary.opacity(0.08))
            } else {
                badgePill(text: label, foreground: .secondary, background: Color.primary.opacity(0.08))
            }
        } else if isEdited {
            let label = SpreadsheetPreviewLocalization.text(.unsavedBadge)
            if isCompactIconTier {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .help(label)
            } else {
                badgePill(text: label, foreground: .orange, background: Color.orange.opacity(0.12))
            }
        }
    }

    private func compactIconPill(icon: String, helpText: String, foreground: Color, background: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 22, height: 22)
            .background(background)
            .clipShape(Circle())
            .fixedSize(horizontal: true, vertical: false)
            .help(helpText)
    }

    private func badgePill(text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(background)
            .clipShape(Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct SpreadsheetModePickerView: View {
    let metrics: SpreadsheetLayoutMetrics
    @Binding var mode: SpreadsheetPreviewMode
    let onSelectMode: (SpreadsheetPreviewMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SpreadsheetPreviewMode.allCases) { item in
                Button(action: { onSelectMode(item) }) {
                    Group {
                        if metrics.tier == .narrow {
                            Image(systemName: item.icon)
                                .frame(width: 26, height: 22)
                        } else if metrics.tier == .wide {
                            Label(item.localizedTitle, systemImage: item.icon)
                                .padding(.horizontal, 6)
                                .frame(height: 22)
                        } else {
                            Text(item.localizedTitle)
                                .padding(.horizontal, 6)
                                .frame(height: 22)
                        }
                    }
                    .font(.system(size: 10.5, weight: mode == item ? .bold : .medium))
                    .lineLimit(1)
                    .background(mode == item ? Color.accentColor : Color.clear)
                    .foregroundStyle(mode == item ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .help(item.localizedTitle)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Spreadsheet Grid View

/// Declarative spreadsheet table grid view backed by TTSpreadsheetView.
public struct SpreadsheetGridView: View {
    public let paginatedDataRows: [SpreadsheetRowItem]
    public let headerNames: [String]
    public let maxColumnCount: Int
    public let useFirstRowAsHeader: Bool
    public let searchQuery: String
    @Binding public var selectedCoordinate: SpreadsheetCellCoordinate?
    public let columnWidths: [Int: CGFloat]
    public let availableWidth: CGFloat
    public let selectedDelimiter: TTSpreadsheetDelimiter
    public let onCopyText: (String, String) -> Void
    public let onFilterQuery: (String) -> Void

    public init(
        paginatedDataRows: [SpreadsheetRowItem],
        headerNames: [String],
        maxColumnCount: Int,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        selectedCoordinate: Binding<SpreadsheetCellCoordinate?>,
        columnWidths: [Int: CGFloat],
        availableWidth: CGFloat = 0.0,
        selectedDelimiter: TTSpreadsheetDelimiter,
        onCopyText: @escaping (String, String) -> Void,
        onFilterQuery: @escaping (String) -> Void
    ) {
        self.paginatedDataRows = paginatedDataRows
        self.headerNames = headerNames
        self.maxColumnCount = maxColumnCount
        self.useFirstRowAsHeader = useFirstRowAsHeader
        self.searchQuery = searchQuery
        self._selectedCoordinate = selectedCoordinate
        self.columnWidths = columnWidths
        self.availableWidth = availableWidth
        self.selectedDelimiter = selectedDelimiter
        self.onCopyText = onCopyText
        self.onFilterQuery = onFilterQuery
    }

    private var visibleSelectedCell: (row: Int, column: Int)? {
        guard let coord = selectedCoordinate else { return nil }
        guard let visibleRow = paginatedDataRows.firstIndex(where: { $0.originalIndex - 1 == coord.row }) else {
            return nil
        }
        return (row: visibleRow, column: coord.column)
    }

    public var body: some View {
        TTSpreadsheetView(
            headers: headerNames,
            rows: paginatedDataRows.map(\.cells),
            rowNumbers: paginatedDataRows.map(\.originalIndex),
            columnWidths: columnWidths,
            availableWidth: availableWidth,
            minColumnWidth: 85.0,
            rowHeight: 28.0,
            alternateRowColor: Color.primary.opacity(0.025),
            headerBackgroundColor: Color(NSColor.controlBackgroundColor),
            selectedCell: visibleSelectedCell,
            onCellSelect: { rowIndex, colIndex in
                guard rowIndex >= 0, rowIndex < paginatedDataRows.count else { return }
                let originalRow = max(0, paginatedDataRows[rowIndex].originalIndex - 1)
                selectedCoordinate = SpreadsheetCellCoordinate(row: originalRow, column: max(0, colIndex))
            },
            onCopyCell: { rowIndex, colIndex, cellText in
                guard rowIndex >= 0, rowIndex < paginatedDataRows.count else { return }
                let originalRow = max(0, paginatedDataRows[rowIndex].originalIndex - 1)
                let coord = SpreadsheetCellCoordinate(row: originalRow, column: max(0, colIndex))
                selectedCoordinate = coord
                onCopyText(cellText, SpreadsheetPreviewLocalization.copiedCellContent(coord.excelReference))
            }
        )
    }
}

